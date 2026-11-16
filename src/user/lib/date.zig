//! Time zones from their files, the time now, and ctime.
//! from libc/port/date.c (tzload, loadzone's file, tmnow) and
//! libc/9sys/ctime.c
//!
//! The calendar itself is tm.zig, which the host tests run; this file
//! reads /env/timezone, /adm/timezone and the clock, and puts tm.zig's
//! error text where %r finds it.
//!
//! DIFF:
//!   - localtime and gmtime return the Tm, where the C returns a
//!     pointer to a static one.

const std = @import("std");
const libc = @import("libc.zig");
pub const tm_ = @import("tm.zig");

pub const Tm = tm_.Tm;
pub const Tzone = tm_.Tzone;
pub const Tmfmt = tm_.Tmfmt;
pub const tmtime = tm_.tmtime;
pub const tmtimens = tm_.tmtimens;
pub const tmnorm = tm_.tmnorm;
pub const tmfmtarg = tm_.tmfmtarg;
pub const asctime = tm_.asctime;
pub const ascraw = tm_.ascraw;

var zlock: libc.QLock = .{};
var zones: std.ArrayList(*Tzone) = .empty;

fn seterr(s: []const u8) void {
    libc.werrstr("%s", .{s});
}

/// tm.zig's errors go to the error string as they happen.
fn hook() void {
    if (tm_.errhook == null)
        tm_.errhook = seterr;
}

fn loadzone(tz: *Tzone, name: []const u8) bool {
    hook();
    var buf: [tm_.Tzsize * 11 + 30]u8 = undefined;
    var pb: [128]u8 = undefined;

    if (name.len >= tz.tzname.len) {
        libc.werrstr("timezone name too long", .{});
        return false;
    }
    const path = if (std.mem.eql(u8, name, "local"))
        libc.sprint(&pb, "/env/timezone", .{})
    else
        libc.sprint(&pb, "/adm/timezone/%s", .{name});
    const f = libc.open(path, libc.OREAD | libc.OCEXEC) catch return false;
    const r = libc.read(f, &buf) catch {
        libc.close(f) catch {};
        return false;
    };
    libc.close(f) catch {};
    if (r >= buf.len)
        return false;
    tm_.parsezone(tz, name, buf[0..r]) catch {
        return false;
    };
    return true;
}

/// The zone of that name: "local" is /env/timezone, others are files
/// of /adm/timezone, and null is GMT's file.  Null if it cannot be
/// read, with the reason in the error string.
pub fn tzload(name: ?[]const u8) ?*const Tzone {
    const tzname = name orelse "GMT";
    libc.qlock(&zlock);
    defer libc.qunlock(&zlock);
    for (zones.items) |tz| {
        if (std.mem.eql(u8, tm_.name(&tz.stname), tzname))
            return tz;
        if (std.mem.eql(u8, tm_.name(&tz.dlname), tzname))
            return tz;
        if (std.mem.eql(u8, tm_.name(&tz.tzname), tzname))
            return tz;
    }
    const tz = libc.allocator.create(Tzone) catch return null;
    if (!loadzone(tz, tzname)) {
        libc.allocator.destroy(tz);
        return null;
    }
    zones.append(libc.allocator, tz) catch {
        libc.allocator.destroy(tz);
        return null;
    };
    return tz;
}

fn tzloadname(name: []const u8) ?*const Tzone {
    return tzload(name);
}

pub fn tmnow(tm: *Tm, tz: ?*const Tzone) void {
    tm_.tmnowns(tm, libc.nsec(), tz);
}

/// Print tm by format (null: ctime's) into f.  On error.Garbled the
/// error string says so.
pub fn tmfmt(f: *libc.fmt.Fmt, tm: *const Tm, format: ?[]const u8) error{Garbled}!void {
    hook();
    return tm_.tmfmt(f, tm, format);
}

/// Parse str by format into tm; returns how much of str was used.
pub fn tmparse(tm: *Tm, format: []const u8, str: []const u8, tz: ?*const Tzone) error{ Garbled, BadDate }!usize {
    hook();
    return tm_.tmparse(tm, format, str, tz, tzloadname);
}

// We have no way to report errors,
// so we just ignore them here.
pub fn localtime(tim: i32) Tm {
    var tm: Tm = .{};
    tmtime(&tm, tim, tzload("local"));
    return tm;
}

pub fn gmtime(abs: i32) Tm {
    var tm: Tm = .{};
    tmtime(&tm, abs, null);
    return tm;
}

/// "Sun Nov 15 21:05:00 MST 2026\n" for local time, in a buffer that
/// the next call uses again.
pub fn ctime(abs: i32) []const u8 {
    var tm: Tm = .{};
    tmtime(&tm, abs, tzload("local"));
    return asctime(&tm);
}
