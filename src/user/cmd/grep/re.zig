//! grep's patterns and its machine: the lexer and parser (grep.y), the
//! pattern graph (sub.c), classes as UTF-8 byte ranges and the DFA built
//! as the input needs it (comp.c).
//! from cmd/grep/grep.y, comp.c, sub.c, grep.h
//!
//! The machine matches bytes.  A pattern becomes a graph of nodes, each
//! matching one byte range or joining others; a state of the DFA is the
//! sorted set of nodes waiting for the next byte, and `increment` makes
//! the state a byte leads to the first time that byte arrives.
//!
//! DIFF:
//!   - Nodes are a tagged union in one list, linked by index (0 is no
//!     node); the C has a type byte, a union and pointers.  States are
//!     found through the C's binary tree, ordered by node index where the
//!     C compares addresses: only the tree's shape can differ.
//!   - yacc is replaced by recursive descent with one token of
//!     lookahead.  It accepts the same patterns, gives "empty pattern"
//!     where yacc's first state reduces the empty program (any first
//!     token that cannot start an expression) and "syntax error"
//!     elsewhere, and starts the literal mode of a leading `*` before
//!     reading the next token, as yacc's mid-rule action does.
//!   - Errors return error.Syntax or error.Internal with the C's message
//!     in `diag`; the C prints and exits.  grep.zig prints them as the C
//!     does.
//!   - The pattern is a slice read through an accessor that gives 0 past
//!     its end.  Fixed from C: after a pattern ending in `\`, the C's
//!     getrec has stepped past the string's 0 and goes on lexing the
//!     memory after it.
//!   - `follow` is a list that grows; the C sizes it before addcase adds
//!     nodes.  The C's bound (`nfollow >= maxfollow`, with maxfollow
//!     counting every node made) is kept.
//!   - Fixed from C: the generation is 32 bits, not 16; see Gen.
//!   - An empty class "[]" is the C's own empty range, the byte 0xff
//!     (as `[z-a]` is); the C reads stale stack there.
//!   - The pairs of a class are sorted with std.sort: their order is
//!     total, so any sort gives the C's result.
//!   - Not ported: the graph listing of the undocumented -1 flag
//!     (reprint), which stock cannot reach since 1 is not a valid flag.

const std = @import("std");
const libc = @import("libc"); // only the runes; the host tests give rune.zig

pub const Cbegin: u32 = libc.Runemax + 1;
const Caselim = 7;

/// The generation that marks the nodes a walk has visited, one more for
/// each new transition.  Fixed from C: the C's is a ushort, so after
/// 65536 transitions a node last visited exactly that many before looks
/// visited and is skipped, and a matching line can be missed
/// (tools/grepwrap.zig makes such an input; stock grep misses its last
/// line).  32 bits would take 2^32 transitions to come round.
pub const Gen = u32;

/// A node.  `next` is the node after it; on the nodes of an unfinished
/// expression's end list, it links the list.
pub const Re = struct {
    gen: Gen = 0,
    next: u32 = 0,
    op: Op,
};

pub const Op = union(enum) {
    /// Talt: alt and next both.
    alt: u32,
    /// Tor: the same, but addcase may turn a tree of them into a case.
    or_: u32,
    /// Tbegin: after a newline or at the start.
    begin,
    /// Tend: before a newline; with no next, the whole pattern matched.
    end,
    /// Tclass: one byte in lo..hi.
    class: struct { lo: u8, hi: u8 },
    /// Tcase: the node for each byte value.
    case: *[256]u32,
};

const Re2 = struct { beg: u32 = 0, end: u32 = 0 };

pub const State = struct {
    match: bool = false,
    re: []u32,
    linkleft: ?*State = null,
    linkright: ?*State = null,
    next: [256]?*State = @splat(null),
};

const Token = union(enum) {
    char: u8,
    class: []const u8,
    lparen,
    rparen,
    alt,
    star,
    plus,
    ques,
    begin,
    end,
    dot,
    bad,
    newline,
    eof,
};

pub const Error = error{ Syntax, Internal, OutOfMemory };

pub const Grep = struct {
    a: std.mem.Allocator,
    re: std.ArrayList(Re) = .empty,
    gen: Gen = 0,
    maxfollow: usize = 0,
    follow: std.ArrayList(u32) = .empty,
    matched: bool = false,
    state0: ?*State = null,
    topre: Re2 = .{},

    /// -i: fold the pattern's upper case letters
    fold: bool = false,
    /// -f's file, read once any -f has been given (the C's flags['f'])
    rein: ?*const fn () ?u8 = null,
    input: []const u8 = "",
    inpos: usize = 0,
    literal: bool = false,
    peekeof: bool = false,
    tok: Token = .eof,
    classbuf: [16 * 1024]u8 = undefined,

    /// For the messages: where the pattern came from, and its line.
    lineno: i32 = 0,
    filename: ?[]const u8 = null,
    pattern: ?[]const u8 = null,
    diag: []const u8 = "",

    pub fn init(a: std.mem.Allocator) Error!Grep {
        var g: Grep = .{ .a = a };
        try g.re.append(a, .{ .op = .begin }); // index 0: no node
        return g;
    }

    fn yyerror(g: *Grep, msg: []const u8) error{Syntax} {
        g.diag = msg;
        return error.Syntax;
    }

    fn internal(g: *Grep, msg: []const u8) error{Internal} {
        g.diag = msg;
        return error.Internal;
    }

    // sub.c

    fn ral(g: *Grep, op: Op) Error!u32 {
        try g.re.append(g.a, .{ .op = op });
        g.maxfollow += 1;
        return @intCast(g.re.items.len - 1);
    }

    fn sal(g: *Grep, re: []const u32) Error!*State {
        const s = try g.a.create(State);
        s.* = .{ .re = try g.a.dupe(u32, re) };
        return s;
    }

    fn countor(g: *Grep, r_: u32) i32 {
        var r = r_;
        var n: i32 = 0;
        while (true) switch (g.re.items[r].op) {
            .or_ => |alt| {
                n += g.countor(alt);
                r = g.re.items[r].next;
            },
            .class => |k| return n + @as(i32, k.hi) - k.lo + 1,
            else => return n,
        };
    }

    fn oralloc(g: *Grep, comptime kind: enum { alt, or_ }, r: u32, b: u32) Error!u32 {
        if (b == 0)
            return r;
        const a = try g.ral(switch (kind) {
            .alt => .{ .alt = r },
            .or_ => .{ .or_ = r },
        });
        g.re.items[a].next = b;
        return a;
    }

    fn case1(g: *Grep, c: u32, r_: u32) Error!void {
        const tab = g.re.items[c].op.case;
        var r = r_;
        while (true) switch (g.re.items[r].op) {
            .or_ => |alt| {
                try g.case1(c, alt);
                r = g.re.items[r].next;
            },
            .class => |k| { // add to character
                const nx = g.re.items[r].next;
                var n: u32 = k.lo;
                while (n <= k.hi) : (n += 1)
                    tab[n] = try g.oralloc(.or_, nx, tab[n]);
                return;
            },
            else => { // add everything unknown to next
                const v = try g.oralloc(.alt, r, g.re.items[c].next);
                g.re.items[c].next = v;
                return;
            },
        };
    }

    fn addcase(g: *Grep, r: u32) Error!u32 {
        std.debug.assert(r != 0);
        if (g.re.items[r].gen == g.gen)
            return r;
        g.re.items[r].gen = g.gen;
        switch (g.re.items[r].op) {
            .case => return g.internal("addcase"),
            .or_ => {
                const n = g.countor(r);
                if (n >= Caselim) {
                    const tab = try g.a.create([256]u32);
                    tab.* = @splat(0);
                    const a = try g.ral(.{ .case = tab });
                    try g.case1(a, r);
                    for (tab) |*t| {
                        if (t.* != 0) {
                            const r1 = t.*;
                            if (g.countor(r1) < n)
                                t.* = try g.addcase(r1);
                        }
                    }
                    return a;
                }
                return r;
            },
            .alt => {
                const nx = try g.addcase(g.re.items[r].next);
                g.re.items[r].next = nx;
                const al = try g.addcase(g.re.items[r].op.alt);
                g.re.items[r].op.alt = al;
                return r;
            },
            .begin, .end, .class => return r,
        }
    }

    /// Parse one pattern (or -f's file) and or it with those before.
    pub fn str2top(g: *Grep, p: []const u8) Error!void {
        const oldtop = g.topre;
        g.input = p;
        g.inpos = 0;
        if (p.len == 0)
            return g.yyerror("empty pattern"); // can't be a file name here
        if (g.rein == null)
            g.pattern = p;
        g.topre = .{};
        try g.yyparse();
        g.gen +%= 1;
        if (g.topre.beg == 0)
            return g.yyerror("syntax");
        if (oldtop.beg != 0)
            g.topre = try g.re2or(oldtop, g.topre);
    }

    fn appendnext(g: *Grep, a_: u32, b: u32) void {
        var a = a_;
        while (g.re.items[a].next != 0)
            a = g.re.items[a].next;
        g.re.items[a].next = b;
    }

    fn patchnext(g: *Grep, a_: u32, b: u32) void {
        var a = a_;
        while (a != 0) {
            const n = g.re.items[a].next;
            g.re.items[a].next = b;
            a = n;
        }
    }

    fn getrec(g: *Grep) u8 {
        var c: u8 = undefined;
        if (g.rein) |f| {
            c = f() orelse 0;
        } else {
            c = if (g.inpos < g.input.len) g.input[g.inpos] else 0;
            g.inpos += 1;
        }
        if (g.fold and c >= 'A' and c <= 'Z')
            c += 'a' - 'A';
        if (c == '\n')
            g.lineno +%= 1;
        return c;
    }

    fn re2cat(g: *Grep, a: Re2, b: Re2) Re2 {
        g.patchnext(a.end, b.beg);
        return .{ .beg = a.beg, .end = b.end };
    }

    fn re2star(g: *Grep, a: Re2) Error!Re2 {
        const c = try g.ral(.{ .alt = a.beg });
        g.patchnext(a.end, c);
        return .{ .beg = c, .end = c };
    }

    fn re2or(g: *Grep, a: Re2, b: Re2) Error!Re2 {
        const c = try g.ral(.{ .or_ = b.beg });
        g.re.items[c].next = a.beg;
        g.appendnext(b.end, a.end);
        return .{ .beg = c, .end = b.end };
    }

    fn re2char(g: *Grep, c0: u32, c1: u32) Error!Re2 {
        const c = try g.ral(.{ .class = .{ .lo = @truncate(c0), .hi = @truncate(c1) } });
        return .{ .beg = c, .end = c };
    }

    // comp.c

    /// The state the start of the input is in.
    pub fn initstate(g: *Grep) Error!void {
        const r = g.topre.beg;
        _ = try g.addcase(r); // the C drops what addcase returns
        g.follow.clearRetainingCapacity();
        g.gen +%= 1;
        try g.fol1(r, Cbegin);
        try g.follow.append(g.a, r);
        std.mem.sort(u32, g.follow.items, {}, std.sort.asc(u32));
        g.state0 = try g.sal(g.follow.items);
    }

    /// incremental compiler: add the branch c to the state s.
    pub fn increment(g: *Grep, s: *State, c: u8) Error!void {
        g.follow.clearRetainingCapacity();
        g.gen +%= 1;
        g.matched = false;
        for (s.re) |r|
            try g.fol1(r, c);
        std.mem.sort(u32, g.follow.items, {}, std.sort.asc(u32));
        const f = g.follow.items;
        var tt: *?*State = &g.state0;
        find: while (tt.*) |t| {
            if (t.re.len > f.len) {
                tt = &t.linkleft;
                continue;
            }
            if (t.re.len < f.len) {
                tt = &t.linkright;
                continue;
            }
            for (t.re, f) |re1, re2| {
                if (re1 > re2) {
                    tt = &t.linkleft;
                    continue :find;
                }
                if (re1 < re2) {
                    tt = &t.linkright;
                    continue :find;
                }
            }
            if (g.matched and !t.match) {
                tt = &t.linkleft;
                continue;
            }
            if (!g.matched and t.match) {
                tt = &t.linkright;
                continue;
            }
            s.next[c] = t;
            return;
        }
        const t = try g.sal(f);
        tt.* = t;
        s.next[c] = t;
        t.match = g.matched;
    }

    fn fol1(g: *Grep, r_: u32, c: u32) Error!void {
        var r = r_;
        while (true) {
            std.debug.assert(r != 0);
            const n = &g.re.items[r]; // fol1 makes no nodes
            if (n.gen == g.gen)
                return;
            if (g.follow.items.len >= g.maxfollow)
                return g.internal("nfollow");
            n.gen = g.gen;
            switch (n.op) {
                .case => |tab| {
                    if (c < 256 and tab[c] != 0)
                        try g.follow.append(g.a, tab[c]);
                    if (n.next == 0)
                        return;
                    r = n.next;
                },
                .alt, .or_ => |alt| {
                    try g.fol1(alt, c);
                    r = n.next;
                },
                .begin => {
                    if (c == '\n' or c == Cbegin)
                        try g.follow.append(g.a, n.next);
                    return;
                },
                .end => {
                    if (c != '\n')
                        return;
                    if (n.next == 0) {
                        g.matched = true;
                        return;
                    }
                    r = n.next;
                },
                .class => |k| {
                    if (c >= k.lo and c <= k.hi)
                        try g.follow.append(g.a, n.next);
                    return;
                },
            }
        }
    }

    const tab1 = [_]u32{ 0x007f, 0x07ff, 0xffff };
    const tab2 = [_]u32{ 0x003f, 0x0fff, 0x3ffff };

    fn rclass(g: *Grep, p0: u32, p1: u32) Error!Re2 {
        if (p0 > p1)
            return g.re2char(0xff, 0xff); // no match

        // bust range into same length character sequences
        for (tab1) |m| {
            if (p0 <= m and p1 > m)
                return g.re2or(try g.rclass(p0, m), try g.rclass(m + 1, p1));
        }

        // bust range into part of a single page or into full pages
        for (tab2) |m| {
            if ((p0 & ~m) != (p1 & ~m)) {
                if ((p0 & m) != 0)
                    return g.re2or(try g.rclass(p0, p0 | m), try g.rclass((p0 | m) + 1, p1));
                if ((p1 & m) != m)
                    return g.re2or(try g.rclass(p0, (p1 & ~m) - 1), try g.rclass(p1 & ~m, p1));
            }
        }

        var xc0: [libc.UTFmax]u8 = undefined;
        var xc1: [libc.UTFmax]u8 = undefined;
        const n = libc.runetochar(&xc0, p0);
        if (libc.runetochar(&xc1, p1) != n)
            return g.internal("length");

        var x = try g.re2char(xc0[0], xc1[0]);
        for (1..n) |i|
            x = g.re2cat(x, try g.re2char(xc0[i], xc1[i]));
        return x;
    }

    /// convert character class into run-pair ranges of matches.  this is
    /// 10646/utf specific and needs to be changed for some other input
    /// character set.  this is the key to a fast regular search of
    /// characters by looking at sequential bytes.
    fn re2class(g: *Grep, s: []const u8) Error!Re2 {
        var pairs: [200 + 2]u32 = undefined;
        var i: usize = 0;
        const Get = struct {
            fn r(str: []const u8, pos: *usize) u32 {
                if (pos.* >= str.len)
                    return 0;
                const d = libc.chartorune(str[pos.*..]);
                pos.* += d.n;
                return d.r;
            }
        };

        var nc = false;
        if (s.len > 0 and s[0] == '^') {
            nc = true;
            i = 1;
        }

        var p: usize = 0;
        pairs[p] = Get.r(s, &i);
        while (true) {
            if (pairs[p] == '\\')
                pairs[p] = Get.r(s, &i);
            if (pairs[p] == 0)
                break;
            pairs[p + 1] = pairs[p];
            p += 2;
            if (p >= pairs.len - 2)
                return g.internal("class too big");
            pairs[p] = Get.r(s, &i);
            if (pairs[p] != '-')
                continue;
            pairs[p] = Get.r(s, &i);
            if (pairs[p] == '\\')
                pairs[p] = Get.r(s, &i);
            if (pairs[p] == 0)
                break;
            pairs[p - 1] = pairs[p];
            pairs[p] = Get.r(s, &i);
        }
        pairs[p] = 0;
        if (p == 0) // "[]"; see the DIFF above
            return g.rclass(1, 0);
        const Pair = [2]u32;
        const pp: []Pair = @as([*]Pair, @ptrCast(&pairs))[0 .. p / 2];
        std.mem.sort(Pair, pp, {}, struct {
            fn lt(_: void, a: Pair, b: Pair) bool {
                return a[0] < b[0] or (a[0] == b[0] and a[1] < b[1]);
            }
        }.lt);

        var q: usize = 0;
        p = 2;
        while (pairs[p] != 0) : (p += 2) {
            if (pairs[p] > pairs[p + 1])
                continue;
            if (pairs[p] > pairs[q + 1] or pairs[p + 1] < pairs[q]) {
                pairs[q + 2] = pairs[p];
                pairs[q + 3] = pairs[p + 1];
                q += 2;
                continue;
            }
            if (pairs[p] < pairs[q])
                pairs[q] = pairs[p];
            if (pairs[p + 1] > pairs[q + 1])
                pairs[q + 1] = pairs[p + 1];
        }
        pairs[q + 2] = 0;

        p = 0;
        var x: Re2 = undefined;
        if (nc) {
            x = try g.rclass(0, pairs[p] -% 1);
            var ov = pairs[p + 1] +% 1;
            p += 2;
            while (pairs[p] != 0) : (p += 2) {
                x = try g.re2or(x, try g.rclass(ov, pairs[p] -% 1));
                ov = pairs[p + 1] +% 1;
            }
            x = try g.re2or(x, try g.rclass(ov, libc.Runemax));
        } else {
            x = try g.rclass(pairs[p], pairs[p + 1]);
            p += 2;
            while (pairs[p] != 0) : (p += 2)
                x = try g.re2or(x, try g.rclass(pairs[p], pairs[p + 1]));
        }
        return x;
    }

    // grep.y

    fn lex(g: *Grep) Error!Token {
        if (g.peekeof) {
            g.peekeof = false;
            return .eof;
        }
        const c = g.getrec();
        if (g.literal) {
            if (c != 0 and c != '\n')
                return .{ .char = c };
            g.literal = false;
        }
        return switch (c) {
            '\\' => blk: {
                const d = g.getrec();
                break :blk if (d == '\n') .newline else .{ .char = d };
            },
            '[' => g.getclass(),
            '(' => .lparen,
            ')' => .rparen,
            '|' => .alt,
            '*' => .star,
            '+' => .plus,
            '?' => .ques,
            '^' => .begin,
            '$' => .end,
            '.' => .dot,
            0 => blk: {
                g.peekeof = true;
                break :blk .newline;
            },
            '\n' => .newline,
            else => .{ .char = c },
        };
    }

    fn getclass(g: *Grep) Error!Token {
        const buf = &g.classbuf;
        const eq = buf.len - 5;
        var q: usize = 0;
        var c = g.getrec();
        if (c == '^') {
            buf[0..4].* = "^\n-\n".*;
            q = 4;
            c = g.getrec();
        }
        while (true) {
            if (q >= eq)
                return g.internal("class too long");
            if (c == ']' or c == 0)
                break;
            if (c == '\\') {
                buf[q] = c;
                q += 1;
                c = g.getrec();
                if (c == 0)
                    break;
            }
            buf[q] = c;
            q += 1;
            c = g.getrec();
        }
        if (c == 0)
            return .bad;
        return .{ .class = buf[0..q] };
    }

    fn advance(g: *Grep) Error!void {
        g.tok = try g.lex();
    }

    /// Can the token start expr0, or expr3?
    fn first0(t: Token) bool {
        return t == .star or first3(t);
    }

    fn first3(t: Token) bool {
        return switch (t) {
            .char, .begin, .end, .dot, .class, .lparen => true,
            else => false,
        };
    }

    // prog: /* empty */ | expr newlines
    // expr: expr0 | expr newlines expr0
    fn yyparse(g: *Grep) Error!void {
        try g.advance();
        if (!first0(g.tok))
            return g.yyerror("empty pattern");
        var e = try g.expr0();
        while (true) {
            if (g.tok != .newline)
                return g.yyerror("syntax error");
            while (g.tok == .newline)
                try g.advance();
            if (g.tok == .eof)
                break;
            if (!first0(g.tok))
                return g.yyerror("syntax error");
            e = try g.re2or(e, try g.expr0());
        }

        const t = try g.ral(.end);
        var x: Re2 = .{ .beg = t, .end = t };
        x = g.re2cat(try g.re2star(try g.re2or(try g.re2char(0x00, '\n' - 1), try g.re2char('\n' + 1, 0xff))), x);
        x = g.re2cat(e, x);
        x = g.re2cat(try g.re2star(try g.re2char(0x00, 0xff)), x);
        g.topre = x;
    }

    // expr0: expr1 | LSTAR { literal = 1; } expr1
    fn expr0(g: *Grep) Error!Re2 {
        if (g.tok == .star) {
            g.literal = true;
            try g.advance();
        }
        return g.expr1();
    }

    // expr1: expr2 | expr1 LALT expr2
    fn expr1(g: *Grep) Error!Re2 {
        var e = try g.expr2();
        while (g.tok == .alt) {
            try g.advance();
            e = try g.re2or(e, try g.expr2());
        }
        return e;
    }

    // expr2: expr3 | expr2 expr3
    fn expr2(g: *Grep) Error!Re2 {
        var e = try g.expr3();
        while (first3(g.tok))
            e = g.re2cat(e, try g.expr3());
        return e;
    }

    // expr3: expr4 | expr3 LSTAR | expr3 LPLUS | expr3 LQUES
    fn expr3(g: *Grep) Error!Re2 {
        var e = try g.expr4();
        while (true) {
            switch (g.tok) {
                .star => e = try g.re2star(e),
                .plus => {
                    const t = try g.ral(.{ .alt = e.beg });
                    g.patchnext(e.end, t);
                    e.end = t;
                },
                .ques => {
                    const t = try g.ral(.{ .alt = e.beg });
                    g.appendnext(e.end, t);
                    e.beg = t;
                },
                else => return e,
            }
            try g.advance();
        }
    }

    // expr4: LCHAR | LBEGIN | LEND | LDOT | LCLASS | LLPAREN expr1 LRPAREN
    fn expr4(g: *Grep) Error!Re2 {
        const x: Re2 = switch (g.tok) {
            .char => |c| try g.re2char(c, c),
            .begin => blk: {
                const t = try g.ral(.begin);
                break :blk .{ .beg = t, .end = t };
            },
            .end => blk: {
                const t = try g.ral(.end);
                break :blk .{ .beg = t, .end = t };
            },
            .dot => try g.re2class("^\n"),
            .class => |s| try g.re2class(s), // before the next token reuses the buffer
            .lparen => {
                try g.advance();
                const e = try g.expr1();
                if (g.tok != .rparen)
                    return g.yyerror("syntax error");
                try g.advance();
                return e;
            },
            else => return g.yyerror("syntax error"),
        };
        try g.advance();
        return x;
    }
};

// Tests, on the host.

const testing = std.testing;

const T = struct {
    arena: *std.heap.ArenaAllocator,
    g: *Grep,

    fn init(patterns: []const []const u8, fold: bool) !T {
        const arena = try std.heap.page_allocator.create(std.heap.ArenaAllocator);
        arena.* = .init(std.heap.page_allocator);
        var t: T = .{ .arena = arena, .g = undefined };
        errdefer t.deinit();
        const a = t.arena.allocator();
        t.g = try a.create(Grep);
        t.g.* = try Grep.init(a);
        t.g.fold = fold;
        for (patterns) |p|
            try t.g.str2top(p);
        try t.g.initstate();
        return t;
    }

    fn deinit(t: *T) void {
        t.arena.deinit();
        std.heap.page_allocator.destroy(t.arena);
    }

    /// Run text through the machine, as main.c's loop does, and give
    /// whether each line matched.
    fn lines(t: *T, text: []const u8, out: []bool) !usize {
        var s = t.g.state0.?;
        var n: usize = 0;
        for (text) |c_| {
            var c = c_;
            if (t.g.fold and c >= 'A' and c <= 'Z')
                c += 'a' - 'A';
            while (s.next[c] == null)
                try t.g.increment(s, c);
            s = s.next[c].?;
            if (c == '\n') {
                out[n] = s.match;
                n += 1;
            }
        }
        return n;
    }

    fn match(t: *T, line: []const u8) !bool {
        var buf: [256]u8 = undefined;
        @memcpy(buf[0..line.len], line);
        buf[line.len] = '\n';
        var out: [1]bool = undefined;
        // a fresh run each time: the C's state carries across lines
        const saved = t.g.state0.?;
        _ = try t.lines(buf[0 .. line.len + 1], &out);
        t.g.state0 = saved;
        return out[0];
    }
};

fn expectErr(pattern: []const u8, e: Error, msg: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const g = try a.create(Grep);
    g.* = try Grep.init(a);
    try testing.expectError(e, g.str2top(pattern));
    try testing.expectEqualStrings(msg, g.diag);
}

test "grammar" {
    for ([_][]const u8{ "a", "a**", "a+?", "**", "*a(b", "a\n\nb", "a\n", "(a|b)c", "^$", "a^b$c", "[a-z]", "[^\n]", "a\\", ".", "x\n*y\\" }) |p| {
        var t = try T.init(&.{p}, false);
        t.deinit();
    }
    try expectErr("", error.Syntax, "empty pattern");
    for ([_][]const u8{ ")", "|a", "+a", "?", "\n", "[abc", "\na" }) |p|
        try expectErr(p, error.Syntax, "empty pattern");
    for ([_][]const u8{ "a)", "(a", "a|", "a||b", "*", "a(*b)", "a|*b", "()", "a[bc", "a\n)", "a\n|" }) |p|
        try expectErr(p, error.Syntax, "syntax error");

    var big: [512]u8 = undefined;
    var n: usize = 0;
    big[n] = '[';
    n += 1;
    for (0..100) |i|
        n += libc.runetochar(big[n..], @intCast(0x100 + 2 * i));
    big[n] = ']';
    try expectErr(big[0 .. n + 1], error.Internal, "class too big");
    // 99 ranges are not too big
    n = 1;
    for (0..99) |i|
        n += libc.runetochar(big[n..], @intCast(0x100 + 2 * i));
    big[n] = ']';
    var t = try T.init(&.{big[0 .. n + 1]}, false);
    t.deinit();

    const long = try testing.allocator.alloc(u8, 16 * 1024);
    defer testing.allocator.free(long);
    long[0] = '[';
    @memset(long[1..], 'a');
    try expectErr(long, error.Internal, "class too long");
}

test "simple matches" {
    const cases = [_]struct { p: []const u8, yes: []const []const u8, no: []const []const u8 }{
        .{ .p = "abc", .yes = &.{ "abc", "xabcx" }, .no = &.{ "ab", "" } },
        .{ .p = "^ab", .yes = &.{"abx"}, .no = &.{"xab"} },
        .{ .p = "ab$", .yes = &.{"xab"}, .no = &.{"abx"} },
        .{ .p = "^$", .yes = &.{""}, .no = &.{"a"} },
        .{ .p = "a.c", .yes = &.{ "abc", "aβc" }, .no = &.{ "ac", "a\xffc" } },
        .{ .p = "*a.c", .yes = &.{"a.c"}, .no = &.{"abc"} },
        .{ .p = "a+b", .yes = &.{ "ab", "aab" }, .no = &.{"b"} },
        .{ .p = "^a?b$", .yes = &.{ "ab", "b" }, .no = &.{"aab"} },
        .{ .p = "x\ny", .yes = &.{ "x", "y" }, .no = &.{"z"} },
        .{ .p = "a|b|c|d|e|f|g|h", .yes = &.{ "h", "zzd" }, .no = &.{"z"} },
        .{ .p = "[α-ω]", .yes = &.{"β"}, .no = &.{ "a", "Ω" } },
        .{ .p = "^[^a]$", .yes = &.{ "b", "β", "😀" }, .no = &.{ "a", "\xff", "\x80" } },
        // the C's "no match" range is a byte 0xff, which input can hold
        .{ .p = "^[^ab]$", .yes = &.{ "\xff", "c" }, .no = &.{ "a", "\x80" } },
        .{ .p = "^[]$", .yes = &.{"\xff"}, .no = &.{ "", "a" } },
    };
    for (cases) |c| {
        var t = try T.init(&.{c.p}, false);
        defer t.deinit();
        for (c.yes) |l|
            testing.expect(try t.match(l)) catch |e| {
                std.debug.print("{s} should match {s}\n", .{ c.p, l });
                return e;
            };
        for (c.no) |l|
            testing.expect(!try t.match(l)) catch |e| {
                std.debug.print("{s} should not match {s}\n", .{ c.p, l });
                return e;
            };
    }
    var t = try T.init(&.{"[A-Z]x"}, true);
    defer t.deinit();
    try testing.expect(try t.match("QX"));
    try testing.expect(try t.match("qx"));
}

test "classes as byte ranges" {
    var prng = std.Random.DefaultPrng.init(1);
    const rnd = prng.random();
    const edges = [_]u32{ 1, 0x7f, 0x80, 0x7ff, 0x800, 0xffff, 0x10000, 0x10ffff, 0xd800, 0xdfff, 0x3f, 0x40, 0xfff, 0x1000, 0x3ffff, 0x40000 };
    const pick = struct {
        fn f(r: std.Random, e: []const u32) u32 {
            return switch (r.uintLessThan(u32, 4)) {
                0 => e[r.uintLessThan(usize, e.len)],
                1 => r.intRangeAtMost(u32, 1, 0x7ff),
                2 => r.intRangeAtMost(u32, 1, 0xffff),
                else => r.intRangeAtMost(u32, 1, 0x10ffff),
            };
        }
    }.f;
    for (0..300) |_| {
        var lo = pick(rnd, &edges);
        var hi = pick(rnd, &edges);
        if (lo > hi) std.mem.swap(u32, &lo, &hi);
        for ([_]bool{ false, true }) |neg| {
            var pat: [32]u8 = undefined;
            var n: usize = 0;
            for ([_][]const u8{ "^[", if (neg) "^" else "", "\\" }) |s| {
                @memcpy(pat[n..][0..s.len], s);
                n += s.len;
            }
            n += libc.runetochar(pat[n..], lo);
            @memcpy(pat[n..][0..2], "-\\");
            n += 2;
            n += libc.runetochar(pat[n..], hi);
            @memcpy(pat[n..][0..2], "]$");
            n += 2;
            var t = try T.init(&.{pat[0..n]}, false);
            defer t.deinit();
            for (0..40) |k| {
                var r = if (k < edges.len) edges[k] else pick(rnd, &edges);
                if (k % 3 == 0) r = std.math.clamp(lo +% @as(u32, @intCast(k)) -% 20, 1, 0x10ffff);
                if (r == '\n') continue;
                var line: [4]u8 = undefined;
                const ln = libc.runetochar(&line, r);
                const want = (r >= lo and r <= hi) != neg;
                testing.expectEqual(want, try t.match(line[0..ln])) catch |e| {
                    std.debug.print("[{s}{x}-{x}] rune {x}\n", .{ if (neg) "^" else "", lo, hi, r });
                    return e;
                };
            }
        }
    }
}

/// A backtracking matcher for the generated patterns, as the oracle.
const Ref = struct {
    const Node = union(enum) {
        lit: u8,
        any,
        set: struct { bits: u8, neg: bool }, // bits over 'a'..'c'
        cat: [2]u16,
        alt: [2]u16,
        star: u16,
        plus: u16,
        ques: u16,
        bol,
        eol,
    };
    nodes: [512]Node = undefined,
    n: u16 = 0,
    text: [256]u8 = undefined,
    tn: usize = 0,
    rnd: std.Random,

    fn add(r: *Ref, x: Node) u16 {
        r.nodes[r.n] = x;
        r.n += 1;
        return r.n - 1;
    }
    fn put(r: *Ref, s: []const u8) void {
        @memcpy(r.text[r.tn..][0..s.len], s);
        r.tn += s.len;
    }

    fn atom(r: *Ref, depth: u32) u16 {
        switch (r.rnd.uintLessThan(u32, if (depth > 0) 6 else 5)) {
            0, 1 => {
                const c = "abc"[r.rnd.uintLessThan(usize, 3)];
                r.put(&.{c});
                return r.add(.{ .lit = c });
            },
            2 => {
                r.put(".");
                return r.add(.any);
            },
            3, 4 => {
                const neg = r.rnd.boolean();
                r.put(if (neg) "[^" else "[");
                var bits: u8 = 0;
                if (r.rnd.boolean()) {
                    r.put("a-b");
                    bits = 3;
                } else for (0..1 + r.rnd.uintLessThan(usize, 2)) |_| {
                    const k = r.rnd.uintLessThan(u3, 3);
                    r.put(&.{'a' + @as(u8, k)});
                    bits |= @as(u8, 1) << k;
                }
                r.put("]");
                return r.add(.{ .set = .{ .bits = bits, .neg = neg } });
            },
            else => {
                r.put("(");
                const e = r.alts(depth - 1, false);
                r.put(")");
                return e;
            },
        }
    }

    fn post(r: *Ref, depth: u32) u16 {
        var e = r.atom(depth);
        switch (r.rnd.uintLessThan(u32, 6)) {
            0 => {
                r.put("*");
                e = r.add(.{ .star = e });
            },
            1 => {
                r.put("+");
                e = r.add(.{ .plus = e });
            },
            2 => {
                r.put("?");
                e = r.add(.{ .ques = e });
            },
            else => {},
        }
        return e;
    }

    fn cat(r: *Ref, depth: u32, top: bool) u16 {
        var e: u16 = undefined;
        const bol = top and r.rnd.uintLessThan(u32, 4) == 0;
        if (bol)
            r.put("^");
        e = r.post(depth);
        for (0..r.rnd.uintLessThan(usize, 3)) |_|
            e = r.add(.{ .cat = .{ e, r.post(depth) } });
        if (bol)
            e = r.add(.{ .cat = .{ r.add(.bol), e } });
        if (top and r.rnd.uintLessThan(u32, 4) == 0) {
            r.put("$");
            e = r.add(.{ .cat = .{ e, r.add(.eol) } });
        }
        return e;
    }

    fn alts(r: *Ref, depth: u32, top: bool) u16 {
        var e = r.cat(depth, top);
        for (0..r.rnd.uintLessThan(usize, 3)) |_| {
            r.put(if (top and r.rnd.boolean()) "\n" else "|");
            e = r.add(.{ .alt = .{ e, r.cat(depth, top) } });
        }
        return e;
    }

    /// The positions an expression can end at, from the positions in s.
    fn m(r: *Ref, x: u16, s: u32, line: []const u8) u32 {
        var out: u32 = 0;
        switch (r.nodes[x]) {
            .lit, .any, .set => for (0..line.len) |p| {
                if (s & (@as(u32, 1) << @intCast(p)) == 0) continue;
                const c = line[p];
                const ok = switch (r.nodes[x]) {
                    .lit => |l| c == l,
                    .any => c != '\n',
                    .set => |k| (c >= 'a' and c <= 'c' and k.bits & (@as(u8, 1) << @intCast(c - 'a')) != 0) != k.neg and c != '\n',
                    else => unreachable,
                };
                if (ok) out |= @as(u32, 1) << @intCast(p + 1);
            },
            .cat => |c| out = r.m(c[1], r.m(c[0], s, line), line),
            .alt => |c| out = r.m(c[0], s, line) | r.m(c[1], s, line),
            .star, .plus => |a| {
                out = if (r.nodes[x] == .star) s else r.m(a, s, line);
                while (true) {
                    const o2 = out | r.m(a, out, line);
                    if (o2 == out) break;
                    out = o2;
                }
            },
            .ques => |a| out = s | r.m(a, s, line),
            .bol => out = s & 1,
            .eol => out = s & (@as(u32, 1) << @intCast(line.len)),
        }
        return out;
    }
};

test "the machine against a backtracking matcher" {
    var prng = std.Random.DefaultPrng.init(7);
    const rnd = prng.random();
    for (0..3000) |_| {
        var r: Ref = .{ .rnd = rnd };
        const top = r.alts(2, true);
        const pat = r.text[0..r.tn];
        var t = try T.init(&.{pat}, false);
        defer t.deinit();
        // one run over many lines, as grep runs a file
        var text: [4096]u8 = undefined;
        var tn: usize = 0;
        var want: [256]bool = undefined;
        var nl: usize = 0;
        while (nl < 200) : (nl += 1) {
            const len = rnd.uintLessThan(usize, 11);
            const line = text[tn..][0..len];
            for (line) |*c| c.* = "abcx"[rnd.uintLessThan(usize, 4)];
            want[nl] = r.m(top, (@as(u32, 1) << @intCast(len + 1)) - 1, line) != 0;
            tn += len;
            text[tn] = '\n';
            tn += 1;
        }
        var got: [256]bool = undefined;
        const n = try t.lines(text[0..tn], &got);
        try testing.expectEqual(nl, n);
        var start: usize = 0;
        for (0..nl) |i| {
            const end = std.mem.indexOfScalarPos(u8, text[0..tn], start, '\n').?;
            testing.expectEqual(want[i], got[i]) catch |e| {
                std.debug.print("pattern {f} line {f}\n", .{ std.ascii.hexEscape(pat, .lower), std.ascii.hexEscape(text[start..end], .lower) });
                return e;
            };
            start = end + 1;
        }
    }
}
