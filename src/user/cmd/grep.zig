//! grep - search a file for a pattern
//! from cmd/grep/main.c, and the messages of grep.y's yyerror and
//! sub.c's error; the pattern compiler and the DFA are in grep/re.zig.
//!
//! DIFF:
//!   - The C's two copies of the byte loop (plain and -i) are one
//!     function with a comptime fold flag, compiled twice.
//!   - The buffer is one array, the 16K kept from the previous read
//!     followed by the 16K read into, where the C has a union of two.
//!   - Out of memory is "internal error: sbrk", as when the C's sbrk
//!     fails.

const std = @import("std");
const libc = @import("libc");
const re = @import("grep/re.zig");

const Cflag = 1 << 0;
const Hflag = 1 << 1;
const Iflag = 1 << 2;
const Llflag = 1 << 3;
const LLflag = 1 << 4;
const Nflag = 1 << 5;
const Sflag = 1 << 6;
const Vflag = 1 << 7;
const Bflag = 1 << 8;

const Flshcnt = (1 << 9) - 1;
const Nbuf = 16 * 1024;

const validflags = "bchiLlnsv";

var flags: [256]u32 = @splat(0);
var g: re.Grep = undefined;
var bout: libc.Biobuf = .{};
var rein: libc.Biobuf = .{};

/// if a line requires multiple reads, we keep shifting buf down into pre
/// and then do another read into buf.  so you'll get the last 16-32k of
/// the matching line.  if pre were smaller than buf you'd get a suffix
/// of the line with a hole cut out.
var u: [2 * Nbuf]u8 = undefined; // pre, then buf

fn usage() noreturn {
    libc.fprint(2, "usage: grep [-%s] [-e pattern] [-f patternfile] [file ...]\n", .{validflags});
    libc.exits("usage");
}

fn reinc() ?u8 {
    return rein.getc();
}

/// Print the error the compiler returned, as yyerror and error do.
fn fail(e: re.Error) noreturn {
    switch (e) {
        error.Syntax => {
            libc.fprint(2, "grep: ", .{});
            if (g.filename) |f|
                libc.fprint(2, "%s:%ld: ", .{ f, g.lineno })
            else if (g.pattern) |p|
                libc.fprint(2, "%s: ", .{p});
            libc.fprint(2, "%s\n", .{g.diag});
            libc.exits("syntax");
        },
        error.Internal, error.OutOfMemory => {
            const s = if (e == error.OutOfMemory) "sbrk" else g.diag;
            libc.fprint(2, "grep: internal error: %s\n", .{s});
            libc.exits(s);
        },
    }
}

pub fn main(argv: []const []const u8) void {
    g = re.Grep.init(libc.allocator) catch |e| fail(e);
    var args = libc.Args.init(argv);
    while (args.next()) |c| switch (c) {
        'e' => {
            flags['e'] += 1;
            g.lineno = 0;
            g.str2top(args.value() orelse usage()) catch |e| fail(e);
        },
        'f' => {
            flags['f'] += 1;
            const name = args.value() orelse usage();
            g.filename = name;
            rein.open(name, libc.OREAD) catch {
                libc.fprint(2, "grep: can't open %s: %r\n", .{name});
                libc.exits("open");
            };
            g.rein = &reinc;
            g.lineno = 1;
            g.str2top(name) catch |e| fail(e);
        },
        else => {
            if (std.mem.indexOfScalar(u8, validflags, c) == null)
                usage();
            flags[c] += 1;
            if (c == 'i')
                g.fold = true;
        },
    };
    var files = args.rest();

    if (flags['f'] == 0 and flags['e'] == 0) {
        if (files.len == 0)
            usage();
        g.str2top(files[0]) catch |e| fail(e);
        files = files[1..];
    }

    g.initstate() catch |e| fail(e);

    bout.init(1, libc.OWRITE);
    var status = false;
    switch (files.len) {
        0 => status = search(null, 0),
        1 => status = search(files[0], 0),
        else => for (files) |f| {
            if (search(f, Hflag))
                status = true;
        },
    }
    if (status)
        libc.exits(null);
    libc.exits("no matches");
}

/// What search keeps from one read to the next.
const Scan = struct {
    s: *re.State,
    lp: usize,
    elp: usize,
    bol: usize,
    lineno: i32 = 0,
    count: i32 = 0,
    eof: bool = false,
    flag: u32,
    file: []const u8,
};

fn search(file_: ?[]const u8, flag_: u32) bool {
    var flag = flag_;
    var fid: i32 = 0;
    var file: []const u8 = undefined;
    if (file_) |f| {
        file = f;
        fid = libc.open(f, libc.OREAD) catch {
            libc.fprint(2, "grep: can't open %s: %r\n", .{f});
            return false;
        };
    } else {
        file = "stdin";
        flag |= Bflag;
    }

    if (flags['b'] != 0)
        flag |= Bflag; // dont buffer output
    if (flags['c'] != 0)
        flag |= Cflag; // count
    if (flags['h'] != 0)
        flag &= ~@as(u32, Hflag); // do not print file name in output
    if (flags['i'] != 0)
        flag |= Iflag; // fold upper-lower
    if (flags['l'] != 0)
        flag |= Llflag; // print only name of file if any match
    if (flags['L'] != 0)
        flag |= LLflag; // print only name of file if any non match
    if (flags['n'] != 0)
        flag |= Nflag; // count only
    if (flags['s'] != 0)
        flag |= Sflag; // status only
    if (flags['v'] != 0)
        flag |= Vflag; // inverse match

    var sc: Scan = .{ .s = g.state0.?, .lp = Nbuf, .elp = Nbuf, .bol = Nbuf, .flag = flag, .file = file };
    var nl = false;
    var empty = true;

    while (true) {
        var n = sc.lp - sc.bol;
        if (n > Nbuf)
            n = Nbuf;
        std.mem.copyForwards(u8, u[Nbuf - n .. Nbuf], u[sc.bol..][0..n]);
        sc.bol = Nbuf - n;
        var got: usize = 0;
        if (libc.read(fid, u[Nbuf..])) |k| {
            got = k;
        } else |_| {
            libc.fprint(2, "grep: read error on %s: %r\n", .{file});
            return sc.count != 0;
        }
        // if file has no final newline, simulate one to emit matches to last line
        if (got > 0) {
            empty = false;
            nl = u[Nbuf + got - 1] == '\n';
        } else if (!sc.eof and !nl and !empty) {
            u[Nbuf] = '\n';
            got = 1;
            sc.eof = true;
        }
        if (got == 0) {
            libc.close(fid) catch {};
            if (flag & Cflag != 0) {
                if (flag & Hflag != 0)
                    bout.print("%s:", .{file}) catch {};
                bout.print("%ld\n", .{sc.count}) catch {};
            }
            if ((flag & Llflag != 0 and sc.count != 0) or (flag & LLflag != 0 and sc.count == 0))
                bout.print("%s\n", .{file}) catch {};
            bout.flush() catch {};
            return sc.count != 0;
        }
        sc.lp = Nbuf;
        sc.elp = Nbuf + got;
        if (flag & Iflag != 0)
            scan(true, &sc)
        else
            scan(false, &sc);
    }
}

/// The character loop, over u[lp..elp]; with fold, for -i.
inline fn scan(comptime fold: bool, sc: *Scan) void {
    const flag = sc.flag;
    var s = sc.s;
    var lp = sc.lp;
    defer {
        sc.s = s;
        sc.lp = lp;
    }
    while (true) {
        var c = u[lp];
        if (fold and c >= 'A' and c <= 'Z')
            c += 'a' - 'A';
        const ns = s.next[c] orelse {
            g.increment(s, c) catch |e| fail(e);
            continue;
        };
        lp += 1;
        s = ns;
        if (c == '\n') {
            sc.lineno +%= 1;
            if (s.match == (flag & Vflag == 0)) {
                sc.count +%= 1;
                if (flag & (Cflag | Sflag | Llflag | LLflag) == 0) {
                    if (flag & Hflag != 0)
                        bout.print("%s:", .{sc.file}) catch {};
                    if (flag & Nflag != 0)
                        bout.print("%ld: ", .{sc.lineno}) catch {};
                    // suppress extra newline at EOF unless we are labeling matches with file name
                    const drop: usize = @intFromBool(sc.eof and flag & Hflag == 0);
                    _ = bout.write(u[sc.bol .. lp - drop]) catch {};
                    if (flag & Bflag != 0)
                        bout.flush() catch {};
                    if (sc.lineno & Flshcnt == 0)
                        bout.flush() catch {};
                }
            } else if (sc.lineno & Flshcnt == 0)
                bout.flush() catch {};
            sc.bol = lp;
        }
        if (lp == sc.elp)
            return;
    }
}
