//! authtest - libauth, the client's half: the attribute lists
//! (attr.zig), and the name space that newns and addns make from a
//! file.  The twin of tools/authtest.c, which is built in the guest
//! against stock libauth and prints the same lines.
//!
//! usage: authtest attr
//!     authtest newns [file]
//!     authtest addns file
//!
//! newns and addns change the name space of this process for good; it
//! then prints its own /proc/n/ns (by the device's name, whatever the
//! name space has become), its directory, and $user and $home.

const std = @import("std");
const libc = @import("libc");
const auth = @import("auth");
const sys = libc.sys;

const print = libc.print;

const strs = [_][]const u8{
    "proto=p9sk1 dom=example.com user=glenda !password=secret",
    "proto=p9any role=client",
    "user? dom=x !password?",
    "user? user=bob",
    "a=1 b a=2 c?",
    "'quoted name'='a value' q='it''s'",
    "x= y=''",
    "",
    "   ",
    "lone",
};

/// The C's %A.
fn A(buf: []u8, a: ?*auth.Attr) []const u8 {
    var f: libc.fmt.Fmt = .{ .buf = buf };
    auth.attrfmt(&f, a);
    return buf[0..f.n];
}

fn attrs() void {
    var buf: [512]u8 = undefined;

    for (strs) |s| {
        const a = auth.parseattr(s);
        print("[%s] -> [%s]\n", .{ s, A(&buf, a) });
        var b = auth.copyattr(a);
        print("  copy [%s]\n", .{A(&buf, b)});
        const f = auth.findattr(a, "user");
        print("  find user: %s\n", .{if (f) |x| x.val else "(none)"});
        print("  strfind a: %s\n", .{auth.strfindattr(a, "a") orelse "(none)"});
        b = auth.delattr(b, "user");
        b = auth.delattr(b, "a");
        print("  del user, a [%s]\n", .{A(&buf, b)});
        auth.freeattr(a);
        auth.freeattr(b);
    }
    const a = auth.mkattr(.AttrQuery, "q", "", auth.mkattr(.AttrDefault, "d", "v", auth.mkattr(.AttrNameval, "n", "two words", null)));
    print("made [%s]\n", .{A(&buf, a)});
    auth.freeattr(a);
}

fn cat(name: []const u8) void {
    var buf: [8192]u8 = undefined;

    const fd = sys.open(name, sys.OREAD);
    if (fd < 0) {
        print("open %s: %r\n", .{name});
        return;
    }
    while (true) {
        const n = sys.read(fd, &buf);
        if (n <= 0)
            break;
        _ = sys.write(1, buf[0..@intCast(n)]);
    }
    _ = sys.close(fd);
}

fn show() void {
    var name: [64]u8 = undefined;
    var wd: [512]u8 = undefined;

    cat(libc.sprint(&name, "#p/%d/ns", .{libc.getpid()}));
    if (libc.getwd(&wd)) |w|
        print("wd %s\n", .{w})
    else |_|
        print("getwd: %r\n", .{});
    print("user ", .{});
    cat("#e/user");
    print("\nhome ", .{});
    cat("#e/home");
    print("\n", .{});
    const fd = sys.open("#A/volume", sys.OREAD);
    if (fd < 0)
        print("audio: %r\n", .{})
    else
        print("audio: opened\n", .{});
}

fn r(e: libc.Error!void) i32 {
    return if (e) |_| 0 else |_| -1;
}

pub fn main(argv: []const []const u8) void {
    if (argv.len < 2)
        libc.sysfatal("usage", .{});
    const file: ?[]const u8 = if (argv.len > 2) argv[2] else null;
    const eql = std.mem.eql;
    if (eql(u8, argv[1], "attr"))
        attrs()
    else if (eql(u8, argv[1], "newns")) {
        print("newns %d\n", .{r(auth.newns(libc.getuser(), file))});
        show();
    } else if (eql(u8, argv[1], "addns")) {
        print("addns %d", .{r(auth.addns(libc.getuser(), file))});
        print(" %r\n", .{});
        show();
    } else libc.sysfatal("usage", .{});
    libc.exits(null);
}
