//! ps - process status
//! from cmd/ps.c

const std = @import("std");
const libc = @import("libc");

var bout: libc.Biobuf = .{};
var pflag = false;
var aflag = false;
var nflag = false;
var rflag = false;

pub fn main(argv: []const []const u8) void {
    var none = true;

    var args = libc.Args.init(argv);
    while (args.next()) |c| switch (c) {
        'a' => aflag = true,
        'p' => pflag = true,
        'n' => nflag = true,
        'r' => rflag = true,
        else => {},
    };
    bout.init(1, libc.OWRITE);

    libc.chdir("/proc") catch error_("/proc");
    const fd = libc.open(".", libc.OREAD) catch error_("/proc");
    const dirs = libc.dirreadall(libc.allocator, fd) catch null;
    if (dirs == null or dirs.?.dirs.len == 0) {
        libc.fprint(2, "ps: empty directory /proc\n", .{});
        libc.exits("empty");
    }
    const dir = dirs.?.dirs;
    const mem = libc.allocator.alloc(*const libc.Dir, dir.len) catch libc.sysfatal("out of memory", .{});
    for (dir, 0..) |*d, i|
        mem[i] = d;
    libc.qsort(*const libc.Dir, mem, {}, cmp);
    for (mem) |d| {
        ps(d.name);
        none = false;
    }

    if (none)
        error_("no processes; bad #p");
    libc.exits(null);
}

fn pr(comptime format: []const u8, a: anytype) void {
    bout.print(format, a) catch {};
}

fn readfile(buf: []u8, comptime format: []const u8, a: anytype) ?[]u8 {
    var nb: [64]u8 = undefined;
    const fd = libc.open(libc.sprint(&nb, format, a), libc.OREAD) catch return null;
    const n = libc.read(fd, buf) catch {
        libc.close(fd) catch {};
        return null;
    };
    libc.close(fd) catch {};
    return buf[0..n];
}

fn ps(s: []const u8) void {
    var args: [256]u8 = undefined;
    var argv: [15][]u8 = undefined;
    var buf: [64]u8 = undefined;
    var nbuf: [13]u8 = undefined;
    var pbuf: [8]u8 = undefined;
    var rbuf: [20]u8 = undefined;
    var rbuf1: [20]u8 = undefined;
    var status: [4096]u8 = undefined;

    const fd = libc.open(libc.sprint(&buf, "%s/status", .{s}), libc.OREAD) catch return;
    const n = libc.read(fd, status[0 .. status.len - 1]) catch 0;
    libc.close(fd) catch {};
    if (n == 0)
        return;
    const argc = libc.tokenize(status[0..n], &argv);
    if (argc < 12)
        return;

    // 0  text
    // 1  user
    // 2  state
    // 3  cputime[6]
    // 9  memory
    // 10 basepri
    // 11 pri
    const utime = libc.strtoul32(argv[3], 0).v / 1000;
    const stime = libc.strtoul32(argv[4], 0).v / 1000;
    const rtime = libc.strtoul32(argv[5], 0).v / 1000;
    const size = libc.strtoul32(argv[9], 0).v;

    var ns: []const u8 = "";
    if (nflag) {
        ns = libc.fmt.snprint(&nbuf, " %8s", .{"?"});
        const fd2 = libc.open(libc.sprint(&buf, "%s/noteid", .{s}), libc.OREAD) catch -1;
        if (fd2 >= 0) {
            const m = libc.read(fd2, buf[0 .. buf.len - 1]) catch 0;
            libc.close(fd2) catch {};
            if (m > 0)
                ns = libc.fmt.snprint(nbuf[0..12], " %7ud", .{@as(u32, @truncate(@as(u64, @bitCast(libc.atoi(buf[0..m])))))});
        }
    }

    var pri: []const u8 = "";
    if (pflag) {
        const basepri: i32 = @bitCast(libc.strtoul32(argv[10], 0).v);
        const p: i32 = @bitCast(libc.strtoul32(argv[11], 0).v);
        pri = libc.sprint(&pbuf, " %2d %2d", .{ basepri, p });
    }

    var rs: []const u8 = "";
    if (rflag) {
        const r = if (rtime >= 86400)
            libc.sprint(&rbuf, " %lud:%02lud:%02lud:%02lud", .{ rtime / 86400, (rtime / 3600) % 24, (rtime / 60) % 60, rtime % 60 })
        else if (rtime >= 3600)
            libc.sprint(&rbuf, " %lud:%02lud:%02lud", .{ rtime / 3600, (rtime / 60) % 60, rtime % 60 })
        else
            libc.sprint(&rbuf, " %lud:%02lud", .{ rtime / 60, rtime % 60 });
        rs = libc.sprint(&rbuf1, "%12s", .{r});
    }

    pr("%-10s %8s%s%s %4lud:%.2lud %3lud:%.2lud %s %7ludK %-8.8s ", .{
        argv[1],
        s,
        ns,
        rs,
        utime / 60,
        utime % 60,
        stime / 60,
        stime % 60,
        pri,
        size,
        argv[2],
    });

    if (!aflag) {
        pr("%s\n", .{argv[0]});
        return;
    }

    const a = readfile(args[0 .. args.len - 1], "%s/args", .{s}) orelse {
        pr("%s ?\n", .{argv[0]});
        return;
    };
    if (a.len == 0) {
        pr("%s\n", .{argv[0]});
        return;
    }
    for (a) |*c| {
        if (c.* == '\n')
            c.* = ' ';
    }
    // the C prints it as a string: to its first 0
    pr("%s\n", .{a[0 .. std.mem.findScalar(u8, a, 0) orelse a.len]});
}

fn error_(s: []const u8) noreturn {
    libc.fprint(2, "ps: %s: ", .{s});
    libc.fprint(2, "error: %r\n", .{});
    libc.exits(s);
}

fn cmp(_: void, x: *const *const libc.Dir, y: *const *const libc.Dir) i32 {
    return @truncate(libc.atoi(x.*.name) - libc.atoi(y.*.name));
}
