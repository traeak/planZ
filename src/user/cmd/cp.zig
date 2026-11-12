//! cp - copy files
//! from cmd/cp.c

const std = @import("std");
const libc = @import("libc");

const Dir = libc.Dir;
const a = libc.allocator;

var buflen: usize = 0;
var failed = false;
var gflag = false;
var uflag = false;
var xflag = false;

fn usage() noreturn {
    libc.fprint(2, "usage:\tcp [-gux] fromfile tofile\n", .{});
    libc.fprint(2, "\tcp [-x] fromfile ... todir\n", .{});
    libc.exits("usage");
}

pub fn main(argv: []const []const u8) void {
    var args = libc.Args.init(argv);
    while (args.next()) |c| switch (c) {
        'g' => gflag = true,
        'u' => {
            uflag = true;
            gflag = true;
        },
        'x' => xflag = true,
        else => usage(),
    };
    const files = args.rest();

    var todir = false;
    if (files.len < 2)
        usage();
    const last = files[files.len - 1];
    if (libc.dirstat(a, last)) |st_| {
        var st = st_;
        if ((st.dir.mode & libc.DMDIR) != 0)
            todir = true;
        st.deinit(a);
    } else |_| {}
    if (files.len > 2 and !todir) {
        libc.fprint(2, "cp: %s not a directory\n", .{last});
        libc.exits("bad usage");
    }
    for (files[0 .. files.len - 1]) |f|
        copy(f, last, todir);
    if (failed)
        libc.exits("errors");
}

fn samefile(d: *const Dir, an: []const u8, bn: []const u8) bool {
    var st = libc.dirstat(a, bn) catch return false;
    defer st.deinit(a);
    const b = &st.dir;
    if (b.qid.type == d.qid.type and b.qid.path == d.qid.path and b.qid.vers == d.qid.vers and
        b.dev == d.dev and b.type == d.type)
    {
        libc.fprint(2, "cp: %s and %s are the same file\n", .{ an, bn });
        return true;
    }
    return false;
}

fn copy(from: []const u8, to_: []const u8, todir: bool) void {
    var to = to_;
    var name: ?[]u8 = null;
    defer if (name) |n| a.free(n);
    if (todir) {
        const elem = libc.basename(from);
        name = std.fmt.allocPrint(a, "{s}/{s}", .{ to, elem }) catch {
            libc.fprint(2, "cp: out of memory\n", .{});
            failed = true;
            return;
        };
        to = name.?;
    }

    var st = libc.dirstat(a, from) catch {
        libc.fprint(2, "cp: can't stat %s: %r\n", .{from});
        failed = true;
        return;
    };
    defer st.deinit(a);
    const dirb = &st.dir;
    var mode = dirb.mode;
    if ((mode & libc.DMDIR) != 0) {
        libc.fprint(2, "cp: %s is a directory\n", .{from});
        failed = true;
        return;
    }
    if (samefile(dirb, from, to)) {
        failed = true;
        return;
    }
    mode &= 0o777;
    const fdf = libc.open(from, libc.OREAD) catch {
        libc.fprint(2, "cp: can't open %s: %r\n", .{from});
        failed = true;
        return;
    };
    defer libc.close(fdf) catch {};
    const fdt = libc.create(to, libc.OWRITE, mode) catch {
        libc.fprint(2, "cp: can't create %s: %r\n", .{to});
        failed = true;
        return;
    };
    defer libc.close(fdt) catch {};

    buflen = libc.iounit(fdf);
    if (buflen == 0)
        buflen = libc.IOUNIT;

    if (copy1(fdf, fdt, from, to)) {
        if (xflag or gflag or uflag) {
            var dirt = libc.nulldir();
            if (xflag) {
                dirt.mtime = dirb.mtime;
                dirt.mode = dirb.mode;
            }
            if (uflag)
                dirt.uid = dirb.uid;
            if (gflag)
                dirt.gid = dirb.gid;
            libc.dirfwstat(fdt, &dirt) catch
                libc.fprint(2, "cp: warning: can't wstat %s: %r\n", .{to});
        }
    }
}

fn copy1(fdf: i32, fdt: i32, from: []const u8, to: []const u8) bool {
    const buf = a.alloc(u8, buflen) catch {
        libc.fprint(2, "cp: out of memory\n", .{});
        return false;
    };
    defer a.free(buf);

    // clear any residual error
    libc.werrstr("", .{});
    while (true) {
        const n = libc.read(fdf, buf) catch {
            libc.fprint(2, "cp: error reading %s: %r\n", .{from});
            failed = true;
            return false;
        };
        if (n == 0)
            break;
        const n1 = libc.write(fdt, buf[0..n]) catch 0;
        if (n1 != n) {
            libc.fprint(2, "cp: error writing %s: %r\n", .{to});
            failed = true;
            return false;
        }
    }
    return true;
}
