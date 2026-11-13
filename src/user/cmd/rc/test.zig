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
    exec.err = io.openiostr();
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

/// The error output so far, emptied.
fn takeErr() []u8 {
    const s = io.closeiostr(exec.err);
    exec.err = io.openiostr();
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
    try expectError("echo >[x] y\n", "t:1: token '>[x': redirection syntax\n");
    try expectError("a |[2=] b\n", "t:1: token '|[22=': pipe syntax\n");
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
