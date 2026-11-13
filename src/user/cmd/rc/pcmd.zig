//! rc's syntax trees printed as rc text: what `whatis` shows and what
//! /env/fn#name holds, so the same as stock byte for byte.
//! from cmd/rc/pcmd.c

const rc = @import("rc.zig");
const io = @import("io.zig");

const Tree = rc.Tree;
const pfmt = io.pfmt;

fn pdeglob(f: *io.Io, s: []const u8) void {
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == rc.GLOB) {
            i += 1;
            if (i == s.len) break;
        }
        io.pchr(f, s[i]);
        i += 1;
    }
}

var ntab: u32 = 0;

fn tabs() []const u8 {
    return "\t\t\t\t\t\t\t\t"[8 - ntab % 8 ..];
}

pub fn pcmd(f: *io.Io, t_: ?*Tree) void {
    const t = t_ orelse return;
    const c0 = t.child[0];
    const c1 = t.child[1];
    const c2 = t.child[2];
    switch (t.type) {
        else => pfmt(f, "bad %d %p %p %p", .{ t.type, c0, c1, c2 }),
        '$' => pfmt(f, "$%t", .{c0}),
        '"' => pfmt(f, "$\"%t", .{c0}),
        '&' => pfmt(f, "%t&", .{c0}),
        '^' => pfmt(f, "%t^%t", .{ c0, c1 }),
        '`' => pfmt(f, "`%t%t", .{ c0, c1 }),
        rc.ANDAND => pfmt(f, "%t && %t", .{ c0, c1 }),
        rc.BANG => pfmt(f, "! %t", .{c0}),
        rc.BRACE => {
            ntab += 1;
            pfmt(f, "{\n%s%t", .{ tabs(), c0 });
            ntab -= 1;
            pfmt(f, "\n%s}", .{tabs()});
        },
        rc.COUNT => pfmt(f, "$#%t", .{c0}),
        rc.FN => pfmt(f, "fn %t %t", .{ c0, c1 }),
        rc.IF => pfmt(f, "if%t%t", .{ c0, c1 }),
        rc.NOT => pfmt(f, "if not %t", .{c0}),
        rc.OROR => pfmt(f, "%t || %t", .{ c0, c1 }),
        rc.PCMD, rc.PAREN => pfmt(f, "(%t)", .{c0}),
        rc.SUB => pfmt(f, "$%t(%t)", .{ c0, c1 }),
        rc.SIMPLE => pfmt(f, "%t", .{c0}),
        rc.SUBSHELL => pfmt(f, "@ %t", .{c0}),
        rc.SWITCH => pfmt(f, "switch %t %t", .{ c0, c1 }),
        rc.TWIDDLE => pfmt(f, "~ %t %t", .{ c0, c1 }),
        rc.WHILE => pfmt(f, "while %t%t", .{ c0, c1 }),
        rc.ARGLIST => {
            if (c0 == null)
                pfmt(f, "%t", .{c1})
            else if (c1 == null)
                pfmt(f, "%t", .{c0})
            else
                pfmt(f, "%t %t", .{ c0, c1 });
        },
        ';' => {
            if (c0) |x| {
                pfmt(f, "%t", .{x});
                if (c1) |y| {
                    if (x.line == y.line)
                        io.pstr(f, "; ")
                    else
                        pfmt(f, "\n%s", .{tabs()});
                    pfmt(f, "%t", .{y});
                }
            } else pfmt(f, "%t", .{c1});
        },
        rc.WORDS => {
            if (c0 != null)
                pfmt(f, "%t ", .{c0});
            pfmt(f, "%t", .{c1});
        },
        rc.FOR => {
            pfmt(f, "for(%t", .{c0});
            if (c1 != null)
                pfmt(f, " in %t", .{c1});
            pfmt(f, ")%t", .{c2});
        },
        rc.WORD => {
            if (t.quoted)
                pfmt(f, "%Q", .{t.str.?})
            else
                pdeglob(f, t.str.?);
        },
        rc.DUP => {
            if (t.rtype == rc.DUPFD)
                pfmt(f, ">[%d=%d]", .{ t.fd1, t.fd0 }) // yes, fd1, then fd0; read lex.c
            else
                pfmt(f, ">[%d=]", .{t.fd0});
            pfmt(f, "%t", .{c1});
        },
        rc.PIPEFD, rc.REDIR => {
            io.pchr(f, ' ');
            switch (t.rtype) {
                rc.HERE, rc.READ, rc.RDWR => {
                    if (t.rtype == rc.HERE) {
                        if (c1 != null)
                            pfmt(f, "%t ", .{c1});
                        io.pchr(f, '<');
                    }
                    io.pchr(f, '<');
                    if (t.rtype == rc.RDWR)
                        io.pchr(f, '>');
                    if (t.fd0 != 0)
                        pfmt(f, "[%d]", .{t.fd0});
                },
                rc.APPEND, rc.WRITE => {
                    if (t.rtype == rc.APPEND)
                        io.pchr(f, '>');
                    io.pchr(f, '>');
                    if (t.fd0 != 1)
                        pfmt(f, "[%d]", .{t.fd0});
                },
                else => {},
            }
            pfmt(f, "%t", .{c0});
            if (t.rtype == rc.HERE)
                pfmt(f, "\n%s%s\n", .{ t.str, c0.?.str })
            else if (c1 != null)
                pfmt(f, " %t", .{c1});
        },
        '=' => {
            pfmt(f, "%t=%t", .{ c0, c1 });
            if (c2 != null)
                pfmt(f, " %t", .{c2});
        },
        rc.PIPE => {
            pfmt(f, "%t|", .{c0});
            if (t.fd1 == 0) {
                if (t.fd0 != 1)
                    pfmt(f, "[%d]", .{t.fd0});
            } else pfmt(f, "[%d=%d]", .{ t.fd0, t.fd1 });
            pfmt(f, "%t", .{c1});
        },
    }
}
