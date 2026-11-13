//! Host tests of rc's lexer, parser and printer.  Not part of rc.

const std = @import("std");
const rc = @import("rc.zig");
const io = @import("io.zig");
const lex = @import("lex.zig");
const syn = @import("syn.zig");
const tree = @import("tree.zig");
const exec = @import("exec.zig");
const @"var" = @import("var.zig");

const testing = std.testing;

var inited = false;

fn setup() void {
    if (inited) return;
    @"var".kinit();
    exec.err = io.openiofd(2);
    exec.err_open = true;
    const t = rc.new(rc.Thread);
    t.* = .{};
    exec.runq = t;
    syn.compile = &keep;
    inited = true;
}

/// What the parser gave, one printed command per compile.
var out: std.ArrayList(u8) = .empty;
var ncmds: usize = 0;

fn keep(t: ?*rc.Tree) bool {
    const s = tree.fnstr(t);
    defer rc.a.free(s);
    out.appendSlice(std.heap.smp_allocator, s) catch unreachable;
    out.append(std.heap.smp_allocator, '\n') catch unreachable;
    ncmds += 1;
    return true;
}

const hostlibc = @import("libc");

/// The error output so far (rc's fd 2), emptied.
fn takeErr() []u8 {
    io.flushio(exec.err);
    const s = rc.estrdup(hostlibc.fd2.items);
    hostlibc.fd2.clearRetainingCapacity();
    return s;
}

/// Parse text as `. file` does (line by line), as file; returns the
/// number of errors.
fn parse(text: []const u8, block: bool) i32 {
    setup();
    const l = lex.newlexer(io.openiocore(rc.estrdup(text)), rc.estrdup("t"));
    if (!block) {
        l.peekc = io.EOF;
        l.epilog = "";
    }
    var errors: i32 = 0;
    while (true) {
        lex.lex = l;
        lex.nerror = 0;
        const r = syn.yyparse();
        errors += lex.nerror;
        tree.freenodes();
        if (r != 0 and (l.eof or lex.nerror != 0))
            break;
    }
    lex.freelexer(l);
    lex.lex = null;
    return errors;
}

fn expectParse(text: []const u8, want: []const u8) !void {
    out.clearRetainingCapacity();
    const e = parse(text, false);
    const msg = takeErr();
    defer rc.a.free(msg);
    testing.expectEqual(@as(i32, 0), e) catch |x| {
        std.debug.print("errors parsing {s}: {s}\n", .{ text, msg });
        return x;
    };
    testing.expectEqualStrings(want, out.items) catch |x| {
        std.debug.print("parsing {f}\n", .{std.zig.fmtString(text)});
        return x;
    };
}

fn expectError(text: []const u8, want: []const u8) !void {
    out.clearRetainingCapacity();
    const e = parse(text, false);
    const msg = takeErr();
    defer rc.a.free(msg);
    try testing.expect(e > 0);
    try testing.expectEqualStrings(want, msg);
}

test "tokens" {
    setup();
    const l = lex.newlexer(io.openiocore(rc.estrdup("a'b c'$x(1) >[2=1] |[2] <<EOF $#y $\"z `{ls}\n")), null);
    l.peekc = io.EOF;
    l.epilog = "";
    lex.lex = l;
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(testing.allocator);
    while (true) {
        const c = lex.yylex();
        if (c == io.EOF) break;
        try got.appendSlice(testing.allocator, l.token());
        try got.append(testing.allocator, '|');
    }
    tree.freenodes();
    lex.freelexer(l);
    lex.lex = null;
    try testing.expectEqualStrings("a|^|b c|^|$|x|( [SUB]|1|)|>[22=1]||[22]|<<|EOF|$#|y|$\"|z|`|{|ls|}|\n|", got.items);
}

test "parse and print" {
    try expectParse("echo hello world\n", "echo hello world\n");
    try expectParse("x=(a b c) echo $x(2) $#x $\"x\n", "x=(a b c) echo $x(2) $#x $\"x\n");
    try expectParse("a^b c^'d e'^$f\n", "a^b c^'d e'^$f\n");
    try expectParse("echo a'b'c$d\n", "echo a^'b'^c^$d\n");
    try expectParse("cat <a >b >>c <>d >[2=1] >[3=] |[2] wc\n", " <a  >b  >>c  <>d >[2=1]>[3=]cat|[2]wc\n");
    try expectParse("if(~ $x a*) echo yes\nif not echo no\n", "if(~ $x a*)echo yes\nif not echo no\n");
    try expectParse("for(i in 1 2 3) echo $i\nfor(i) echo\nfor(i in) echo\n", "for(i in 1 2 3)echo $i\nfor(i)echo\nfor(i in ())echo\n");
    try expectParse("fn f { echo a; echo b\n echo c }\n", "fn f {\n\techo a; echo b\n\techo c\n}\n");
    try expectParse("switch($x){\ncase a\n\techo a\ncase *\n\techo other\n}\n", "switch ($x) {\n\tcase a\n\techo a\n\tcase *\n\techo other\n}\n");
    try expectParse("a && b || ! c &\n@{ cd /tmp; ls }\n", "a && b || ! c&\n@ {\n\tcd /tmp; ls\n}\n");
    try expectParse("echo `{date} `x{ls} <{a} >{b}\n", "echo `{\n\tdate\n} `x{\n\tls\n}  <{\n\ta\n}  >{\n\tb\n}\n");
    try expectParse("while(true) {\n\tbreak\n}\n", "while (true){\n\tbreak\n}\n");
    try expectParse("cat <<EOF\nhello $x\nEOF\necho after\n", " cat <<EOF\nhello $x\nEOF\n\necho after\n");
    try expectParse("echo a\\\nb # comment\n", "echo a b\n");
    try expectParse("fn x\n", "fn x \n");
}

test "syntax errors" {
    try expectError("echo (\n", "t:2: syntax error\n");
    try expectError("if) x\n", "t:1: token ')': syntax error\n");
    // the lexer's error returns EOF, which is a syntax error too
    try expectError("echo >[x] y\n", "t:1: token '>[x': redirection syntax\nt:2: token '>[x': syntax error\n");
    try expectError("a |[2=] b\n", "t:1: token '|[22=': pipe syntax\nt:2: token '|[22=': syntax error\n");
}

// Parse each of 9front's rc scripts and print what was parsed: the
// printed text parses again.  (It need not print the same: whether two
// commands print on one line with "; " depends on their line numbers,
// which printing a block over several lines changes.  That the printing
// is stock's is checked against stock rc in the guest.)
test "9front's scripts parse, and what they print parses" {
    var dir = std.Io.Dir.cwd().openDir(testing.io, "ref/src/rc/bin", .{ .iterate = true }) catch return error.SkipZigTest;
    defer dir.close(testing.io);
    var it = dir.iterate();
    var n: usize = 0;
    var cmds: usize = 0;
    while (try it.next(testing.io)) |e| {
        if (e.kind != .file) continue;
        const text = try dir.readFileAlloc(testing.io, e.name, testing.allocator, .limited(1 << 20));
        defer testing.allocator.free(text);
        if (!std.mem.startsWith(u8, text, "#!/bin/rc"))
            continue;
        out.clearRetainingCapacity();
        ncmds = 0;
        const e1 = parse(text, false);
        const m1 = takeErr();
        defer rc.a.free(m1);
        if (e1 != 0) {
            std.debug.print("{s}: {s}", .{ e.name, m1 });
            return error.TestUnexpectedResult;
        }
        const first = try testing.allocator.dupe(u8, out.items);
        defer testing.allocator.free(first);
        cmds += ncmds;
        out.clearRetainingCapacity();
        const e2 = parse(first, false);
        const m2 = takeErr();
        defer rc.a.free(m2);
        if (e2 != 0) {
            std.debug.print("{s} printed: {s}", .{ e.name, m2 });
            return error.TestUnexpectedResult;
        }
        n += 1;
    }
    // 126 scripts and 1778 commands in 9front 11952
    try testing.expect(n > 100 and cmds > 1000);
}

const code = @import("code.zig");

/// The code compiled for text: one instruction per line, with its
/// operands, as "name operand...".
var listing: std.ArrayList(u8) = .empty;

fn list(t: ?*rc.Tree) bool {
    if (!code.compile(t))
        return false;
    const c = code.codebuf.?;
    const g = std.heap.smp_allocator;
    for (c.inst, 0..) |i, n| {
        listing.print(g, "{d} ", .{n}) catch unreachable;
        listing.appendSlice(g, i.name()) catch unreachable;
        switch (i) {
            .word => |w| listing.print(g, " {f}", .{std.zig.fmtString(w)}) catch unreachable,
            .here, .hereq => |h| listing.print(g, " {f} {d}", .{ std.zig.fmtString(h.str), h.fd }) catch unreachable,
            .@"fn" => |f| listing.print(g, " {d} {f}", .{ f.end, std.zig.fmtString(f.str) }) catch unreachable,
            .dup => |d| listing.print(g, " {d} {d}", .{ d.fd0, d.fd1 }) catch unreachable,
            .pipe => |p| listing.print(g, " {d} {d} {d} {d}", .{ p.fd0, p.fd1, p.right, p.end }) catch unreachable,
            .pipefd => |p| listing.print(g, " {d} {d}", .{ p.rtype, p.end }) catch unreachable,
            .builtin => |b| listing.print(g, " {s}", .{b.name()}) catch unreachable,
            inline else => |v| if (@TypeOf(v) != void) listing.print(g, " {d}", .{v}) catch unreachable,
        }
        listing.append(g, '\n') catch unreachable;
    }
    lastwordpc = c.wordpc(c.inst.len - 1);
    c.ref = 1;
    code.codefree(c);
    return true;
}

/// The C's pc of the last instruction of what list compiled.
var lastwordpc: u32 = 0;

fn expectCode(text: []const u8, want: []const u8) !void {
    setup();
    syn.compile = &list;
    defer syn.compile = &keep;
    listing.clearRetainingCapacity();
    const e = parse(text, false);
    const msg = takeErr();
    defer rc.a.free(msg);
    testing.expectEqual(@as(i32, 0), e) catch |x| {
        std.debug.print("errors compiling {s}: {s}\n", .{ text, msg });
        return x;
    };
    testing.expectEqualStrings(want, listing.items) catch |x| {
        std.debug.print("compiling {f}\n", .{std.zig.fmtString(text)});
        return x;
    };
}

test "compile" {
    try expectCode("echo hi\n",
        \\0 Xsrcline 1
        \\1 Xmark
        \\2 Xword hi
        \\3 Xword echo
        \\4 Xsimple
        \\5 Xreturn
        \\
    );
    // [0] count [1] file [2] Xsrcline [3] 1 [4] Xmark [5] Xword [6] "hi"
    // [7] Xword [8] "echo" [9] Xsimple [10] Xreturn
    try testing.expectEqual(@as(u32, 10), lastwordpc);
    try expectCode("x=1\n",
        \\0 Xsrcline 1
        \\1 Xmark
        \\2 Xword 1
        \\3 Xmark
        \\4 Xword x
        \\5 Xassign
        \\6 Xreturn
        \\
    );
    try expectCode("x=1 y=2 cmd\n",
        \\0 Xsrcline 1
        \\1 Xmark
        \\2 Xword 1
        \\3 Xmark
        \\4 Xword x
        \\5 Xlocal
        \\6 Xmark
        \\7 Xword 2
        \\8 Xmark
        \\9 Xword y
        \\10 Xlocal
        \\11 Xmark
        \\12 Xword cmd
        \\13 Xsimple
        \\14 Xunlocal
        \\15 Xunlocal
        \\16 Xreturn
        \\
    );
    try expectCode("if(a) b\n",
        \\0 Xsrcline 1
        \\1 Xmark
        \\2 Xword a
        \\3 Xsimple
        \\4 Xif 9
        \\5 Xmark
        \\6 Xword b
        \\7 Xsimple
        \\8 Xwastrue
        \\9 Xreturn
        \\
    );
    try expectCode("a | b\n",
        \\0 Xsrcline 1
        \\1 Xpipe 1 0 7 12
        \\2 Xsrcline 1
        \\3 Xmark
        \\4 Xword a
        \\5 Xsimple
        \\6 Xexit
        \\7 Xsrcline 1
        \\8 Xmark
        \\9 Xword b
        \\10 Xsimple
        \\11 Xreturn
        \\12 Xpipewait
        \\13 Xreturn
        \\
    );
    try expectCode("for(i in a b) echo $i\n",
        \\0 Xsrcline 1
        \\1 Xmark
        \\2 Xword b
        \\3 Xword a
        \\4 Xmark
        \\5 Xmark
        \\6 Xword i
        \\7 Xlocal
        \\8 Xfor 16
        \\9 Xmark
        \\10 Xmark
        \\11 Xword i
        \\12 Xdol
        \\13 Xword echo
        \\14 Xsimple
        \\15 Xjump 8
        \\16 Xunlocal
        \\17 Xreturn
        \\
    );
    try expectCode("switch(x){case a; echo A; case *; echo B}\n",
        \\0 Xsrcline 1
        \\1 Xmark
        \\2 Xword x
        \\3 Xqw
        \\4 Xjump 6
        \\5 Xjump 22
        \\6 Xmark
        \\7 Xword a
        \\8 Xcase 14
        \\9 Xmark
        \\10 Xword A
        \\11 Xword echo
        \\12 Xsimple
        \\13 Xjump 5
        \\14 Xmark
        \\15 Xword \x01*
        \\16 Xcase 22
        \\17 Xmark
        \\18 Xword B
        \\19 Xword echo
        \\20 Xsimple
        \\21 Xjump 5
        \\22 Xpopm
        \\23 Xreturn
        \\
    );
    try expectCode("a &\n",
        \\0 Xsrcline 1
        \\1 Xasync 14
        \\2 Xmark
        \\3 Xword /dev/null
        \\4 Xread 0
        \\5 Xmark
        \\6 Xword s
        \\7 Xword rfork
        \\8 builtin rfork
        \\9 Xsrcline 1
        \\10 Xmark
        \\11 Xword a
        \\12 Xsimple
        \\13 Xexit
        \\14 Xreturn
        \\
    );
    try expectCode("echo `{date}\n",
        \\0 Xsrcline 1
        \\1 Xmark
        \\2 Xmark
        \\3 Xmark
        \\4 Xword ifs
        \\5 Xdol
        \\6 Xqw
        \\7 Xbackq 13
        \\8 Xsrcline 1
        \\9 Xmark
        \\10 Xword date
        \\11 Xsimple
        \\12 Xexit
        \\13 Xword echo
        \\14 Xsimple
        \\15 Xreturn
        \\
    );
}

test "compile errors" {
    setup();
    syn.compile = &code.compile;
    defer syn.compile = &keep;
    try expectError("if not echo\n", "t:2: `if not' does not follow `if(...)'\n");
    try expectError("switch(x){echo}\n", "t:2: case missing in switch\n");
}

fn compileFree(t: ?*rc.Tree) bool {
    if (!code.compile(t))
        return false;
    const c = code.codebuf.?;
    c.ref = 1;
    code.codefree(c);
    ncmds += 1;
    return true;
}

test "9front's scripts compile" {
    setup();
    syn.compile = &compileFree;
    defer syn.compile = &keep;
    var dir = std.Io.Dir.cwd().openDir(testing.io, "ref/src/rc/bin", .{ .iterate = true }) catch return error.SkipZigTest;
    defer dir.close(testing.io);
    var it = dir.iterate();
    ncmds = 0;
    while (try it.next(testing.io)) |e| {
        if (e.kind != .file) continue;
        const text = try dir.readFileAlloc(testing.io, e.name, testing.allocator, .limited(1 << 20));
        defer testing.allocator.free(text);
        if (!std.mem.startsWith(u8, text, "#!/bin/rc"))
            continue;
        const errs = parse(text, false);
        const m = takeErr();
        defer rc.a.free(m);
        if (errs != 0) {
            std.debug.print("{s}: {s}", .{ e.name, m });
            return error.TestUnexpectedResult;
        }
    }
    try testing.expect(ncmds > 1000);
}


const simple = @import("simple.zig");

var basecode: ?*code.Code = null;

/// Run text as rc runs a file of commands (execcmds), on top of an
/// interactive thread that errors unwind to; returns when it is read.
fn runText(text: []const u8) void {
    setup();
    syn.compile = &code.compile;
    defer syn.compile = &keep;
    const bc = basecode orelse blk: {
        const c = rc.new(code.Code);
        c.* = .{ .ref = 1, .file = null, .inst = rc.a.dupe(code.Inst, &.{.mark}) catch unreachable };
        basecode = c;
        break :blk c;
    };
    const base = rc.new(rc.Thread);
    base.* = .{ .iflag = true, .code = bc, .ret = exec.runq };
    exec.runq = base;
    simple.execcmds(io.openiocore(rc.estrdup(text)), rc.estrdup("t"), null, null);
    while (exec.runq != base) exec.step();
    exec.runq = base.ret;
    rc.destroy(base);
}

/// A variable's value, its words joined by spaces.
fn val(name: []const u8) []const u8 {
    const g = std.heap.smp_allocator;
    var s: std.ArrayList(u8) = .empty;
    var w = @"var".vlook(name).val;
    while (w) |x| : (w = x.next) {
        if (s.items.len > 0) s.append(g, ' ') catch unreachable;
        s.appendSlice(g, x.word) catch unreachable;
    }
    return s.items;
}

fn expectVal(name: []const u8, want: []const u8) !void {
    testing.expectEqualStrings(want, val(name)) catch |e| {
        std.debug.print("${s}\n", .{name});
        return e;
    };
}

test "run" {
    runText(
        \\x=(a b c)
        \\n=$#x
        \\y=$x(2-)
        \\y1=$x(3 1)
        \\z=pre-^$x
        \\q=$"x
        \\e=()
        \\ne=$#e
        \\fn f { r=$2 }
        \\f p q
        \\switch(b){case a; s=1; case b c; s=2; case *; s=3}
        \\~ abc a*; m=$status
        \\~ abc x*; m2=$status
        \\~ é [à-ê]; m3=$status
        \\if(~ a b) i=1
        \\if not i=2
        \\for(k in 1 2 3) acc=($acc $k)
        \\*=(a b c)
        \\while(! ~ $#* 0) { l=($l $1); shift }
        \\x=1 { inner=$x }
        \\eval 'ev=5; ev2=$ev'
        \\fn g { *=(1 2 3); shift 2; gs=$* }
        \\g
        \\t1=a^(1 2)^b
        \\cnt=$#t1
        \\
    );
    const msg = takeErr();
    defer rc.a.free(msg);
    try testing.expectEqualStrings("", msg);
    try expectVal("x", "a b c");
    try expectVal("n", "3");
    try expectVal("y", "b c");
    try expectVal("y1", "c a");
    try expectVal("z", "pre-a pre-b pre-c");
    try expectVal("q", "a b c");
    try expectVal("ne", "0");
    try expectVal("r", "q");
    try expectVal("s", "2");
    try expectVal("m", "");
    try expectVal("m2", "no match");
    try expectVal("m3", "");
    try expectVal("i", "2");
    try expectVal("acc", "1 2 3");
    try expectVal("l", "a b c");
    try expectVal("inner", "1");
    try expectVal("ev", "5");
    try expectVal("ev2", "5");
    try expectVal("gs", "3");
    try expectVal("t1", "a1b a2b");
    try expectVal("cnt", "2");
}

test "run errors" {
    runText("u=(a b c)^(1 2)\n");
    var msg = takeErr();
    try testing.expectEqualStrings("t:1: mismatched list lengths in concatenation\n", msg);
    rc.a.free(msg);
    try expectVal("status", "error");
    runText("w=(a b); $w=1\n");
    msg = takeErr();
    try testing.expectEqualStrings("t:1: = variable name not singleton!\n", msg);
    rc.a.free(msg);
}
