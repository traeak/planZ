//! Lists of name=value, as factotum's keys are written.
//! from libauth/attr.c
//!
//! DIFF:
//!   - The C's %A is attrfmt, which prints a list into a Fmt; a list
//!     is a value with fmt9, so "%s" of it prints it.
//!   - The functions have the C's names without the underscore.

const std = @import("std");
const libc = @import("libc");
const fmt = libc.fmt;

pub const AttrType = enum(u32) {
    AttrNameval, // name=val -- when matching, must have name=val
    AttrQuery, // name? -- when matching, must be present
    AttrDefault, // name=val -- when matching, if present must match INTERNAL
};

pub const Attr = struct {
    type: AttrType,
    next: ?*Attr,
    name: []u8,
    val: []u8,
};

/// Print the list: name=val and name? with rc's quoting, a space
/// between.
pub fn attrfmt(f: *fmt.Fmt, a_: ?*Attr) void {
    var first = true;
    var a = a_;
    while (a) |x| : (a = x.next) {
        switch (x.type) {
            .AttrQuery => fmt.fmtprint(f, "%s%q?", .{ if (first) "" else " ", x.name }),
            .AttrNameval, .AttrDefault => fmt.fmtprint(f, "%s%q=%q", .{ if (first) "" else " ", x.name, x.val }),
        }
        first = false;
    }
}

pub fn copyattr(a_: ?*Attr) ?*Attr {
    var na: ?*Attr = null;
    var la: *?*Attr = &na;
    var a = a_;
    while (a) |x| : (a = x.next) {
        const n = mkattr(x.type, x.name, x.val, null);
        la.* = n;
        la = &n.next;
    }
    la.* = null;
    return na;
}

pub fn delattr(a_: ?*Attr, name: []const u8) ?*Attr {
    var a = a_;
    var la: *?*Attr = &a;
    while (la.*) |x| {
        if (std.mem.eql(u8, x.name, name)) {
            la.* = x.next;
            x.next = null;
            freeattr(x);
        } else la = &x.next;
    }
    return a;
}

pub fn findattr(a_: ?*Attr, n: []const u8) ?*Attr {
    var a = a_;
    while (a) |x| : (a = x.next) {
        if (std.mem.eql(u8, x.name, n) and x.type != .AttrQuery)
            return x;
    }
    return null;
}

pub fn freeattr(a_: ?*Attr) void {
    var a = a_;
    while (a) |x| {
        a = x.next;
        libc.allocator.free(x.name);
        libc.allocator.free(x.val);
        libc.allocator.destroy(x);
    }
}

pub fn mkattr(t: AttrType, name: []const u8, val: []const u8, next: ?*Attr) *Attr {
    const a = libc.allocator.create(Attr) catch libc.sysfatal("_mkattr malloc: %r", .{});
    a.* = .{
        .type = t,
        .name = libc.allocator.dupe(u8, name) catch libc.sysfatal("_mkattr malloc: %r", .{}),
        .val = libc.allocator.dupe(u8, val) catch libc.sysfatal("_mkattr malloc: %r", .{}),
        .next = next,
    };
    return a;
}

fn cleanattr(a_: ?*Attr) ?*Attr {
    var a = a_;
    var la: *?*Attr = &a;
    while (la.*) |x| {
        if (x.type == .AttrQuery and findattr(a, x.name) != null) {
            la.* = x.next;
            x.next = null;
            freeattr(x);
        } else la = &x.next;
    }
    return a;
}

pub fn parseattr(s_: []const u8) ?*Attr {
    var tok: [256][]u8 = undefined;

    const s = libc.allocator.dupe(u8, s_) catch libc.sysfatal("_parseattr strdup: %r", .{});
    defer libc.allocator.free(s);

    const ntok = libc.tokenize(s, &tok);
    var a: ?*Attr = null;
    var i = ntok;
    while (i > 0) {
        i -= 1;
        const t = tok[i];
        if (std.mem.indexOfScalar(u8, t, '=')) |p| {
            a = mkattr(.AttrNameval, t[0..p], t[p + 1 ..], a);
        } else if (t.len > 0 and t[t.len - 1] == '?') {
            a = mkattr(.AttrQuery, t[0 .. t.len - 1], "", a);
        } else {
            // really a syntax error, but better to provide some indication
            a = mkattr(.AttrNameval, t, "", a);
        }
    }
    return cleanattr(a);
}

pub fn strfindattr(a: ?*Attr, n: []const u8) ?[]const u8 {
    const x = findattr(a, n) orelse return null;
    return x.val;
}
