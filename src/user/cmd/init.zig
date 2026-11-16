//! init - the first program after boot: the user's name space, and rc
//! from /sys/src/cmd/init.c
//!
//! usage: init [-ctm] [command]

const std = @import("std");
const libc = @import("libc");
const auth = @import("auth");
const sys = libc.sys;

var service: []const u8 = "cpu";
var cmd: ?[]const u8 = null;
var cpu: []const u8 = "";
var systemname: []const u8 = "";
var manual = false;
var iscpu = false;

pub fn main(argv_: []const []const u8) void {
    closefds();

    service = "cpu";
    manual = false;
    var args = libc.Args.init(argv_);
    while (args.next()) |c| switch (c) {
        'c' => service = "cpu",
        'm' => manual = true,
        't' => service = "terminal",
        else => {},
    };
    const argv = args.rest();
    cmd = if (argv.len > 0) argv[0] else null;

    const fd = procopen(@intCast(libc.getpid()), "ctl", sys.OWRITE);
    if (fd >= 0) {
        if (sys.write(fd, "pri 10") != 6)
            libc.fprint(2, "init: warning: can't set priority: %r\n", .{});
        _ = sys.close(fd);
    }

    cpu = readenv("#e/cputype");
    setenv("#e/objtype", cpu);
    setenv("#e/service", service);
    cpenv("/adm/timezone/local", "#e/timezone");

    const user = readenv("#c/user");
    systemname = readenv("#c/sysname");

    auth.newns(user, null) catch {};
    iscpu = std.mem.eql(u8, service, "cpu");

    if (iscpu and !manual)
        fexec(cpustart);

    while (true) {
        libc.fprint(2, "\ninit: starting /bin/rc\n", .{});
        fexec(rcexec);
        manual = true;
        cmd = null;
        _ = sys.sleep(1000);
    }
}

var gotnote: bool = false;
var interrupted: bool = false;

comptime {
    asm (
        \\ .text
        \\ .globl _initnotetramp
        \\_initnotetramp:
        \\ movq 8(%rsp), %rdi
        \\ movq 16(%rsp), %rsi
        \\ andq $-16, %rsp
        \\ call _initpinhead
        \\ hlt
    );
}

extern fn _initnotetramp() callconv(.c) void;

// DIFF: the kernel enters a note handler the Plan 9 way, so a small
// trampoline calls it (as libc's atnotify has).
export fn _initpinhead(_: ?*anyopaque, m: [*]const u8) callconv(.c) void {
    const msg = sys.span(m);
    @atomicStore(bool, &gotnote, true, .seq_cst);
    if (std.mem.eql(u8, msg, "interrupt"))
        @atomicStore(bool, &interrupted, true, .seq_cst)
    else
        libc.fprint(2, "init got note '%s'\n", .{msg});
    _ = sys.noted(sys.NCONT);
}

fn fexec(execfn: *const fn () void) void {
    const pid = sys.rfork(sys.RFPROC | sys.RFFDG | sys.RFREND);
    if (pid == 0) {
        _ = sys.rfork(sys.RFNOTEG);
        execfn();
        libc.fprint(2, "init: exec error: %r\n", .{});
        libc.exits("exec");
    }
    if (pid < 0) {
        libc.fprint(2, "init: fork error: %r\n", .{});
        return;
    }
    const fd = procopen(@intCast(pid), "notepg", sys.OWRITE);
    while (true) {
        _ = sys.notify(&_initnotetramp);
        @atomicStore(bool, &interrupted, false, .seq_cst);
        @atomicStore(bool, &gotnote, false, .seq_cst);
        const w = libc.wait() catch {
            if (@atomicLoad(bool, &interrupted, .seq_cst) and fd >= 0)
                _ = sys.write(fd, "interrupt");
            if (@atomicLoad(bool, &gotnote, .seq_cst))
                continue;
            libc.fprint(2, "init: wait error: %r\n", .{});
            break;
        };
        if (w.pid != pid)
            continue;
        if (std.mem.indexOf(u8, w.msg(), "exec error") != null) {
            libc.fprint(2, "init: exit string %s\n", .{w.msg()});
            libc.fprint(2, "init: sleeping because exec failed\n", .{});
            while (true)
                _ = sys.sleep(1000);
        }
        if (w.msg().len != 0)
            libc.fprint(2, "init: rc exit status: %s\n", .{w.msg()});
        break;
    }
    if (fd >= 0)
        _ = sys.close(fd);
}

fn execl(args: []const []const u8) void {
    _ = libc.exec("/bin/rc", args) catch {};
}

fn rcexec() void {
    if (cmd) |c|
        execl(&.{ "rc", "-c", c })
    else if (manual or iscpu)
        execl(&.{"rc"})
    else if (std.mem.eql(u8, service, "terminal"))
        execl(&.{ "rc", "-c", ". /rc/bin/termrc; home=/usr/$user; cd && . ./lib/profile" })
    else
        execl(&.{"rc"});
}

fn cpustart() void {
    execl(&.{ "rc", "-c", "/rc/bin/cpurc" });
}

fn readfile(name: []const u8) ?[]u8 {
    const f = sys.open(name, sys.OREAD);
    if (f < 0) {
        libc.fprint(2, "init: can't open %s: %r\n", .{name});
        return null;
    }
    defer _ = sys.close(f);
    var st = libc.dirfstat(libc.allocator, @intCast(f)) catch {
        libc.fprint(2, "init: can't stat %s: %r\n", .{name});
        return null;
    };
    var len: usize = @intCast(st.dir.length);
    st.deinit(libc.allocator);
    if (len == 0) // device files can be zero length but have contents
        len = 64;
    const val = libc.allocator.alloc(u8, len) catch {
        libc.fprint(2, "init: can't malloc %s: %r\n", .{name});
        return null;
    };
    const n = sys.read(f, val);
    if (n < 0) {
        libc.fprint(2, "init: can't read %s: %r\n", .{name});
        return null;
    }
    return val[0..@intCast(n)];
}

fn readenv(name: []const u8) []const u8 {
    return readfile(name) orelse "*unknown*";
}

fn setenv(name: []const u8, val: []const u8) void {
    const fd = sys.create(name, sys.OWRITE, 0o644);
    if (fd < 0)
        libc.fprint(2, "init: can't create %s: %r\n", .{name})
    else {
        _ = sys.write(fd, val);
        _ = sys.close(fd);
    }
}

fn cpenv(from: []const u8, to: []const u8) void {
    if (readfile(from)) |val|
        setenv(to, val);
}

/// clean up after /boot
fn closefds() void {
    var i: i32 = 3;
    while (i < 30) : (i += 1)
        _ = sys.close(i);
}

fn procopen(pid: i32, name: []const u8, mode: u32) isize {
    var buf: [128]u8 = undefined;

    const fd = sys.open(libc.sprint(&buf, "#p/%d/%s", .{ pid, name }), mode);
    if (fd < 0)
        libc.fprint(2, "init: warning: can't open %s: %r\n", .{name});
    return fd;
}
