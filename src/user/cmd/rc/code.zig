//! rc's compiler: syntax trees to code for the interpreter.
//! from cmd/rc/code.c
//!
//! DIFF:
//!   - Code is a list of instructions, each a tagged union holding its
//!     operands, where the C's code vector is a list of words mixing
//!     function pointers, integers and strings.  A pc counts
//!     instructions; jumps hold instruction numbers.  wordpc gives the
//!     C's pc of an instruction, for the -r trace (pfnc).
//!   - A builtin compiled into code (the `rfork s` of `&`) is the
//!     builtin's name in an enum, not a function pointer.
//!   - The reference count and the source file name are fields; the
//!     C keeps them in the first two words, so its code starts at pc 2.
//!   - On a compile error the strings already emitted are freed; the C
//!     frees only the vector.

const std = @import("std");
const rc = @import("rc.zig");
const io = @import("io.zig");
const lex = @import("lex.zig");
const tree = @import("tree.zig");
const exec = @import("exec.zig");
const glob = @import("glob.zig");
const simple = @import("simple.zig");
const getflags = @import("getflags.zig");

const Tree = rc.Tree;

pub const Builtin = simple.Builtin;

/// An instruction: what the C's Xname function does, with the operands
/// the C reads from the words after it.
pub const Inst = union(enum) {
    append: i32, // fd
    assign,
    async: u32, // where the parent goes on
    backq: u32, // where the parent goes on
    bang,
    builtin: Builtin,
    case: u32, // the next case
    close: i32, // fd
    conc,
    count,
    delfn,
    dol,
    dup: struct { fd0: i32, fd1: i32 },
    eflag,
    exit,
    false: u32, // where to go if the status is false
    @"fn": struct { end: u32, str: []u8 }, // after the body; its text
    @"for": u32, // after the loop
    glob,
    here: Here,
    hereq: Here, // the document is not substituted
    @"if": u32, // after the body
    ifnot: u32, // after the body
    jump: u32,
    local,
    mark,
    match,
    pipe: struct { fd0: i32, fd1: i32, right: u32, end: u32 },
    pipefd: struct { rtype: i32, end: u32 },
    pipewait,
    popm,
    popredir,
    push,
    qw,
    rdcmds,
    rdwr: i32, // fd
    read: i32, // fd
    @"return",
    settrue,
    simple,
    srcline: i32,
    sub,
    subshell: u32, // where the parent goes on
    true: u32, // where to go if the status is true
    unlocal,
    wastrue,
    word: []u8,
    write: i32, // fd

    /// The C's name of the instruction (pfnc.c's table).
    pub fn name(i: Inst) []const u8 {
        return switch (i) {
            .builtin => "builtin",
            inline else => |_, tag| "X" ++ @tagName(tag),
        };
    }

    /// How many words it takes in the C's code vector.
    pub fn words(i: Inst) u32 {
        return switch (i) {
            .append, .async, .backq, .case, .close, .false, .@"for", .@"if", .ifnot, .jump, .rdwr, .read, .srcline, .subshell, .true, .word, .write => 2,
            .dup, .pipefd, .here, .hereq, .@"fn" => 3,
            .pipe => 5,
            else => 1,
        };
    }
};

/// A here document's text and the fd it goes to.
pub const Here = struct { str: []u8, fd: i32 };

pub const Code = struct {
    ref: i32, // reference count
    file: ?[]u8, // for srcfile()
    inst: []Inst,

    /// The C's pc of instruction pc (its code starts at word 2).
    pub fn wordpc(c: *const Code, pc: usize) u32 {
        var n: u32 = 2;
        for (c.inst[0..@min(pc, c.inst.len)]) |i|
            n += i.words();
        return n;
    }
};

pub var codebuf: ?*Code = null;
var code: std.ArrayList(Inst) = .empty;
var codeline: i32 = 0;

fn emit(i: Inst) u32 {
    code.append(rc.a, i) catch rc.panic("Can't malloc %d bytes", @sizeOf(Inst));
    return @intCast(code.items.len - 1);
}

fn here() u32 {
    return @intCast(code.items.len);
}

/// stuffdot: point the address of the instruction at a to here.
fn stuffdot(a: u32) void {
    if (a >= code.items.len)
        rc.panic("Bad address %d in stuffdot", a);
    const h = here();
    switch (code.items[a]) {
        .async, .backq, .case, .false, .@"for", .@"if", .ifnot, .jump, .subshell, .true => |*p| p.* = h,
        .@"fn" => |*f| f.end = h,
        .pipefd => |*p| p.end = h,
        else => rc.panic("Bad address %d in stuffdot", a),
    }
}

pub fn compile(t: ?*Tree) bool {
    code = .empty;
    codeline = 0; // force source
    const l = lex.lex.?;
    const file = if (l.file) |f| rc.estrdup(f) else null;
    outcode(t, !l.qflag and getflags.flag['e'] != null);
    if (lex.nerror != 0) {
        freeinsts(code.items);
        code.deinit(rc.a);
        rc.free(file);
        return false;
    }
    _ = emit(.@"return");
    const c = rc.new(Code);
    c.* = .{
        .ref = 0,
        .file = file,
        .inst = code.toOwnedSlice(rc.a) catch rc.panic("Can't malloc %d bytes", 0),
    };
    codebuf = c;
    return true;
}

/// called on a tree where we expect eigther a pattern or a string
/// instead of a glob to remove the GLOB chars from the strings or set
/// glob to 2 for pattern so Xglob is not inserted when compiling the
/// tree.
fn noglobs(t_: ?*Tree, pattern: bool) void {
    var t_opt = t_;
    while (t_opt) |t| {
        if (t.type == rc.WORD and t.glob != 0) {
            if (pattern)
                t.glob = 2
            else {
                t.str = glob.deglob(t.str.?);
                t.glob = 0;
            }
        }
        if (t.type == rc.PAREN or t.type == rc.WORDS or t.type == '^') {
            t.glob = 0;
            noglobs(t.child[1], pattern);
            t_opt = t.child[0];
            continue;
        }
        return;
    }
}

/// emits(t->str); t->str=0: the instruction owns the string.
fn take(t: *Tree) []u8 {
    const s = t.str.?;
    t.str = null;
    return s;
}

fn outcode(t_: ?*Tree, eflag: bool) void {
    var t = t_ orelse return;
    const l = lex.lex.?;
    var c0 = t.child[0];
    var c1 = t.child[1];
    const c2 = t.child[2];
    if (t.type != rc.NOT and t.type != ';')
        l.iflast = false;
    if (t.line != codeline) {
        codeline = t.line;
        if (code.items.len > 0 and code.items[code.items.len - 1] == .srcline)
            code.items[code.items.len - 1].srcline = codeline
        else
            _ = emit(.{ .srcline = codeline });
    }
    switch (t.type) {
        else => io.pfmt(exec.err, "bad type %d in outcode\n", .{t.type}),
        '$' => {
            _ = emit(.mark);
            noglobs(c0, false);
            outcode(c0, eflag);
            _ = emit(.dol);
        },
        '"' => {
            _ = emit(.mark);
            _ = emit(.mark);
            noglobs(c0, false);
            outcode(c0, eflag);
            _ = emit(.dol);
            _ = emit(.qw);
            _ = emit(.push);
        },
        rc.SUB => {
            _ = emit(.mark);
            noglobs(c0, false);
            outcode(c0, eflag);
            _ = emit(.mark);
            noglobs(c1, false);
            outcode(c1, eflag);
            _ = emit(.sub);
        },
        '&' => {
            const p = emit(.{ .async = 0 });

            // undocumented?
            _ = emit(.mark);
            _ = emit(.{ .word = rc.estrdup("/dev/null") });
            _ = emit(.{ .read = 0 });

            // insert rfork s for plan9
            if (simple.builtinfunc("rfork")) |f| {
                _ = emit(.mark);
                _ = emit(.{ .word = rc.estrdup("s") });
                _ = emit(.{ .word = rc.estrdup("rfork") });
                _ = emit(.{ .builtin = f });
            }

            codeline = 0; // force source
            outcode(c0, eflag);
            _ = emit(.exit);
            stuffdot(p);
        },
        ';' => {
            outcode(c0, eflag);
            outcode(c1, eflag);
        },
        '^' => {
            _ = emit(.mark);
            outcode(c1, eflag);
            _ = emit(.mark);
            outcode(c0, eflag);
            _ = emit(.conc);
        },
        '`' => {
            _ = emit(.mark);
            if (c0 != null) {
                noglobs(c0, false);
                outcode(c0, false);
            } else {
                _ = emit(.mark);
                _ = emit(.{ .word = rc.estrdup("ifs") });
                _ = emit(.dol);
            }
            _ = emit(.qw);
            const p = emit(.{ .backq = 0 });
            codeline = 0; // force source
            outcode(c1, false);
            _ = emit(.exit);
            stuffdot(p);
        },
        rc.ANDAND => {
            outcode(c0, false);
            const p = emit(.{ .true = 0 });
            outcode(c1, eflag);
            stuffdot(p);
        },
        rc.ARGLIST => {
            outcode(c1, eflag);
            outcode(c0, eflag);
        },
        rc.BANG => {
            outcode(c0, eflag);
            _ = emit(.bang);
        },
        rc.PCMD, rc.BRACE => outcode(c0, eflag),
        rc.COUNT => {
            _ = emit(.mark);
            noglobs(c0, false);
            outcode(c0, eflag);
            _ = emit(.count);
        },
        rc.FN => {
            _ = emit(.mark);
            noglobs(c0, false);
            outcode(c0, eflag);
            if (c1 != null) {
                const p = emit(.{ .@"fn" = .{ .end = 0, .str = tree.fnstr(c1) } });
                codeline = 0; // force source
                outcode(c1, eflag);
                _ = emit(.@"return");
                stuffdot(p);
            } else _ = emit(.delfn);
        },
        rc.IF => {
            outcode(c0, false);
            const p = emit(.{ .@"if" = 0 });
            outcode(c1, eflag);
            _ = emit(.wastrue);
            stuffdot(p);
        },
        rc.NOT => {
            if (!l.iflast)
                lex.yyerror("`if not' does not follow `if(...)'");
            const p = emit(.{ .ifnot = 0 });
            outcode(c0, eflag);
            stuffdot(p);
        },
        rc.OROR => {
            outcode(c0, false);
            const p = emit(.{ .false = 0 });
            outcode(c1, eflag);
            stuffdot(p);
        },
        rc.PAREN => outcode(c0, eflag),
        rc.SIMPLE => {
            _ = emit(.mark);
            outcode(c0, eflag);
            _ = emit(.simple);
            if (eflag)
                _ = emit(.eflag);
        },
        rc.SUBSHELL => {
            const p = emit(.{ .subshell = 0 });
            codeline = 0; // force source
            outcode(c0, eflag);
            _ = emit(.exit);
            stuffdot(p);
            if (eflag)
                _ = emit(.eflag);
        },
        rc.SWITCH => codeswitch(t, eflag),
        rc.TWIDDLE => {
            _ = emit(.mark);
            noglobs(c1, true);
            outcode(c1, eflag);
            _ = emit(.mark);
            outcode(c0, eflag);
            _ = emit(.qw);
            _ = emit(.match);
            if (eflag)
                _ = emit(.eflag);
        },
        rc.WHILE => {
            const q = here();
            outcode(c0, false);
            if (q == here())
                _ = emit(.settrue); // empty condition == while(true)
            const p = emit(.{ .true = 0 });
            outcode(c1, eflag);
            _ = emit(.{ .jump = q });
            stuffdot(p);
        },
        rc.WORDS => {
            outcode(c1, eflag);
            outcode(c0, eflag);
        },
        rc.FOR => {
            _ = emit(.mark);
            if (c1 != null) {
                outcode(c1, eflag);
            } else {
                _ = emit(.mark);
                _ = emit(.{ .word = rc.estrdup("*") });
                _ = emit(.dol);
            }
            _ = emit(.mark); // dummy value for Xlocal
            _ = emit(.mark);
            noglobs(c0, false);
            outcode(c0, eflag);
            _ = emit(.local);
            const p = emit(.{ .@"for" = 0 });
            outcode(c2, eflag);
            _ = emit(.{ .jump = p });
            stuffdot(p);
            _ = emit(.unlocal);
        },
        rc.WORD => _ = emit(.{ .word = take(t) }),
        rc.DUP => {
            if (t.rtype == rc.DUPFD)
                _ = emit(.{ .dup = .{ .fd0 = t.fd0, .fd1 = t.fd1 } })
            else
                _ = emit(.{ .close = t.fd0 });
            outcode(c1, eflag);
            _ = emit(.popredir);
        },
        rc.PIPEFD => {
            const p = emit(.{ .pipefd = .{ .rtype = t.rtype, .end = 0 } });
            codeline = 0; // force source
            outcode(c0, eflag);
            _ = emit(.exit);
            stuffdot(p);
        },
        rc.REDIR => {
            if (t.rtype != rc.HERE) {
                _ = emit(.mark);
                outcode(c0, eflag);
            }
            switch (t.rtype) {
                rc.APPEND => _ = emit(.{ .append = t.fd0 }),
                rc.WRITE => _ = emit(.{ .write = t.fd0 }),
                rc.READ => _ = emit(.{ .read = t.fd0 }),
                rc.RDWR => _ = emit(.{ .rdwr = t.fd0 }),
                rc.HERE => {
                    // the C's text is nil after a NUL in the document
                    const s = if (t.str) |x| x else rc.estrdup("");
                    t.str = null;
                    if (c0.?.quoted)
                        _ = emit(.{ .hereq = .{ .str = s, .fd = t.fd0 } })
                    else
                        _ = emit(.{ .here = .{ .str = s, .fd = t.fd0 } });
                },
                else => {},
            }
            outcode(c1, eflag);
            _ = emit(.popredir);
        },
        '=' => {
            const tt = t;
            var u: ?*Tree = t;
            while (u) |x| : (u = x.child[2]) {
                if (x.type != '=') break;
            }
            if (u) |cmd| { // var=value cmd
                var v = tt;
                while (v.type == '=') : (v = v.child[2].?) {
                    _ = emit(.mark);
                    outcode(v.child[1], eflag);
                    _ = emit(.mark);
                    noglobs(v.child[0], false);
                    outcode(v.child[0], eflag);
                    _ = emit(.local); // push var for cmd
                }
                outcode(cmd, eflag); // gen. code for cmd
                v = tt;
                while (v.type == '=') : (v = v.child[2].?)
                    _ = emit(.unlocal); // pop var
            } else { // var=value
                var v: ?*Tree = tt;
                while (v) |x| : (v = x.child[2]) {
                    _ = emit(.mark);
                    outcode(x.child[1], eflag);
                    _ = emit(.mark);
                    noglobs(x.child[0], false);
                    outcode(x.child[0], eflag);
                    _ = emit(.assign); // set var permanently
                }
            }
            t = tt; // so tests below will work
            c0 = t.child[0];
            c1 = t.child[1];
        },
        rc.PIPE => {
            const p = emit(.{ .pipe = .{ .fd0 = t.fd0, .fd1 = t.fd1, .right = 0, .end = 0 } });
            codeline = 0; // force source
            outcode(c0, eflag);
            _ = emit(.exit);
            code.items[p].pipe.right = here();
            codeline = 0; // force source
            outcode(c1, eflag);
            _ = emit(.@"return");
            code.items[p].pipe.end = here();
            _ = emit(.pipewait);
        },
    }
    if (t.glob == 1)
        _ = emit(.glob);
    if (t.type != rc.NOT and t.type != ';')
        l.iflast = t.type == rc.IF
    else if (c0) |c|
        l.iflast = c.type == rc.IF;
}

// switch code looks like this:
//    Xmark
//    (get switch value)
//    Xjump    1f
// out:    Xjump    leave
// 1:    Xmark
//    (get case values)
//    Xcase    1f
//    (commands)
//    Xjump    out
// 1:    Xmark
//    (get case values)
//    Xcase    1f
//    (commands)
//    Xjump    out
// 1:
// leave:
//    Xpopm
fn codeswitch(t: *Tree, eflag: bool) void {
    const c1 = t.child[1].?;
    const body = c1.child[0];
    if (body == null or body.?.type != ';' or !iscase(body.?.child[0].?)) {
        lex.yyerror("case missing in switch");
        return;
    }
    _ = emit(.mark);
    outcode(t.child[0], eflag);
    _ = emit(.qw);
    var nextcase = emit(.{ .jump = 0 }); // patch jump address to next case
    const out = emit(.{ .jump = 0 }); // jump here to leave switch
    const leave = out; // patch jump address to leave switch
    stuffdot(nextcase);
    var u = body.?;
    while (u.type == ';') {
        const tt = u.child[1];
        _ = emit(.mark);
        var a = u.child[0].?.child[0].?;
        while (a.type == rc.ARGLIST) : (a = a.child[0].?) {
            noglobs(a.child[1], true);
            outcode(a.child[1], eflag);
        }
        nextcase = emit(.{ .case = 0 });
        var v = tt.?;
        while (true) {
            if (v.type == ';') {
                if (iscase(v.child[0].?)) break;
                outcode(v.child[0], eflag);
                v = v.child[1].?;
            } else {
                if (!iscase(v)) outcode(v, eflag);
                break;
            }
        }
        u = v;
        _ = emit(.{ .jump = out });
        stuffdot(nextcase);
    }
    stuffdot(leave);
    _ = emit(.popm);
}

fn iscase(t_: *Tree) bool {
    var t = t_;
    if (t.type != rc.SIMPLE)
        return false;
    t = t.child[0].?;
    while (t.type == rc.ARGLIST) t = t.child[0].?;
    return t.type == rc.WORD and !t.quoted and std.mem.eql(u8, t.str.?, "case");
}

pub fn codecopy(cp: *Code) *Code {
    cp.ref += 1;
    return cp;
}

fn freeinsts(insts: []Inst) void {
    for (insts) |i| switch (i) {
        .here, .hereq => |h| rc.a.free(h.str),
        .word => |w| rc.a.free(w),
        .@"fn" => |f| rc.a.free(f.str),
        else => {},
    };
}

pub fn codefree(cp: *Code) void {
    cp.ref -= 1;
    if (cp.ref != 0)
        return;
    freeinsts(cp.inst);
    rc.a.free(cp.inst);
    rc.free(cp.file);
    rc.destroy(cp);
}
