//! dd - convert and copy a file
//! from cmd/dd.c
//!
//! DIFF:
//!   - The buffers come from the allocator, where the C takes them with
//!     sbrk.
//!   - The main loop's gotos are a loop; the conversion is an enum
//!     where the C keeps a function pointer.
//!
//! Kept from C:
//!   - swab swaps (n/2)&~1 pairs of a record of n bytes: none of a
//!     2-byte record, two of a 6-byte one.
//!   - In a size, after x and the number that follows, the rest is not
//!     read.
//!   - At the end of the input a record of 0 bytes is counted as a
//!     partial one for each of files= but the last.

const std = @import("std");
const libc = @import("libc");

const BIG: u64 = (1 << 31) - 1;
const VBIG: u64 = (1 << 63) - 1;
const LCASE = 1 << 0;
const UCASE = 1 << 1;
const SWAB = 1 << 2;
const NERR = 1 << 3;
const SYNC = 1 << 4;

var cflag: u32 = 0;
var fflag = false;

var string: []const u8 = "";
var ifile: ?[]const u8 = null;
var ofile: ?[]const u8 = null;
var ibuf: []u8 = &.{};
var obuf: []u8 = &.{};

var skip: i64 = 0;
var oseekn: i64 = 0;
var iseekn: i64 = 0;
var count: i64 = 0;

var files: i32 = 1;
var ibs: i32 = 512;
var obs: i32 = 512;
var bs: i32 = 0;
var cbs: i32 = 0;
var ibc: i32 = 0;
var obc: i32 = 0;
var cbc: i32 = 0;
var nifr: u32 = 0;
var nipr: u32 = 0;
var nofr: u32 = 0;
var nopr: u32 = 0;
var ntrunc: u32 = 0;

var dotrunc: i32 = 1;
var ibf: i32 = 0;
var obf: i32 = 0;

var op: usize = 0; // in obuf
var nspace: i32 = 0;

var quiet: i32 = 0;

const Conv = enum { null, cnull, ascii, unblock, ebcdic, ibm, block };

/// The byte of string at i; 0 at its end and after, as the C reads.
fn sc(i: usize) u8 {
    return if (i < string.len) string[i] else 0;
}

fn iskey(key: []const u8, s: []const u8) bool {
    return key.len > 0 and key[0] == '-' and std.mem.eql(u8, key[1..], s);
}

pub fn main(argv: []const []const u8) void {
    var conv: Conv = .null;

    var c: usize = 1;
    args: while (c < argv.len) : (c += 1) {
        const key = argv[c];
        c += 1;
        if (c >= argv.len) {
            libc.fprint(2, "dd: arg %s needs a value\n", .{key});
            libc.exits("arg");
        }
        string = argv[c];
        if (iskey(key, "ibs")) {
            ibs = @intCast(number(BIG));
            continue;
        }
        if (iskey(key, "obs")) {
            obs = @intCast(number(BIG));
            continue;
        }
        if (iskey(key, "cbs")) {
            cbs = @intCast(number(BIG));
            continue;
        }
        if (iskey(key, "bs")) {
            bs = @intCast(number(BIG));
            continue;
        }
        if (iskey(key, "if")) {
            ifile = string;
            continue;
        }
        if (iskey(key, "of")) {
            ofile = string;
            continue;
        }
        if (iskey(key, "trunc")) {
            dotrunc = @intCast(number(BIG));
            continue;
        }
        if (iskey(key, "quiet")) {
            quiet = @intCast(number(BIG));
            continue;
        }
        if (iskey(key, "skip")) {
            skip = number(VBIG);
            continue;
        }
        if (iskey(key, "seek") or iskey(key, "oseek")) {
            oseekn = number(VBIG);
            continue;
        }
        if (iskey(key, "iseek")) {
            iseekn = number(VBIG);
            continue;
        }
        if (iskey(key, "count")) {
            count = number(VBIG);
            continue;
        }
        if (iskey(key, "files")) {
            files = @intCast(number(BIG));
            continue;
        }
        if (iskey(key, "conv")) {
            while (true) {
                if (match(","))
                    continue;
                if (sc(0) == 0)
                    continue :args;
                if (match("ebcdic")) {
                    conv = .ebcdic;
                } else if (match("ibm")) {
                    conv = .ibm;
                } else if (match("ascii")) {
                    conv = .ascii;
                } else if (match("block")) {
                    conv = .block;
                } else if (match("unblock")) {
                    conv = .unblock;
                } else if (match("lcase")) {
                    cflag |= LCASE;
                } else if (match("ucase")) {
                    cflag |= UCASE;
                } else if (match("swab")) {
                    cflag |= SWAB;
                } else if (match("noerror")) {
                    cflag |= NERR;
                } else if (match("sync")) {
                    cflag |= SYNC;
                } else {
                    libc.fprint(2, "dd: bad conv %s\n", .{argv[c]});
                    libc.exits("arg");
                }
            }
        }
        libc.fprint(2, "dd: bad arg: %s\n", .{key});
        libc.exits("arg");
    }
    if (conv == .null and cflag & (LCASE | UCASE) != 0)
        conv = .cnull;
    ibf = (if (ifile) |f| libc.open(f, 0) else libc.dup(0, -1)) catch {
        // the C prints a nil ifile with %s
        libc.fprint(2, "dd: open %s: %r\n", .{ifile orelse "<nil>"});
        libc.exits("open");
    };
    if (ofile) |f| {
        obf = (if (dotrunc != 0) libc.create(f, 1, 0o664) else libc.open(f, 1)) catch {
            libc.fprint(2, "dd: create %s: %r\n", .{f});
            libc.exits("create");
        };
    } else {
        obf = libc.dup(1, -1) catch {
            libc.fprint(2, "dd: can't dup file descriptor: %s: %r\n", .{"<nil>"});
            libc.exits("dup");
        };
    }
    if (bs != 0) {
        ibs = bs;
        obs = bs;
    }
    if (ibs == obs and conv == .null)
        fflag = true;
    if (ibs == 0 or obs == 0) {
        libc.fprint(2, "dd: counts: cannot be zero\n", .{});
        libc.exits("counts");
    }
    const a = libc.allocator;
    ibuf = a.alloc(u8, @intCast(ibs)) catch nomem();
    obuf = if (fflag) ibuf else a.alloc(u8, @intCast(obs)) catch nomem();
    ibc = 0;
    obc = 0;
    cbc = 0;
    op = 0;

    _ = libc.seek(obf, @as(i64, obs) *% oseekn, 1) catch 0;
    _ = libc.seek(ibf, @as(i64, ibs) *% iseekn, 1) catch 0;
    while (skip != 0) : (skip -= 1)
        _ = libc.read(ibf, ibuf) catch 0;

    var ip: usize = 0;
    while (true) {
        const had = ibc;
        ibc -%= 1;
        if (had == 0) {
            ibc = 0;
            if (count == 0 or @as(i64, nifr) + nipr != count) {
                if (cflag & (NERR | SYNC) != 0)
                    @memset(ibuf, 0);
                ibc = if (libc.read(ibf, ibuf)) |n| @intCast(n) else |_| -1;
            }
            if (ibc == -1) {
                perror("read");
                if (cflag & NERR == 0) {
                    flsh();
                    term("errors");
                }
                ibc = 0;
                for (ibuf, 0..) |b, i| {
                    if (b != 0)
                        ibc = @intCast(i + 1);
                }
                _ = libc.seek(ibf, ibs, 1) catch 0;
                stats();
            } else if (ibc == 0) {
                files -= 1;
                if (files <= 0) {
                    flsh();
                    term(null);
                }
            }
            if (ibc != ibs) {
                nipr +%= 1;
                if (cflag & SYNC != 0)
                    ibc = ibs;
            } else nifr +%= 1;
            ip = 0;
            var n = (ibc >> 1) & ~@as(i32, 1);
            if (cflag & SWAB != 0 and n != 0) {
                while (true) {
                    const t = ibuf[ip];
                    ibuf[ip] = ibuf[ip + 1];
                    ibuf[ip + 1] = t;
                    ip += 2;
                    n -= 1;
                    if (n == 0) break;
                }
            }
            ip = 0;
            if (fflag) {
                obc = ibc;
                flsh();
                ibc = 0;
            }
            continue;
        }
        const ch = ibuf[ip];
        ip += 1;
        switch (conv) {
            .null => null_(ch),
            .cnull => cnull(ch),
            .ascii => ascii(ch),
            .unblock => unblock(ch),
            .ebcdic => ebcdic(ch),
            .ibm => ibm(ch),
            .block => block(ch),
        }
    }
}

fn nomem() noreturn {
    libc.fprint(2, "dd: not enough memory: %r\n", .{});
    libc.exits("memory");
}

/// from libc/port/perror.c
fn perror(s: []const u8) void {
    libc.fprint(2, "%s: %r\n", .{s});
}

fn flsh() void {
    if (obc != 0) {
        // don't perror dregs of previous errors on a short write
        libc.werrstr("", .{});
        const n: usize = @intCast(obc);
        const c: i64 = if (libc.write(obf, obuf[0..n])) |w| @intCast(w) else |_| -1;
        if (c != obc) {
            if (c > 0)
                nopr +%= 1;
            perror("write");
            term("errors");
        }
        if (obc == obs)
            nofr +%= 1
        else
            nopr +%= 1;
        obc = 0;
    }
}

/// Is s what string starts with?  Then string goes past it.
fn match(s: []const u8) bool {
    if (!std.mem.startsWith(u8, string, s))
        return false;
    string = string[s.len..];
    return true;
}

fn number(big: u64) i64 {
    var cs: usize = 0;
    var n: u64 = 0;
    while (sc(cs) >= '0' and sc(cs) <= '9') : (cs += 1)
        n = n *% 10 +% (sc(cs) - '0');
    while (true) {
        const ch = sc(cs);
        cs += 1;
        switch (ch) {
            'm' => {
                n *%= 1024 * 1024;
                continue;
            },
            'k' => {
                n *%= 1024;
                continue;
            },
            'b' => {
                n *%= 512;
                continue;
            },
            'x', 0 => {
                if (ch == 'x') {
                    string = if (cs < string.len) string[cs..] else "";
                    n *%= @as(u64, @bitCast(number(VBIG)));
                }
                if (n > big) {
                    libc.fprint(2, "dd: argument %llud out of range\n", .{n});
                    libc.exits("range");
                }
                return @bitCast(n);
            },
            else => {
                libc.fprint(2, "dd: invalid size suffix '%c'\n", .{ch});
                libc.exits("invalid");
            },
        }
    }
}

fn fold(cc: u8) u8 {
    var c = cc;
    if (cflag & UCASE != 0 and c >= 'a' and c <= 'z')
        c = c - 'a' + 'A';
    if (cflag & LCASE != 0 and c >= 'A' and c <= 'Z')
        c = c - 'A' + 'a';
    return c;
}

fn cnull(cc: u8) void {
    null_(fold(cc));
}

fn null_(c: u8) void {
    obuf[op] = c;
    op += 1;
    obc += 1;
    if (obc >= obs) {
        flsh();
        op = 0;
    }
}

fn ascii(cc: u8) void {
    unblock(etoa[cc]);
}

fn unblock(c: u8) void {
    if (cbs == 0) {
        cnull(c);
        return;
    }
    if (c == ' ') {
        nspace += 1;
    } else {
        while (nspace > 0) : (nspace -= 1)
            null_(' ');
        cnull(c);
    }

    cbc += 1;
    if (cbc >= cbs) {
        null_('\n');
        cbc = 0;
        nspace = 0;
    }
}

/// ebcdic, ibm and block: a line becomes a record of cbs bytes.
fn record(cc: u8, c: u8, space: u8) void {
    if (cbs == 0) {
        null_(c);
        return;
    }
    if (cc == '\n') {
        while (cbc < cbs) : (cbc += 1)
            null_(space);
        cbc = 0;
        return;
    }
    if (cbc == cbs)
        ntrunc +%= 1;
    cbc += 1;
    if (cbc <= cbs)
        null_(c);
}

fn ebcdic(cc: u8) void {
    record(cc, atoe[fold(cc)], atoe[' ']);
}

fn ibm(cc: u8) void {
    record(cc, atoibm[fold(cc)], atoibm[' ']);
}

fn block(cc: u8) void {
    record(cc, fold(cc), ' ');
}

fn term(status: ?[]const u8) noreturn {
    stats();
    libc.exits(status);
}

fn stats() void {
    if (quiet != 0)
        return;
    libc.fprint(2, "%lud+%lud records in\n", .{ nifr, nipr });
    libc.fprint(2, "%lud+%lud records out\n", .{ nofr, nopr });
    if (ntrunc != 0)
        libc.fprint(2, "%lud truncated records\n", .{ntrunc});
}

const etoa = [256]u8{
    0o000, 0o001, 0o002, 0o003, 0o234, 0o011, 0o206, 0o177,
    0o227, 0o215, 0o216, 0o013, 0o014, 0o015, 0o016, 0o017,
    0o020, 0o021, 0o022, 0o023, 0o235, 0o205, 0o010, 0o207,
    0o030, 0o031, 0o222, 0o217, 0o034, 0o035, 0o036, 0o037,
    0o200, 0o201, 0o202, 0o203, 0o204, 0o012, 0o027, 0o033,
    0o210, 0o211, 0o212, 0o213, 0o214, 0o005, 0o006, 0o007,
    0o220, 0o221, 0o026, 0o223, 0o224, 0o225, 0o226, 0o004,
    0o230, 0o231, 0o232, 0o233, 0o024, 0o025, 0o236, 0o032,
    0o040, 0o240, 0o241, 0o242, 0o243, 0o244, 0o245, 0o246,
    0o247, 0o250, 0o133, 0o056, 0o074, 0o050, 0o053, 0o041,
    0o046, 0o251, 0o252, 0o253, 0o254, 0o255, 0o256, 0o257,
    0o260, 0o261, 0o135, 0o044, 0o052, 0o051, 0o073, 0o136,
    0o055, 0o057, 0o262, 0o263, 0o264, 0o265, 0o266, 0o267,
    0o270, 0o271, 0o174, 0o054, 0o045, 0o137, 0o076, 0o077,
    0o272, 0o273, 0o274, 0o275, 0o276, 0o277, 0o300, 0o301,
    0o302, 0o140, 0o072, 0o043, 0o100, 0o047, 0o075, 0o042,
    0o303, 0o141, 0o142, 0o143, 0o144, 0o145, 0o146, 0o147,
    0o150, 0o151, 0o304, 0o305, 0o306, 0o307, 0o310, 0o311,
    0o312, 0o152, 0o153, 0o154, 0o155, 0o156, 0o157, 0o160,
    0o161, 0o162, 0o313, 0o314, 0o315, 0o316, 0o317, 0o320,
    0o321, 0o176, 0o163, 0o164, 0o165, 0o166, 0o167, 0o170,
    0o171, 0o172, 0o322, 0o323, 0o324, 0o325, 0o326, 0o327,
    0o330, 0o331, 0o332, 0o333, 0o334, 0o335, 0o336, 0o337,
    0o340, 0o341, 0o342, 0o343, 0o344, 0o345, 0o346, 0o347,
    0o173, 0o101, 0o102, 0o103, 0o104, 0o105, 0o106, 0o107,
    0o110, 0o111, 0o350, 0o351, 0o352, 0o353, 0o354, 0o355,
    0o175, 0o112, 0o113, 0o114, 0o115, 0o116, 0o117, 0o120,
    0o121, 0o122, 0o356, 0o357, 0o360, 0o361, 0o362, 0o363,
    0o134, 0o237, 0o123, 0o124, 0o125, 0o126, 0o127, 0o130,
    0o131, 0o132, 0o364, 0o365, 0o366, 0o367, 0o370, 0o371,
    0o060, 0o061, 0o062, 0o063, 0o064, 0o065, 0o066, 0o067,
    0o070, 0o071, 0o372, 0o373, 0o374, 0o375, 0o376, 0o377,
};
const atoe = [256]u8{
    0o000, 0o001, 0o002, 0o003, 0o067, 0o055, 0o056, 0o057,
    0o026, 0o005, 0o045, 0o013, 0o014, 0o015, 0o016, 0o017,
    0o020, 0o021, 0o022, 0o023, 0o074, 0o075, 0o062, 0o046,
    0o030, 0o031, 0o077, 0o047, 0o034, 0o035, 0o036, 0o037,
    0o100, 0o117, 0o177, 0o173, 0o133, 0o154, 0o120, 0o175,
    0o115, 0o135, 0o134, 0o116, 0o153, 0o140, 0o113, 0o141,
    0o360, 0o361, 0o362, 0o363, 0o364, 0o365, 0o366, 0o367,
    0o370, 0o371, 0o172, 0o136, 0o114, 0o176, 0o156, 0o157,
    0o174, 0o301, 0o302, 0o303, 0o304, 0o305, 0o306, 0o307,
    0o310, 0o311, 0o321, 0o322, 0o323, 0o324, 0o325, 0o326,
    0o327, 0o330, 0o331, 0o342, 0o343, 0o344, 0o345, 0o346,
    0o347, 0o350, 0o351, 0o112, 0o340, 0o132, 0o137, 0o155,
    0o171, 0o201, 0o202, 0o203, 0o204, 0o205, 0o206, 0o207,
    0o210, 0o211, 0o221, 0o222, 0o223, 0o224, 0o225, 0o226,
    0o227, 0o230, 0o231, 0o242, 0o243, 0o244, 0o245, 0o246,
    0o247, 0o250, 0o251, 0o300, 0o152, 0o320, 0o241, 0o007,
    0o040, 0o041, 0o042, 0o043, 0o044, 0o025, 0o006, 0o027,
    0o050, 0o051, 0o052, 0o053, 0o054, 0o011, 0o012, 0o033,
    0o060, 0o061, 0o032, 0o063, 0o064, 0o065, 0o066, 0o010,
    0o070, 0o071, 0o072, 0o073, 0o004, 0o024, 0o076, 0o341,
    0o101, 0o102, 0o103, 0o104, 0o105, 0o106, 0o107, 0o110,
    0o111, 0o121, 0o122, 0o123, 0o124, 0o125, 0o126, 0o127,
    0o130, 0o131, 0o142, 0o143, 0o144, 0o145, 0o146, 0o147,
    0o150, 0o151, 0o160, 0o161, 0o162, 0o163, 0o164, 0o165,
    0o166, 0o167, 0o170, 0o200, 0o212, 0o213, 0o214, 0o215,
    0o216, 0o217, 0o220, 0o232, 0o233, 0o234, 0o235, 0o236,
    0o237, 0o240, 0o252, 0o253, 0o254, 0o255, 0o256, 0o257,
    0o260, 0o261, 0o262, 0o263, 0o264, 0o265, 0o266, 0o267,
    0o270, 0o271, 0o272, 0o273, 0o274, 0o275, 0o276, 0o277,
    0o312, 0o313, 0o314, 0o315, 0o316, 0o317, 0o332, 0o333,
    0o334, 0o335, 0o336, 0o337, 0o352, 0o353, 0o354, 0o355,
    0o356, 0o357, 0o372, 0o373, 0o374, 0o375, 0o376, 0o377,
};
const atoibm = [256]u8{
    0o000, 0o001, 0o002, 0o003, 0o067, 0o055, 0o056, 0o057,
    0o026, 0o005, 0o045, 0o013, 0o014, 0o015, 0o016, 0o017,
    0o020, 0o021, 0o022, 0o023, 0o074, 0o075, 0o062, 0o046,
    0o030, 0o031, 0o077, 0o047, 0o034, 0o035, 0o036, 0o037,
    0o100, 0o132, 0o177, 0o173, 0o133, 0o154, 0o120, 0o175,
    0o115, 0o135, 0o134, 0o116, 0o153, 0o140, 0o113, 0o141,
    0o360, 0o361, 0o362, 0o363, 0o364, 0o365, 0o366, 0o367,
    0o370, 0o371, 0o172, 0o136, 0o114, 0o176, 0o156, 0o157,
    0o174, 0o301, 0o302, 0o303, 0o304, 0o305, 0o306, 0o307,
    0o310, 0o311, 0o321, 0o322, 0o323, 0o324, 0o325, 0o326,
    0o327, 0o330, 0o331, 0o342, 0o343, 0o344, 0o345, 0o346,
    0o347, 0o350, 0o351, 0o255, 0o340, 0o275, 0o137, 0o155,
    0o171, 0o201, 0o202, 0o203, 0o204, 0o205, 0o206, 0o207,
    0o210, 0o211, 0o221, 0o222, 0o223, 0o224, 0o225, 0o226,
    0o227, 0o230, 0o231, 0o242, 0o243, 0o244, 0o245, 0o246,
    0o247, 0o250, 0o251, 0o300, 0o117, 0o320, 0o241, 0o007,
    0o040, 0o041, 0o042, 0o043, 0o044, 0o025, 0o006, 0o027,
    0o050, 0o051, 0o052, 0o053, 0o054, 0o011, 0o012, 0o033,
    0o060, 0o061, 0o032, 0o063, 0o064, 0o065, 0o066, 0o010,
    0o070, 0o071, 0o072, 0o073, 0o004, 0o024, 0o076, 0o341,
    0o101, 0o102, 0o103, 0o104, 0o105, 0o106, 0o107, 0o110,
    0o111, 0o121, 0o122, 0o123, 0o124, 0o125, 0o126, 0o127,
    0o130, 0o131, 0o142, 0o143, 0o144, 0o145, 0o146, 0o147,
    0o150, 0o151, 0o160, 0o161, 0o162, 0o163, 0o164, 0o165,
    0o166, 0o167, 0o170, 0o200, 0o212, 0o213, 0o214, 0o215,
    0o216, 0o217, 0o220, 0o232, 0o233, 0o234, 0o235, 0o236,
    0o237, 0o240, 0o252, 0o253, 0o254, 0o255, 0o256, 0o257,
    0o260, 0o261, 0o262, 0o263, 0o264, 0o265, 0o266, 0o267,
    0o270, 0o271, 0o272, 0o273, 0o274, 0o275, 0o276, 0o277,
    0o312, 0o313, 0o314, 0o315, 0o316, 0o317, 0o332, 0o333,
    0o334, 0o335, 0o336, 0o337, 0o352, 0o353, 0o354, 0o355,
    0o356, 0o357, 0o372, 0o373, 0o374, 0o375, 0o376, 0o377,
};
