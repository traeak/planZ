//! rc's here documents.
//! from cmd/rc/here.c
//!
//! DIFF: psubst reads the document as a slice; the C writes a 0 after
//! each variable name for a while.

const rc = @import("rc.zig");
const io = @import("io.zig");
const lex = @import("lex.zig");
const exec = @import("exec.zig");
const @"var" = @import("var.zig");

const Tree = rc.Tree;

fn readhere1(tag: *Tree, in: *io.Io) ?[]u8 {
    exec.pprompt();
    const out = io.openiostr();
    const str = tag.str.?;
    var m: ?usize = 0; // how much of the tag the line matches so far
    while (true) {
        const ci = io.rchr(in);
        // Kept from C: c is a signed char there, so a 0xff byte is EOF
        // too and ends the document.
        if (ci == io.EOF or ci == 0xff)
            break;
        const c: u8 = @intCast(ci);
        if (c == 0) {
            lex.yyerror("NUL bytes in here doc");
            io.closeio(out);
            return null;
        }
        if (c == '\n') {
            lex.lex.?.line += 1;
            if (m != null and m.? == str.len) {
                out.bufp -= m.?;
                out.buf[out.bufp] = 0;
                break;
            }
            exec.pprompt();
            m = 0;
        } else if (m) |k| {
            if (k < str.len and str[k] == c) {
                m = k + 1;
            } else {
                m = null;
            }
        }
        io.pchr(out, c);
    }
    lex.doprompt = true;
    return io.closeiostr(out);
}

var head: ?*Tree = null;
var tail: ?*Tree = null;

pub fn heredoc(redir: *Tree) void {
    if (redir.child[0].?.type != rc.WORD) {
        lex.yyerror("Bad here tag");
        return;
    }
    redir.child[2] = null;
    if (head != null)
        tail.?.child[2] = redir
    else
        head = redir;
    tail = redir;
}

pub fn readhere(in: *io.Io) void {
    while (head) |h| {
        tail = h.child[2];
        h.child[2] = null;
        h.str = readhere1(h.child[0].?, in);
        head = tail;
    }
}

fn at(s: []const u8, i: usize) u8 {
    return if (i < s.len) s[i] else 0;
}

/// Write the document s with its $variables substituted.
pub fn psubst(f: *io.Io, s: []const u8) void {
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] != '$') {
            if (0xa0 <= s[i] and s[i] <= 0xf5) {
                io.pchr(f, s[i]);
                i += 1;
                if (at(s, i) == 0)
                    break;
            } else if (0xf6 <= s[i] and s[i] <= 0xf7) {
                io.pchr(f, s[i]);
                i += 1;
                if (at(s, i) == 0)
                    break;
                io.pchr(f, s[i]);
                i += 1;
                if (at(s, i) == 0)
                    break;
            }
            io.pchr(f, s[i]);
            i += 1;
        } else {
            i += 1;
            var t = i;
            if (at(s, t) == '$') {
                io.pchr(f, '$');
                t += 1;
            } else {
                while (at(s, t) != 0 and lex.idchr(s[t])) t += 1;
                const name = s[i..t];
                var n: i32 = 0;
                var u: usize = 0;
                while (u < name.len and '0' <= name[u] and name[u] <= '9') : (u += 1)
                    n = n *% 10 +% (name[u] - '0');
                if (n != 0 and u == name.len) {
                    var star = @"var".vlook("*").val;
                    if (star != null and 1 <= n and n <= exec.count(star)) {
                        n -= 1;
                        while (n > 0) : (n -= 1) star = star.?.next;
                        io.pstr(f, star.?.word);
                    }
                } else pstrs(f, @"var".vlook(name).val);
                if (at(s, t) == '^')
                    t += 1;
            }
            i = t;
        }
    }
}

fn pstrs(f: *io.Io, a_: ?*rc.Word) void {
    var a = a_ orelse return;
    while (a.next) |n| {
        io.pstr(f, a.word);
        io.pchr(f, ' ');
        a = n;
    }
    io.pstr(f, a.word);
}
