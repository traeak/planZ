//! rc's syntax trees.
//! from cmd/rc/tree.c

const rc = @import("rc.zig");
const io = @import("io.zig");
const lex = @import("lex.zig");

const Tree = rc.Tree;

// create and clear a new tree node, and add it to the node list.
var treefree: ?*Tree = null;
var treenodes: ?*Tree = null;

pub fn newtree() *Tree {
    var t: *Tree = undefined;
    if (treefree) |f| {
        t = f;
        treefree = f.next;
    } else t = rc.new(Tree);
    t.* = .{
        .type = t.type,
        .rtype = t.rtype,
        .fd0 = t.fd0,
        .fd1 = t.fd1,
        .line = lex.lex.?.line,
        .next = treenodes,
    };
    treenodes = t;
    return t;
}

pub fn freenodes() void {
    var t_ = treenodes;
    while (t_) |t| {
        rc.free(t.str);
        t.str = null;
        t.child = .{ null, null, null };
        if (t.next == null) {
            t.next = treefree;
            treefree = treenodes;
            break;
        }
        t_ = t.next;
    }
    treenodes = null;
}

pub fn tree1(@"type": i32, c0: ?*Tree) ?*Tree {
    return tree3(@"type", c0, null, null);
}

pub fn tree2(@"type": i32, c0: ?*Tree, c1: ?*Tree) ?*Tree {
    return tree3(@"type", c0, c1, null);
}

pub fn tree3(@"type": i32, c0: ?*Tree, c1: ?*Tree, c2: ?*Tree) ?*Tree {
    if (@"type" == ';') {
        if (c0 == null)
            return c1;
        if (c1 == null)
            return c0;
    }
    const t = newtree();
    t.type = @"type";
    t.child = .{ c0, c1, c2 };

    if (c0) |c|
        t.line = c.line
    else if (c1) |c|
        t.line = c.line
    else if (c2) |c|
        t.line = c.line;
    return t;
}

pub fn mung1(t: *Tree, c0: ?*Tree) *Tree {
    t.child[0] = c0;
    return t;
}

pub fn mung2(t: *Tree, c0: ?*Tree, c1: ?*Tree) *Tree {
    t.child[0] = c0;
    t.child[1] = c1;
    return t;
}

pub fn mung3(t: *Tree, c0: ?*Tree, c1: ?*Tree, c2: ?*Tree) *Tree {
    t.child = .{ c0, c1, c2 };
    return t;
}

pub fn epimung(comp: ?*Tree, epi_: ?*Tree) ?*Tree {
    const epi = epi_ orelse return comp;
    var p = epi;
    while (p.child[1]) |c|
        p = c;
    p.child[1] = comp;
    return epi;
}

/// Add a SIMPLE node at the root of t and percolate all the
/// redirections up to the root.
pub fn simplemung(t_: ?*Tree) ?*Tree {
    var t = tree1(rc.SIMPLE, t_).?;
    t.str = fnstr(t);
    var u = t.child[0].?;
    while (u.type == rc.ARGLIST) : (u = u.child[0].?) {
        const c1 = u.child[1].?;
        if (c1.type == rc.DUP or c1.type == rc.REDIR) {
            c1.child[1] = t;
            t = c1;
            u.child[1] = null;
        }
    }
    return t;
}

pub fn fnstr(t: ?*Tree) []u8 {
    const f = io.openiostr();
    io.pfmt(f, "%t", .{t});
    return io.closeiostr(f);
}

pub fn globprop(t: *Tree) *Tree {
    var c0 = t.child[0];
    var c1 = t.child[1];
    if (c1 == null) {
        while (c0) |c| {
            if (c.type != rc.WORDS)
                break;
            c1 = c.child[1];
            if (c1) |w| {
                if (w.glob != 0) {
                    w.glob = 2;
                    t.glob = 1;
                }
            }
            c0 = c.child[0];
        }
    } else {
        if (c0.?.glob != 0) {
            c0.?.glob = 2;
            t.glob = 1;
        }
        if (c1.?.glob != 0) {
            c1.?.glob = 2;
            t.glob = 1;
        }
    }
    return t;
}

pub fn token(str: []const u8, @"type": i32) *Tree {
    const t = newtree();
    t.str = rc.estrdup(str);
    t.type = @"type";
    return t;
}
