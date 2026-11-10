//! planZ's own /boot/boot, until the real one can be used: a user-mode
//! self-test.  It exercises the system calls a shell needs and prints
//! "usertest ok", the line `zig build test-boot` waits for.
//!
//! Not part of 9front.  When stock 9front binaries are available this
//! is replaced by the real boot program.

const sys = @import("sys.zig");

comptime {
    asm (
        \\ .section .text.start, "ax"
        \\ .globl _start
        \\_start:
        \\ movq %rsp, %rdi             /* argc, argv */
        \\ movq %rax, %rsi             /* Tos, as exec returns it */
        \\ andq $-16, %rsp
        \\ call main
    );
}

fn print(s: []const u8) void {
    _ = sys.write(1, s);
}

fn printnum(v: usize) void {
    var buf: [20]u8 = undefined;
    var i: usize = buf.len;
    var n = v;
    while (true) {
        i -= 1;
        buf[i] = '0' + @as(u8, @intCast(n % 10));
        n /= 10;
        if (n == 0) break;
    }
    print(buf[i..]);
}

fn fail(what: []const u8) noreturn {
    var err: [sys.ERRMAX]u8 = undefined;
    err[0] = 0;
    _ = sys.errstr(&err);
    print("usertest: FAILED: ");
    print(what);
    print(": ");
    print(cstr(@ptrCast(&err)));
    print("\n");
    while (true) _ = sys.sleep(1000);
}

fn cstr(p: [*:0]const u8) []const u8 {
    var n: usize = 0;
    while (p[n] != 0) n += 1;
    return p[0..n];
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}

fn contains(hay: []const u8, needle: []const u8) bool {
    if (needle.len > hay.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (eql(hay[i..][0..needle.len], needle)) return true;
    }
    return false;
}

// In the data and bss segments, to see that both are mapped and that a
// child gets its own copy.
var counter: u32 = 7;
var zeroed: [8192]u8 = @splat(0);
var notes: u32 = 0;

extern var end: u8;

// The kernel enters a note handler the Plan 9 way: a null return
// address, then the Ureg pointer and the message, on the stack.
comptime {
    asm (
        \\ .text
        \\ .globl notetramp
        \\notetramp:
        \\ movq 8(%rsp), %rdi
        \\ movq 16(%rsp), %rsi
        \\ andq $-16, %rsp
        \\ call handler
    );
}

extern fn notetramp() callconv(.c) void;

export fn handler(_: *anyopaque, msg: [*:0]const u8) callconv(.c) void {
    if (eql(cstr(msg), "alarm")) {
        notes += 1;
        _ = sys.noted(sys.NCONT);
    }
    _ = sys.noted(sys.NDFLT);
}

/// Wait for a child and return its exit message (after "pid user sys real ").
fn waitmsg(buf: []u8) []const u8 {
    const n = sys.await(buf[0 .. buf.len - 1]);
    if (n < 0) fail("await");
    var s: []const u8 = buf[0..@intCast(n)];
    // Four numbers, then the quoted message.
    var fields: usize = 0;
    var i: usize = 0;
    while (i < s.len and fields < 4) : (i += 1) {
        if (s[i] == ' ') fields += 1;
    }
    s = s[i..];
    return s;
}

export fn main(sp: [*]usize, tos: usize) callconv(.c) noreturn {
    const argc = sp[0];
    const argv: [*]const ?[*:0]const u8 = @ptrCast(sp + 1);

    // Second life: started by the exec test below.
    if (argc == 2 and eql(cstr(argv[1].?), "execd")) {
        if (counter != 7) sys.exits("data segment not fresh after exec");
        sys.exits("execd ok");
    }

    print("usertest: hello from user mode\n");
    if (argc != 1 or !eql(cstr(argv[0].?), "boot")) fail("argv");
    if (tos == 0) fail("no Tos");

    // Data, bss and the stack.
    if (counter != 7) fail("data segment");
    const zp: *volatile [zeroed.len]u8 = &zeroed;
    for (zp) |*c| {
        if (c.* != 0) fail("bss not zero");
    }
    zp[100] = 1;
    counter += 1;

    // Errors come back as -1 and a string.
    if (sys.open("/no/such/file", sys.OREAD) != -1) fail("open of a missing file worked");
    var err: [sys.ERRMAX]u8 = undefined;
    _ = sys.errstr(&err);
    if (!contains(cstr(@ptrCast(&err)), "does not exist")) fail("errstr");

    // Files.
    var buf: [256]u8 = undefined;
    const fd = sys.open("/dev/pid", sys.OREAD);
    if (fd < 0) fail("open /dev/pid");
    const n = sys.read(fd, &buf);
    if (n <= 0) fail("read /dev/pid");
    if (sys.fd2path(fd, &buf) < 0 or !eql(cstr(@ptrCast(&buf)), "/dev/pid")) fail("fd2path");
    _ = sys.close(fd);

    const e = sys.create("/env/usertest", sys.OWRITE, 0o666);
    if (e < 0) fail("create /env/usertest");
    if (sys.write(e, "value") != 5) fail("write /env/usertest");
    _ = sys.close(e);
    const e2 = sys.open("/env/usertest", sys.OREAD);
    if (e2 < 0 or sys.read(e2, &buf) != 5 or !eql(buf[0..5], "value")) fail("read back /env/usertest");
    _ = sys.close(e2);

    // The heap: grow the bss and use it.
    const base = @intFromPtr(&end);
    if (sys.brk(base + 1024 * 1024) < 0) fail("brk");
    const heap: [*]volatile u8 = @ptrFromInt(base);
    var i: usize = 0;
    while (i < 1024 * 1024) : (i += 4096) {
        if (heap[i] != 0) fail("heap not zero");
        heap[i] = @truncate(i >> 12);
    }
    i = 0;
    while (i < 1024 * 1024) : (i += 4096) {
        if (heap[i] != @as(u8, @truncate(i >> 12))) fail("heap lost data");
    }

    // Floating point: the first use traps to the kernel to get a state.
    var x: f64 = 1.5;
    const xp: *volatile f64 = &x;
    xp.* = xp.* * 2.0 + 0.25;
    if (xp.* != 3.25) fail("floating point");

    // fork: the child has a copy of memory, the parent keeps its own;
    // a pipe carries data between them; the exit message comes back.
    var p: [2]i32 = undefined;
    if (sys.pipe(&p) < 0) fail("pipe");
    const pid = sys.rfork(sys.RFPROC | sys.RFFDG);
    if (pid < 0) fail("rfork");
    if (pid == 0) {
        if (counter != 8) sys.exits("child did not get a copy of data");
        counter = 100;
        xp.* += 1.0; // the child inherits floating point state
        if (xp.* != 4.25) sys.exits("child floating point");
        _ = sys.close(p[0]);
        if (sys.write(p[1], "from the child") != 14) sys.exits("child write");
        sys.exits("child done");
    }
    _ = sys.close(p[1]);
    const got = sys.read(p[0], &buf);
    if (got != 14 or !eql(buf[0..14], "from the child")) fail("pipe from child");
    if (sys.read(p[0], &buf) != 0) fail("no EOF after child exit");
    _ = sys.close(p[0]);
    if (!contains(waitmsg(&buf), "child done")) fail("child exit message");
    if (counter != 8) fail("child wrote on the parent's memory");
    if (xp.* != 3.25) fail("parent floating point changed");

    // exec in a child: argument passing and a fresh image.
    const pid2 = sys.rfork(sys.RFPROC | sys.RFFDG);
    if (pid2 < 0) fail("rfork");
    if (pid2 == 0) {
        const args = [_]?[*:0]const u8{ "boot", "execd", null };
        _ = sys.exec("/boot/boot", &args);
        sys.exits("exec failed");
    }
    if (!contains(waitmsg(&buf), "execd ok")) fail("exec'd child exit message");

    // Shared memory and rendezvous.
    const pid3 = sys.rfork(sys.RFPROC | sys.RFMEM);
    if (pid3 < 0) fail("rfork RFMEM");
    if (pid3 == 0) {
        counter = 55; // seen by the parent: the data segment is shared
        _ = sys.rendezvous(0x1234, 0xabc);
        sys.exits(null);
    }
    if (sys.rendezvous(0x1234, 0xdef) != 0xabc) fail("rendezvous");
    _ = waitmsg(&buf);
    if (counter != 55) fail("RFMEM did not share data");

    // Notes: an alarm interrupts a sleep and runs the handler.
    if (sys.notify(@ptrCast(&notetramp)) < 0) fail("notify");
    _ = sys.alarm(50);
    _ = sys.sleep(2000);
    if (notes != 1) fail("alarm note not delivered");

    // A fault in a child kills only the child.
    const pid4 = sys.rfork(sys.RFPROC);
    if (pid4 < 0) fail("rfork");
    if (pid4 == 0) {
        _ = sys.notify(null);
        const bad: *volatile u32 = @ptrFromInt(0x10);
        bad.* = 1;
        sys.exits("survived a fault");
    }
    if (!contains(waitmsg(&buf), "fault")) fail("faulting child exit message");

    // An unmodified 9front binary, if the kernel was built with one.
    const efd = sys.open("/boot/echo", sys.OREAD);
    if (efd >= 0) {
        _ = sys.close(efd);
        const pid5 = sys.rfork(sys.RFPROC | sys.RFFDG);
        if (pid5 < 0) fail("rfork");
        if (pid5 == 0) {
            const args = [_]?[*:0]const u8{ "echo", "hello", "from", "stock", "9front", "echo", null };
            _ = sys.exec("/boot/echo", &args);
            sys.exits("exec of /boot/echo failed");
        }
        const m = waitmsg(&buf);
        if (!eql(m, "''") and m.len != 0) {
            print("usertest: stock echo exited with: ");
            print(m);
            print("\n");
            fail("stock echo");
        }
    }

    print("usertest ok\n");

    // The first user process must not exit.
    while (true) _ = sys.sleep(60000);
}
