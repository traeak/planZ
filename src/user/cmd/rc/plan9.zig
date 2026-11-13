//! rc's system interface for Plan 9.
//! from cmd/rc/plan9.c
//!
//! The builtins of plan9.c's table (finit, rfork) are in simple.zig.
//!
//! DIFF:
//!   - Notes come through libc's atnotify, whose handler returning true
//!     is the C's noted(NCONT) and false its noted(NDFLT).
//!   - Exec takes the arguments as slices (planZ's exec with slices).

const std = @import("std");
const rc = @import("rc.zig");
const io = @import("io.zig");
const exec = @import("exec.zig");
const @"var" = @import("var.zig");
const trap = @import("trap.zig");
const libc = rc.libc;

pub const Rcmain = "/rc/lib/rcmain";
pub const Fdprefix = "/fd/";

/// The trap function for each note; the C's list ends at sigterm, and
/// no note sets a trap past it.
pub const Signame: [rc.NSIG]?[]const u8 = blk: {
    var t: [rc.NSIG]?[]const u8 = @splat(null);
    for ([_][]const u8{ "sigexit", "sighup", "sigint", "sigquit", "sigalrm", "sigkill", "sigfpe", "sigterm" }, 0..) |n, i|
        t[i] = n;
    break :blk t;
};

const syssigname = [_][]const u8{
    "exit", // can't happen
    "hangup",
    "interrupt",
    "quit", // can't happen
    "alarm",
    "kill",
    "sys: fp: ",
    "term",
};

var envbuf: [128]u8 = undefined;

/// /env/name or /env/fn#name, cut to 127 bytes as the C's snprint does.
pub fn Env(name: []const u8, @"fn": bool) []const u8 {
    var w = std.Io.Writer.fixed(envbuf[0 .. envbuf.len - 1]);
    w.writeAll("/env/") catch {};
    if (@"fn") w.writeAll("fn#") catch {};
    w.writeAll(name) catch {};
    return w.buffered();
}

pub fn Vinit() void {
    const dir = Open(Env("", false), 0);
    if (dir < 0) {
        io.pfmt(exec.err, "%s: can't open: %s\n", .{ rc.argv0, Errstr() });
        return;
    }
    while (true) {
        var ds = libc.dirread(rc.a, dir) catch break;
        defer ds.deinit(rc.a);
        if (ds.dirs.len == 0)
            break;
        for (ds.dirs) |*ent| {
            if (ent.length <= 0 or std.mem.startsWith(u8, ent.name, "fn#"))
                continue;
            const fd = Open(Env(ent.name, false), 0);
            if (fd >= 0) {
                const f = io.openiofd(fd);
                var w: ?*rc.Word = null;
                var wp: *?*rc.Word = &w;
                while (io.rstr(f, "")) |s| {
                    const n = exec.Newword(s, null);
                    wp.* = n;
                    wp = &n.next;
                }
                io.closeio(f);
                @"var".setvar(ent.name, w);
                @"var".vlook(ent.name).changed = false;
            }
        }
    }
    Close(dir);
}

var errbuf: [libc.ERRMAX]u8 = undefined;

pub fn Errstr() []const u8 {
    return libc.rerrstr(&errbuf);
}

pub fn Waitfor(pid: i32) i32 {
    const havefork = @import("havefork.zig");
    if (pid >= 0 and !havefork.havewaitpid(pid))
        return 0;

    while (libc.wait()) |w| {
        havefork.delwaitpid(w.pid);
        if (w.pid == pid) {
            exec.setstatus(w.msg());
            return 0;
        }
        var p = exec.rq().ret;
        while (p) |t| : (p = t.ret) {
            if (t.pid == w.pid) {
                t.pid = -1;
                t.status = rc.estrdup(w.msg());
                break;
            }
        }
    } else |_| {}

    if (std.mem.eql(u8, Errstr(), "interrupted")) return -1;
    return 0;
}

fn addenv(v: *rc.Var) void {
    if (v.changed) {
        v.changed = false;
        const fd = Creat(Env(v.name, false));
        if (fd < 0)
            io.pfmt(exec.err, "%s: can't open: %s\n", .{ rc.argv0, Errstr() })
        else {
            const f = io.openiofd(fd);
            var w = v.val;
            while (w) |x| : (w = x.next) {
                io.pstr(f, x.word);
                io.pchr(f, 0);
            }
            io.flushio(f);
            io.closeio(f);
        }
    }
    if (v.fnchanged) {
        v.fnchanged = false;
        const fd = Creat(Env(v.name, true));
        if (fd < 0)
            io.pfmt(exec.err, "%s: can't open: %s\n", .{ rc.argv0, Errstr() })
        else {
            const f = io.openiofd(fd);
            if (v.@"fn") |c|
                io.pfmt(f, "fn %q %s\n", .{ v.name, c.inst[v.pc - 1].@"fn".str });
            io.flushio(f);
            io.closeio(f);
        }
    }
}

fn updenvlocal(v_: ?*rc.Var) void {
    if (v_) |v| {
        updenvlocal(v.next);
        addenv(v);
    }
}

pub fn Updenv() void {
    for (&@"var".gvar) |h| {
        var v = h;
        while (v) |x| : (v = x.next)
            addenv(x);
    }
    if (exec.runq) |r|
        updenvlocal(r.local);
    if (exec.err_open)
        io.flushio(exec.err);
}

/// exec(argv[0], argv+1)
pub fn Exec(argv: [][]const u8) void {
    libc.exec(argv[0], argv[1..]) catch {};
}

pub fn Fork() i32 {
    Updenv();
    return Rfork(libc.sys.RFPROC | libc.sys.RFFDG | libc.sys.RFREND);
}

pub fn Rfork(flags: u32) i32 {
    return libc.rfork(flags) catch -1;
}

/// An open directory, read a block of entries at a time.
pub const Rdir = struct {
    dirs: ?libc.Dirs = null,
    i: usize = 0,
    fd: i32,
};

pub fn Opendir(name: []const u8) ?*Rdir {
    const fd = Open(name, 0);
    if (fd < 0)
        return null;
    const rd = rc.new(Rdir);
    rd.* = .{ .fd = fd };
    return rd;
}

/// The next entry's name, of directories only if onlydirs; it lasts
/// until the next call.
pub fn Readdir(rd: *Rdir, onlydirs: bool) ?[]const u8 {
    while (true) {
        if (rd.dirs) |*d| {
            while (rd.i < d.dirs.len) {
                const e = &d.dirs[rd.i];
                rd.i += 1;
                if (!onlydirs or e.mode & libc.DMDIR != 0)
                    return e.name;
            }
            d.deinit(rc.a);
            rd.dirs = null;
        }
        const d = libc.dirread(rc.a, rd.fd) catch return null;
        if (d.dirs.len == 0) {
            var dd = d;
            dd.deinit(rc.a);
            return null;
        }
        rd.dirs = d;
        rd.i = 0;
    }
}

pub fn Closedir(rd: *Rdir) void {
    Close(rd.fd);
    if (rd.dirs) |*d| d.deinit(rc.a);
    rc.destroy(rd);
}

var interrupted = false;

fn notifyf(_: *anyopaque, s: []const u8) bool {
    for (syssigname, 0..) |n, i| {
        if (std.mem.startsWith(u8, s, n)) {
            if (!std.mem.startsWith(u8, s, "sys: ")) interrupted = true;
            if (!std.mem.eql(u8, s, "interrupt") or trap.trap[i] == 0) {
                trap.trap[i] += 1;
                trap.ntrap += 1;
            }
            return true; // noted(NCONT)
        }
    }
    return false; // noted(NDFLT)
}

pub fn Trapinit() void {
    _ = libc.atnotify(&notifyf, true);
}

pub fn Write(fd: i32, buf: []const u8) i64 {
    const n = libc.write(fd, buf) catch return -1;
    return @intCast(n);
}

pub fn Read(fd: i32, buf: []u8) i64 {
    const n = libc.read(fd, buf) catch return -1;
    return @intCast(n);
}

pub fn Seek(fd: i32, n: i64, whence: u32) i64 {
    return libc.seek(fd, n, whence) catch -1;
}

pub fn Executable(file: []const u8) bool {
    var st = libc.dirstat(rc.a, file) catch return false;
    defer st.deinit(rc.a);
    return st.dir.mode & 0o111 != 0 and st.dir.mode & libc.DMDIR == 0;
}

pub fn Open(file: []const u8, mode: u32) i32 {
    const tab = [_]u32{ libc.OREAD, libc.OWRITE, libc.ORDWR, libc.OREAD | libc.ORCLOSE };
    return libc.open(file, tab[mode & 3]) catch -1;
}

pub fn Close(fd: i32) void {
    libc.close(fd) catch {};
}

pub fn Creat(file: []const u8) i32 {
    return libc.create(file, libc.OWRITE, 0o666) catch -1;
}

pub fn Dup(a: i32, b: i32) i32 {
    return libc.dup(a, b) catch -1;
}

pub fn Dup1(a: i32) i32 {
    return libc.dup(a, -1) catch -1;
}

pub fn Exit() noreturn {
    Updenv();
    libc.exits(if (exec.truestatus()) "" else exec.getstatus());
}

pub fn Eintr() bool {
    return interrupted;
}

pub fn Noerror() void {
    interrupted = false;
}

pub fn Isatty(fd: i32) bool {
    var buf: [64]u8 = undefined;
    const p = libc.fd2path(fd, &buf) catch return false;
    // might be /mnt/term/dev/cons
    return p.len >= 9 and std.mem.endsWith(u8, p, "/dev/cons");
}

/// abort: fault, as 9front's abort does by reading address 0.
pub fn Abort() noreturn {
    const p: *allowzero volatile i32 = @ptrFromInt(0);
    while (p.* != 0) {}
    unreachable;
}

var newwdir = false;

pub fn Chdir(dir: []const u8) i32 {
    newwdir = true;
    libc.chdir(dir) catch return -1;
    return 0;
}

pub fn Prompt(s: []const u8) void {
    io.pstr(exec.err, s);
    io.flushio(exec.err);

    if (newwdir) {
        const fd = Creat("/dev/wdir");
        if (fd >= 0) {
            var dir: [4096]u8 = undefined;
            const d = libc.getwd(&dir) catch "";
            _ = Write(fd, d);
            Close(fd);
        }
        newwdir = false;
    }
}
