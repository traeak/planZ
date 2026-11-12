//! read - read from a file and write to standard output
//! from cmd/read.c

const libc = @import("libc");

var multi = false;
var count: i64 = 0;
var status: ?[]const u8 = null;

fn readerr(file: []const u8) noreturn {
    libc.fprint(2, "read: error reading %s: %r\n", .{file});
    libc.exits("read error");
}

fn line(fd: i32, file: []const u8) usize {
    var buf: []u8 = &.{};
    defer libc.allocator.free(buf);
    var m: usize = 0;
    while (true) {
        var c: [1]u8 = undefined;
        const n = libc.read(fd, &c) catch readerr(file);
        if (n == 0) {
            if (m == 0)
                status = "eof";
            break;
        }
        if (m == buf.len) {
            buf = libc.allocator.realloc(buf, buf.len + 1024) catch {
                libc.fprint(2, "read: malloc error: %r\n", .{});
                libc.exits("malloc");
            };
        }
        buf[m] = c[0];
        m += 1;
        if (c[0] == '\n')
            break;
    }
    if (m > 0)
        _ = libc.write(1, buf[0..m]) catch {};
    return m;
}

fn lines(fd: i32, file: []const u8) void {
    while (true) {
        if (line(fd, file) == 0)
            break;
        if (!multi) {
            count -= 1;
            if (count <= 0)
                break;
        }
    }
}

fn chars(fd: i32, file: []const u8) void {
    var buf: [8 * 1024]u8 = undefined;
    var m: i64 = 0;
    while (m < count) {
        var n: usize = buf.len;
        if (n > count - m)
            n = @intCast(count - m);
        n = libc.read(fd, buf[0..n]) catch readerr(file);
        if (n == 0) {
            if (m == 0)
                status = "eof";
            break;
        }
        _ = libc.write(1, buf[0..n]) catch {};
        m += @intCast(n);
    }
}

fn runes(fd: i32, file: []const u8) void {
    var buf: [8 * 1024]u8 = undefined;
    while (count > 0) {
        const want: usize = if (count + libc.UTFmax < buf.len) @intCast(count) else buf.len - libc.UTFmax;
        var e = libc.read(fd, buf[0..want]) catch readerr(file);
        if (e == 0)
            break;
        var s: usize = 0;
        while (s < e and libc.fullrune(buf[s..e])) : (s += libc.chartorune(buf[s..e]).n)
            count -= 1;
        if (s < e) {
            while (!libc.fullrune(buf[s..e])) {
                switch (libc.read(fd, buf[e..][0..1]) catch readerr(file)) {
                    0 => {
                        libc.fprint(2, "warning: partial rune at end of %s: %r\n", .{file});
                        _ = libc.write(1, buf[0..e]) catch {};
                        return;
                    },
                    else => e += 1,
                }
            }
            count -= 1;
        }
        _ = libc.write(1, buf[0..e]) catch {};
    }
}

fn usage() noreturn {
    libc.fprint(2, "usage: read [ -m | -n nlines | -c nbytes | -r nrunes ] [ file ... ]\n", .{});
    libc.exits("usage");
}

pub fn main(argv: []const []const u8) void {
    var proc: *const fn (i32, []const u8) void = lines;
    var args = libc.Args.init(argv);
    while (args.next()) |c| switch (c) {
        'c' => {
            count = libc.atoi(args.value() orelse usage());
            proc = chars;
        },
        'r' => {
            count = libc.atoi(args.value() orelse usage());
            proc = runes;
        },
        'n' => count = @as(i32, @truncate(libc.atoi(args.value() orelse usage()))),
        'm' => multi = true,
        else => usage(),
    };
    const files = args.rest();

    if (files.len == 0)
        proc(0, "<stdin>")
    else for (files) |name| {
        const fd = libc.open(name, libc.OREAD) catch {
            libc.fprint(2, "read: can't open %s: %r\n", .{name});
            libc.exits("open");
        };
        proc(fd, name);
        libc.close(fd) catch {};
    }

    libc.exits(status);
}
