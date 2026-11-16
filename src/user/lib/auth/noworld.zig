//! from libauth/noworld.c

const std = @import("std");
const libc = @import("libc");
const sys = libc.sys;

/// see if user is in the group noworld, i.e., has all file
/// priviledges masked with 770, and all directories with
/// 771, before checking access rights
pub fn noworld(user: []const u8) bool {
    var b: libc.Biobuf = .{};
    b.open("/adm/users", sys.OREAD | sys.OCEXEC) catch return false;
    defer b.term() catch {};

    var members: ?[]const u8 = null;
    while (b.rdline('\n')) |line| {
        const l = line[0 .. line.len - 1];
        const c = std.mem.indexOfScalar(u8, l, ':') orelse continue;
        if (std.mem.startsWith(u8, l[c..], ":noworld:")) {
            members = l[c + 9 ..];
            break;
        }
    }
    // DIFF: the C looks for the user in the last line read when no
    // line is noworld's (its p is then nil, and it finds nothing)
    const p = members orelse return false;
    var off: usize = 0;
    while (std.mem.indexOfPos(u8, p, off, user)) |i| {
        const before = if (i == 0) ':' else p[i - 1];
        const after: u8 = if (i + user.len >= p.len) 0 else p[i + user.len];
        if ((before == ':' or before == ',') and (after == ':' or after == ',' or after == 0))
            return true;
        off = i + 1;
    }
    return false;
}
