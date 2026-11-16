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
pub const pool = @import("pool");
pub const fcall = @import("fcall");

pub const sys = @import("sys.zig");
const malloc_ = @import("malloc.zig");
const dir_ = @import("dir.zig");
const proc_ = @import("proc.zig");
const string_ = @import("string.zig");

/// The start-up code; root.zig exports it.
pub const start = @import("start.zig");
pub const srv = @import("srv.zig");

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

/// What each process has of its own though the processes share their
/// memory: it is in the stack segment, which rfork copies and never
/// shares, so the one address holds each process's own (start.zig
/// puts it in the frame under main).
/// from libc/9sys/callmain.c (privates)
pub const Private = struct {
    /// The words privalloc gives out.
    privates: [NPRIVATES]usize = @splat(0),
    /// %r's copy of the error string.  DIFF: the C's %r reads the
    /// string into the caller's frame.
    errbuf: [ERRMAX]u8 = undefined,
};
pub const NPRIVATES = 16;
pub var private: *Private = undefined;
var nprivates: usize = NPRIVATES;
var privlock: Lock = .{};

/// A word that each process sharing memory has its own of: the same
/// pointer in all of them, a different word behind it.  Null when the
/// 16 are given out.  A new process starts with a copy of its parent's.
/// from libc/9sys/privalloc.c
pub fn privalloc() ?*usize {
    lock(&privlock);
    defer unlock(&privlock);
    if (nprivates == 0)
        return null;
    nprivates -= 1;
    return &private.privates[nprivates];
}
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
pub const dirmode = dir_.dirmode;

// Processes

pub const Waitmsg = proc_.Waitmsg;
pub const fork = proc_.fork;
pub const wait = proc_.wait;
pub const waitpid = proc_.waitpid;
pub const getpid = proc_.getpid;
pub const getuser = proc_.getuser;
pub const getenv = proc_.getenv;
pub const putenv = proc_.putenv;
pub const atnotify = proc_.atnotify;
pub const postnote = proc_.postnote;
pub const PNPROC = proc_.PNPROC;
pub const PNGROUP = proc_.PNGROUP;
pub const spawn = proc_.spawn;

// Locks and atomic operations, for processes that share memory

const lock_ = @import("lock.zig");
pub const Lock = lock_.Lock;
pub const lock = lock_.lock;
pub const canlock = lock_.canlock;
pub const unlock = lock_.unlock;
pub const QLock = lock_.QLock;
pub const QLp = lock_.QLp;
pub const qlock = lock_.qlock;
pub const canqlock = lock_.canqlock;
pub const qunlock = lock_.qunlock;
pub const RWLock = lock_.RWLock;
pub const rlock = lock_.rlock;
pub const canrlock = lock_.canrlock;
pub const runlock = lock_.runlock;
pub const wlock = lock_.wlock;
pub const canwlock = lock_.canwlock;
pub const wunlock = lock_.wunlock;
pub const Rendez = lock_.Rendez;
pub const rsleep = lock_.rsleep;
pub const rwakeup = lock_.rwakeup;
pub const rwakeupall = lock_.rwakeupall;
pub const qlockinit = lock_.qlockinit;
pub const ainc = lock_.ainc;
pub const adec = lock_.adec;
pub const Along = lock_.Along;
pub const Avlong = lock_.Avlong;
pub const Aptr = lock_.Aptr;
pub const agetl = lock_.agetl;
pub const agetv = lock_.agetv;
pub const agetp = lock_.agetp;
pub const aswapl = lock_.aswapl;
pub const aswapv = lock_.aswapv;
pub const aswapp = lock_.aswapp;
pub const aincl = lock_.aincl;
pub const aincv = lock_.aincv;
pub const acasl = lock_.acasl;
pub const acasv = lock_.acasv;
pub const acasp = lock_.acasp;
pub const coherence = lock_.coherence;

// Random numbers

const rand_ = @import("rand.zig");
pub const srand = rand_.srand;
pub const rand = rand_.rand;
pub const lrand = rand_.lrand;
pub const nrand = rand_.nrand;
pub const lnrand = rand_.lnrand;

// Strings and arguments

pub const tokenize = string_.tokenize;
pub const gettokens = string_.gettokens;
pub const getfields = string_.getfields;
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

// Dates and times (tm.zig, date.zig)

const date_ = @import("date.zig");
pub const Tm = date_.Tm;
pub const Tzone = date_.Tzone;
pub const tzload = date_.tzload;
pub const tmnow = date_.tmnow;
pub const tmtime = date_.tmtime;
pub const tmtimens = date_.tmtimens;
pub const tmnorm = date_.tmnorm;
pub const tmfmt = date_.tmfmt;
pub const tmfmtarg = date_.tmfmtarg;
pub const tmparse = date_.tmparse;
pub const localtime = date_.localtime;
pub const gmtime = date_.gmtime;
pub const asctime = date_.asctime;
pub const ctime = date_.ctime;
pub const ascraw = date_.ascraw;

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

/// For %r.
pub fn errtext() []const u8 {
    return rerrstr(&private.errbuf);
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

/// Read one 9P message from fd into buf: its length, or 0 at the end of
/// the file (or a message cut short).
/// from libc/9sys/read9pmsg.c
/// DIFF: an error union for the C's -1.
pub fn read9pmsg(fd: i32, buf: []u8) Error!usize {
    const sz = fcall.BIT32SZ;
    if (buf.len < sz) {
        werrstr("bad length in 9P2000 message header", .{});
        return error.Plan9;
    }
    // read count
    if (try readn(fd, buf[0..sz]) != sz)
        return 0;
    const len = fcall.GBIT32(buf, 0);
    if (len <= sz or len > buf.len) {
        werrstr("bad length in 9P2000 message header", .{});
        return error.Plan9;
    }
    const m = try readn(fd, buf[sz..len]);
    if (m < len - sz)
        return 0;
    return len;
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

/// Meet the process that calls with the same tag (one that shares the
/// rendezvous group): each gets the other's value.  Fails if a note
/// interrupts the wait.
pub fn rendezvous(tag: usize, val: usize) Error!usize {
    const r = sys.rendezvous(tag, val);
    if (r == ~@as(usize, 0))
        return error.Plan9;
    return r;
}

/// Take one from the semaphore at addr, waiting until it is above 0 if
/// block is set.  Returns whether it was taken; fails if a note
/// interrupts the wait.
pub fn semacquire(addr: *i32, block: bool) Error!bool {
    return try check(sys.semacquire(addr, block)) != 0;
}

/// As semacquire, waiting at most ms milliseconds.
pub fn tsemacquire(addr: *i32, ms: u32) Error!bool {
    return try check(sys.tsemacquire(addr, ms)) != 0;
}

/// Add count to the semaphore and wake those that wait for it; returns
/// its new value.
pub fn semrelease(addr: *i32, count: i32) Error!i32 {
    return @intCast(try check(sys.semrelease(addr, count)));
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
const Onex = struct {
    f: ?*const fn () void = null,
    pid: u32 = 0,
};
var onexlock: Lock = .{};
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

/// Have f called when this process exits through exits: of the
/// processes that share memory, only in the one that asked.
pub fn atexit(f: *const fn () void) bool {
    lock(&onexlock);
    defer unlock(&onexlock);
    for (&onex) |*o| {
        if (o.f == null) {
            o.pid = proc_.getpid();
            o.f = f;
            return true;
        }
    }
    return false;
}

/// Take back what this process asked of atexit for f.
pub fn atexitdont(f: *const fn () void) void {
    const pid = proc_.getpid();
    for (&onex) |*o| {
        if (o.f == f and o.pid == pid)
            o.f = null;
    }
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
    if (fatalhook) |h|
        h(s);
    exits(s);
}

/// How a program of several processes ends on sysfatal or a panic,
/// after the message is printed: libthread sets it to end them all
/// (the C's _sysfatal).
pub var fatalhook: ?*const fn (msg: []const u8) noreturn = null;

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
    if (fatalhook) |h|
        h(s);
    exits(s);
}
