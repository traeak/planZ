//! Boot-time self-test.  Not part of 9front.
//!
//! Runs as a kernel process once the scheduler is going and exercises
//! what has been ported, ending with "selftest ok" on the console, which
//! is the line `zig build test-boot` waits for.
//!
//! plan9.ini settings:
//!   *selftest=fault   end with a deliberate kernel fault instead
//!   *schedtest=N      run the scheduling test for N seconds (default 3)

const std = @import("std");
const arch = @import("../arch.zig");
const portdat = @import("portdat.zig");
const taslock = @import("taslock.zig");
const ql = @import("qlock.zig");
const alloc = @import("alloc.zig");
const proc = @import("proc.zig");
const tod = @import("tod.zig");
const alarm = @import("alarm.zig");
const fcall = @import("fcall");
const lib = @import("lib.zig");
const chan = @import("chan.zig");
const devmod = @import("dev.zig");
const pgrp = @import("pgrp.zig");
const devenv = @import("devenv.zig");
const p9 = @import("print.zig");

const print = p9.print;
const panic = p9.panic;
const mem = arch.mem;
const Rendez = portdat.Rendez;

pub fn selftest(_: ?*anyopaque) void {
    const conf = arch.conf;
    print("%lludM memory: %lludM kernel data, %lludM user\n", .{
        conf.npage * mem.BY2PG / mem.MiB,
        (conf.npage - conf.upages) * mem.BY2PG / mem.MiB,
        conf.upages * mem.BY2PG / mem.MiB,
    });

    malloctest();
    sleeptest();
    nstest() catch |err| panic("selftest: name space: %s", .{proc.errtext(err)});
    schedtest();

    if (arch.getconf("*selftest")) |t| {
        if (std.mem.eql(u8, t, "fault")) {
            print("selftest: faulting on purpose\n", .{});
            const p: *volatile u32 = @ptrFromInt(0x1234);
            p.* = 1;
        }
    }
    print("selftest ok\n", .{});

    // Nothing left to do; a kernel process made at boot must not exit.
    var r: Rendez = .{};
    while (true) proc.sleep(&r, proc.return0, null) catch {};
}

// Kernel stacks are small: the big tables are static.
var slots: [128]?[]u8 = @splat(null);

fn malloctest() void {
    var seed: u32 = 1;
    var rounds: usize = 0;
    while (rounds < 20000) : (rounds += 1) {
        seed = seed *% 1103515245 +% 12345;
        const i = (seed >> 16) % slots.len;
        if (slots[i]) |s| {
            for (s) |c| {
                if (c != @as(u8, @truncate(i)))
                    panic("selftest: malloc block %d damaged", .{i});
            }
            alloc.free(s.ptr);
            slots[i] = null;
            continue;
        }
        // Mostly small, now and then large.
        const n: usize = if (seed & 0xff == 0) 100000 + (seed >> 8) % 400000 else 1 + (seed >> 8) % 3000;
        const p = alloc.malloc(n) orelse panic("selftest: malloc(%lud) failed", .{n});
        for (p[0..n]) |c| {
            if (c != 0) panic("selftest: malloc memory not zeroed", .{});
        }
        @memset(p[0..n], @truncate(i));
        slots[i] = p[0..n];
    }
    for (&slots) |*s| {
        if (s.*) |b| alloc.free(b.ptr);
        s.* = null;
    }

    const a = alloc.mallocalign(3 * mem.BY2PG, mem.BY2PG, 0, 0) orelse panic("selftest: mallocalign failed", .{});
    if (@intFromPtr(a) % mem.BY2PG != 0) panic("selftest: mallocalign not aligned", .{});
    if (alloc.msize(a) < 3 * mem.BY2PG) panic("selftest: msize of aligned block", .{});
    alloc.free(a);

    var r = alloc.malloc(10).?;
    @memcpy(r[0..10], "0123456789");
    r = alloc.realloc(r, 5000).?;
    if (!std.mem.eql(u8, r[0..10], "0123456789")) panic("selftest: realloc lost data", .{});
    alloc.free(r);

    stdalloctest();

    // DIFF from earlier milestones: no check that the total in use is
    // back where it was.  Drivers and the network stack have processes
    // of their own now, allocating while this runs.
    print("selftest: malloc ok, %lludK in the arena\n", .{alloc.mallocstats().cursize / mem.KiB});
}

/// The standard library's containers on the kernel allocator.
fn stdalloctest() void {
    const gpa = alloc.allocator;

    var list: std.ArrayList(u32) = .empty;
    defer list.deinit(gpa);
    var i: u32 = 0;
    while (i < 5000) : (i += 1)
        list.append(gpa, i * 3) catch panic("selftest: ArrayList append", .{});
    for (list.items, 0..) |v, k| {
        if (v != k * 3) panic("selftest: ArrayList lost data at %lud", .{k});
    }

    var map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer map.deinit(gpa);
    i = 0;
    while (i < 1000) : (i += 1)
        map.put(gpa, i, i * i) catch panic("selftest: HashMap put", .{});
    i = 0;
    while (i < 1000) : (i += 1) {
        if (map.get(i) != i * i) panic("selftest: HashMap lost key %ud", .{i});
    }

    // An over-aligned allocation and a typed one.
    const page = gpa.alignedAlloc(u8, .fromByteUnits(mem.BY2PG), 100) catch panic("selftest: alignedAlloc", .{});
    if (@intFromPtr(page.ptr) % mem.BY2PG != 0) panic("selftest: alignedAlloc not aligned", .{});
    gpa.free(page);
    const one = gpa.create(Rendez) catch panic("selftest: create", .{});
    gpa.destroy(one);
}

/// The clock, the timers and time of day agree on how long 250ms is.
fn sleeptest() void {
    var r: Rendez = .{};
    const t0 = tod.uptime();
    const k0 = arch.MACHP(0).ticks;
    proc.tsleep(&r, proc.return0, null, 250) catch panic("selftest: tsleep interrupted", .{});
    const ms = @divTrunc(tod.uptime() - t0, 1000000);
    const ticks = arch.MACHP(0).ticks -% k0;
    print("selftest: slept %lldms, %lud ticks\n", .{ ms, ticks });
    // Never early.  Late by up to a scheduling quantum: the process that
    // seeds the random number generator spins at the same priority for
    // the first seconds after boot.
    if (ms < 250 or ms > 400)
        panic("selftest: tsleep(250) took %lldms", .{ms});
    if (ticks < mem.HZ / 4 - 2 or ticks > mem.HZ / 4 + 15)
        panic("selftest: %lud clock ticks in 250ms", .{ticks});
}

// The name space test: what init does first, done from inside the
// kernel.  There are no system calls yet, so these helpers stand in
// for the ones in sysfile.c.

const Chan = portdat.Chan;
const Error = proc.Error;

fn dev(c: *Chan) *const devmod.Dev {
    return devmod.devtab[c.type];
}

/// bind(2): from sysfile.c:/^bindmount without the mount half.
fn bind(new: []const u8, old: []const u8, flag: u32) Error!void {
    const c0 = try chan.namec(new, portdat.Abind, 0, 0);
    defer chan.cclose(c0);
    const c1 = try chan.namec(old, portdat.Amount, 0, 0);
    defer chan.cclose(c1);
    try chan.cmount(c0, c1, flag, "");
}

fn open(name: []const u8, omode: u32) Error!*Chan {
    return chan.namec(name, portdat.Aopen, omode, 0);
}

/// Read a whole small file into buf.
fn readfile(name: []const u8, buf: []u8) Error![]u8 {
    const c = try open(name, lib.OREAD);
    defer chan.cclose(c);
    var n: usize = 0;
    while (n < buf.len) {
        const k = try dev(c).read(c, buf[n..], @intCast(n));
        if (k == 0) break;
        n += k;
    }
    return buf[0..n];
}

fn writefile(name: []const u8, data: []const u8) Error!void {
    const c = try open(name, lib.OWRITE);
    defer chan.cclose(c);
    const n = try dev(c).write(c, data, 0);
    if (n != data.len) panic("selftest: short write to %s", .{name});
}

/// Whether the directory has an entry of that name.
fn hasentry(dirname: []const u8, want: []const u8) Error!bool {
    const S = struct {
        var buf: [2048]u8 = undefined;
        var strs: [256]u8 = undefined;
    };
    const c = try open(dirname, lib.OREAD);
    defer chan.cclose(c);
    var found = false;
    while (true) {
        const n = try dev(c).read(c, &S.buf, c.offset);
        if (n == 0) break;
        c.offset += @intCast(n);
        var i: usize = 0;
        while (i + fcall.BIT16SZ <= n) {
            const m = fcall.BIT16SZ + fcall.GBIT16(&S.buf, i);
            var d: portdat.Dir = .{};
            if (i + m > n or fcall.convM2D(S.buf[i..][0..m], &d, &S.strs) == 0)
                panic("selftest: bad directory entry in %s", .{dirname});
            if (std.mem.eql(u8, d.name, want)) found = true;
            i += m;
        }
    }
    return found;
}

/// The error text a failing namec leaves.
fn nameerror(name: []const u8, amode: u32) []const u8 {
    if (chan.namec(name, amode, lib.OREAD, 0)) |c| {
        chan.cclose(c);
        return "";
    } else |err| return proc.errtext(err);
}

fn expecterr(name: []const u8, amode: u32, want: []const u8) void {
    const got = nameerror(name, amode);
    if (!std.mem.eql(u8, got, want))
        panic("selftest: namec %s: got error \"%s\", expected \"%s\"", .{ name, got, want });
}

var pipetest: struct {
    c: ?*Chan = null,
    r: Rendez = .{},
    got: usize = 0,
    buf: [64]u8 = undefined,
    done: bool = false,
} = .{};

fn piped(_: ?*anyopaque) bool {
    return pipetest.done;
}

/// Blocks in read until the other end is written.
fn pipereader(_: ?*anyopaque) void {
    const c = pipetest.c.?;
    pipetest.got = dev(c).read(c, &pipetest.buf, 0) catch 0;
    pipetest.done = true;
    _ = proc.wakeup(&pipetest.r);
    proc.pexit("", true);
}

fn nstest() Error!void {
    const up = arch.up().?;
    var buf: [256]u8 = undefined;

    // What proc0 does in 9/port/userinit.c: a name space, environment
    // and file descriptor group of our own, rooted at #/.
    const oldpg = up.pgrp;
    up.pgrp = try pgrp.newpgrp();
    if (oldpg) |pg| pgrp.closepgrp(pg);
    up.egrp = try devenv.newegrp();
    up.fgrp = try pgrp.dupfgrp(null);
    up.rgrp = try pgrp.newrgrp();

    // These are o.k. because rootinit is null.
    // Then early kproc's will have a root and dot.
    up.slash = try chan.namec("#/", portdat.Atodir, 0, 0);
    chan.pathclose(up.slash.?.path);
    up.slash.?.path = chan.newpath("/");
    up.dot = try chan.cclone(up.slash.?);

    // The root device has the directories to mount things on.
    for ([_][]const u8{ "dev", "env", "fd", "srv", "proc", "boot" }) |name| {
        if (!try hasentry("/", name)) panic("selftest: no /%s in the root", .{name});
    }

    // What 9/port/initcode.c does before it execs /boot/boot.
    try bind("#c", "/dev", lib.MAFTER);
    try bind("#d", "/fd", lib.MREPL);
    try bind("#e", "/env", lib.MREPL | lib.MCREATE);
    try bind("#s", "/srv", lib.MREPL | lib.MCREATE);

    try writefile("/dev/cons", "selftest: hello from /dev/cons\n");

    // Through the union at /dev, relative to dot, and back out again.
    // (Reading the union directory /dev itself needs unionread, which is
    // part of the read system call; list the device instead.)
    if (!try hasentry("#c", "cons") or !try hasentry("#c", "time"))
        panic("selftest: #c lacks cons or time", .{});
    const c = try chan.namec("dev/../dev/./cons", portdat.Aaccess, 0, 0);
    if (!std.mem.eql(u8, chan.chanpath(c), "/dev/cons"))
        panic("selftest: path of dev/../dev/./cons is %s", .{chan.chanpath(c)});
    chan.cclose(c);
    const dd = try chan.namec("/dev/..", portdat.Atodir, 0, 0);
    if (!std.mem.eql(u8, chan.chanpath(dd), "/"))
        panic("selftest: path of /dev/.. is %s", .{chan.chanpath(dd)});
    chan.cclose(dd);

    // Files programs parse.
    const t = try readfile("/dev/time", &buf);
    if (t.len < 4 * portdat.NUMSIZE) panic("selftest: /dev/time is \"%s\"", .{t});
    if ((try readfile("/dev/null", &buf)).len != 0) panic("selftest: /dev/null has contents", .{});
    const pid = try readfile("/dev/pid", &buf);
    const want = std.fmt.parseInt(u32, std.mem.trim(u8, pid, " "), 10) catch 0;
    if (want != up.pid) panic("selftest: /dev/pid says \"%s\", pid is %ud", .{ pid, up.pid });

    // Errors carry the name, as user programs print them.
    expecterr("/nosuch/file", portdat.Aopen, "file does not exist: '/nosuch'");
    expecterr("/dev/cons/x", portdat.Aopen, "not a directory: '/dev/cons'");
    expecterr("#Z", portdat.Aopen, "unknown device in # filename");
    expecterr("/dev/bad\x01name", portdat.Aopen, "bad character in file name: '/dev/bad\x01name'");

    // The environment: create, write, read back, remove.
    const e = try chan.namec("/env/planz", portdat.Acreate, lib.OWRITE, 0o666);
    _ = try dev(e).write(e, "nine", 0);
    chan.cclose(e);
    if (!std.mem.eql(u8, try readfile("/env/planz", &buf), "nine"))
        panic("selftest: /env/planz did not read back", .{});
    try devenv.ksetenv("cputype", "amd64", false);
    if (!std.mem.eql(u8, try readfile("#e/cputype", &buf), "amd64"))
        panic("selftest: ksetenv", .{});
    const rm = try chan.namec("/env/planz", portdat.Aremove, 0, 0);
    try dev(rm).remove(rm);
    chan.cclose(rm);
    expecterr("/env/planz", portdat.Aopen, "file does not exist: '/env/planz'");

    // A pipe, as syspipe makes one: both ends from one attach.  The
    // reader is another process, asleep in read when the write arrives.
    const p = try chan.namec("#|", portdat.Atodir, 0, 0);
    var p0 = try chan.cclone(p);
    try chan.walk(&p0, &.{"data"}, true, null);
    var p1 = try chan.cclone(p);
    try chan.walk(&p1, &.{"data1"}, true, null);
    chan.cclose(p);
    p0 = try dev(p0).open(p0, lib.ORDWR);
    p1 = try dev(p1).open(p1, lib.ORDWR);
    pipetest.c = p1;
    proc.kproc("pipereader", pipereader, null);
    pause(20);
    const msg = "through the pipe";
    if (try dev(p0).write(p0, msg, 0) != msg.len) panic("selftest: short pipe write", .{});
    while (!pipetest.done) mustsleep(&pipetest.r, piped, null);
    if (!std.mem.eql(u8, pipetest.buf[0..pipetest.got], msg))
        panic("selftest: pipe delivered \"%s\"", .{pipetest.buf[0..pipetest.got]});
    // With one end closed, the other reads end of file.
    chan.cclose(p0);
    if (try dev(p1).read(p1, &buf, 0) != 0) panic("selftest: no EOF on a closed pipe", .{});
    chan.cclose(p1);

    // A copy of the name space is independent of the original.
    const copy = try pgrp.newpgrp();
    try pgrp.pgrpcpy(copy, up.pgrp.?, pgrp.RFNAMEG);
    const mine = up.pgrp.?;
    const und = try chan.namec("/env", portdat.Amount, 0, 0);
    try chan.cunmount(und, null);
    chan.cclose(und);
    expecterr("/env/cputype", portdat.Aopen, "file does not exist: '/env/cputype'");
    up.pgrp = copy;
    if (!std.mem.eql(u8, try readfile("/env/cputype", &buf), "amd64"))
        panic("selftest: copied name space lost /env", .{});
    up.pgrp = mine;
    pgrp.closepgrp(copy);
    try bind("#e", "/env", lib.MREPL | lib.MCREATE);

    print("selftest: name space ok\n", .{});
}

// The scheduling test: kernel processes that block on each other in
// every way the kernel has so far, with processor hogs to force
// preemption, all running until told to stop.

var stop: bool = false;

/// Workers still running, and where the test waits for them.
var live: struct {
    lock: taslock.Lock = .{},
    n: i32 = 0,
    r: Rendez = .{},
} = .{};

fn stopping() bool {
    return @atomicLoad(bool, &stop, .seq_cst);
}

fn spawn(name: []const u8, f: *const fn (?*anyopaque) void, arg: ?*anyopaque) void {
    taslock.lock(&live.lock);
    live.n += 1;
    taslock.unlock(&live.lock);
    proc.kproc(name, f, arg);
}

/// A worker's last act.
fn done() noreturn {
    taslock.lock(&live.lock);
    live.n -= 1;
    taslock.unlock(&live.lock);
    _ = proc.wakeup(&live.r);
    proc.pexit("", true);
}

fn alldone(_: ?*anyopaque) bool {
    return live.n == 0;
}

/// Sleep that only its wakeup should end.
fn mustsleep(r: *Rendez, f: *const fn (?*anyopaque) bool, arg: ?*anyopaque) void {
    proc.sleep(r, f, arg) catch panic("selftest: sleep interrupted", .{});
}

fn pause(ms: u32) void {
    var r: Rendez = .{};
    proc.tsleep(&r, proc.return0, null, ms) catch {};
}

// Ping-pong: two processes hand a turn back and forth.

var pp: struct {
    turn: usize = 0,
    r: [2]Rendez = .{ .{}, .{} },
    count: [2]u32 = .{ 0, 0 },
} = .{};

fn myturn(arg: ?*anyopaque) bool {
    return pp.turn == @intFromPtr(arg) or stopping();
}

fn pingpong(arg: ?*anyopaque) void {
    const me = @intFromPtr(arg);
    while (!stopping()) {
        mustsleep(&pp.r[me], myturn, arg);
        if (pp.turn != me) break;
        pp.count[me] += 1;
        pp.turn = 1 - me;
        _ = proc.wakeup(&pp.r[1 - me]);
    }
    _ = proc.wakeup(&pp.r[1 - me]);
    done();
}

// Producer and consumer on a small buffer under a QLock.

var pc: struct {
    q: portdat.QLock = .{},
    buf: [8]u32 = undefined,
    n: usize = 0,
    ri: usize = 0,
    wi: usize = 0,
    notfull: Rendez = .{},
    notempty: Rendez = .{},
    produced: u32 = 0,
    consumed: u32 = 0,
} = .{};

fn hasroom(_: ?*anyopaque) bool {
    return pc.n < pc.buf.len or stopping();
}

fn hasdata(_: ?*anyopaque) bool {
    return pc.n > 0 or stopping();
}

fn producer(_: ?*anyopaque) void {
    while (!stopping()) {
        mustsleep(&pc.notfull, hasroom, null);
        ql.qlock(&pc.q);
        if (pc.n < pc.buf.len) {
            pc.buf[pc.wi] = pc.produced;
            pc.wi = (pc.wi + 1) % pc.buf.len;
            pc.n += 1;
            pc.produced += 1;
        }
        ql.qunlock(&pc.q);
        _ = proc.wakeup(&pc.notempty);
    }
    _ = proc.wakeup(&pc.notempty);
    done();
}

fn consumer(_: ?*anyopaque) void {
    while (!stopping()) {
        mustsleep(&pc.notempty, hasdata, null);
        ql.qlock(&pc.q);
        if (pc.n > 0) {
            const v = pc.buf[pc.ri];
            pc.ri = (pc.ri + 1) % pc.buf.len;
            pc.n -= 1;
            if (v != pc.consumed)
                panic("selftest: consumer got %ud, expected %ud", .{ v, pc.consumed });
            pc.consumed += 1;
        }
        ql.qunlock(&pc.q);
        _ = proc.wakeup(&pc.notfull);
    }
    _ = proc.wakeup(&pc.notfull);
    done();
}

// Hogs never give up the processor; only the clock gets it back.

var hogcount: [3]u64 = @splat(0);

fn hog(arg: ?*anyopaque) void {
    const c: *volatile u64 = @ptrCast(@alignCast(arg.?));
    while (!stopping()) c.* += 1;
    done();
}

// Readers and one writer on an RWLock.  The writer breaks the invariant
// a == b for a while with the lock held; no reader may see that.

var rw: struct {
    l: portdat.RWLock = .{},
    a: u32 = 0,
    b: u32 = 0,
    reads: [3]u32 = @splat(0),
    writes: u32 = 0,
} = .{};

fn reader(arg: ?*anyopaque) void {
    const me = @intFromPtr(arg);
    while (!stopping()) {
        ql.rlock(&rw.l);
        const a = rw.a;
        proc.yield();
        if (a != rw.b)
            panic("selftest: reader saw a=%ud b=%ud", .{ a, rw.b });
        rw.reads[me] += 1;
        ql.runlock(&rw.l);
    }
    done();
}

fn writer(_: ?*anyopaque) void {
    while (!stopping()) {
        ql.wlock(&rw.l);
        rw.a += 1;
        pause(1);
        rw.b += 1;
        rw.writes += 1;
        ql.wunlock(&rw.l);
        pause(1);
    }
    done();
}

// Two processes add to one counter under a spin lock.

var sl: struct {
    l: taslock.Lock = .{},
    total: u64 = 0,
    mine: [2]u64 = .{ 0, 0 },
} = .{};

fn spinner(arg: ?*anyopaque) void {
    const me = @intFromPtr(arg);
    while (!stopping()) {
        taslock.lock(&sl.l);
        const t = sl.total;
        // Long enough inside the lock that the clock interrupts it.
        var i: u32 = 0;
        while (i < 2000) : (i += 1) std.mem.doNotOptimizeAway(i);
        sl.total = t + 1;
        taslock.unlock(&sl.l);
        sl.mine[me] += 1;
    }
    done();
}

// Churn: make short-lived processes one after another, so process
// slots, pids and stacks are freed and used again.

var churn: struct {
    r: Rendez = .{},
    finished: bool = false,
    made: u32 = 0,
    sum: u64 = 0,
} = .{};

fn childdone(_: ?*anyopaque) bool {
    return churn.finished;
}

fn child(arg: ?*anyopaque) void {
    churn.sum += @intFromPtr(arg);
    churn.finished = true;
    _ = proc.wakeup(&churn.r);
    proc.pexit("", true);
}

fn churner(_: ?*anyopaque) void {
    while (!stopping()) {
        churn.finished = false;
        proc.kproc("child", child, @ptrFromInt(churn.made + 1));
        mustsleep(&churn.r, childdone, null);
        churn.made += 1;
    }
    done();
}

// Notes: one ends a timed sleep early, one ends the wait for a QLock,
// and an alarm does the same from the alarm process.

var nt: struct {
    sleeper: ?*portdat.Proc = null,
    locker: ?*portdat.Proc = null,
    held: portdat.QLock = .{},
    slept: bool = false,
    locked: bool = false,
    alarmed: bool = false,
} = .{};

fn notesleeper(_: ?*anyopaque) void {
    nt.sleeper = arch.up();
    var r: Rendez = .{};
    if (proc.tsleep(&r, proc.return0, null, 60000)) |_| {
        panic("selftest: sleep was not interrupted", .{});
    } else |err| {
        if (err != error.Eintr) panic("selftest: sleep: wrong error", .{});
        nt.slept = true;
    }
    done();
}

fn notelocker(_: ?*anyopaque) void {
    nt.locker = arch.up();
    if (ql.eqlock(&nt.held)) |_| {
        panic("selftest: eqlock was not interrupted", .{});
    } else |err| {
        if (err != error.Eintr) panic("selftest: eqlock: wrong error", .{});
        nt.locked = true;
    }
    done();
}

fn alarmed(_: ?*anyopaque) void {
    _ = alarm.procalarm(100);
    var r: Rendez = .{};
    const t0 = tod.uptime();
    if (proc.tsleep(&r, proc.return0, null, 60000)) |_| {
        panic("selftest: alarm did not interrupt", .{});
    } else |_| {
        const ms = @divTrunc(tod.uptime() - t0, 1000000);
        // Late is allowed for: the hogs are in the way at first.
        if (ms < 90 or ms > 2000)
            panic("selftest: alarm(100) arrived after %lldms", .{ms});
        nt.alarmed = true;
    }
    done();
}

// Every processor runs processes: one process is wired to each and
// reports where it found itself.

var wiredon: [arch.mem.MAXMACH]i32 = @splat(-1);

fn wiredproc(arg: ?*anyopaque) void {
    const want = @intFromPtr(arg);
    proc.procwired(arch.up().?, @intCast(want));
    // Wiring takes effect the next time the process is scheduled.
    pause(10);
    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        const on = arch.m().machno;
        if (on != want)
            panic("selftest: process wired to cpu%lud ran on cpu%d", .{ want, on });
        proc.yield();
        pause(1);
    }
    wiredon[want] = arch.m().machno;
    done();
}

fn schedtest() void {
    var secs: u32 = 3;
    if (arch.getconf("*schedtest")) |s|
        secs = std.fmt.parseInt(u32, s, 10) catch secs;

    const pid0 = arch.up().?.pid;
    ql.qlock(&nt.held);

    spawn("ping", pingpong, @ptrFromInt(0));
    spawn("pong", pingpong, @ptrFromInt(1));
    spawn("producer", producer, null);
    spawn("consumer", consumer, null);
    for (&hogcount) |*c| spawn("hog", hog, c);
    for (0..rw.reads.len) |i| spawn("reader", reader, @ptrFromInt(i));
    spawn("writer", writer, null);
    spawn("spinner", spinner, @ptrFromInt(0));
    spawn("spinner", spinner, @ptrFromInt(1));
    spawn("churner", churner, null);
    spawn("notesleeper", notesleeper, null);
    spawn("notelocker", notelocker, null);
    spawn("alarmed", alarmed, null);
    for (0..arch.conf.nmach) |i| spawn("wired", wiredproc, @ptrFromInt(i));

    // Let the two note victims get going, then post their notes.  With
    // three hogs taking full quanta that can take a while.
    var waited: u32 = 0;
    while (nt.sleeper == null or nt.locker == null) : (waited += 10) {
        if (waited > 5000) panic("selftest: workers did not start", .{});
        pause(10);
    }
    pause(50);
    if (!proc.postnote(nt.sleeper, true, "selftest", portdat.NUser))
        panic("selftest: postnote failed", .{});
    if (!proc.postnote(nt.locker, true, "selftest", portdat.NUser))
        panic("selftest: postnote failed", .{});

    pause(secs * 1000);
    @atomicStore(bool, &stop, true, .seq_cst);
    // Whoever is asleep on a condition looks at `stop` when woken.
    _ = proc.wakeup(&pp.r[0]);
    _ = proc.wakeup(&pp.r[1]);
    _ = proc.wakeup(&pc.notfull);
    _ = proc.wakeup(&pc.notempty);
    // sleep returns on any wakeup, and each worker sends one.
    while (!alldone(null)) mustsleep(&live.r, alldone, null);
    ql.qunlock(&nt.held);

    print("selftest: sched %uds: pingpong %ud, queue %ud, hogs %llud %llud %llud, reads %ud %ud %ud writes %ud, spins %llud, procs %ud\n", .{
        secs,        pp.count[0] + pp.count[1], pc.consumed,
        hogcount[0], hogcount[1],               hogcount[2],
        rw.reads[0], rw.reads[1],               rw.reads[2],
        rw.writes,   sl.total,                  churn.made,
    });
    print("selftest: %ud delayed scheds, %ud cooperative, %ud preemptive\n", .{ proc.delayedscheds, proc.skipscheds, proc.preempts });

    for (0..arch.conf.nmach) |i| {
        if (wiredon[i] != @as(i32, @intCast(i)))
            panic("selftest: nothing ran on cpu%lud", .{i});
    }
    print("selftest: %lud processors scheduling\n", .{arch.conf.nmach});

    if (pp.count[0] == 0 or pp.count[1] == 0) panic("selftest: pingpong did not run", .{});
    if (pc.consumed == 0 or pc.produced < pc.consumed) panic("selftest: queue did not run", .{});
    for (hogcount) |c| {
        if (c == 0) panic("selftest: a hog never ran", .{});
    }
    for (rw.reads) |c| {
        if (c == 0) panic("selftest: a reader never ran", .{});
    }
    if (rw.writes == 0 or rw.a != rw.b) panic("selftest: writer", .{});
    if (sl.total != sl.mine[0] + sl.mine[1] or sl.mine[0] == 0 or sl.mine[1] == 0)
        panic("selftest: spin lock lost updates: %llud != %llud + %llud", .{ sl.total, sl.mine[0], sl.mine[1] });
    if (churn.made < 10) panic("selftest: only %ud processes made", .{churn.made});
    if (churn.sum != @as(u64, churn.made) * (churn.made + 1) / 2) panic("selftest: churn sum", .{});
    if (!nt.slept or !nt.locked or !nt.alarmed) panic("selftest: notes: sleep %d eqlock %d alarm %d", .{ nt.slept, nt.locked, nt.alarmed });

    // The processes made here are gone and their slots are being used
    // again: there were 17 and one per processor at once.  The kernel,
    // the drivers and whatever user programs are starting meanwhile
    // have more, but nowhere near the thousands made here.
    var slots_used: u32 = 0;
    while (proc.proctab(slots_used) != null) slots_used += 1;
    if (slots_used > 400)
        panic("selftest: %ud process slots used; exited processes are not being reused", .{slots_used});
    if (arch.up().?.pid != pid0) panic("selftest: pid changed", .{});
}
