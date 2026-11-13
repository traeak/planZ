//! rc's definitions and its small helpers.
//! from cmd/rc/rc.h, exec.h and subr.c
//!
//! DIFF:
//!   - Strings are slices that own their bytes (from `a`), not 0-ended
//!     C strings.  A byte the C would treat as the end of a string can
//!     not get into one here either: the lexer and the readers stop at
//!     the places the C's 0 would.
//!   - Unix is not ported: unix.c and the #ifdef branches are left out.

const std = @import("std");
pub const libc = @import("libc");
const io = @import("io.zig");
pub const tab = @import("syn_tab.zig");

/// rc's allocator: libc's malloc pool (the host tests give their own).
pub const a = libc.allocator;

pub const NSIG = 32;
pub const SIGINT = 2;
pub const SIGQUIT = 3;

pub const YYMAXDEPTH = 500;

// tokens, from y.tab.h; the single-character ones are themselves
pub const FOR = tab.FOR;
pub const IN = tab.IN;
pub const WHILE = tab.WHILE;
pub const IF = tab.IF;
pub const NOT = tab.NOT;
pub const TWIDDLE = tab.TWIDDLE;
pub const BANG = tab.BANG;
pub const SUBSHELL = tab.SUBSHELL;
pub const SWITCH = tab.SWITCH;
pub const FN = tab.FN;
pub const WORD = tab.WORD;
pub const REDIR = tab.REDIR;
pub const DUP = tab.DUP;
pub const PIPE = tab.PIPE;
pub const SUB = tab.SUB;
pub const SIMPLE = tab.SIMPLE;
pub const ARGLIST = tab.ARGLIST;
pub const WORDS = tab.WORDS;
pub const BRACE = tab.BRACE;
pub const PAREN = tab.PAREN;
pub const PCMD = tab.PCMD;
pub const PIPEFD = tab.PIPEFD;
pub const ANDAND = tab.ANDAND;
pub const OROR = tab.OROR;
pub const COUNT = tab.COUNT;

pub const Tree = struct {
    type: i32 = 0,
    rtype: i32 = 0, // details of REDIR PIPE DUP tokens
    fd0: i32 = 0,
    fd1: i32 = 0,
    line: i32 = 0,
    glob: u8 = 0, // 0=string, 1=glob, 2=pattern see globprop() and noglobs()
    quoted: bool = false,
    iskw: bool = false,
    str: ?[]u8 = null,
    child: [3]?*Tree = .{ null, null, null },
    next: ?*Tree = null,
};

pub const NTOK = 8192;

pub const Lexer = struct {
    input: *io.Io,
    file: ?[]u8,
    line: i32 = 1,

    prolog: []const u8 = "",
    epilog: []const u8 = "}\n",

    peekc: i32 = '{',
    future: i32 = io.EOF,
    lastc: i32 = 0,

    eof: bool = false,
    inquote: bool = false,
    incomm: bool = false,
    lastword: bool = false, // was the last token read a word or compound word terminator?
    lastdol: bool = false, // was the last token read '$' or '$#' or '"'?
    iflast: bool = false, // static `if not' checking

    qflag: bool = false,

    tok: [NTOK]u8 = undefined,
    /// The length of the token in tok (the C's string ends at a 0).
    ntok: usize = 0,

    pub fn token(l: *const Lexer) []const u8 {
        return l.tok[0..l.ntok];
    }
};

pub const APPEND = 1;
pub const WRITE = 2;
pub const READ = 3;
pub const HERE = 4;
pub const DUPFD = 5;
pub const CLOSE = 6;
pub const RDWR = 7;

/// word lists are in correct order, i.e. word0->word1->word2->word3->0
pub const Word = struct {
    word: []u8,
    next: ?*Word,
};

pub const List = struct {
    words: ?*Word,
    next: ?*List,
};

pub const Redir = struct {
    type: i32, // what to do
    from: i32, // what to do it to
    to: i32,
    next: ?*Redir, // what else to do (reverse order)
};

// redir types
pub const ROPEN = 1; // dup2(from, to); close(from);
pub const RDUP = 2; // dup2(from, to);
pub const RCLOSE = 3; // close(from);

/// A function's or a command's compiled code (code.zig); opaque here.
pub const Code = opaque {};

pub const Var = struct {
    next: ?*Var, // next on hash or local list
    val: ?*Word = null, // value
    @"fn": ?*Code = null, // pointer to function's code vector
    pc: i32 = 0, // pc of start of function
    fnchanged: bool = false,
    changed: bool = false,
    name: []u8,
};

pub const NVAR = 521;

pub const Thread = struct {
    code: ?*Code = null, // code for this thread
    pc: i32 = 0, // code[pc] is the next instruction
    line: i32 = 0, // source code line for Xsrcline
    argv: ?*List = null, // argument stack
    redir: ?*Redir = null, // redirection stack
    startredir: ?*Redir = null, // redir inheritance point
    local: ?*Var = null, // list of local variables
    lex: ?*Lexer = null, // lexer for Xrdcmds
    iflag: bool = false, // interactive?
    pid: i32 = 0, // process for Xpipewait to wait for
    status: ?[]u8 = null, // status for Xpipewait
    ret: ?*Thread = null, // who continues when this finishes
};

/// Glob character escape in strings:
///    In a string, GLOB must be followed by *?[ or GLOB.
///    GLOB* matches any string
///    GLOB? matches any single character
///    GLOB[...] matches anything in the brackets
///    GLOBGLOB matches GLOB
pub const GLOB: u8 = 0x01;

/// Is c the first character of a utf sequence?
pub fn onebyte(c: i32) bool {
    return c & 0x80 == 0x00;
}
pub fn twobyte(c: i32) bool {
    return c & 0xe0 == 0xc0;
}
pub fn threebyte(c: i32) bool {
    return c & 0xf0 == 0xe0;
}
pub fn fourbyte(c: i32) bool {
    return c & 0xf8 == 0xf0;
}
pub fn xbyte(c: i32) bool {
    return c & 0xc0 == 0x80;
}

/// Which fds are the reading/writing end of a pipe?
pub const PRD = 0;
pub const PWR = 1;

pub var argv0: []const u8 = "rc";

// subr.c

pub fn new(comptime T: type) *T {
    return a.create(T) catch panic("Can't malloc %d bytes", @sizeOf(T));
}

pub fn destroy(p: anytype) void {
    a.destroy(p);
}

pub fn emalloc(n: usize) []u8 {
    return a.alloc(u8, n) catch panic("Can't malloc %d bytes", n);
}

pub fn erealloc(p: []u8, n: usize) []u8 {
    return a.realloc(p, n) catch panic("Can't realloc %d bytes\n", n);
}

pub fn estrdup(s: []const u8) []u8 {
    const d = emalloc(s.len);
    @memcpy(d, s);
    return d;
}

pub fn free(s: ?[]u8) void {
    if (s) |p| a.free(p);
}

pub fn pfln(fd: *io.Io, file: ?[]const u8, line: i32) void {
    if (file != null and line != 0)
        io.pfmt(fd, "%s:%d", .{ file, line })
    else if (file) |f|
        io.pstr(fd, f)
    else
        io.pstr(fd, argv0);
}

/// inttoascii: n in decimal, as iacvt makes it.
pub fn inttoascii(buf: []u8, n_: i32) []u8 {
    var k: usize = 0;
    const S = struct {
        fn iacvt(b: []u8, kk: *usize, n0: i32) void {
            var n = n0;
            if (n < 0) {
                b[kk.*] = '-';
                kk.* += 1;
                n = -%n; // doesn't work for n==-inf
            }
            if (@divTrunc(n, 10) != 0)
                iacvt(b, kk, @divTrunc(n, 10));
            b[kk.*] = @intCast('0' + @rem(n, 10));
            kk.* += 1;
        }
    };
    S.iacvt(buf, &k, n_);
    return buf[0..k];
}

pub fn panic(comptime s: []const u8, n: anytype) noreturn {
    const exec = @import("exec.zig");
    io.pfmt(exec.err, "%s: ", .{argv0});
    io.pfmt(exec.err, s, .{@as(i32, @truncate(@as(i64, @intCast(n))))});
    io.pchr(exec.err, '\n');
    io.flushio(exec.err);
    @import("plan9.zig").Abort();
}
