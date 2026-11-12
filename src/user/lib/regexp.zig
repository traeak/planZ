//! Regular expressions.
//! from libregexp: regcomp.c, regexec.c, rregexec.c, regsub.c,
//! rregsub.c, regprint.c and regimpl.h, regexp.h
//!
//! The syntax and the matching are the C's: a pattern is compiled into
//! a list of instructions, and the matcher runs every thread of it in
//! step over the subject, one rune at a time (a Pike VM).
//!
//! DIFF:
//!   - Strings are slices.  A 0 byte (or rune) in a pattern or subject
//!     ends it there, as the C's terminator does, so results stay the
//!     same as stock on binary input.
//!   - Resub holds offsets into the subject, not pointers.  The matcher
//!     never writes into the subject: the C bounds a search by putting a
//!     0 at sem[0].ep and restoring the byte; here the offset is the
//!     bound, with the C's rule that `$` matches only at the real end.
//!   - regexec and rregexec are one function over u8 or Rune subjects;
//!     regsub and rregsub likewise.  regsub takes the subject, since
//!     Resub holds offsets, and returns the part of dst it wrote.
//!   - Tokens, parse nodes and instructions are tagged unions, and
//!     jumps are indices; the C has op codes, unions and pointers.  The
//!     matcher's gotos are a labeled switch.  A compile error returns
//!     error.Regexp with the C's message in a Diag, where the C calls
//!     regerror and longjmps out; libc.regerror does what the C's
//!     default regerror does.
//!   - The compiler fills buffers its caller sizes, so the same code
//!     runs at compile time: Static(pattern) is a pattern compiled into
//!     read-only data, and a bad one fails the build.
//!   - The class pairs are sorted with std.sort, not qsort: the order
//!     is total, so any sort gives the C's result.
//!   - An empty class "[]" has no ranges and matches nothing; the C
//!     reads stale memory there.
//!   - The listing (regprint.c) gives instruction indices where the C
//!     prints addresses.

const std = @import("std");
const fmt = @import("fmt");
const rune = @import("rune.zig");

const Rune = rune.Rune;
const Runemax = rune.Runemax;
const Allocator = std.mem.Allocator;

pub const NSUBEXPM = 32;

/// A subexpression's place in the subject: offsets, null when unset.
pub const Resub = struct {
    sp: ?usize = null,
    ep: ?usize = null,
};

/// One instruction.  Jumps are indices into the program.
pub const Inst = union(enum) {
    any,
    bol,
    /// A class is a chain of these, in descending order: a rune below
    /// lo fails, one above hi tries the next, one in range continues at
    /// `next` (past the chain).
    class: struct { lo: u32, hi: u32, next: u32 },
    eol,
    jmp: u32,
    notnl,
    rune: Rune,
    save: u32,
    split: struct { a: u32, b: u32 },
    unsave: u32,
};

pub const Error = error{ Regexp, OutOfMemory };

/// Where regcomp leaves its message on error.
pub const Diag = struct {
    buf: [128]u8 = undefined,
    msg: []const u8 = "",

    fn set(d: *Diag, comptime format: []const u8, args: anytype) void {
        // the C's snprint into char error[128]
        d.msg = fmt.snprint(d.buf[0 .. d.buf.len - 1], format, args);
    }
};

// ---------------------------------------------------------------- lexer

const Rep = enum { star, plus, ques };

const Token = union(enum) {
    any,
    bol,
    class: bool, // negated
    end,
    eol,
    lpar,
    alt,
    rep: Rep,
    rpar,
    rune: Rune,
};

/// What a node costs in instructions (the C's instrcnt).
fn instrcnt(n: Node) u32 {
    return switch (n) {
        .any => 2,
        .bol => 1,
        .cat => 0,
        .class => 1,
        .eol => 1,
        .notnl => 1,
        .alt => 2,
        .plus => 1,
        .ques => 1,
        .rune => 1,
        .star => 2,
        .sub => 2,
    };
}

const Node = union(enum) {
    any,
    bol,
    cat: struct { left: u32, right: u32 },
    /// left is the rest of the chain
    class: struct { lo: u32, hi: u32, nclass: u32, left: ?u32 },
    eol,
    notnl,
    alt: struct { left: u32, right: u32 },
    plus: u32,
    ques: u32,
    rune: Rune,
    star: u32,
    sub: ?u32,
};

const Parser = struct {
    // Parse
    nodes: []Node,
    next: u32 = 0,
    instrs: u32 = 0,
    diag: ?*Diag,
    // Lex
    lit: bool,
    exp: []const u8, // the C's orig
    pos: usize = 0, // the C's rawexp
    rune: Rune = 0,
    peek: bool = false,
    peeklex: Token = .end,
    done: bool = false,
    literal: bool = false,
    cpairs: [400 + 2]u32 = undefined,
    npairs: usize = 0,

    fn fail(p: *Parser, comptime format: []const u8, args: anytype) error{Regexp} {
        if (p.diag) |d|
            d.set(format, args);
        return error.Regexp;
    }

    fn node(p: *Parser, n: Node) u32 {
        p.instrs += instrcnt(n);
        const i = p.next;
        p.nodes[i] = n;
        p.next += 1;
        return i;
    }

    fn getnextr(p: *Parser) void {
        if (p.lit)
            return p.getnextrlit();
        p.literal = false;
        if (p.done) {
            p.rune = 0;
            return;
        }
        const d = rune.chartorune(p.exp[p.pos..]);
        p.rune = d.r;
        p.pos += d.n;
        if (p.pos >= p.exp.len)
            p.done = true;
        if (p.rune == '\\')
            p.getnextrlit();
    }

    fn getnextrlit(p: *Parser) void {
        p.literal = true;
        if (p.done) {
            p.literal = false;
            p.rune = 0;
            return;
        }
        const d = rune.chartorune(p.exp[p.pos..]);
        p.rune = d.r;
        p.pos += d.n;
        if (p.pos >= p.exp.len)
            p.done = true;
    }

    fn lex(p: *Parser) error{Regexp}!Token {
        if (p.peek) {
            p.peek = false;
            return p.peeklex;
        }
        p.getnextr();
        p.peeklex = if (p.literal) .{ .rune = p.rune } else switch (p.rune) {
            0 => .end,
            '*' => .{ .rep = .star },
            '?' => .{ .rep = .ques },
            '+' => .{ .rep = .plus },
            '|' => .alt,
            '.' => .any,
            '(' => .lpar,
            ')' => .rpar,
            '^' => .bol,
            '$' => .eol,
            '[' => .{ .class = try p.getclass() },
            else => .{ .rune = p.rune },
        };
        return p.peeklex;
    }

    /// Read a class into cpairs, merged into descending ranges; true if
    /// it is negated.
    fn getclass(p: *Parser) error{Regexp}!bool {
        var nc = false;
        p.getnextrlit();
        if (p.rune == '^') {
            nc = true;
            p.getnextrlit();
        }
        const cp = &p.cpairs;
        var i: usize = 0;
        while (true) {
            cp[i] = p.rune;
            if (p.rune == ']')
                break;
            if (p.rune == '-')
                return p.fail("Malformed class", .{});
            if (p.rune == '\\') {
                p.getnextrlit();
                cp[i] = p.rune;
            }
            if (p.rune == 0)
                return p.fail("No closing ] for class", .{});
            p.getnextrlit();
            if (p.rune == '-') {
                p.getnextrlit();
                if (p.rune == ']')
                    return p.fail("Malformed class", .{});
                if (p.rune == '-')
                    return p.fail("Malformed class", .{});
                if (p.rune == '\\')
                    p.getnextrlit();
                cp[i + 1] = p.rune;
                if (cp[i] > cp[i + 1])
                    std.mem.swap(u32, &cp[i], &cp[i + 1]);
                p.getnextrlit();
            } else cp[i + 1] = cp[i];
            if (i >= cp.len - 2)
                return p.fail("Class too big\n", .{});
            i += 2;
        }
        const n = i / 2;
        const prs: [][2]u32 = @as([*][2]u32, @ptrCast(cp))[0..n];
        std.sort.insertion([2]u32, prs, {}, struct {
            // descending, as the C's pcmp
            fn lt(_: void, a: [2]u32, b: [2]u32) bool {
                if (a[0] != b[0]) return a[0] > b[0];
                return a[1] > b[1];
            }
        }.lt);
        var q: usize = 0;
        var k: usize = 1;
        while (k < n) : (k += 1) {
            if (prs[k][1] < prs[q][0] -% 1) {
                q += 1;
                prs[q] = prs[k];
                continue;
            }
            prs[q][0] = prs[k][0];
            if (prs[k][1] > prs[q][1])
                prs[q][1] = prs[k][1];
        }
        p.npairs = if (n == 0) 0 else q + 1;
        return nc;
    }

    fn pairs(p: *Parser) []const [2]u32 {
        return @as([*]const [2]u32, @ptrCast(&p.cpairs))[0..p.npairs];
    }

    // classes are in descending order see pcmp
    fn buildclassn(p: *Parser) u32 {
        const ps = p.pairs();
        var i: u32 = 0;
        var n = p.node(.{ .class = .{
            .lo = if (ps.len > 0) ps[0][1] + 1 else 1,
            .hi = Runemax,
            .nclass = i,
            .left = null,
        } });
        i += 1;
        for (ps, 0..) |pr, k| {
            n = p.node(.{ .class = .{
                // the next (lower) range's top, past the last range 0
                .lo = if (k + 1 < ps.len) ps[k + 1][1] + 1 else 0,
                .hi = pr[0] -% 1,
                .nclass = i,
                .left = n,
            } });
            i += 1;
        }
        p.nodes[n].class.lo = 0;
        const nl = p.node(.notnl);
        return p.node(.{ .cat = .{ .left = nl, .right = n } });
    }

    fn buildclass(p: *Parser) u32 {
        var i: u32 = 0;
        var n = p.node(.{ .class = .{ .lo = Runemax + 1, .hi = 0, .nclass = i, .left = null } });
        i += 1;
        for (p.pairs()) |pr| {
            n = p.node(.{ .class = .{ .lo = pr[0], .hi = pr[1], .nclass = i, .left = n } });
            i += 1;
        }
        return n;
    }

    fn e3(p: *Parser) error{Regexp}!u32 {
        const t = try p.lex();
        switch (t) {
            .any => return p.node(.any),
            .bol => return p.node(.bol),
            .eol => return p.node(.eol),
            .rune => |r| return p.node(.{ .rune = r }),
            .class => |nc| return if (nc) p.buildclassn() else p.buildclass(),
            .lpar => {
                const n = try p.e0();
                const s = p.node(.{ .sub = n });
                if (try p.lex() != .rpar)
                    return p.fail("regexp %s: no matching parenthesis", .{p.exp});
                return s;
            },
            else => {
                if (p.rune != 0)
                    return p.fail("regexp %s: syntax error: %C", .{ p.exp, p.rune });
                return p.fail("regexp %s: parsing error", .{p.exp});
            },
        }
    }

    fn e2(p: *Parser) error{Regexp}!u32 {
        var n = try p.e3();
        while (true) {
            const t = try p.lex();
            if (t != .rep)
                break;
            n = switch (t.rep) {
                .star => p.node(.{ .star = n }),
                .plus => p.node(.{ .plus = n }),
                .ques => p.node(.{ .ques = n }),
            };
        }
        p.peek = true;
        return n;
    }

    /// Turn a left-leaning chain of cats into a right-leaning one.
    fn invert(p: *Parser, n_: u32) u32 {
        var n = n_;
        if (p.nodes[n] != .cat)
            return n;
        while (p.nodes[p.nodes[n].cat.left] == .cat) {
            const n1 = p.nodes[n].cat.left;
            p.nodes[n].cat.left = p.nodes[n1].cat.right;
            p.nodes[n1].cat.right = n;
            n = n1;
        }
        return n;
    }

    fn e1(p: *Parser) error{Regexp}!u32 {
        var n = try p.e2();
        while (true) {
            const t = try p.lex();
            if (t == .end or t == .alt or t == .rpar)
                break;
            p.peek = true;
            const r = try p.e2();
            n = p.node(.{ .cat = .{ .left = n, .right = r } });
        }
        p.peek = true;
        return p.invert(n);
    }

    fn e0(p: *Parser) error{Regexp}!u32 {
        var n = try p.e1();
        while (true) {
            if (try p.lex() != .alt)
                break;
            const r = try p.e1();
            n = p.node(.{ .alt = .{ .left = n, .right = r } });
        }
        p.peek = true;
        return n;
    }
};

// ------------------------------------------------------------- compiler

/// The pattern up to its first 0 byte.
fn upto0(s: []const u8) []const u8 {
    return s[0 .. std.mem.findScalar(u8, s, 0) orelse s.len];
}

pub const Options = struct {
    /// regcompnl: `.` matches newline too
    nl: bool = false,
    /// regcomplit: every character is literal
    lit: bool = false,
};

fn nodecount(pattern: []const u8) usize {
    return rune.utflen(upto0(pattern)) * 2 + 1;
}

/// Parse pattern into nodes (nodecount long); the root and the number
/// of instructions.
fn parse(pattern_: []const u8, opt: Options, nodes: []Node, diag: ?*Diag) error{Regexp}!struct { root: u32, instrs: u32 } {
    const pattern = upto0(pattern_);
    var p: Parser = .{ .nodes = nodes, .diag = diag, .lit = opt.lit, .exp = pattern };
    p.done = pattern.len == 0;
    const tree: ?u32 = if (pattern.len != 0) try p.e0() else null;
    const root = p.node(.{ .sub = tree });
    return .{ .root = root, .instrs = p.instrs };
}

fn compile1(nodes: []const Node, renode_: ?u32, insts: []Inst, at_: u32, sub: *u32, nl: bool) u32 {
    var renode = renode_;
    var at = at_;
    while (true) {
        const rn = renode orelse return at;
        switch (nodes[rn]) {
            .class => |c| {
                insts[at] = .{ .class = .{ .lo = c.lo, .hi = c.hi, .next = at + 1 + c.nclass } };
                renode = c.left;
                at += 1;
            },
            .cat => |c| {
                at = compile1(nodes, c.left, insts, at, sub, nl);
                renode = c.right;
            },
            .alt => |c| {
                const a = at + 1;
                const i = compile1(nodes, c.left, insts, a, sub, nl);
                const b = i + 1;
                const e = compile1(nodes, c.right, insts, b, sub, nl);
                insts[at] = .{ .split = .{ .a = a, .b = b } };
                insts[i] = .{ .jmp = e };
                return e;
            },
            .star => |l| {
                const a = at + 1;
                const i = compile1(nodes, l, insts, a, sub, nl);
                insts[at] = .{ .split = .{ .a = a, .b = i + 1 } };
                insts[i] = .{ .jmp = at };
                return i + 1;
            },
            .plus => |l| {
                const i = at;
                at = compile1(nodes, l, insts, at, sub, nl);
                insts[at] = .{ .split = .{ .a = i, .b = at + 1 } };
                return at + 1;
            },
            .ques => |l| {
                const a = at + 1;
                const b = compile1(nodes, l, insts, a, sub, nl);
                insts[at] = .{ .split = .{ .a = a, .b = b } };
                return b;
            },
            .sub => |l| {
                const s = sub.*;
                sub.* += 1;
                insts[at] = .{ .save = s };
                at = compile1(nodes, l, insts, at + 1, sub, nl);
                insts[at] = .{ .unsave = s };
                return at + 1;
            },
            .any => {
                if (!nl) {
                    insts[at] = .notnl;
                    at += 1;
                }
                insts[at] = .any;
                return at + 1;
            },
            .rune => |r| {
                insts[at] = .{ .rune = r };
                return at + 1;
            },
            .notnl => {
                insts[at] = .notnl;
                return at + 1;
            },
            .eol => {
                insts[at] = .eol;
                return at + 1;
            },
            .bol => {
                insts[at] = .bol;
                return at + 1;
            },
        }
    }
}

fn compile(nodes: []const Node, root: u32, insts: []Inst, nl: bool) void {
    // instructions the tree does not use (a `.` with nl) stay .any
    @memset(insts, .any);
    var sub: u32 = 0;
    const end = compile1(nodes, root, insts, 0, &sub, nl);
    std.debug.assert(end <= insts.len);
}

// -------------------------------------------------------------- matcher

const Rethread = struct {
    i: u32 = 0,
    sem: [NSUBEXPM]Resub = @splat(.{}),
    next: ?u32 = null,
    gen: u32 = 0,
};

/// Where a list's tail pointer points: the list's head or a thread's
/// next field (the C's Rethread **tail).
const Tail = union(enum) { head, thread: u32 };

const ThreadQ = struct {
    head: ?u32 = null,
    tail: Tail = .head,
};

/// The matcher's working memory for a program: a generation per
/// instruction and the threads.
pub const Scratch = struct {
    gen: []u32,
    threads: []Rethread,
};

fn setnext(threads: []Rethread, q: *ThreadQ, t: Tail, v: ?u32) void {
    switch (t) {
        .head => q.head = v,
        .thread => |i| threads[i].next = v,
    }
}

/// regexec and rregexec: whether str (bytes or runes) matches; on a
/// match, sem[0] is the whole match and sem[1..] the subexpressions.
/// sem[0], when given, can bound the search: sp where it starts, ep
/// where it ends.
fn exec(comptime T: type, insts: []const Inst, s: Scratch, str_: []const T, sem_: ?[]Resub) bool {
    const str = str_[0 .. std.mem.findScalar(T, str_, 0) orelse str_.len];
    var msize: usize = 0;
    if (sem_) |sm|
        msize = @min(sm.len, NSUBEXPM);
    if (s.gen[0] != 0)
        @memset(s.gen, 0);

    var sp: usize = 0;
    var end: usize = str.len;
    var bounded = false; // the C's ep != nil
    if (sem_) |sem| {
        if (msize > 0) {
            if (sem[0].sp) |x|
                sp = x;
            if (sem[0].ep) |x| {
                if (x < str.len) {
                    end = x;
                    bounded = true;
                }
            }
        }
    }

    const threads = s.threads;
    var avail: ?u32 = null;
    var pool: u32 = 0;

    var lists: [2]ThreadQ = .{ .{}, .{} };
    var clist: *ThreadQ = &lists[0];
    var nlist: *ThreadQ = &lists[1];

    var gen: u32 = 0;
    var matchgen: u32 = 0;
    var r: u32 = '☺';
    var i: usize = 1;
    while (r != 0) : (sp += i) {
        if (sp >= end) {
            r = 0;
            i = 1;
        } else if (T == u8) {
            if (str[sp] < rune.Runeself) {
                r = str[sp];
                i = 1;
            } else {
                const d = rune.chartorune(str[sp..end]);
                r = d.r;
                i = d.n;
            }
        } else {
            r = str[sp];
            i = 1;
        }
        gen += 1;
        if (matchgen == 0) {
            var t: u32 = undefined;
            if (avail) |a| {
                if (msize > 0)
                    @memset(threads[a].sem[0..msize], .{});
                t = a;
                avail = threads[a].next;
            } else {
                if (pool >= threads.len) @panic("regexec: out of threads");
                threads[pool] = .{};
                t = pool;
                pool += 1;
            }
            threads[t].i = 0;
            threads[t].next = null;
            threads[t].gen = gen;
            setnext(threads, clist, clist.tail, t);
            clist.tail = .{ .thread = t };
        }
        var t = clist.head orelse break;
        var ci = threads[t].i;
        var next: ?u32 = null;
        vm: switch (@as(enum { again, done, switch_, class, advance }, .again)) {
            .again => {
                if (s.gen[ci] == gen)
                    continue :vm .done;
                s.gen[ci] = gen;
                switch (insts[ci]) {
                    .rune => |want| {
                        if (r != want)
                            continue :vm .done;
                        ci += 1;
                        continue :vm .switch_;
                    },
                    .any => {
                        ci += 1;
                        continue :vm .switch_;
                    },
                    .class => continue :vm .class,
                    .notnl => {
                        if (r != '\n') {
                            ci += 1;
                            continue :vm .again;
                        }
                        continue :vm .done;
                    },
                    .bol => {
                        if (sp == 0 or str[sp - 1] == '\n') {
                            ci += 1;
                            continue :vm .again;
                        }
                        continue :vm .done;
                    },
                    .eol => {
                        if (r == '\n' or r == 0 and !bounded) {
                            ci += 1;
                            continue :vm .again;
                        }
                        continue :vm .done;
                    },
                    .jmp => |a| {
                        ci = a;
                        continue :vm .again;
                    },
                    .split => |sl| {
                        var n: u32 = undefined;
                        if (avail) |a| {
                            n = a;
                            avail = threads[a].next;
                        } else {
                            if (pool >= threads.len) @panic("regexec: out of threads");
                            threads[pool] = .{};
                            n = pool;
                            pool += 1;
                        }
                        if (msize > 0)
                            @memcpy(threads[n].sem[0..msize], threads[t].sem[0..msize]);
                        threads[n].i = sl.b;
                        threads[n].next = threads[t].next;
                        threads[n].gen = threads[t].gen;
                        threads[t].next = n;
                        ci = sl.a;
                        continue :vm .again;
                    },
                    .save => |sub| {
                        if (sub < msize)
                            threads[t].sem[sub].sp = sp;
                        ci += 1;
                        continue :vm .again;
                    },
                    .unsave => |sub| {
                        if (sub == 0) {
                            matchgen = threads[t].gen;
                            if (sem_) |sem| {
                                if (msize > 0) {
                                    @memcpy(sem[0..msize], threads[t].sem[0..msize]);
                                    sem[0].ep = sp;
                                }
                            }
                            continue :vm .done;
                        }
                        if (sub < msize)
                            threads[t].sem[sub].ep = sp;
                        ci += 1;
                        continue :vm .again;
                    },
                }
            },
            .class => {
                const c = insts[ci].class;
                if (r < c.lo)
                    continue :vm .done;
                if (r > c.hi) {
                    ci += 1;
                    continue :vm .class;
                }
                ci = c.next;
                continue :vm .switch_;
            },
            .done => {
                next = threads[t].next;
                threads[t].next = avail;
                avail = t;
                continue :vm .advance;
            },
            .switch_ => {
                next = threads[t].next;
                threads[t].next = null;
                threads[t].i = ci;
                setnext(threads, nlist, nlist.tail, t);
                nlist.tail = .{ .thread = t };
                continue :vm .advance;
            },
            .advance => {
                const nx = next orelse break :vm;
                if (matchgen != 0 and threads[nx].gen > matchgen) {
                    setnext(threads, clist, clist.tail, avail);
                    avail = nx;
                    break :vm;
                }
                t = nx;
                ci = threads[t].i;
                continue :vm .again;
            },
        }
        const tmp = clist;
        clist = nlist;
        nlist = tmp;
        nlist.head = null;
        nlist.tail = .head;
    }
    return matchgen > 0;
}

// ------------------------------------------------------- the interface

/// A compiled pattern with its own working memory.
pub const Reprog = struct {
    insts: []Inst,
    gen: []u32,
    threads: []Rethread,
    regstr: []const u8,
    allocator: Allocator,

    pub fn deinit(p: *Reprog) void {
        const a = p.allocator;
        a.free(p.insts);
        a.free(p.gen);
        a.free(p.threads);
        a.destroy(p);
    }

    pub fn len(p: *const Reprog) usize {
        return p.insts.len;
    }

    /// regexec
    pub fn exec(p: *Reprog, str: []const u8, sem: ?[]Resub) bool {
        return execAny(u8, p.insts, .{ .gen = p.gen, .threads = p.threads }, str, sem);
    }

    /// rregexec
    pub fn rexec(p: *Reprog, str: []const Rune, sem: ?[]Resub) bool {
        return execAny(Rune, p.insts, .{ .gen = p.gen, .threads = p.threads }, str, sem);
    }

    /// The listing regprint gives (reprogfmt).
    pub fn fmt9(p: *const Reprog, f: *fmt.Fmt) void {
        listing(p.insts, f);
    }
};

const execAny = exec;

fn regcomp1(a: Allocator, str: []const u8, opt: Options, diag: ?*Diag) Error!*Reprog {
    const nodes = try a.alloc(Node, nodecount(str));
    defer a.free(nodes);
    const t = try parse(str, opt, nodes, diag);
    const maxthr = rune.utflen(upto0(str)) + 1;

    const p = try a.create(Reprog);
    errdefer a.destroy(p);
    const insts = try a.alloc(Inst, t.instrs);
    errdefer a.free(insts);
    const gen = try a.alloc(u32, t.instrs);
    errdefer a.free(gen);
    const threads = try a.alloc(Rethread, maxthr);
    compile(nodes, t.root, insts, opt.nl);
    @memset(gen, 0);
    p.* = .{ .insts = insts, .gen = gen, .threads = threads, .regstr = str, .allocator = a };
    return p;
}

/// Compile str; on a bad pattern error.Regexp, with the message in diag.
pub fn regcomp(a: Allocator, str: []const u8, diag: ?*Diag) Error!*Reprog {
    return regcomp1(a, str, .{}, diag);
}

/// As regcomp, with every character literal.
pub fn regcomplit(a: Allocator, str: []const u8, diag: ?*Diag) Error!*Reprog {
    return regcomp1(a, str, .{ .lit = true }, diag);
}

/// As regcomp, with `.` matching newline too.
pub fn regcompnl(a: Allocator, str: []const u8, diag: ?*Diag) Error!*Reprog {
    return regcomp1(a, str, .{ .nl = true }, diag);
}

/// A pattern compiled at build time, in read-only data.  A variable of
/// the type holds the matcher's working memory:
///
///     var ident: regexp.Static("^[a-z_][a-z0-9_]*$", .{}) = .{};
///     if (ident.exec(s, null)) ...
///
/// A bad pattern is a compile error with regcomp's message.
pub fn Static(comptime pattern: []const u8, comptime opt: Options) type {
    @setEvalBranchQuota(100000 + 1000 * pattern.len);
    const built = comptime blk: {
        var nodes: [nodecount(pattern)]Node = undefined;
        var diag: Diag = .{};
        const t = parse(pattern, opt, &nodes, &diag) catch
            @compileError(diag.msg);
        var insts: [t.instrs]Inst = undefined;
        compile(&nodes, t.root, &insts, opt.nl);
        const final = insts;
        break :blk .{ .insts = final, .nthr = rune.utflen(upto0(pattern)) + 1 };
    };
    return struct {
        pub const insts: [built.insts.len]Inst = built.insts;
        pub const regstr = pattern;

        gen: [built.insts.len]u32 = @splat(0),
        threads: [built.nthr]Rethread = undefined,

        pub fn exec(self: *@This(), str: []const u8, sem: ?[]Resub) bool {
            return execAny(u8, &insts, .{ .gen = &self.gen, .threads = &self.threads }, str, sem);
        }

        pub fn rexec(self: *@This(), str: []const Rune, sem: ?[]Resub) bool {
            return execAny(Rune, &insts, .{ .gen = &self.gen, .threads = &self.threads }, str, sem);
        }
    };
}

/// regsub and rregsub: src with \0 to \9 replaced by the subexpressions
/// of match in subject, & by the whole match, and \c by c, into dst;
/// at most dst.len-1 elements, as the C leaves room for its 0.  Returns
/// the part of dst written.
pub fn regsub(comptime T: type, src_: []const T, dst: []T, subject_: []const T, match: ?[]const Resub) []T {
    const src = src_[0 .. std.mem.findScalar(T, src_, 0) orelse src_.len];
    const subject = subject_[0 .. std.mem.findScalar(T, subject_, 0) orelse subject_.len];
    if (dst.len == 0)
        return dst;
    const ep = dst.len - 1;
    var d: usize = 0;
    const msize = if (match) |m| m.len else 0;

    // strecpy(dst, ep+1, s): as much of s as fits before ep
    const S = struct {
        fn copy(out: []T, at: usize, e: usize, s: []const T) usize {
            if (at >= e) return at;
            const n = @min(s.len, e - at);
            @memcpy(out[at..][0..n], s[0..n]);
            return at + n;
        }
    };

    var k: usize = 0;
    loop: while (k < src.len) : (k += 1) {
        switch (src[k]) {
            '\\' => {
                k += 1;
                if (k >= src.len)
                    break :loop;
                const c = src[k];
                switch (c) {
                    '0'...'9' => {
                        const i: usize = @intCast(c - '0');
                        if (match != null and i < msize) {
                            const m = match.?[i];
                            // the C checks ep for bytes, sp for runes
                            const set = if (T == u8) m.ep != null else m.sp != null;
                            if (set)
                                d = S.copy(dst, d, ep, subject[m.sp.?..m.ep.?]);
                        }
                    },
                    '\\' => {
                        if (d < ep) {
                            dst[d] = '\\';
                            d += 1;
                        } else break :loop;
                    },
                    else => {
                        if (d < ep) {
                            dst[d] = c;
                            d += 1;
                        } else break :loop;
                    },
                }
            },
            '&' => {
                if (match != null and msize > 0 and match.?[0].sp != null) {
                    const m = match.?[0];
                    d = S.copy(dst, d, ep, subject[m.sp.?..m.ep.?]);
                }
            },
            else => {
                if (d < ep) {
                    dst[d] = src[k];
                    d += 1;
                } else break :loop;
            },
        }
    }
    return dst[0..d];
}

/// regprint.c: one line per instruction.
fn listing(insts: []const Inst, f: *fmt.Fmt) void {
    for (insts, 0..) |inst, k| {
        f.print("%d ", .{k});
        switch (inst) {
            .rune => |r| f.print("ORUNE\t%C\n", .{r}),
            .notnl => f.print("ONOTNL\n", .{}),
            .class => |c| f.print("OCLASS\t%C-%C %d\n", .{ c.lo, c.hi, c.next }),
            .split => |s| f.print("OSPLIT\t%d %d\n", .{ s.a, s.b }),
            .jmp => |a| f.print("OJMP \t%d\n", .{a}),
            .save => |s| f.print("OSAVE\t%d\n", .{s}),
            .unsave => |s| f.print("OUNSAVE\t%d\n", .{s}),
            .any => f.print("OANY \t.\n", .{}),
            .eol => f.print("OEOL \t$\n", .{}),
            .bol => f.print("OBOL \t^\n", .{}),
        }
    }
}

// ----------------------------------------------------------------- tests

const testing = std.testing;

fn matchOf(pattern: []const u8, subject: []const u8) !?[2]usize {
    var d: Diag = .{};
    const p = try regcomp(testing.allocator, pattern, &d);
    defer p.deinit();
    var sem: [1]Resub = .{.{}};
    if (!p.exec(subject, &sem))
        return null;
    return .{ sem[0].sp.?, sem[0].ep.? };
}

fn expectMatch(pattern: []const u8, subject: []const u8, sp: usize, ep: usize) !void {
    const m = (try matchOf(pattern, subject)) orelse {
        std.debug.print("no match: /{s}/ on \"{s}\"\n", .{ pattern, subject });
        return error.TestUnexpectedResult;
    };
    if (m[0] != sp or m[1] != ep) {
        std.debug.print("/{s}/ on \"{s}\": {d}-{d}, want {d}-{d}\n", .{ pattern, subject, m[0], m[1], sp, ep });
        return error.TestUnexpectedResult;
    }
}

fn expectNoMatch(pattern: []const u8, subject: []const u8) !void {
    if (try matchOf(pattern, subject)) |m| {
        std.debug.print("/{s}/ on \"{s}\": matched {d}-{d}\n", .{ pattern, subject, m[0], m[1] });
        return error.TestUnexpectedResult;
    }
}

fn expectError(pattern: []const u8, msg: []const u8) !void {
    var d: Diag = .{};
    if (regcomp(testing.allocator, pattern, &d)) |p| {
        p.deinit();
        std.debug.print("/{s}/ compiled\n", .{pattern});
        return error.TestUnexpectedResult;
    } else |e| {
        try testing.expectEqual(error.Regexp, e);
        try testing.expectEqualStrings(msg, d.msg);
    }
}

test "literals, any, anchors" {
    try expectMatch("abc", "xxabcxx", 2, 5);
    try expectMatch("a.c", "abc", 0, 3);
    try expectNoMatch("a.c", "a\nc");
    try expectMatch("^ab", "abab", 0, 2);
    try expectNoMatch("^b", "ab");
    try expectMatch("^b", "a\nb", 2, 3);
    try expectMatch("b$", "abab", 3, 4);
    try expectMatch("a$", "xa\nya", 1, 2);
    try expectMatch("", "anything", 0, 0);
    try expectMatch("x*", "abc", 0, 0);
}

test "repetition and leftmost-longest" {
    try expectMatch("a*", "aaab", 0, 3);
    try expectMatch("ba+", "cbaaad", 1, 5);
    try expectNoMatch("ba+", "cbd");
    try expectMatch("colou?r", "my color", 3, 8);
    try expectMatch("colou?r", "my colour", 3, 9);
    try expectMatch("(ab)+", "xababab", 1, 7);
    try expectMatch("a|ab|abc", "abcd", 0, 3);
    try expectMatch("(a|b)*c", "abbac", 0, 5);
}

test "classes" {
    try expectMatch("[a-c]+", "xxabcabd", 2, 7);
    try expectMatch("[^a-c]+", "abcxyzab", 3, 6);
    try expectNoMatch("[^a]", "\n");
    try expectMatch("[\\]]", "a]b", 1, 2);
    try expectMatch("[c-a]", "b", 0, 1); // ranges are swapped
    try expectMatch("[a-cb-e]+", "xedcbay", 1, 6);
    try expectMatch("[☺-☻]", "x☻y", 1, 4);
    try expectNoMatch("[]", "abc");
    try expectMatch("[^]", "\nq", 1, 2);
}

test "escapes and literal" {
    try expectMatch("a\\.c", "abc a.c", 4, 7);
    try expectMatch("\\*", "a*b", 1, 2);
    var d: Diag = .{};
    const p = try regcomplit(testing.allocator, "a.*", &d);
    defer p.deinit();
    var sem: [1]Resub = .{.{}};
    try testing.expect(p.exec("xa.*y", &sem));
    try testing.expectEqual(@as(?usize, 1), sem[0].sp);
    try testing.expect(!p.exec("abc", null));
}

test "newline with regcompnl" {
    var d: Diag = .{};
    const p = try regcompnl(testing.allocator, "a.c", &d);
    defer p.deinit();
    try testing.expect(p.exec("a\nc", null));
}

test "submatches" {
    var d: Diag = .{};
    const p = try regcomp(testing.allocator, "([a-z]+)=([0-9]+)", &d);
    defer p.deinit();
    var sem: [3]Resub = @splat(.{});
    try testing.expect(p.exec("  key=42;", &sem));
    try testing.expectEqual(@as(?usize, 2), sem[0].sp);
    try testing.expectEqual(@as(?usize, 8), sem[0].ep);
    try testing.expectEqual(@as(?usize, 2), sem[1].sp);
    try testing.expectEqual(@as(?usize, 5), sem[1].ep);
    try testing.expectEqual(@as(?usize, 6), sem[2].sp);
    try testing.expectEqual(@as(?usize, 8), sem[2].ep);

    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("42 <- key [key=42] \\&", regsub(u8, "\\2 <- \\1 [&] \\\\\\&", &buf, "  key=42;", &sem));
    // dst keeps room for the C's 0
    var small: [5]u8 = undefined;
    try testing.expectEqualStrings("42 <", regsub(u8, "\\2 <- \\1", &small, "  key=42;", &sem));
}

test "search bounds in sem[0]" {
    var d: Diag = .{};
    const p = try regcomp(testing.allocator, "b$", &d);
    defer p.deinit();
    var sem: [1]Resub = .{.{ .sp = 2, .ep = null }};
    try testing.expect(p.exec("abab", &sem));
    try testing.expectEqual(@as(?usize, 3), sem[0].sp);
    // a bound before the end: $ does not match there
    sem = .{.{ .sp = 0, .ep = 2 }};
    try testing.expect(!p.exec("abab", &sem));
    // a start past a match
    const q = try regcomp(testing.allocator, "ab", &d);
    defer q.deinit();
    sem = .{.{ .sp = 1, .ep = null }};
    try testing.expect(q.exec("abab", &sem));
    try testing.expectEqual(@as(?usize, 2), sem[0].sp);
}

test "a 0 byte ends the subject" {
    try expectNoMatch("b", "a\x00b");
    try expectMatch("a$", "a\x00b", 0, 1);
}

test "runes" {
    var d: Diag = .{};
    const p = try regcomp(testing.allocator, "☺+(.)", &d);
    defer p.deinit();
    const s = [_]Rune{ 'x', '☺', '☺', 'y', 'z' };
    var sem: [2]Resub = @splat(.{});
    try testing.expect(p.rexec(&s, &sem));
    try testing.expectEqual(@as(?usize, 1), sem[0].sp);
    try testing.expectEqual(@as(?usize, 4), sem[0].ep);
    var out: [16]Rune = undefined;
    const r = regsub(Rune, &[_]Rune{ '<', '\\', '1', '>' }, &out, &s, &sem);
    try testing.expectEqualSlices(Rune, &[_]Rune{ '<', 'y', '>' }, r);
}

test "compile errors" {
    try expectError("(ab", "regexp (ab: no matching parenthesis");
    try expectError("a|", "regexp a|: parsing error");
    try expectError("*a", "regexp *a: syntax error: *");
    try expectError("a||b", "regexp a||b: syntax error: |");
    try expectError("[a-]", "Malformed class");
    try expectError("[-a]", "Malformed class");
    try expectError("[a-b-c]", "Malformed class");
    try expectError("[abc", "No closing ] for class");
    try expectError("()", "regexp (): syntax error: )");
}

test "what is left after the pattern is not checked, as in C" {
    try expectMatch("a)", "ba", 1, 2);
}

test "class too big" {
    var buf: [1024]u8 = undefined;
    var n: usize = 0;
    buf[n] = '[';
    n += 1;
    for (0..210) |k| {
        n += rune.runetochar(buf[n..], @intCast(0x100 + 2 * k));
    }
    buf[n] = ']';
    n += 1;
    try expectError(buf[0..n], "Class too big\n");
}

test "static" {
    var ident: Static("^[a-zA-Z_][a-zA-Z0-9_]*$", .{}) = .{};
    try testing.expect(ident.exec("snake_case9", null));
    try testing.expect(!ident.exec("9lives", null));
    var sem: [2]Resub = @splat(.{});
    var kv: Static("([a-z]+)=", .{}) = .{};
    try testing.expect(kv.exec("x abc=1", &sem));
    try testing.expectEqual(@as(?usize, 2), sem[1].sp);
    try testing.expectEqual(@as(?usize, 5), sem[1].ep);
}

test "static and runtime compile the same program" {
    const pats = [_][]const u8{ "a|b*c", "[^x-z0]+(q)?", "^.$", "(a(b(c)))+" };
    inline for (pats) |pat| {
        var d: Diag = .{};
        const p = try regcomp(testing.allocator, pat, &d);
        defer p.deinit();
        const S = Static(pat, .{});
        try testing.expectEqualSlices(Inst, &S.insts, p.insts);
    }
}
