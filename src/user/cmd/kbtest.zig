//! kbtest - drive a kbdfs through its files and print what it gives
//! back: the client of the kbdfs comparison (tools/usbzig.rc), run
//! against the stock kbdfs and against planZ's with the same script.
//! Not part of 9front.
//!
//! usage: kbtest mnt script
//!        kbtest -l         (print kbdfs's compose table as mklatin -r does)
//!
//! mnt is where the kbdfs is mounted.  The script's lines:
//!     sc hex... write those scan codes to kbin
//!     in msg|msg... write messages to kbdin, a 0 after each
//!     old text write text to kbdin with no 0 (the old format)
//!     okbd, ckbd open, close kbd
//!     kbd n  read kbd until n messages have come, and print them
//!     cons [n]  read cons once (at most n bytes), and print it
//!     wcons text write text and a newline to cons
//!     octl, cctl open, close consctl
//!     ctl text write text to consctl
//!     # ...  a comment, printed
//! A read that is not answered in 5 seconds prints "timeout".  One
//! key is sent at a time and what it gives is read before the next:
//! kbdfs's threads would otherwise order two keys' messages by when
//! each arrived.

const std = @import("std");
const libc = @import("libc");
const sys = libc.sys;

const print = libc.print;

var mnt: []const u8 = "";
var kbdfd: isize = -1;
var ctlfd: isize = -1;
var consfd: isize = -1;
var timedout = false;

fn onalarm(_: *anyopaque, msg: []const u8) bool {
    if (!std.mem.eql(u8, msg, "alarm"))
        return false;
    timedout = true;
    return true;
}

fn open(name: []const u8, mode: u32) isize {
    var buf: [256]u8 = undefined;
    const fd = sys.open(libc.sprint(&buf, "%s/%s", .{ mnt, name }), mode);
    if (fd < 0)
        print("open %s: %r\n", .{name});
    return fd;
}

fn writeto(name: []const u8, data: []const u8) void {
    const fd = open(name, sys.OWRITE);
    if (fd < 0)
        return;
    if (sys.write(fd, data) != data.len)
        print("write %s: %r\n", .{name});
    _ = sys.close(fd);
}

/// Bytes as they can be compared: printable ASCII as it is, the rest
/// as \xx.
fn show(data: []const u8) void {
    for (data) |c| {
        if (c >= 0x20 and c < 0x7f and c != '\\')
            print("%c", .{c})
        else
            print("\\%02x", .{c});
    }
}

fn read(fd: isize, buf: []u8) isize {
    timedout = false;
    _ = sys.alarm(5000);
    const n = sys.read(fd, buf);
    _ = sys.alarm(0);
    return n;
}

/// A byte as mklatin.c prints it in a C string.
fn cprintchar(c: u8) void {
    switch (c) {
        '\'', '"', '\\' => print("\\%c", .{c}),
        '\t' => print("\\t", .{}),
        else => {
            if (c >= 0x20 and c < 0x7f)
                print("%c", .{c})
            else
                print("\\x%.2x", .{c});
        },
    }
}

/// kbdfs's compose table as `mklatin -r` prints 9front's.
fn latin() void {
    for (@import("kbdfs/latin1.zig").tab) |t| {
        print("\t\"", .{});
        for (t.ld) |c|
            cprintchar(c);
        print("\", \"", .{});
        for (t.si) |c|
            cprintchar(c);
        print("\",\t{", .{});
        for (t.so) |r|
            print(" 0x%.4ux,", .{@as(u32, r)});
        print(" },\n", .{});
    }
}

pub fn main(argv: []const []const u8) void {
    var buf: [8192]u8 = undefined;
    var b: libc.Biobuf = .{};

    if (argv.len == 2 and std.mem.eql(u8, argv[1], "-l")) {
        latin();
        libc.exits(null);
    }
    if (argv.len != 3)
        libc.sysfatal("usage: kbtest mnt script", .{});
    mnt = argv[1];
    b.open(argv[2], sys.OREAD) catch libc.sysfatal("open %s: %r", .{argv[2]});
    _ = libc.atnotify(onalarm, true);

    while (b.rdline('\n')) |l| {
        const line = l[0 .. l.len - 1];
        if (line.len == 0)
            continue;
        const sp = std.mem.indexOfScalar(u8, line, ' ') orelse line.len;
        const op = line[0..sp];
        const arg = if (sp < line.len) line[sp + 1 ..] else "";
        const eql = std.mem.eql;
        if (op[0] == '#') {
            print("%s\n", .{line});
        } else if (eql(u8, op, "sc")) {
            var n: usize = 0;
            var it = std.mem.tokenizeScalar(u8, arg, ' ');
            while (it.next()) |h| : (n += 1)
                buf[n] = @truncate(libc.strtoul(h, 16).v);
            writeto("kbin", buf[0..n]);
        } else if (eql(u8, op, "in")) {
            var n: usize = 0;
            var it = std.mem.splitScalar(u8, arg, '|');
            while (it.next()) |m| {
                @memcpy(buf[n..][0..m.len], m);
                buf[n + m.len] = 0;
                n += m.len + 1;
            }
            writeto("kbdin", buf[0..n]);
        } else if (eql(u8, op, "old")) {
            writeto("kbdin", arg);
        } else if (eql(u8, op, "okbd")) {
            kbdfd = open("kbd", sys.OREAD);
        } else if (eql(u8, op, "ckbd")) {
            _ = sys.close(kbdfd);
            kbdfd = -1;
        } else if (eql(u8, op, "kbd")) {
            const want: usize = @intCast(libc.atoi(arg));
            var got: usize = 0;
            print("kbd:", .{});
            while (got < want) {
                const n = read(kbdfd, &buf);
                if (n <= 0) {
                    if (timedout) print(" timeout", .{}) else print(" error %r", .{});
                    break;
                }
                var it = std.mem.splitScalar(u8, buf[0..@intCast(n)], 0);
                while (it.next()) |m| {
                    if (m.len == 0)
                        continue;
                    print(" [", .{});
                    show(m);
                    print("]", .{});
                    got += 1;
                }
            }
            print("\n", .{});
        } else if (eql(u8, op, "cons")) {
            if (consfd < 0)
                consfd = open("cons", sys.OREAD);
            const max: usize = if (arg.len != 0) @intCast(libc.atoi(arg)) else buf.len;
            const n = read(consfd, buf[0..max]);
            print("cons: ", .{});
            if (n < 0) {
                if (timedout) print("timeout", .{}) else print("error %r", .{});
            } else {
                print("%d [", .{n});
                show(buf[0..@intCast(n)]);
                print("]", .{});
            }
            print("\n", .{});
        } else if (eql(u8, op, "wcons")) {
            const n = libc.sprint(&buf, "%s\n", .{arg}).len;
            writeto("cons", buf[0..n]);
        } else if (eql(u8, op, "octl")) {
            ctlfd = open("consctl", sys.OWRITE);
        } else if (eql(u8, op, "cctl")) {
            _ = sys.close(ctlfd);
            ctlfd = -1;
        } else if (eql(u8, op, "ctl")) {
            if (sys.write(ctlfd, arg) != arg.len)
                print("ctl %s: %r\n", .{arg});
        } else print("kbtest: bad line: %s\n", .{line});
    }
    libc.exits(null);
}
