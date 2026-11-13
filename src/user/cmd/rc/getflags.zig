//! rc's flags.
//! from cmd/rc/getflags.c and getflags.h
//!
//! DIFF:
//!   - argv is a copied list of optional slices (the C's ends with a
//!     nil, which the shifting moves along); a flag's arguments are a
//!     slice of it, set when getflags returns.
//!   - Fixed from C: the table has 256 entries where the C's has 128;
//!     getflags still refuses letters past 127 as the C does, but the
//!     builtin `flag` indexes it with any byte.

const std = @import("std");
const rc = @import("rc.zig");
const plan9 = @import("plan9.zig");
const exec = @import("exec.zig");

pub const NFLAG = 128;

/// flag[c]: null when the flag is not set, else its arguments.
pub var flag: [256]?[]const []const u8 = @splat(null);
pub const flagset: []const []const u8 = &.{"<flag>"};
var cmdname: ?[]const u8 = null;
var flagarg: []const u8 = "";

const RESET = 1;
const FEWARGS = 2;
const FLAGSYN = 3;
const BADFLAG = 4;
var reason: i32 = 0;
var badflag: i32 = 0;

/// argv as getflags works on it: the arguments, then a null.
pub fn copyargv(argv: []const []const u8) []?[]const u8 {
    const v = rc.a.alloc(?[]const u8, argv.len + 1) catch rc.panic("Can't malloc %d bytes", 0);
    for (argv, 0..) |s, i| v[i] = s;
    v[argv.len] = null;
    return v;
}

fn at(s: []const u8, i: usize) u8 {
    return if (i < s.len) s[i] else 0;
}

/// Take the flags out of argv (its last entry null); returns the new
/// count of arguments, or -1.
pub fn getflags(argv: []?[]const u8, flags: []const u8, stop: bool) i32 {
    flagarg = flags;
    var argc: usize = argv.len - 1;
    if (cmdname == null)
        cmdname = argv[0];

    var i: usize = 1;
    while (i != argc) {
        const a = argv[i].?;
        if (at(a, 0) != '-' or at(a, 1) == 0) {
            if (stop) // always true in rc
                return @intCast(argc);
            i += 1;
            continue;
        }
        var s: []const u8 = a[1..];
        while (s.len > 0) {
            const c: i32 = @as(i8, @bitCast(s[0])); // the C's signed char
            s = s[1..];
            const cnt = scanflag(c, flags);
            if (cnt == -1)
                return -1;
            const uc: usize = @intCast(c);
            if (flag[uc] != null) {
                reason = RESET;
                badflag = c;
                return -1;
            }
            if (cnt == 0) {
                flag[uc] = flagset;
                if (s.len == 0) {
                    var j = i + 1;
                    while (j <= argc) : (j += 1) argv[j - 1] = argv[j];
                    argc -= 1;
                }
            } else {
                const n: usize = @intCast(cnt);
                if (s.len == 0) {
                    var j = i + 1;
                    while (j <= argc) : (j += 1) argv[j - 1] = argv[j];
                    argc -= 1;
                    s = argv[i] orelse "";
                }
                if (argc - i < n) {
                    reason = FEWARGS;
                    badflag = c;
                    return -1;
                }
                reverse(argv[i .. argc + 1]);
                reverse(argv[i .. argc - n + 1]);
                reverse(argv[argc - n + 1 .. argc + 1]);
                argc -= n;
                argv[argc + 1] = s;
                const vals = rc.a.alloc([]const u8, n) catch rc.panic("Can't malloc %d bytes", 0);
                for (vals, argv[argc + 1 ..][0..n]) |*v, w| v.* = w.?;
                flag[uc] = vals;
                s = "";
            }
        }
    }
    return @intCast(argc);
}

fn reverse(p: []?[]const u8) void {
    std.mem.reverse(?[]const u8, p);
}

fn scanflag(c: i32, f_: []const u8) i32 {
    var f = f_;
    if (0 <= c and c < NFLAG) {
        while (f.len > 0) {
            if (f[0] == ' ') {
                f = f[1..];
                continue;
            }
            const fc = f[0];
            f = f[1..];
            var cnt: i32 = 0;
            if (at(f, 0) == ':') {
                f = f[1..];
                if (at(f, 0) < '0' or '9' < at(f, 0)) {
                    reason = FLAGSYN;
                    return -1;
                }
                while ('0' <= at(f, 0) and at(f, 0) <= '9') {
                    cnt = cnt * 10 + f[0] - '0';
                    f = f[1..];
                }
            }
            if (at(f, 0) == '[') {
                while (true) {
                    f = f[1..];
                    if (f.len == 0) {
                        reason = FLAGSYN;
                        return -1;
                    }
                    if (f[0] == ']') break;
                }
                f = f[1..];
            }
            if (c == fc)
                return cnt;
        }
    }
    reason = BADFLAG;
    badflag = c;
    return -1;
}

pub fn usage(tail: ?[]const u8) noreturn {
    switch (reason) {
        RESET => {
            errs("Flag -");
            errc(badflag);
            errs(": set twice\n");
        },
        FEWARGS => {
            errs("Flag -");
            errc(badflag);
            errs(": too few arguments\n");
        },
        FLAGSYN => errs("Bad argument to getflags!\n"),
        BADFLAG => {
            errs("Illegal flag -");
            errc(badflag);
            errc('\n');
        },
        else => {},
    }
    errs("Usage: ");
    errs(cmdname orelse "");
    var nflag: usize = 0;
    var s = flagarg;
    while (s.len > 0) {
        const c = s[0];
        s = s[1..];
        if (c == ' ')
            continue;
        var cnt: i32 = 0;
        if (at(s, 0) == ':') {
            s = s[1..];
            while ('0' <= at(s, 0) and at(s, 0) <= '9') {
                cnt = cnt * 10 + s[0] - '0';
                s = s[1..];
            }
        }
        if (cnt == 0) {
            if (nflag == 0)
                errs(" [-");
            nflag += 1;
            errc(c);
        }
        if (at(s, 0) == '[') {
            s = s[1..];
            while (s.len > 0 and s[0] != ']') s = s[1..];
            if (s.len > 0) s = s[1..];
        }
    }
    if (nflag != 0)
        errs("]");
    s = flagarg;
    while (s.len > 0) {
        const c = s[0];
        s = s[1..];
        if (c == ' ')
            continue;
        var cnt: i32 = 0;
        if (at(s, 0) == ':') {
            s = s[1..];
            while ('0' <= at(s, 0) and at(s, 0) <= '9') {
                cnt = cnt * 10 + s[0] - '0';
                s = s[1..];
            }
        }
        if (cnt != 0) {
            errs(" [-");
            errc(c);
            if (at(s, 0) == '[') {
                s = s[1..];
                const t = s;
                while (s.len > 0 and s[0] != ']') s = s[1..];
                errs(" ");
                errs(t[0 .. t.len - s.len]);
                if (s.len > 0) s = s[1..];
            } else while (cnt > 0) : (cnt -= 1) errs(" arg");
            errs("]");
        } else if (at(s, 0) == '[') {
            s = s[1..];
            while (s.len > 0 and s[0] != ']') s = s[1..];
            if (s.len > 0) s = s[1..];
        }
    }
    if (tail) |t| {
        errs(" ");
        errs(t);
    }
    errs("\n");
    exec.setstatus("bad flags");
    plan9.Exit();
}

fn errs(s: []const u8) void {
    for (s) |c| errc(c);
}

const NBUF = 80;
var buf: [NBUF]u8 = undefined;
var bufp: usize = 0;

fn errc(c: anytype) void {
    buf[bufp] = @truncate(@as(u32, @bitCast(@as(i32, c))));
    bufp += 1;
    if (bufp == NBUF or c == '\n') {
        _ = plan9.Write(2, buf[0..bufp]);
        bufp = 0;
    }
}
