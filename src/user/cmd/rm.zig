//! rm - remove files
//! from cmd/rm.c

const std = @import("std");
const libc = @import("libc");

var errbuf: [libc.ERRMAX]u8 = undefined;
var errlen: usize = 0;
var ignerr = false;

fn err(f: []const u8) void {
    if (!ignerr) {
        // DIFF: read with rerrstr; the C's errstr swaps its empty
        // buffer in, which comes to the same here
        errlen = libc.rerrstr(&errbuf).len;
        libc.fprint(2, "rm: %s: %s\n", .{ f, errbuf[0..errlen] });
    }
}

/// f is a non-empty directory. Remove its contents and then it.
fn rmdir(f: []const u8) void {
    const a = libc.allocator;
    const fd = libc.open(f, libc.OREAD) catch {
        err(f);
        return;
    };
    var db = libc.dirreadall(a, fd) catch {
        libc.close(fd) catch {};
        err("dirreadall");
        return;
    };
    defer db.deinit(a);
    libc.close(fd) catch {};

    const nname = f.len + 1 + libc.fcall.STATMAX + 1; // plenty!
    const name = a.alloc(u8, nname) catch {
        err("memory allocation");
        return;
    };
    defer a.free(name);

    var ndir: usize = 0;
    for (db.dirs) |*d| {
        const n = libc.sprint(name, "%s/%s", .{ f, d.name });
        if (libc.remove(n)) |_| {
            d.qid.type = libc.fcall.QTFILE; // so we won't recurse
        } else |_| {
            if ((d.qid.type & libc.fcall.QTDIR) != 0)
                ndir += 1
            else
                err(n);
        }
    }
    if (ndir != 0) {
        for (db.dirs) |*d| {
            if ((d.qid.type & libc.fcall.QTDIR) != 0) {
                // DIFF: each recursion has its own name buffer
                const n = libc.sprint(name, "%s/%s", .{ f, d.name });
                const copy = a.dupe(u8, n) catch {
                    err("memory allocation");
                    continue;
                };
                defer a.free(copy);
                rmdir(copy);
            }
        }
    }
    libc.remove(f) catch err(f);
}

pub fn main(argv: []const []const u8) void {
    var recurse = false;
    var args = libc.Args.init(argv);
    while (args.next()) |c| switch (c) {
        'r' => recurse = true,
        'f' => ignerr = true,
        else => {
            libc.fprint(2, "usage: rm [-fr] file ...\n", .{});
            libc.exits("usage");
        },
    };
    const a = libc.allocator;
    for (args.rest()) |f| {
        if (libc.remove(f)) |_| continue else |_| {}
        if (recurse) {
            if (libc.dirstat(a, f)) |st_| {
                var st = st_;
                defer st.deinit(a);
                if ((st.dir.qid.type & libc.fcall.QTDIR) != 0) {
                    rmdir(f);
                    continue;
                }
            } else |_| {}
        }
        err(f);
    }
    libc.exits(errbuf[0..errlen]);
}
