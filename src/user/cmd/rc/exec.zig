//! rc's interpreter: threads, the argument stack, words and the status.
//! from cmd/rc/exec.c
//!
//! In progress: so far the parts the lexer and the parser use.

const std = @import("std");
const rc = @import("rc.zig");
const io = @import("io.zig");
const @"var" = @import("var.zig");
const plan9 = @import("plan9.zig");

const Word = rc.Word;

pub var err: *io.Io = undefined;
pub var mypid: i32 = 0;
pub var runq: ?*rc.Thread = null;

pub fn Newword(s: []u8, next: ?*Word) *Word {
    const p = rc.new(Word);
    p.* = .{ .word = s, .next = next };
    return p;
}

pub fn newword(s: []const u8, next: ?*Word) *Word {
    return Newword(rc.estrdup(s), next);
}

pub fn Freeword(p: *Word) []u8 {
    const s = p.word;
    rc.destroy(p);
    return s;
}

pub fn freewords(w_: ?*Word) void {
    var w = w_;
    while (w) |p| {
        w = p.next;
        rc.a.free(Freeword(p));
    }
}

pub fn count(w_: ?*Word) i32 {
    var n: i32 = 0;
    var w = w_;
    while (w) |p| : (n += 1)
        w = p.next;
    return n;
}

var promptstr: []const u8 = "";

pub fn pprompt() void {
    if (!runq.?.iflag)
        return;

    plan9.Prompt(promptstr);
    @import("lex.zig").doprompt = false;

    const prompt = @"var".vlook("prompt").val;
    if (prompt != null and prompt.?.next != null)
        promptstr = prompt.?.next.?.word
    else
        promptstr = "\t";
}

pub fn Setstatus(s: ?[]u8) void {
    @"var".setvar("status", Newword(s orelse rc.estrdup(""), null));
}

pub fn setstatus(s: []const u8) void {
    Setstatus(rc.estrdup(s));
}

pub fn getstatus() []const u8 {
    const status = @"var".vlook("status");
    return if (status.val) |v| v.word else "";
}

pub fn truestatus() bool {
    for (getstatus()) |c|
        if (c != '|' and c != '0') return false;
    return true;
}
