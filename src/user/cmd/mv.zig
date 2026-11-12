//! mv - move files
//! from cmd/mv.c

const std = @import("std");
const libc = @import("libc");

const Dir = libc.Dir;
const a = libc.allocator;

pub fn main(argv_: []const []const u8) !void {
    if (argv_.len < 3) {
        libc.fprint(2, "usage: mv fromfile tofile\n", .{});
        libc.fprint(2, "\t  mv fromfile ... todir\n", .{});
        libc.exits("bad usage");
    }

    // prepass to canonicalise names before splitting, etc.
    // DIFF: into copies; the C edits argv in place.
    const argv = try a.alloc([]const u8, argv_.len);
    for (argv_, 0..) |s, i| {
        const b = try a.alloc(u8, s.len + 2);
        @memcpy(b[0..s.len], s);
        argv[i] = b[0..libc.cleanname(b, s.len)];
    }

    const last = argv[argv.len - 1];
    var todir: []const u8 = undefined;
    var toelem: ?[]const u8 = undefined;
    if (isdir(last)) {
        if (argv.len == 3 and isdir(argv[1])) {
            split(last, &todir, &toelem); // mv dir1 dir2
        } else { // mv file... dir
            todir = last;
            toelem = null; // toelem will be fromelem
        }
    } else split(last, &todir, &toelem); // mv file1 file2
    if (argv.len > 3 and toelem != null) {
        libc.fprint(2, "mv: %s not a directory\n", .{last});
        libc.exits("bad usage");
    }

    var failed = false;
    for (argv[1 .. argv.len - 1]) |f| {
        if (!mv(f, todir, toelem))
            failed = true;
    }
    if (failed)
        libc.exits("failure");
}

fn isdir(name: []const u8) bool {
    var st = libc.dirstat(a, name) catch return false;
    defer st.deinit(a);
    return (st.dir.mode & libc.DMDIR) != 0;
}

fn mv(from: []const u8, todir: []const u8, toelem: ?[]const u8) bool {
    var st = libc.dirstat(a, from) catch {
        libc.fprint(2, "mv: can't stat %s: %r\n", .{from});
        return false;
    };
    defer st.deinit(a);
    return mv1(from, &st.dir, todir, toelem);
}

fn mv1(fromname: []const u8, dirb: *const Dir, todir: []const u8, toelem_: ?[]const u8) bool {
    var toname_buf: [4096]u8 = undefined;
    var fromdir: []const u8 = undefined;
    var fromelem: ?[]const u8 = undefined;
    split(fromname, &fromdir, &fromelem);
    const toelem = toelem_ orelse fromelem.?;
    if (toelem.len == 0) {
        libc.fprint(2, "mv: null last name element moving %s\n", .{fromname});
        return false;
    }
    if (toelem.len + todir.len + 2 > toname_buf.len) {
        libc.fprint(2, "mv: path too big (max %d): %s/%s\n", .{ toname_buf.len, todir, toelem });
        return false;
    }
    const toname = libc.sprint(&toname_buf, "%s/%s", .{ todir, toelem });

    if (samefile(fromdir, todir)) {
        if (samefile(fromname, toname)) {
            libc.fprint(2, "mv: %s and %s are the same\n", .{ fromname, toname });
            return false;
        }

        // remove target if present
        if (libc.access(toname, libc.AEXIST))
            hardremove(toname);

        // try wstat
        var null_ = libc.nulldir();
        null_.name = toelem;
        if (libc.dirwstat(fromname, &null_)) |_| return true else |_| {}
        if ((dirb.mode & libc.DMDIR) != 0) {
            libc.fprint(2, "mv: can't rename directory %s: %r\n", .{fromname});
            return false;
        }
    }
    // Renaming won't work --- must copy
    if ((dirb.mode & libc.DMDIR) != 0) {
        libc.fprint(2, "mv: %s is a directory, not copied to %s\n", .{ fromname, toname });
        return false;
    }
    const fdf = libc.open(fromname, libc.OREAD) catch {
        libc.fprint(2, "mv: can't open %s: %r\n", .{fromname});
        return false;
    };

    if (libc.dirstat(a, toname)) |dt_| {
        var dt = dt_;
        if ((dt.dir.mode & libc.fcall.DMAPPEND) != 0)
            hardremove(toname); // because create() won't truncate file
        dt.deinit(a);
    } else |_| {}

    const fdt = libc.create(toname, libc.OWRITE, dirb.mode) catch {
        libc.fprint(2, "mv: can't create %s: %r\n", .{toname});
        libc.close(fdf) catch {};
        return false;
    };
    var ok = copy1(fdf, fdt, fromname, toname);
    libc.close(fdf) catch {};

    if (ok) {
        var null_ = libc.nulldir();
        null_.mtime = dirb.mtime;
        null_.mode = dirb.mode;
        libc.dirfwstat(fdt, &null_) catch {}; // ignore errors; e.g. user none always fails
        libc.remove(fromname) catch {
            libc.fprint(2, "mv: can't remove %s: %r\n", .{fromname});
            ok = false;
        };
    }
    libc.close(fdt) catch {};
    return ok;
}

var buf: [libc.IOUNIT]u8 = undefined;

fn copy1(fdf: i32, fdt: i32, from: []const u8, to: []const u8) bool {
    while (true) {
        const n = libc.read(fdf, &buf) catch {
            libc.fprint(2, "mv: error reading %s: %r\n", .{from});
            return false;
        };
        if (n == 0)
            return true;
        const n1 = libc.write(fdt, buf[0..n]) catch 0;
        if (n1 != n) {
            libc.fprint(2, "mv: error writing %s: %r\n", .{to});
            return false;
        }
    }
}

/// DIFF: returns slices of name; the C writes a NUL over the '/'.
fn split(name: []const u8, pdir: *[]const u8, pelem: *?[]const u8) void {
    if (std.mem.findScalarLast(u8, name, '/')) |s| {
        pelem.* = name[s + 1 ..];
        pdir.* = name[0..s];
    } else if (std.mem.eql(u8, name, "..")) {
        pdir.* = "..";
        pelem.* = ".";
    } else {
        pdir.* = ".";
        pelem.* = name;
    }
}

fn samefile(x: []const u8, y: []const u8) bool {
    if (std.mem.eql(u8, x, y))
        return true;
    var da = libc.dirstat(a, x) catch return false;
    defer da.deinit(a);
    var db = libc.dirstat(a, y) catch return false;
    defer db.deinit(a);
    return da.dir.qid.type == db.dir.qid.type and
        da.dir.qid.path == db.dir.qid.path and
        da.dir.qid.vers == db.dir.qid.vers and
        da.dir.dev == db.dir.dev and
        da.dir.type == db.dir.type;
}

fn hardremove(x: []const u8) void {
    libc.remove(x) catch {
        libc.fprint(2, "mv: can't remove %s: %r\n", .{x});
        libc.exits("mv");
    };
    while (true) {
        libc.remove(x) catch break;
    }
}
