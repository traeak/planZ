//! The kernel's random number generator: a ChaCha20 stream that is
//! rekeyed on every read, seeded once from clock jitter (and from the
//! machine's hardware generator if it has one).
//! from 9/port/random.c; nrand and rand from libc/port/nrand.c, rand.c
//!
//! DIFF:
//!   - libsec is replaced by std.crypto: ChaCha20 (IETF, 12-byte nonce,
//!     32-bit block counter, which is what setupChachastate(.., 12, 20)
//!     selects) and SHA-512.  std's ChaCha is a function of
//!     (key, nonce, counter), so the generator's state is the key and
//!     the nonce where the C keeps a Chachastate; the stream of bytes
//!     is the same construction: block 0 rekeys, the data is encrypted
//!     from block 1 with the old key.
//!   - The generator's state is a static variable; the C allocates it
//!     with secalloc.  The Seedbuf has no SHA2_512state: the hash is
//!     done in one call.
//!   - hwrandbuf takes a slice.
//!   - randomread takes a slice and returns its length.
//!   - The seeding loop reads the Seedbuf through a volatile pointer,
//!     because the timer interrupt changes it underneath the loop; the
//!     Plan 9 compiler does not keep such values in registers.
//!   - nrand and rand come from libc in 9front (the kernel links them
//!     with its own lrand); they are here because lrand is.

const std = @import("std");
const arch = @import("../arch.zig");
const portdat = @import("portdat.zig");
const taslock = @import("taslock.zig");
const qlockmod = @import("qlock.zig");
const alloc = @import("alloc.zig");
const proc = @import("proc.zig");
const portclock = @import("portclock.zig");

const ChaCha = std.crypto.stream.chacha.ChaCha20IETF;
const Sha512 = std.crypto.hash.sha2.Sha512;

const Lock = portdat.Lock;
const QLock = portdat.QLock;
const Timer = portdat.Timer;
const Ureg = arch.Ureg;
const lock = taslock.lock;
const unlock = taslock.unlock;
const qlock = qlockmod.qlock;
const qunlock = qlockmod.qunlock;

const MS2HZ = 1000 / arch.mem.HZ; // millisec per clock tick

/// machine specific hardware random number generator
pub var hwrandbuf: ?*const fn ([]u8) void = null;

const Rs = struct {
    lock: QLock = .{},
    key: [ChaCha.key_length]u8 = @splat(0), // input[4..12] in the C
    nonce: [ChaCha.nonce_length]u8 = @splat(0), // input[13..16]
};

var rs: Rs = .{};

const Seedbuf = struct {
    randomcount: u32 = 0,
    buf: [64]u8 = @splat(0),
    nbuf: u8 = 0,
    next: u8 = 0,
    bits: u16 = 0,
};

fn randomsample(_: ?*Ureg, t: *Timer) void {
    const s: *volatile Seedbuf = @ptrCast(@alignCast(t.ta.?));

    if (s.randomcount == 0 or s.nbuf >= s.buf.len)
        return;
    s.bits = (s.bits << 2) ^ @as(u16, @truncate(s.randomcount));
    s.randomcount = 0;
    s.next += 1;
    if (s.next < 8 / 2)
        return;
    s.next = 0;
    s.buf[s.nbuf] ^= @truncate(s.bits);
    s.nbuf += 1;
}

fn randomseed(_: ?*anyopaque) void {
    const up = arch.up().?;

    const sp: *Seedbuf = @ptrCast(@alignCast(alloc.secalloc(@sizeOf(Seedbuf))));
    sp.* = .{};

    if (hwrandbuf) |f|
        f(&sp.buf);

    const s: *volatile Seedbuf = sp;

    // Frequency close but not equal to HZ
    up.timer.tns = @as(i64, MS2HZ + 3) * 1000000;
    up.timer.tmode = portdat.Tperiodic;
    up.timer.tt = null;
    up.timer.ta = sp;
    up.timer.tf = randomsample;
    portclock.timeradd(&up.timer);
    while (s.nbuf < sp.buf.len) {
        s.randomcount +%= 1;
        if (s.randomcount <= 100000)
            continue;
        if (proc.anyhigher())
            proc.sched();
    }
    portclock.timerdel(&up.timer);

    Sha512.hash(&sp.buf, &sp.buf, .{});
    rs.key = sp.buf[0..32].*;
    rs.nonce = sp.buf[32..44].*;
    qunlock(&rs.lock);

    alloc.secfree(sp);

    proc.pexit("", true);
}

pub fn randominit() void {
    qlock(&rs.lock); // randomseed() unlocks once seeded
    proc.kproc("randomseed", randomseed, null);
}

pub fn randomread(p: []u8) usize {
    if (p.len == 0)
        return 0;

    if (hwrandbuf) |f|
        f(p);

    // copy chacha state, rekey and increment iv
    qlock(&rs.lock);
    var key = rs.key;
    const nonce = rs.nonce;
    ChaCha.xor(&rs.key, &rs.key, 0, key, nonce);
    for (0..3) |i| {
        const w = rs.nonce[4 * i ..][0..4];
        const v = std.mem.readInt(u32, w, .little) +% 1;
        std.mem.writeInt(u32, w, v, .little);
        if (v != 0)
            break;
    }
    qunlock(&rs.lock);

    // encrypt the buffer, can fault
    ChaCha.xor(p, p, 1, key, nonce);

    // prevent state leakage
    std.crypto.secureZero(u8, &key);

    return p.len;
}

/// used by fastrand()
pub fn genrandom(p: []u8) void {
    _ = randomread(p);
}

var lrandseeded: bool = false;
var lrands: [2]u64 = .{ 0, 0 };
var lrandlk: Lock = .{};

/// used by rand(),nrand()
pub fn lrand() i32 {
    // xoroshiro128+ algorithm
    const s = &lrands;

    if (!lrandseeded) {
        _ = randomread(std.mem.asBytes(s));
        lrandseeded = (s[0] | s[1]) != 0;
    }

    lock(&lrandlk);
    const r: u32 = @truncate((s[0] +% s[1]) >> 33);
    s[1] ^= s[0];
    s[0] = (s[0] << 55 | s[0] >> 9) ^ s[1] ^ (s[1] << 14);
    s[1] = (s[1] << 36 | s[1] >> 28);
    unlock(&lrandlk);

    return @intCast(r);
}

const MASK = 0x7fffffff;

pub fn nrand(n: i32) i32 {
    if (n < 0)
        return n;
    if (n == 1)
        return 0;
    // and if n == 0, you deserve what you get
    const slop = @rem(@as(i32, MASK), n);
    var v = lrand();
    while (v <= slop)
        v = lrand();
    return @rem(v, n);
}

pub fn rand() i32 {
    return lrand() & 0x7fff;
}
