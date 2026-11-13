//! rc's here documents.
//! from cmd/rc/here.c
//!
//! In progress: so far the reading (what the parser does); psubst comes
//! with the interpreter.

const rc = @import("rc.zig");
const io = @import("io.zig");
const lex = @import("lex.zig");
const exec = @import("exec.zig");

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
