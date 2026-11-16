//! A name space from a file of binds and mounts (/lib/namespace).
//! from libauth/newns.c
//!
//! DIFF:
//!   - The arguments of a line are slices into a buffer; where the C
//!     cuts a string by writing a 0, a shorter slice is taken.

const std = @import("std");
const libc = @import("libc");
const sys = libc.sys;
const auth = @import("libauth.zig");

const AuthRpc = auth.AuthRpc;
const Biobuf = libc.Biobuf;
const Error = libc.Error;

/// from authsrv.h: name max size in previous proto
const ANAMELEN = 28;
const MAXARG = 10 * ANAMELEN; // max length of an argument

pub var newnsdebug: bool = false;

fn freecloserpc(rpc: ?*AuthRpc) void {
    if (rpc) |r| {
        _ = sys.close(r.afd);
        auth.auth_freerpc(r);
    }
}

fn buildns(new: bool, user: []const u8, file_: ?[]const u8) Error!void {
    var home: [4 * ANAMELEN]u8 = undefined;
    var b: Biobuf = .{};

    var rpc: ?*AuthRpc = null;
    // try for factotum now because later is impossible
    const afd = sys.open("/mnt/factotum/rpc", sys.ORDWR | sys.OCEXEC);
    if (afd < 0 and newnsdebug)
        libc.fprint(2, "open /mnt/factotum/rpc: %r\n", .{});
    if (afd >= 0) {
        rpc = auth.auth_allocrpc(@intCast(afd));
        if (rpc == null)
            _ = sys.close(afd);
    }
    // rpc != nil iff afd >= 0

    const dfd = sys.open("#c/drivers", sys.OWRITE | sys.OCEXEC);
    if (dfd < 0 and newnsdebug)
        libc.fprint(2, "open #c/drivers: %r\n", .{});

    const file = file_ orelse blk: {
        if (!new) {
            _ = sys.close(dfd);
            libc.werrstr("no namespace file specified", .{});
            freecloserpc(rpc);
            return error.Plan9;
        }
        break :blk "/lib/namespace";
    };
    b.open(file, sys.OREAD | sys.OCEXEC) catch {
        _ = sys.close(dfd);
        libc.werrstr("can't open %s: %r", .{file});
        freecloserpc(rpc);
        return error.Plan9;
    };
    if (new) {
        _ = sys.rfork(sys.RFENVG | sys.RFCNAMEG);
        _ = setenv("user", user);
        _ = setenv("home", libc.sprint(&home, "/usr/%s", .{user}));
    }

    const cdroot = nsfile(if (new) "newns" else "addns", &b, rpc, @intCast(dfd));
    _ = sys.close(dfd);
    b.term() catch {};
    freecloserpc(rpc);

    // make sure we managed to cd into the new name space
    if (new and !cdroot) {
        var path: [1024]u8 = undefined;
        const ok = if (libc.getwd(&path)) |wd| if (libc.chdir(wd)) |_| true else |_| false else |_| false;
        if (!ok)
            libc.chdir("/") catch {};
    }
}

fn nsfile(fn_: []const u8, b: *Biobuf, rpc: ?*AuthRpc, dfd: i32) bool {
    var argv: [16][]u8 = undefined;
    var argbuf: [MAXARG * 16]u8 = undefined;

    var cdroot = false;
    _ = libc.atnotify(catcher, true);
    while (b.rdline('\n')) |line| {
        var cmd = line[0 .. line.len - 1];
        while (cmd.len > 0 and (cmd[0] == ' ' or cmd[0] == '\t'))
            cmd = cmd[1..];
        if (cmd.len > 0 and cmd[0] == '#')
            continue;
        const argc = splitargs(cmd, &argv, &argbuf);
        if (argc != 0) {
            if (nsop(fn_, argv[0..argc], rpc, dfd))
                cdroot = true;
        }
    }
    _ = libc.atnotify(catcher, false);
    return cdroot;
}

/// Replace this process's name space with the one file describes
/// (/lib/namespace for null), for user: the environment is new too,
/// with user and home set.
pub fn newns(user: []const u8, file: ?[]const u8) Error!void {
    return buildns(true, user, file);
}

/// Add what file describes to this process's name space.
pub fn addns(user: []const u8, file: ?[]const u8) Error!void {
    return buildns(false, user, file);
}

fn famount(fd: i32, rpc: ?*AuthRpc, mntpt: []const u8, flags: u32, aname: []const u8) bool {
    const afd = sys.fauth(fd, aname);
    if (afd >= 0) {
        if (auth.fauth_proxy(@intCast(afd), rpc, auth.amount_getkey, "proto=p9any role=client")) |ai|
            auth.auth_freeAI(ai)
        else |_| {}
    }
    const ret = sys.mount(fd, afd, mntpt, flags, aname);
    if (ret < 0)
        _ = sys.close(fd);
    if (afd >= 0)
        _ = sys.close(afd);
    return ret >= 0;
}

fn nsop(fn_: []const u8, argv_: []const []u8, rpc: ?*AuthRpc, dfd: i32) bool {
    var cdroot = false;
    var flags: u32 = 0;
    var devop: []const u8 = "&";
    if (newnsdebug) {
        for (argv_) |a|
            libc.fprint(2, "%s ", .{a});
        libc.fprint(2, "\n", .{});
    }
    const argv0 = argv_[0];
    var args = libc.Args.init(@ptrCast(argv_));
    while (args.next()) |c| switch (c) {
        'a' => flags |= sys.MAFTER,
        'b' => flags |= sys.MBEFORE,
        'c' => flags |= sys.MCREATE,
        'C' => flags |= sys.MCACHE,
        'r' => devop = "&~",
        'n' => devop = "~",
        else => {},
    };
    const argv = args.rest();
    const argc = argv.len;

    if (flags & (sys.MAFTER | sys.MBEFORE) == 0)
        flags |= sys.MREPL;

    const eql = std.mem.eql;
    if (eql(u8, argv0, ".") and argc == 1) {
        var b: Biobuf = .{};
        b.open(argv[0], sys.OREAD | sys.OCEXEC) catch return false;
        if (nsfile(fn_, &b, rpc, dfd))
            cdroot = true;
        b.term() catch {};
    } else if (eql(u8, argv0, "clear") and argc == 0) {
        _ = sys.rfork(sys.RFCNAMEG);
    } else if (eql(u8, argv0, "bind") and argc == 2) {
        if (sys.bind(argv[0], argv[1], flags) < 0 and newnsdebug)
            libc.fprint(2, "%s: bind: %s %s: %r\n", .{ fn_, argv[0], argv[1] });
    } else if (eql(u8, argv0, "unmount")) {
        if (argc == 1)
            _ = sys.unmount(null, argv[0])
        else if (argc == 2)
            _ = sys.unmount(argv[0], argv[1]);
    } else if (eql(u8, argv0, "mount")) {
        const fd = sys.open(argv[0], sys.ORDWR);
        if (fd < 0) {
            if (newnsdebug)
                libc.fprint(2, "%s: mount: %s: %r\n", .{ fn_, argv[0] });
            return false;
        }
        if (argc == 2) {
            if (!famount(@intCast(fd), rpc, argv[1], flags, "") and newnsdebug)
                libc.fprint(2, "%s: mount: %s %s: %r\n", .{ fn_, argv[0], argv[1] });
        } else if (argc == 3) {
            if (!famount(@intCast(fd), rpc, argv[1], flags, argv[2]) and newnsdebug)
                libc.fprint(2, "%s: mount: %s %s %s: %r\n", .{ fn_, argv[0], argv[1], argv[2] });
        } else {
            _ = sys.close(fd);
        }
    } else if (eql(u8, argv0, "cd") and argc == 1) {
        if (sys.chdir(argv[0]) == 0 and argv[0].len > 0 and argv[0][0] == '/')
            cdroot = true;
    } else if (eql(u8, argv0, "chdev")) {
        //We should not silently fail if we can not honor a chdev
        //due to the parent namespace missing #c/drivers.
        if (dfd <= 0)
            libc.sysfatal("chdev requested, but could not open #c/drivers", .{});
        var buf: [MAXARG + 16]u8 = undefined;
        if (argc == 0 and devop[0] == '~') {
            if (sys.write(dfd, "chdev ~") < 0 and newnsdebug)
                libc.fprint(2, "%s: chdev ~: %r\n", .{fn_});
        } else if (argc == 1) {
            if (sys.write(dfd, libc.sprint(&buf, "chdev %s %s", .{ devop, argv[0] })) < 0 and newnsdebug)
                libc.fprint(2, "%s: chdev %s %s: %r\n", .{ fn_, devop, argv[0] });
        }
    }
    return cdroot;
}

const wocp = "sys: write on closed pipe";

fn catcher(_: *anyopaque, m: []const u8) bool {
    return std.mem.startsWith(u8, m, wocp);
}

/// Take the quotes off s, in place; returns what is left.
fn unquote(s: []u8) []u8 {
    var w: usize = 0;
    var inquote = false;
    var r: usize = 0;
    while (r < s.len) : (r += 1) {
        if (s[r] != '\'') {
            s[w] = s[r];
            w += 1;
            continue;
        }
        if (inquote) {
            if (r + 1 < s.len and s[r + 1] == '\'') {
                s[w] = '\'';
                w += 1;
                r += 1;
            } else inquote = false;
        } else inquote = true;
    }
    return s[0..w];
}

fn splitargs(p: []u8, argv: [][]u8, argbuf: []u8) usize {
    const n = libc.gettokens(p, argv, " \t\r");
    if (n == argv.len)
        return 0;
    var off: usize = 0;
    for (argv[0..n]) |*a| {
        const x = expandarg(a.*, argbuf[off..]) orelse return 0;
        off += x.len + 1;
        a.* = unquote(x);
    }
    return n;
}

fn nextdollar(arg: []const u8) ?usize {
    var inquote = false;
    for (arg, 0..) |c, i| {
        if (c == '\'')
            inquote = !inquote;
        if (c == '$' and !inquote)
            return i;
    }
    return null;
}

/// copy the arg into the buffer,
/// expanding any environment variables.
/// environment variables are assumed to be
/// names (ie. < ANAMELEN long)
/// the entire argument is expanded to be at
/// most MAXARG long
/// the expanded argument is returned, at the start of buf
/// any problems cause a null return;
fn expandarg(arg_: []const u8, buf: []u8) ?[]u8 {
    var env: [3 + ANAMELEN]u8 = undefined;

    if (buf.len < MAXARG)
        return null;
    var arg = arg_;
    var n: usize = 0;
    while (nextdollar(arg)) |d| {
        if (n + d + ANAMELEN >= MAXARG - 1)
            return null;
        @memcpy(buf[n..][0..d], arg[0..d]);
        n += d;
        const p = arg[d + 1 ..];
        const len = std.mem.indexOfAny(u8, p, "/.!'$") orelse p.len;
        arg = p[len..];
        if (len == 0 or len >= ANAMELEN)
            continue;
        const name = libc.sprint(&env, "#e/%s", .{p[0..len]});
        const fd = sys.open(name, sys.OREAD | sys.OCEXEC);
        if (fd >= 0) {
            const r = sys.read(fd, buf[n..][0 .. ANAMELEN - 1]);
            // some singleton environment variables have trailing NULs
            // lists separate entries with NULs; we arbitrarily take the first element
            if (r > 0) {
                const got = buf[n..][0..@intCast(r)];
                n += std.mem.indexOfScalar(u8, got, 0) orelse got.len;
            }
            _ = sys.close(fd);
        }
    }
    if (n + arg.len >= MAXARG - 1)
        return null;
    @memcpy(buf[n..][0..arg.len], arg);
    return buf[0 .. n + arg.len];
}

fn setenv(name: []const u8, val: []const u8) bool {
    var ename: [ANAMELEN + 6]u8 = undefined;

    const f = sys.create(libc.sprint(&ename, "#e/%s", .{name}), sys.OWRITE | sys.OCEXEC, 0o664);
    if (f < 0)
        return false;
    defer _ = sys.close(f);
    return sys.write(f, val) == val.len;
}
