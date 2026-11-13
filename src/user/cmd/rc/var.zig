//! rc's variables and its keywords.
//! from cmd/rc/var.c

const std = @import("std");
const rc = @import("rc.zig");
const tree = @import("tree.zig");
const exec = @import("exec.zig");

const Var = rc.Var;

pub var gvar: [rc.NVAR]?*Var = @splat(null);

/// The C's hash, over its signed chars.
pub fn hash(s: []const u8, n: i32) i32 {
    var h: i32 = 0;
    var i: i32 = 1;
    for (s) |c| {
        h +%= @as(i32, @as(i8, @bitCast(c))) *% i;
        i += 1;
    }
    h = @rem(h, n);
    return if (h < 0) h + n else h;
}

const NKW = 30;
const Kw = struct {
    name: []const u8,
    type: i32,
    next: ?*Kw,
};
var kw: [NKW]?*Kw = @splat(null);

fn kenter(@"type": i32, name: []const u8) void {
    const h: usize = @intCast(hash(name, NKW));
    const p = rc.new(Kw);
    p.* = .{ .type = @"type", .name = name, .next = kw[h] };
    kw[h] = p;
}

pub fn kinit() void {
    kenter(rc.FOR, "for");
    kenter(rc.IN, "in");
    kenter(rc.WHILE, "while");
    kenter(rc.IF, "if");
    kenter(rc.NOT, "not");
    kenter(rc.TWIDDLE, "~");
    kenter(rc.BANG, "!");
    kenter(rc.SUBSHELL, "@");
    kenter(rc.SWITCH, "switch");
    kenter(rc.FN, "fn");
}

pub fn klook(name: []const u8) *rc.Tree {
    const t = tree.token(name, rc.WORD);
    var p_ = kw[@intCast(hash(name, NKW))];
    while (p_) |p| : (p_ = p.next) {
        if (std.mem.eql(u8, p.name, name)) {
            t.type = p.type;
            t.iskw = true;
            break;
        }
    }
    return t;
}

pub fn newvar(name: []const u8, next: ?*Var) *Var {
    const v = rc.new(Var);
    v.* = .{ .name = rc.estrdup(name), .next = next };
    return v;
}

pub fn gvlook(name: []const u8) *Var {
    const h: usize = @intCast(hash(name, rc.NVAR));
    var v_ = gvar[h];
    while (v_) |v| : (v_ = v.next)
        if (std.mem.eql(u8, v.name, name)) return v;
    gvar[h] = newvar(name, gvar[h]);
    return gvar[h].?;
}

pub fn vlook(name: []const u8) *Var {
    if (exec.runq) |r| {
        var v_ = r.local;
        while (v_) |v| : (v_ = v.next)
            if (std.mem.eql(u8, v.name, name)) return v;
    }
    return gvlook(name);
}

pub fn setvar(name: []const u8, val: ?*rc.Word) void {
    const v = vlook(name);
    exec.freewords(v.val);
    v.val = val;
    v.changed = true;
}

pub fn freevar(v: *Var) void {
    exec.freewords(v.val);
    rc.a.free(v.name);
    rc.destroy(v);
}
