//! rc's lexer.
//! from cmd/rc/lex.c
//!
//! Characters are i32, with io.EOF, as in C.  A 0 byte in the input
//! is not a word character (strchr finds the string's own 0), so yylex
//! returns it as token 0, which the parser takes as the end, as stock
//! rc does.
//!
//! DIFF: the token is tok[0..ntok], kept with the C's 0 after it.
//! Fixed from C: the fd digits of a redirection are bounded (tooLong).

const std = @import("std");
const rc = @import("rc.zig");
const io = @import("io.zig");
const tree = @import("tree.zig");
const @"var" = @import("var.zig");
const exec = @import("exec.zig");
const getflags = @import("getflags.zig");
const syn = @import("syn.zig");

const EOF = io.EOF;
const Lexer = rc.Lexer;

pub var lex: ?*Lexer = null; // current lexer

pub var doprompt = true;
pub var nerror: i32 = 0;

/// strchr(s, c) != 0, where s's 0 is found for c == 0.
fn strchr(s: []const u8, c: i32) bool {
    return c == 0 or (c > 0 and c < 256 and std.mem.indexOfScalar(u8, s, @intCast(c)) != null);
}

pub fn wordchr(c: i32) bool {
    return !strchr("\n \t#;&|^$=`'{}()<>", c) and c != EOF;
}

pub fn idchr(c: i32) bool {
    // Formerly:
    // return 'a'<=c && c<='z' || 'A'<=c && c<='Z' || '0'<=c && c<='9'
    //    || c=='_' || c=='*';
    return c > ' ' and !strchr("!\"#$%&'()+,-./:;<=>?@[\\]^`{|}~", c);
}

pub fn newlexer(input: *io.Io, file: ?[]u8) *Lexer {
    const n = rc.new(Lexer);
    n.* = .{ .input = input, .file = file };
    n.tok[0] = 0;
    return n;
}

pub fn freelexer(p: *Lexer) void {
    io.closeio(p.input);
    rc.free(p.file);
    rc.destroy(p);
}

/// read a character from the input stream
fn getnext() i32 {
    const l = lex.?;
    if (l.peekc != EOF) {
        const c = l.peekc;
        l.peekc = EOF;
        return c;
    }
    if (l.eof)
        return epilog(l);
    if (doprompt)
        exec.pprompt();
    var c = io.rchr(l.input);
    if (c == '\\' and !l.inquote) {
        c = io.rchr(l.input);
        if (c == '\n' and !l.incomm) { // don't continue a comment
            l.line += 1;
            doprompt = true;
            c = ' ';
        } else {
            l.peekc = c;
            c = '\\';
        }
    }
    if (c == EOF) {
        l.eof = true;
        return epilog(l);
    } else {
        if (c == '\n')
            doprompt = true;
        if ((!l.qflag and getflags.flag['v'] != null) or getflags.flag['V'] != null)
            io.pchr(exec.err, @intCast(c));
    }
    return c;
}

fn epilog(l: *Lexer) i32 {
    if (l.epilog.len > 0) {
        const c = l.epilog[0];
        l.epilog = l.epilog[1..];
        return c;
    }
    doprompt = true;
    return EOF;
}

/// Look ahead in the input stream
fn nextc() i32 {
    const l = lex.?;
    if (l.future == EOF)
        l.future = getnext();
    return l.future;
}

/// Consume the lookahead character.
fn advance() i32 {
    const c = nextc();
    const l = lex.?;
    l.lastc = l.future;
    l.future = EOF;
    if (c == '\n')
        l.line += 1;
    return c;
}

fn skipwhite() void {
    while (true) {
        var c = nextc();
        // Why did this used to be  if(!inquote && c=='#') ??
        if (c == '#') {
            lex.?.incomm = true;
            while (true) {
                c = nextc();
                if (c == '\n' or c == EOF) {
                    lex.?.incomm = false;
                    break;
                }
                _ = advance();
            }
        }
        if (c == ' ' or c == '\t')
            _ = advance()
        else
            return;
    }
}

pub fn skipnl() void {
    while (true) {
        skipwhite();
        const c = nextc();
        if (c != '\n')
            return;
        _ = advance();
    }
}

fn nextis(c: i32) bool {
    if (nextc() == c) {
        _ = advance();
        return true;
    }
    return false;
}

/// Add val to the token at p; null (and an error) when it is full.
fn addtok(p_: ?usize, val: i32) ?usize {
    const p = p_ orelse return null;
    const l = lex.?;
    if (p == rc.NTOK - 1) {
        l.tok[p] = 0;
        l.ntok = p;
        yyerror("token buffer too short");
        return null;
    }
    l.tok[p] = @truncate(@as(u32, @bitCast(val)));
    return p + 1;
}

fn addutf(p_: ?usize, c_: i32) ?usize {
    var c = c_;
    var p = addtok(p_, c); // 1-byte UTF runes are special
    if (rc.onebyte(c))
        return p;
    const n: usize = if (rc.twobyte(c)) 2 else if (rc.threebyte(c)) 3 else 4;
    for (1..n) |_| {
        c = nextc();
        if (c == EOF or !rc.xbyte(c))
            break;
        p = addtok(p, advance());
    }
    return p;
}

fn settok(l: *Lexer, s: []const u8) void {
    @memcpy(l.tok[0..s.len], s);
    l.tok[s.len] = 0;
    l.ntok = s.len;
}

/// The token and, in yylval, its tree.
pub fn yylex() i32 {
    const l = lex.?;
    var c: i32 = undefined;
    const d = nextc();
    var w: ?usize = 0;
    var t: *rc.Tree = undefined;

    syn.yylval = null;

    // Embarassing sneakiness:  if the last token read was a quoted or
    // unquoted WORD then we alter the meaning of what follows.  If the
    // next character is `(', we return SUB (a subscript paren) and
    // consume the `('.  Otherwise, if the next character is the first
    // character of a simple or compound word, we insert a `^' before
    // it.
    if (l.lastword) {
        l.lastword = false;
        if (d == '(') {
            _ = advance();
            settok(l, "( [SUB]");
            return rc.SUB;
        }
        if (wordchr(d) or d == '\'' or d == '`' or d == '$' or d == '"') {
            settok(l, "^");
            return '^';
        }
    }
    l.inquote = false;
    skipwhite();
    c = advance();
    switch (c) {
        EOF => {
            l.lastdol = false;
            settok(l, "EOF");
            return EOF;
        },
        '$' => {
            l.lastdol = true;
            if (nextis('#')) {
                settok(l, "$#");
                return rc.COUNT;
            }
            if (nextis('"')) {
                settok(l, "$\"");
                return '"';
            }
            settok(l, "$");
            return '$';
        },
        '&' => {
            l.lastdol = false;
            if (nextis('&')) {
                skipnl();
                settok(l, "&&");
                return rc.ANDAND;
            }
            settok(l, "&");
            return '&';
        },
        '|', '<', '>' => {
            l.lastdol = false;
            if (c == '|' and nextis(c)) {
                skipnl();
                settok(l, "||");
                return rc.OROR;
            }
            // funny redirection tokens:
            //    redir:    arrow | arrow '[' fd ']'
            //    arrow:    '<' | '<<' | '>' | '>>' | '|'
            //    fd:    digit | digit '=' | digit '=' digit
            //    digit:    '0'|'1'|'2'|'3'|'4'|'5'|'6'|'7'|'8'|'9'
            // some possibilities are nonsensical and get a message.
            var k: usize = 0;
            l.tok[k] = @intCast(c);
            k += 1;
            t = tree.newtree();
            switch (c) {
                '|' => {
                    t.type = rc.PIPE;
                    t.fd0 = 1;
                    t.fd1 = 0;
                },
                '>' => {
                    t.type = rc.REDIR;
                    if (nextis(c)) {
                        t.rtype = rc.APPEND;
                        l.tok[k] = @intCast(c);
                        k += 1;
                    } else t.rtype = rc.WRITE;
                    t.fd0 = 1;
                },
                '<' => {
                    t.type = rc.REDIR;
                    if (nextis(c)) {
                        t.rtype = rc.HERE;
                        l.tok[k] = @intCast(c);
                        k += 1;
                    } else if (nextis('>')) {
                        t.rtype = rc.RDWR;
                        l.tok[k] = @intCast(c);
                        k += 1;
                    } else t.rtype = rc.READ;
                    t.fd0 = 0;
                },
                else => unreachable,
            }
            redir: {
                if (!nextis('['))
                    break :redir;
                l.tok[k] = '[';
                k += 1;
                c = advance();
                // Kept from C: the first digit goes into tok here and
                // again in the loop, so stock's messages show >[22=1]
                // for >[2=1].
                l.tok[k] = @truncate(@as(u32, @bitCast(c)));
                k += 1;
                if (c < '0' or '9' < c)
                    return rediErr(l, t, k);
                t.fd0 = 0;
                while (true) {
                    t.fd0 = t.fd0 *% 10 +% c - '0';
                    if (k >= rc.NTOK - 4)
                        return tooLong(l, k);
                    l.tok[k] = @intCast(c);
                    k += 1;
                    c = advance();
                    if (!('0' <= c and c <= '9')) break;
                }
                if (c == '=') {
                    l.tok[k] = '=';
                    k += 1;
                    if (t.type == rc.REDIR)
                        t.type = rc.DUP;
                    c = advance();
                    if ('0' <= c and c <= '9') {
                        t.rtype = rc.DUPFD;
                        t.fd1 = t.fd0;
                        t.fd0 = 0;
                        while (true) {
                            t.fd0 = t.fd0 *% 10 +% c - '0';
                            if (k >= rc.NTOK - 4)
                                return tooLong(l, k);
                            l.tok[k] = @intCast(c);
                            k += 1;
                            c = advance();
                            if (!('0' <= c and c <= '9')) break;
                        }
                    } else {
                        if (t.type == rc.PIPE)
                            return rediErr(l, t, k);
                        t.rtype = rc.CLOSE;
                    }
                }
                if (c != ']' or t.type == rc.DUP and (t.rtype == rc.HERE or t.rtype == rc.APPEND))
                    return rediErr(l, t, k);
                l.tok[k] = ']';
                k += 1;
            }
            l.tok[k] = 0;
            l.ntok = k;
            syn.yylval = t;
            if (t.type == rc.PIPE)
                skipnl();
            return t.type;
        },
        '\'' => {
            l.lastdol = false;
            l.lastword = true;
            l.inquote = true;
            while (true) {
                c = advance();
                if (c == EOF)
                    break;
                if (c == '\'') {
                    if (nextc() != '\'')
                        break;
                    _ = advance();
                }
                w = addutf(w, c);
            }
            if (w) |k| {
                l.tok[k] = 0;
                l.ntok = k;
            }
            t = tree.token(l.token(), rc.WORD);
            t.quoted = true;
            syn.yylval = t;
            return t.type;
        },
        else => {},
    }
    if (!wordchr(c)) {
        l.lastdol = false;
        l.tok[0] = @truncate(@as(u32, @bitCast(c)));
        l.tok[1] = 0;
        l.ntok = if (c == 0) 0 else 1;
        return c;
    }
    var glob = false;
    while (true) {
        if (c == '*' or c == '[' or c == '?' or c == rc.GLOB) {
            glob = true;
            w = addtok(w, rc.GLOB);
        }
        w = addutf(w, c);
        c = nextc();
        if (if (l.lastdol) !idchr(c) else !wordchr(c)) break;
        _ = advance();
    }

    l.lastword = true;
    l.lastdol = false;
    if (w) |k| {
        l.tok[k] = 0;
        l.ntok = k;
    }
    t = @"var".klook(l.token());
    if (t.type != rc.WORD)
        l.lastword = false
    else
        t.glob = @intFromBool(glob);
    t.quoted = false;
    syn.yylval = t;
    return t.type;
}

fn rediErr(l: *Lexer, t: *rc.Tree, k: usize) i32 {
    l.tok[k] = 0;
    l.ntok = k;
    yyerror(if (t.type == rc.PIPE) "pipe syntax" else "redirection syntax");
    return EOF;
}

/// Fixed from C: the C writes the digits of a redirection's fd into tok
/// without a bound and overruns it; this stops as addtok does.
fn tooLong(l: *Lexer, k: usize) i32 {
    l.tok[k] = 0;
    l.ntok = k;
    yyerror("token buffer too short");
    return EOF;
}

pub fn yyerror(m: []const u8) void {
    const l = lex.?;
    rc.pfln(exec.err, l.file, l.line);
    io.pstr(exec.err, ": ");
    if (l.tok[0] != 0 and l.tok[0] != '\n')
        io.pfmt(exec.err, "token %q: ", .{l.token()});
    io.pfmt(exec.err, "%s\n", .{m});
    io.flushio(exec.err);

    l.lastword = false;
    l.lastdol = false;
    while (l.lastc != '\n' and l.lastc != EOF) _ = advance();
    nerror += 1;

    exec.setstatus(m);
}
