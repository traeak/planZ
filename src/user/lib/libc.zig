//! A small libc for planZ's user programs written in Zig: the parts of
//! 9front's libc that a simple program uses, with a Zig interface.
//!
//! Not a C library: there is no C ABI.  Calls that fail return
//! error.Plan9 and leave the kernel's message in the process's error
//! string, which `rerrstr` reads (and `%r` prints) without clearing it,
//! as in C.  Memory comes from `allocator`, 9front's pool allocator
//! over brk.
//!
//! Strings are plain slices everywhere, including sys.zig: paths,
//! arguments, exit messages, error strings and environment values are
//! `[]const u8`, and there are no sentinel-terminated types.  sys.zig
//! passes each string to the kernel as an (address, length) pair, with
//! planZ's own call numbers; the kernel refuses a name with a 0 byte in
//! it ("bad character in file name") or of 2^16 bytes or more.
//!
//! A program has `pub fn main() !void` or
//! `pub fn main(args: []const []const u8) !void`; see start.zig.
//! The build compiles it with root.zig as the root file, which
//! exports _start and calls that main.  Programs with their own
//! _start (initcode, boot) are their own root and use only `sys`.

const std = @import("std");
const builtin = @import("builtin");
pub const fmt = @import("fmt");
pub const fcall = @import("fcall");

pub const sys = @import("sys.zig");
const malloc_ = @import("malloc.zig");
const dir_ = @import("dir.zig");
const proc_ = @import("proc.zig");
const string_ = @import("string.zig");

/// The start-up code; root.zig exports it.
pub const start = @import("start.zig");

pub const Error = error{Plan9};

pub const ERRMAX = sys.ERRMAX;
pub const OREAD = sys.OREAD;
pub const OWRITE = sys.OWRITE;
pub const ORDWR = sys.ORDWR;
pub const OEXEC = sys.OEXEC;
pub const OTRUNC = sys.OTRUNC;
pub const OCEXEC = sys.OCEXEC;
pub const ORCLOSE = sys.ORCLOSE;
pub const OEXCL = sys.OEXCL;
pub const DMDIR = fcall.DMDIR;
pub const DMAPPEND = fcall.DMAPPEND;
pub const DMEXCL = fcall.DMEXCL;
pub const DMTMP = fcall.DMTMP;
pub const QTDIR = fcall.QTDIR;
pub const AEXIST = sys.AEXIST;
pub const AEXEC = sys.AEXEC;
pub const AWRITE = sys.AWRITE;
pub const AREAD = sys.AREAD;
pub const IOUNIT = 32768; // default buffer size for 9p io

/// The per-process block at the top of the stack.
/// from /sys/include/tos.h
pub const Tos = extern struct {
    prof: extern struct {
        pp: usize,
        next: usize,
        last: usize,
        first: usize,
        pid: u32,
        what: u32,
    },
    cyclefreq: u64, // cycle clock frequency if there is one, 0 otherwise
    kcycles: i64, // cycles spent in kernel
    pcycles: i64, // cycles spent in process (kernel + user)
    pid: u32, // might as well put the pid here
    clock: u32,
    // top of stack is here
};

comptime {
    std.debug.assert(@offsetOf(Tos, "pid") == 64);
}

pub var tos: *Tos = undefined;
/// The program's arguments, argv[0] first.
pub var argv: []const []const u8 = &.{};
/// argv[0], for messages.
pub var argv0: []const u8 = "";

// Memory

pub const allocator = malloc_.allocator;
pub const malloc = malloc_.malloc;
pub const mallocz = malloc_.mallocz;
pub const realloc = malloc_.realloc;
pub const free = malloc_.free;
pub const msize = malloc_.msize;
pub const sbrk = malloc_.sbrk;
pub const brk = malloc_.brk;

// Files and directories

pub const Dir = fcall.Dir;
pub const Stat = dir_.Stat;
pub const Dirs = dir_.Dirs;
pub const dirstat = dir_.dirstat;
pub const dirfstat = dir_.dirfstat;
pub const dirwstat = dir_.dirwstat;
pub const dirfwstat = dir_.dirfwstat;
pub const dirread = dir_.dirread;
pub const dirreadall = dir_.dirreadall;
pub const nulldir = dir_.nulldir;

// Processes

pub const Waitmsg = proc_.Waitmsg;
pub const fork = proc_.fork;
pub const wait = proc_.wait;
pub const waitpid = proc_.waitpid;
pub const getpid = proc_.getpid;
pub const getenv = proc_.getenv;
pub const putenv = proc_.putenv;
pub const atnotify = proc_.atnotify;
pub const postnote = proc_.postnote;
pub const PNPROC = proc_.PNPROC;
pub const PNGROUP = proc_.PNGROUP;

// Strings and arguments

pub const tokenize = string_.tokenize;
pub const atoi = string_.atoi;
pub const cleanname = string_.cleanname;
pub const needsrcquote = string_.needsrcquote;
pub const quote = string_.quote;
pub const Args = string_.Args;
pub const qsort = @import("qsort.zig").qsort;
pub const strtol = string_.strtol;
pub const strtoul = string_.strtoul;
pub const strtol32 = string_.strtol32;
pub const strtoul32 = string_.strtoul32;
pub const basename = string_.basename;

// Floating point (src/lib/flt.zig, which fmt's %e %f %g use too)

const flt_ = fmt.flt;
/// strtod: the value and how many bytes it used.
pub const strtod = flt_.strtod;
pub const frexp = flt_.frexp;
pub const ldexp = flt_.ldexp;
pub const modf = flt_.modf;
pub const pow10 = flt_.pow10;
pub const floor = flt_.floor;
pub const ceil = flt_.ceil;
pub const fmod = flt_.fmod;
pub const fabs = flt_.fabs;
pub const sqrt = flt_.sqrt;
pub const NaN = flt_.NaN;
pub const Inf = flt_.Inf;
pub const isNaN = flt_.isNaN;
pub const isInf = flt_.isInf;

/// atof: strtod's value.
pub fn atof(s: []const u8) f64 {
    return flt_.strtod(s).v;
}

/// Format at run time (a format a program builds or is given): the
/// same verbs as print, with the values tagged.
pub const Value = fmt.Value;

pub fn runsnprint(buf: []u8, format: []const u8, args: []const Value) []u8 {
    return fmt.runsnprint(buf, format, args);
}

// Runes

const rune_ = @import("rune.zig");
pub const Rune = rune_.Rune;
pub const UTFmax = rune_.UTFmax;
pub const Runeself = rune_.Runeself;
pub const Runeerror = rune_.Runeerror;
pub const Runemax = rune_.Runemax;
pub const chartorune = rune_.chartorune;
pub const runetochar = rune_.runetochar;
pub const runelen = rune_.runelen;
pub const fullrune = rune_.fullrune;
pub const utflen = rune_.utflen;
pub const utfrune = rune_.utfrune;

// Regular expressions

pub const regexp = @import("regexp.zig");

/// libregexp's default regerror: the message on standard error after
/// "regerror: ", and exit "regerr".  Programs with their own handling
/// (sed, ed) use regexp.Diag instead.
/// from libregexp/regerror.c
pub fn regerror(s: []const u8) noreturn {
    fprint(2, "regerror: %s\n", .{s});
    exits("regerr");
}

// Buffered I/O

pub const Biobuf = @import("bio.zig").Biobuf;
pub const Bsize = @import("bio.zig").Bsize;

// Errors

/// The process's error string, read without clearing it.
/// from libc/9sys/rerrstr.c
pub fn rerrstr(buf: []u8) []const u8 {
    var tmp: [ERRMAX]u8 = undefined;
    tmp[0] = 0;
    _ = sys.errstr(&tmp);
    const s = sys.upto0(&tmp);
    const n = @min(s.len, buf.len -| 1);
    @memcpy(buf[0..n], s[0..n]);
    if (buf.len > 0) buf[n] = 0;
    // put it back
    _ = sys.errstr(&tmp);
    return buf[0..n];
}

/// Set the process's error string.
/// from libc/9sys/werrstr.c
pub fn werrstr(comptime format: []const u8, args: anytype) void {
    var buf: [ERRMAX]u8 = undefined;
    const s = fmt.snprint(buf[0 .. ERRMAX - 1], format, args);
    buf[s.len] = 0;
    _ = sys.errstr(&buf);
}

var rbuf: [ERRMAX]u8 = undefined;

/// For %r.
pub fn errtext() []const u8 {
    return rerrstr(&rbuf);
}

fn check(r: isize) Error!usize {
    if (r < 0)
        return error.Plan9;
    return @intCast(r);
}

fn checkfd(r: isize) Error!i32 {
    if (r < 0)
        return error.Plan9;
    return @intCast(r);
}

// The checked calls

pub fn open(name: []const u8, mode: u32) Error!i32 {
    return checkfd(sys.open(name, mode));
}

pub fn create(name: []const u8, mode: u32, perm: u32) Error!i32 {
    return checkfd(sys.create(name, mode, perm));
}

pub fn close(fd: i32) Error!void {
    _ = try check(sys.close(fd));
}

pub fn read(fd: i32, buf: []u8) Error!usize {
    return check(sys.read(fd, buf));
}

pub fn write(fd: i32, buf: []const u8) Error!usize {
    return check(sys.write(fd, buf));
}

pub fn pread(fd: i32, buf: []u8, off: i64) Error!usize {
    return check(sys.pread(fd, buf, off));
}

pub fn pwrite(fd: i32, buf: []const u8, off: i64) Error!usize {
    return check(sys.pwrite(fd, buf, off));
}

/// Read until buf is full or the file ends.
/// from libc/port/readn.c
pub fn readn(fd: i32, buf: []u8) Error!usize {
    var t: usize = 0;
    while (t < buf.len) {
        const m = try read(fd, buf[t..]);
        if (m == 0)
            break;
        t += m;
    }
    return t;
}

/// Write all of buf.
pub fn writeall(fd: i32, buf: []const u8) Error!void {
    var t: usize = 0;
    while (t < buf.len) {
        const m = try write(fd, buf[t..]);
        if (m == 0) {
            werrstr("write returned 0", .{});
            return error.Plan9;
        }
        t += m;
    }
}

pub fn seek(fd: i32, n: i64, typ: u32) Error!i64 {
    const r = sys.seek(fd, n, typ);
    if (r < 0)
        return error.Plan9;
    return r;
}

pub fn remove(name: []const u8) Error!void {
    _ = try check(sys.remove(name));
}

pub fn dup(old: i32, new: i32) Error!i32 {
    return checkfd(sys.dup(old, new));
}

pub fn pipe() Error![2]i32 {
    var fd: [2]i32 = undefined;
    _ = try check(sys.pipe(&fd));
    return fd;
}

pub fn chdir(name: []const u8) Error!void {
    _ = try check(sys.chdir(name));
}

pub fn bind(name: []const u8, old: []const u8, flag: u32) Error!void {
    _ = try check(sys.bind(name, old, flag));
}

pub fn mount(fd: i32, afd: i32, old: []const u8, flag: u32, aname: ?[]const u8) Error!void {
    _ = try check(sys.mount(fd, afd, old, flag, aname));
}

pub fn unmount(name: ?[]const u8, old: []const u8) Error!void {
    _ = try check(sys.unmount(name, old));
}

pub fn sleep(ms: u32) Error!void {
    _ = try check(sys.sleep(ms));
}

/// The path of fd's file, in buf.
pub fn fd2path(fd: i32, buf: []u8) Error![]const u8 {
    _ = try check(sys.fd2path(fd, buf));
    return sys.upto0(buf);
}

pub fn rfork(flags: u32) Error!i32 {
    return checkfd(sys.rfork(flags));
}

/// Replace the program with name, giving it args (args[0] first).
/// Returns only on failure.
pub fn exec(name: []const u8, args: []const []const u8) (Error || std.mem.Allocator.Error) {
    var small: [32]sys.Str = undefined;
    const strs = if (args.len <= small.len) &small else try allocator.alloc(sys.Str, args.len);
    defer if (strs.len > small.len) allocator.free(strs);
    _ = sys.exec(name, strs, args);
    return error.Plan9;
}

/// Exit with msg as the exit status; null or empty for success.  A
/// message longer than ERRMAX-1 bytes is cut there.  The functions
/// given to atexit run first, the last one given first.
pub fn exits(msg: ?[]const u8) noreturn {
    onexit();
    sys.exits(msg);
}

pub fn nsec() i64 {
    return sys.nsec();
}

/// Seconds since the epoch.
/// from libc/9sys/time.c
pub fn time() i64 {
    return @divTrunc(nsec(), 1000000000);
}

/// The current directory, in buf.
/// from libc/9sys/getwd.c
pub fn getwd(buf: []u8) Error![]const u8 {
    const fd = try open(".", OREAD | OCEXEC);
    defer _ = sys.close(fd);
    return fd2path(fd, buf);
}

/// Whether name exists (AEXIST) or can be opened for the access
/// given (AREAD, AWRITE, AEXEC, or'd together).
/// from libc/9sys/access.c
pub fn access(name: []const u8, mode: u32) bool {
    if (mode == AEXIST) {
        var st = dirstat(allocator, name) catch return false;
        st.deinit(allocator);
        return true;
    }
    const omode = [8]u32{
        0,
        OEXEC,
        OWRITE,
        ORDWR,
        OREAD,
        OEXEC, // only approximate
        ORDWR,
        ORDWR, // only approximate
    };
    const fd = open(name, omode[mode & 7]) catch return false;
    _ = sys.close(fd);
    return true;
}

/// The largest read or write that fd's file server takes in one
/// message; 0 if it is not known.
/// from libc/9sys/iounit.c
pub fn iounit(fd: i32) usize {
    var buf: [128]u8 = undefined;
    const name = sprint(&buf, "/fd/%dctl", .{fd});
    const cfd = open(name, OREAD | OCEXEC) catch return 0;
    var b: [128]u8 = undefined;
    const n = sys.read(cfd, b[0 .. b.len - 1]);
    _ = sys.close(cfd);
    if (n <= 0)
        return 0;
    var args: [10][]u8 = undefined;
    if (string_.tokenize(b[0..@intCast(n)], &args) != args.len)
        return 0;
    const v = atoi(args[7]);
    return if (v > 0) @intCast(v) else 0;
}

/// from libc/port/atexit.c
/// DIFF: no lock (the library has no shared-memory processes yet) and
/// no atexitdont.
const Onex = struct {
    f: ?*const fn () void = null,
    pid: u32 = 0,
};
var onex: [33]Onex = @splat(.{});

fn onexit() void {
    const pid = proc_.getpid();
    var i = onex.len;
    while (i > 0) {
        i -= 1;
        if (onex[i].f) |f| {
            if (onex[i].pid == pid) {
                onex[i].f = null;
                f();
            }
        }
    }
}

/// Have f called when the process exits through exits.
pub fn atexit(f: *const fn () void) bool {
    for (&onex) |*o| {
        if (o.f == null) {
            o.pid = proc_.getpid();
            o.f = f;
            return true;
        }
    }
    return false;
}

// Formatted output

/// The state of fprint: a buffer flushed to fd.
const Out = struct {
    fd: i32,
    n: usize = 0,
    err: bool = false,
};

fn flushout(f: *fmt.Fmt) void {
    const o: *Out = @ptrCast(@alignCast(f.farg.?));
    if (f.n > 0 and !o.err) {
        writeall(o.fd, f.buf[0..f.n]) catch {
            o.err = true;
        };
        o.n += f.n;
    }
    f.n = 0;
}

/// Print to fd with the Plan 9 verbs of src/lib/fmt.zig, %r among them.
/// Errors are ignored, as most callers of the C's print do; fprintn
/// returns them.
pub fn fprint(fd: i32, comptime format: []const u8, args: anytype) void {
    _ = fprintn(fd, format, args) catch {};
}

/// As fprint; returns the number of bytes written.
pub fn fprintn(fd: i32, comptime format: []const u8, args: anytype) Error!usize {
    fmt.errstr = errtext;
    var buf: [256]u8 = undefined;
    var o: Out = .{ .fd = fd };
    var f: fmt.Fmt = .{ .buf = &buf, .flush = flushout, .farg = &o };
    fmt.fmtprint(&f, format, args);
    flushout(&f);
    if (o.err)
        return error.Plan9;
    return o.n;
}

/// Print to standard output.
pub fn print(comptime format: []const u8, args: anytype) void {
    fprint(1, format, args);
}

/// Format into buf and return the part written; what does not fit is
/// dropped.
/// from libc/fmt/snprint.c (sprint, snprint and seprint in one)
pub fn sprint(buf: []u8, comptime format: []const u8, args: anytype) []u8 {
    fmt.errstr = errtext;
    return fmt.snprint(buf, format, args);
}

/// Print "argv0: message" to standard error and exit with the message.
/// from libc/9sys/sysfatal.c
pub fn sysfatal(comptime format: []const u8, args: anytype) noreturn {
    var buf: [ERRMAX]u8 = undefined;
    const s = sprint(&buf, format, args);
    fprint(2, "%s: %s\n", .{ argv0, s });
    exits(s);
}

/// A std.Io.Writer that writes to a file descriptor, so that Zig's own
/// formatting ({d}, {s}) can be used as well:
///
///     var buf: [4096]u8 = undefined;
///     var w = libc.FdWriter.init(1, &buf);
///     try w.interface.print("{d}\n", .{n});
///     try w.interface.flush();
pub const FdWriter = struct {
    fd: i32,
    interface: std.Io.Writer,

    pub fn init(fd: i32, buffer: []u8) FdWriter {
        return .{ .fd = fd, .interface = .{ .vtable = &vtable, .buffer = buffer } };
    }

    const vtable: std.Io.Writer.VTable = .{ .drain = drain };

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *FdWriter = @fieldParentPtr("interface", w);
        if (w.end > 0) {
            writeall(self.fd, w.buffer[0..w.end]) catch return error.WriteFailed;
            w.end = 0;
        }
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |d| {
            writeall(self.fd, d) catch return error.WriteFailed;
            n += d.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| {
            writeall(self.fd, last) catch return error.WriteFailed;
            n += last.len;
        }
        return n;
    }
};

/// A std.Io.Reader that reads from a file descriptor.
pub const FdReader = struct {
    fd: i32,
    interface: std.Io.Reader,

    pub fn init(fd: i32, buffer: []u8) FdReader {
        return .{ .fd = fd, .interface = .{ .vtable = &vtable, .buffer = buffer, .seek = 0, .end = 0 } };
    }

    const vtable: std.Io.Reader.VTable = .{ .stream = stream };

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *FdReader = @fieldParentPtr("interface", r);
        const dest = limit.slice(try w.writableSliceGreedy(1));
        const n = read(self.fd, dest) catch return error.ReadFailed;
        if (n == 0)
            return error.EndOfStream;
        w.advance(n);
        return n;
    }
};

/// The panic handler of root.zig: print the message and exit with it.
pub fn panicfn(msg: []const u8, _: ?usize) noreturn {
    fprint(2, "%s: panic: %s\n", .{ argv0, msg });
    var buf: [ERRMAX]u8 = undefined;
    const s = sprint(&buf, "panic: %s", .{msg});
    exits(s);
}
