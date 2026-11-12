//! libctest - exercise the parts of the library the commands do not:
//! Zig's containers on the library's allocator, the Io.Writer over a
//! file descriptor, dirstat and dirfstat, the environment, fork and
//! wait with an exit message, notes through atnotify, %r and seek.
//! Prints one line per check and "libctest ok" at the end; exits with
//! the name of the first check that fails.
//!
//! Not part of 9front.

const std = @import("std");
const libc = @import("libc");

const a = libc.allocator;

fn fail(comptime what: []const u8) noreturn {
    libc.fprint(2, "libctest: %s failed: %r\n", .{what});
    libc.exits(what);
}

fn ok(comptime what: []const u8) void {
    libc.print("%s ok\n", .{what});
}

var notes: u32 = 0;

fn onnote(_: *anyopaque, msg: []const u8) bool {
    if (std.mem.eql(u8, msg, "alarm")) {
        notes += 1;
        return true;
    }
    return false;
}

pub fn main() !void {
    // memory: a list, a map, and a block bigger than an arena
    var l: std.ArrayList(u64) = .empty;
    for (0..10000) |i| try l.append(a, i * i);
    var m: std.StringHashMapUnmanaged(usize) = .empty;
    try m.put(a, "planZ", 9);
    const big = try a.alloc(u8, 1 << 20);
    @memset(big, 0xA5);
    const aligned = try a.alignedAlloc(u8, .fromByteUnits(4096), 100);
    if (@intFromPtr(aligned.ptr) % 4096 != 0) fail("alignment");
    if (l.items[9999] != 9999 * 9999 or m.get("planZ").? != 9 or big[12345] != 0xA5) fail("memory");
    a.free(big);
    a.free(aligned);
    l.deinit(a);
    ok("memory");

    // Zig's formatting through an FdWriter
    var wb: [64]u8 = undefined;
    var w = libc.FdWriter.init(1, &wb);
    try w.interface.print("writer {d} {s} ok\n", .{ 42, "zig" });
    try w.interface.flush();

    // stat by name and by descriptor
    var st = try libc.dirstat(a, "/dev/cons");
    defer st.deinit(a);
    if (!std.mem.eql(u8, st.dir.name, "cons")) fail("dirstat");
    const fd = try libc.open("/env", libc.OREAD);
    var fst = try libc.dirfstat(a, fd);
    defer fst.deinit(a);
    if ((fst.dir.mode & libc.DMDIR) == 0) fail("dirfstat");
    try libc.close(fd);
    ok("stat");

    // errors and %r
    if (libc.open("/nonexistent/x", libc.OREAD)) |_| fail("open of nothing") else |_| {}
    var eb: [libc.ERRMAX]u8 = undefined;
    const e = libc.rerrstr(&eb);
    if (std.mem.indexOf(u8, e, "does not exist") == null) fail("errstr");
    // rerrstr must not have cleared it
    if (std.mem.indexOf(u8, libc.rerrstr(&eb), "does not exist") == null) fail("rerrstr");
    var pb: [200]u8 = undefined;
    const ps = libc.sprint(&pb, "[%r]", .{});
    if (std.mem.indexOf(u8, ps, "does not exist") == null) fail("%r");
    ok("errstr");

    // environment
    try libc.putenv("libctest", "one two");
    const v = (try libc.getenv(a, "libctest")) orelse fail("getenv");
    if (!std.mem.eql(u8, v, "one two")) fail("getenv value");
    a.free(v);
    if ((try libc.getenv(a, "libctest-none")) != null) fail("getenv of nothing");
    ok("env");

    // fork and wait: the child's exit message comes back
    const pid = try libc.fork();
    if (pid == 0) {
        // the child has its own copy of the parent's memory
        if (m.get("planZ").? != 9) libc.exits("child memory");
        libc.exits("child says hi");
    }
    const wm = try libc.wait();
    // the kernel puts the child's name and pid in front: "zlibctest 123: child says hi"
    if (wm.pid != pid or !std.mem.endsWith(u8, wm.msg(), ": child says hi")) {
        libc.werrstr("pid %d msg '%s'", .{ wm.pid, wm.msg() });
        fail("wait");
    }
    ok("fork");

    // notes: an alarm handled by atnotify
    if (!libc.atnotify(onnote, true)) fail("atnotify");
    _ = libc.sys.alarm(50);
    _ = libc.sys.sleep(1000); // the alarm interrupts it
    if (notes != 1) fail("note");
    ok("notes");

    // seek on a pipe fails, on a file it works
    const p = try libc.pipe();
    if (libc.seek(p[0], 0, 0)) |_| fail("seek on pipe") else |_| {}
    const tf = try libc.create("/tmp/libctest", libc.ORDWR, 0o666);
    try libc.writeall(tf, "0123456789");
    if (try libc.seek(tf, 3, 0) != 3) fail("seek");
    var rb: [4]u8 = undefined;
    if (try libc.readn(tf, &rb) != 4 or !std.mem.eql(u8, &rb, "3456")) fail("read after seek");
    try libc.close(tf);
    try libc.remove("/tmp/libctest");
    ok("seek");

    libc.print("libctest ok\n", .{});
}
