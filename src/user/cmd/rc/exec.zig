//! rc's interpreter: threads, the argument stack, redirections, the
//! instructions, and main.
//! from cmd/rc/exec.c
//!
//! DIFF:
//!   - The instructions are code.zig's tagged union; step runs one with
//!     a switch, and each X function takes its operands as arguments
//!     where the C reads them from the words after the opcode (moving
//!     pc over them).  A pc is an instruction number, so where the C
//!     starts a thread at pc+1 or pc+2 (past the operands) this starts
//!     it at pc, already past the instruction.
//!   - The bootstrap and *rdcmds* code are built as Code at start up.

const std = @import("std");
const rc = @import("rc.zig");
const io = @import("io.zig");
const @"var" = @import("var.zig");
const plan9 = @import("plan9.zig");
const code = @import("code.zig");
const lex = @import("lex.zig");
const syn = @import("syn.zig");
const tree = @import("tree.zig");
const here = @import("here.zig");
const glob = @import("glob.zig");
const trap = @import("trap.zig");
const simple = @import("simple.zig");
const havefork = @import("havefork.zig");
const getflags = @import("getflags.zig");

const Word = rc.Word;
const Thread = rc.Thread;
const Var = rc.Var;
const Code = code.Code;
const Inst = code.Inst;
const pfmt = io.pfmt;
const flag = &getflags.flag;

pub var err: *io.Io = undefined;
/// Whether err is open yet (the C tests its pointer).
pub var err_open = false;
pub var mypid: i32 = 0;
pub var runq: ?*Thread = null;

/// The current thread; there always is one while code runs.
pub fn rq() *Thread {
    return runq.?;
}

/// Start executing the given code at the given pc with the given
/// redirection
pub fn start(c: *Code, pc: u32, local: ?*Var, redir: ?*rc.Redir) void {
    const p = rc.new(Thread);
    p.* = .{
        .code = code.codecopy(c),
        .pc = pc,
        .redir = redir,
        .startredir = redir,
        .local = local,
        .ret = runq,
    };
    runq = p;
}

pub fn startfunc(func: *Var, starval: ?*Word, local: ?*Var, redir: ?*rc.Redir) void {
    start(func.@"fn".?, func.pc, local, redir);
    const r = rq();
    r.local = @"var".newvar("*", r.local);
    r.local.?.val = starval;
    r.local.?.changed = true;
}

fn popthread() void {
    const p = rq();
    while (p.argv != null) poplist();
    while (p.local) |l| {
        if (p.ret != null and l == p.ret.?.local) break;
        Xunlocal();
    }
    runq = p.ret;
    if (p.lex) |l| lex.freelexer(l);
    code.codefree(p.code.?);
    rc.free(p.status);
    rc.destroy(p);
}

pub fn Newword(s: []u8, next: ?*Word) *Word {
    const p = rc.new(Word);
    p.* = .{ .word = s, .next = next };
    return p;
}

pub fn newword(s: []const u8, next: ?*Word) *Word {
    return Newword(rc.estrdup(s), next);
}

pub fn Pushword(s: []u8) *Word {
    const r = rq();
    const l = r.argv orelse rc.panic("pushword but no argv!", 0);
    const p = Newword(s, l.words);
    l.words = p;
    return p;
}

pub fn pushword(s: []const u8) *Word {
    return Pushword(rc.estrdup(s));
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

pub fn Popword() []u8 {
    const l = rq().argv orelse rc.panic("popword but no argv!", 0);
    const p = l.words orelse rc.panic("popword but no word!", 0);
    l.words = p.next;
    return Freeword(p);
}

pub fn popword() void {
    rc.a.free(Popword());
}

pub fn pushlist() void {
    const r = rq();
    const p = rc.new(rc.List);
    p.* = .{ .words = null, .next = r.argv };
    r.argv = p;
}

pub fn Poplist() ?*Word {
    const r = rq();
    const p = r.argv orelse rc.panic("poplist but no argv", 0);
    const w = p.words;
    r.argv = p.next;
    rc.destroy(p);
    return w;
}

pub fn poplist() void {
    freewords(Poplist());
}

pub fn count(w_: ?*Word) i32 {
    var n: i32 = 0;
    var w = w_;
    while (w) |p| : (n += 1)
        w = p.next;
    return n;
}

fn clobbersfd(rp_: ?*rc.Redir, fd: i32) bool {
    var rp = rp_;
    while (rp) |r| : (rp = r.next) {
        if (r.to == fd)
            return true;
    }
    return false;
}

pub fn pushredir(@"type": i32, from: i32, to: i32) void {
    const r = rq();
    // don't let dups clobber the from fd for file redirects
    if (@"type" == rc.ROPEN and clobbersfd(r.redir, from)) {
        pushredir(@"type", plan9.Dup1(from), to);
        plan9.Close(from);
        return;
    }

    const rp = rc.new(rc.Redir);
    rp.* = .{ .type = @"type", .from = from, .to = to, .next = r.redir };
    r.redir = rp;
}

pub fn dontclose(fd: i32) void {
    if (fd < 0)
        return;
    const r = rq();
    var rp_ = r.redir;
    while (rp_ != r.startredir) : (rp_ = rp_.?.next) {
        const rp = rp_.?;
        if (rp.type == rc.RCLOSE and rp.to == fd) {
            rp.to = -1;
            rp.type = 0;
            break;
        }
    }
}

/// we are about to start a new thread that should exit on return, so
/// the current stack is not needed anymore.  free all the threads and
/// lexers, but preserve the redirections and anything referenced by
/// local.
pub fn turfstack(local_: ?*Var) void {
    var local = local_;
    while (local) |l| {
        var p = runq;
        while (p) |t| : (p = t.ret) {
            if (t.local != l) break;
            t.local = l.next;
        }
        local = l.next;
    }
    while (runq) |r| {
        if (r.lex) |l| dontclose(l.input.fd);
        popthread();
    }
}

pub fn shuffleredir() void {
    const r = rq();
    const rp = r.redir orelse return;
    r.redir = rp.next;
    rp.next = r.startredir;
    var rr: *?*rc.Redir = &r.redir;
    while (rr.* != rp.next) rr = &rr.*.?.next;
    rr.* = rp;
}

var bootstrap: *Code = undefined;

/// get command line flags, initialize keywords & traps.  get values
/// from environment.  set $pid, $cflag, $*  fabricate bootstrap code and
/// start it (*=(argv);. -bq /usr/lib/rcmain $*)  start interpreting code
pub fn main(argv_: []const []const u8) noreturn {
    var rcmain: []const u8 = plan9.Rcmain;

    rc.argv0 = argv_[0];
    const argv = getflags.copyargv(argv_);
    const argc = getflags.getflags(argv, "srdiIlxebpvVc:1m:1[command]", true);
    if (argc == -1)
        getflags.usage("[file [arg ...]]");
    if (argv[0].?.len > 0 and argv[0].?[0] == '-')
        flag['l'] = getflags.flagset;
    if (flag['I'] != null)
        flag['i'] = null
    else if (flag['i'] == null and argc == 1 and plan9.Isatty(0))
        flag['i'] = getflags.flagset;
    if (flag['m']) |m| rcmain = m[0];
    err = io.openiofd(2);
    err_open = true;
    @"var".kinit();
    plan9.Trapinit();
    plan9.Vinit();
    mypid = @intCast(rc.libc.getpid());
    var num: [12]u8 = undefined;
    @"var".setvar("pid", newword(rc.inttoascii(&num, mypid), null));
    @"var".setvar("cflag", if (flag['c']) |c| newword(c[0], null) else null);
    @"var".setvar("rcname", newword(argv[0].?, null));
    const insts = [_]Inst{
        .mark,
        .{ .word = rc.estrdup("*") },
        .assign,
        .mark,
        .mark,
        .{ .word = rc.estrdup("*") },
        .dol,
        .{ .word = rc.estrdup(rcmain) },
        .{ .word = rc.estrdup("-bq") },
        .{ .word = rc.estrdup(".") },
        .simple,
        .exit,
    };
    bootstrap = rc.new(Code);
    bootstrap.* = .{
        .ref = 1,
        .file = rc.estrdup("*bootstrap*"),
        .inst = rc.a.dupe(Inst, &insts) catch rc.panic("Can't malloc %d bytes", 0),
    };
    start(bootstrap, 0, null, null);

    // prime bootstrap argv
    pushlist();
    var i: usize = @intCast(argc - 1);
    while (i != 0) : (i -= 1) _ = pushword(argv[i].?);

    while (true) {
        if (flag['r'] != null)
            pfnc(err, rq());
        step();
        if (trap.ntrap != 0)
            trap.dotrap();
    }
}

/// Run the next instruction of the current thread.
pub fn step() void {
    const r = rq();
    const i = r.code.?.inst[r.pc];
    r.pc += 1;
    switch (i) {
        .append => |fd| Xappend(fd),
        .assign => Xassign(),
        .async => |end| havefork.Xasync(end),
        .backq => |end| havefork.Xbackq(end),
        .bang => Xbang(),
        .builtin => |b| simple.run(b),
        .case => |next| Xcase(next),
        .close => |fd| Xclose(fd),
        .conc => Xconc(),
        .count => Xcount(),
        .delfn => Xdelfn(),
        .dol => Xdol(),
        .dup => |d| Xdup(d.fd0, d.fd1),
        .eflag => Xeflag(),
        .exit => Xexit(),
        .false => |to| Xfalse(to),
        .@"fn" => |f| Xfn(f.end),
        .@"for" => |end| Xfor(end),
        .glob => Xglob(),
        .here => |h| Xhere(h.str, h.fd),
        .hereq => |h| Xhereq(h.str, h.fd),
        .@"if" => |to| Xif(to),
        .ifnot => |to| Xifnot(to),
        .jump => |to| Xjump(to),
        .local => Xlocal(),
        .mark => Xmark(),
        .match => Xmatch(),
        .pipe => |p| havefork.Xpipe(p.fd0, p.fd1, p.right, p.end),
        .pipefd => |p| havefork.Xpipefd(p.rtype, p.end),
        .pipewait => Xpipewait(),
        .popm => Xpopm(),
        .popredir => Xpopredir(),
        .push => Xpush(),
        .qw => Xqw(),
        .rdcmds => Xrdcmds(),
        .rdwr => |fd| Xrdwr(fd),
        .read => |fd| Xread(fd),
        .@"return" => Xreturn(),
        .settrue => Xsettrue(),
        .simple => simple.Xsimple(),
        .srcline => |l| Xsrcline(l),
        .sub => Xsub(),
        .subshell => |end| havefork.Xsubshell(end),
        .true => |to| Xtrue(to),
        .unlocal => Xunlocal(),
        .wastrue => Xwastrue(),
        .word => |w| Xword(w),
        .write => |fd| Xwrite(fd),
    }
}

// Opcode routines
// Arguments on stack (...)
// Arguments in line [...]
// Code in line with jump around {...}
//
// Xappend(file)[fd]            open file to append
// Xassign(name, val)            assign val to name
// Xasync{... Xexit}            make thread for {}, no wait
// Xbackq(split){... Xreturn}        make thread for {}, push stdout
// Xbang                complement condition
// Xcase(pat, value){...}        exec code on match, leave (value) on
//                     stack
// Xclose[i]                close file descriptor
// Xconc(left, right)            concatenate, push results
// Xcount(name)                push var count
// Xdelfn(name)                delete function definition
// Xdol(name)                get variable value
// Xdup[i j]                dup file descriptor
// Xexit                rc exits with status
// Xfalse{...}                execute {} if false
// Xfn(name){... Xreturn}        define function
// Xfor(var, list){... Xreturn}        for loop
// Xglob(list)                glob a list of words inplace
// Xjump[addr]                goto
// Xlocal(name, val)            create local variable, assign value
// Xmark                mark stack
// Xmatch(pat, str)            match pattern, set status
// Xpipe[i j]{... Xreturn}{... Xreturn}    construct a pipe between 2 new threads,
//                     wait for both
// Xpipefd[type]{... Xreturn}        connect {} to pipe (input or output,
//                     depending on type), push /dev/fd/??
// Xpopm(value)                pop value from stack
// Xpush(words)                push words down a list
// Xqw(words)                quote words inplace
// Xrdwr(file)[fd]            open file for reading and writing
// Xread(file)[fd]            open file to read
// Xreturn                kill thread
// Xsimple(args)            run command and wait
// Xsrcline[line]            set current source line number
// Xsubshell{... Xexit}            execute {} in a subshell and wait
// Xtrue{...}                execute {} if true
// Xunlocal                delete local variable
// Xword[string]            push string
// Xwrite(file)[fd]            open file to write

/// The single file name of a redirection, or null after the error.
fn redirfile(comptime op: []const u8) ?[]const u8 {
    switch (count(rq().argv.?.words)) {
        0 => {
            Xerror1(op ++ " requires file");
            return null;
        },
        1 => return rq().argv.?.words.?.word,
        else => {
            Xerror1(op ++ " requires singleton");
            return null;
        },
    }
}

fn Xappend(to: i32) void {
    const file = redirfile(">>") orelse return;
    var fd = plan9.Open(file, 1);
    if (fd < 0) {
        fd = plan9.Creat(file);
        if (fd < 0) {
            Xerror3(">> can't open", file, plan9.Errstr());
            return;
        }
    }
    _ = plan9.Seek(fd, 0, 2);
    pushredir(rc.ROPEN, fd, to);
    poplist();
}

fn Xsettrue() void {
    setstatus("");
}

fn Xbang() void {
    setstatus(if (truestatus()) "false" else "");
}

fn Xclose(fd: i32) void {
    pushredir(rc.RCLOSE, -1, fd);
}

fn Xdup(from: i32, to: i32) void {
    pushredir(rc.RDUP, from, to);
}

fn Xeflag() void {
    if (!truestatus()) Xexit();
}

var trapped = false;

pub fn trapexit() ?*Var {
    if (@as(i32, @intCast(rc.libc.getpid())) == mypid and !trapped) {
        const t = @"var".vlook("sigexit");
        if (t.@"fn" != null)
            return t;
    }
    return null;
}

pub fn Xexit() void {
    const t = trapexit() orelse plan9.Exit();
    if (runq) |r| r.pc -= 1;
    startfunc(t, copywords(@"var".vlook("*").val, null), null, null);
    trapped = true;
}

fn Xfalse(to: u32) void {
    if (truestatus()) rq().pc = to;
}

pub var ifnot = false; // dynamic if not flag

fn Xifnot(to: u32) void {
    if (!ifnot)
        rq().pc = to;
}

fn Xjump(to: u32) void {
    rq().pc = to;
}

fn Xmark() void {
    pushlist();
}

fn Xpopm() void {
    poplist();
}

fn Xpush() void {
    const h = Poplist().?;
    var t = h;
    while (t.next) |n| t = n;
    const l = rq().argv.?;
    t.next = l.words;
    l.words = h;
}

var ser: u32 = 0;

/// Create a file named like tmp, its Y's a serial number and its X's
/// the pid; tmp is set to the name used.
fn herefile(tmp: []u8) i32 {
    var s: usize = tmp.len - 1;
    var i = ser;
    ser += 1;
    while (tmp[s] == 'Y') : (s -= 1) {
        tmp[s] = @intCast(i % 26 + 'A');
        i = i / 26;
    }
    var p: u32 = rc.libc.getpid();
    while (tmp[s] == 'X') : (s -= 1) {
        tmp[s] = @intCast(p % 10 + '0');
        p = p / 10;
    }
    s += 1;
    var c: u8 = 'a';
    while (c < 'z') : (c += 1) {
        if (!rc.libc.access(tmp, 0)) {
            const fd = plan9.Creat(tmp);
            if (fd >= 0)
                return fd;
        }
        tmp[s] = c;
    }
    return -1;
}

fn Xhere(body: []u8, to: i32) void {
    var file = "/tmp/hereXXXXXXXXXXYY".*;
    var fd = herefile(&file);
    if (fd < 0) {
        Xerror3("<< can't get temp file", &file, plan9.Errstr());
        return;
    }
    const f = io.openiofd(fd);
    here.psubst(f, body);
    io.flushio(f);
    io.closeio(f);

    // open for reading and unlink
    fd = plan9.Open(&file, 3);
    if (fd < 0) {
        Xerror3("<< can't open", &file, plan9.Errstr());
        return;
    }
    pushredir(rc.ROPEN, fd, to);
}

fn Xhereq(body: []u8, to: i32) void {
    var file = "/tmp/hereXXXXXXXXXXYY".*;
    var fd = herefile(&file);
    if (fd < 0) {
        Xerror3("<< can't get temp file", &file, plan9.Errstr());
        return;
    }
    _ = plan9.Write(fd, body);
    plan9.Close(fd);

    // open for reading and unlink
    fd = plan9.Open(&file, 3);
    if (fd < 0) {
        Xerror3("<< can't open", &file, plan9.Errstr());
        return;
    }
    pushredir(rc.ROPEN, fd, to);
}

fn Xread(to: i32) void {
    const file = redirfile("<") orelse return;
    const fd = plan9.Open(file, 0);
    if (fd < 0) {
        Xerror3("< can't open", file, plan9.Errstr());
        return;
    }
    pushredir(rc.ROPEN, fd, to);
    poplist();
}

fn Xrdwr(to: i32) void {
    const file = redirfile("<>") orelse return;
    const fd = plan9.Open(file, 2);
    if (fd < 0) {
        Xerror3("<> can't open", file, plan9.Errstr());
        return;
    }
    pushredir(rc.ROPEN, fd, to);
    poplist();
}

pub fn Xpopredir() void {
    const r = rq();
    const rp = r.redir orelse rc.panic("Xpopredir null!", 0);
    r.redir = rp.next;
    if (rp.type == rc.ROPEN)
        plan9.Close(rp.from);
    rc.destroy(rp);
}

pub fn Xreturn() void {
    while (rq().redir != rq().startredir)
        Xpopredir();
    popthread();
    if (runq == null)
        Xexit();
}

fn Xtrue(to: u32) void {
    if (!truestatus()) rq().pc = to;
}

fn Xif(to: u32) void {
    ifnot = true;
    if (!truestatus()) rq().pc = to;
}

fn Xwastrue() void {
    ifnot = false;
}

fn Xword(w: []const u8) void {
    _ = pushword(w);
}

fn Xwrite(to: i32) void {
    const file = redirfile(">") orelse return;
    const fd = plan9.Creat(file);
    if (fd < 0) {
        Xerror3("> can't create", file, plan9.Errstr());
        return;
    }
    pushredir(rc.ROPEN, fd, to);
    poplist();
}

fn Xmatch() void {
    setstatus("no match");
    const r = rq();
    const s = r.argv.?.words.?.word;
    var p_ = r.argv.?.next.?.words;
    while (p_) |p| : (p_ = p.next) {
        if (glob.match(s, p.word, 0)) {
            setstatus("");
            break;
        }
    }
    poplist();
    poplist();
}

fn Xcase(next: u32) void {
    const r = rq();
    const s = r.argv.?.next.?.words.?.word;
    var ok = false;
    var p_ = r.argv.?.words;
    while (p_) |p| : (p_ = p.next) {
        if (glob.match(s, p.word, 0)) {
            ok = true;
            break;
        }
    }
    if (!ok)
        r.pc = next;
    poplist();
}

fn conclist(lp_: *Word, rp_: *Word, tail: ?*Word) ?*Word {
    var lp = lp_;
    var rp = rp_;
    var v: ?*Word = null;
    var end: *?*Word = &v;
    while (true) {
        const s = rc.emalloc(lp.word.len + rp.word.len);
        @memcpy(s[0..lp.word.len], lp.word);
        @memcpy(s[lp.word.len..], rp.word);
        const p = Newword(s, null);
        end.* = p;
        end = &p.next;
        if (lp.next == null and rp.next == null)
            break;
        if (lp.next) |n| lp = n;
        if (rp.next) |n| rp = n;
    }
    end.* = tail;
    return v;
}

fn Xconc() void {
    const r = rq();
    const lp = r.argv.?.words;
    const rp = r.argv.?.next.?.words;
    var vp = r.argv.?.next.?.next.?.words;
    const lc = count(lp);
    const rcn = count(rp);
    if (lc != 0 or rcn != 0) {
        if (lc == 0 or rcn == 0) {
            Xerror1("null list in concatenation");
            return;
        }
        if (lc != 1 and rcn != 1 and lc != rcn) {
            Xerror1("mismatched list lengths in concatenation");
            return;
        }
        vp = conclist(lp.?, rp.?, vp);
    }
    poplist();
    poplist();
    rq().argv.?.words = vp;
}

fn Xassign() void {
    if (count(rq().argv.?.words) != 1) {
        Xerror1("= variable name not singleton!");
        return;
    }
    const v = @"var".vlook(rq().argv.?.words.?.word);
    poplist();
    freewords(v.val);
    v.val = Poplist();
    v.changed = true;
}

/// copy arglist a, adding the copy to the front of tail
pub fn copywords(a_: ?*Word, tail: ?*Word) ?*Word {
    var v: ?*Word = null;
    var end: *?*Word = &v;
    var a = a_;
    while (a) |w| : (a = w.next) {
        const n = newword(w.word, null);
        end.* = n;
        end = &n.next;
    }
    end.* = tail;
    return v;
}

/// The number the word is, if it is all digits (0 when it is not).
fn digits(s: []const u8) struct { n: i32, rest: usize } {
    var n: i32 = 0;
    var t: usize = 0;
    while (t < s.len and '0' <= s[t] and s[t] <= '9') : (t += 1)
        n = n *% 10 +% (s[t] - '0');
    return .{ .n = n, .rest = s.len - t };
}

fn Xdol() void {
    if (count(rq().argv.?.words) != 1) {
        Xerror1("$ variable name not singleton!");
        return;
    }
    const s = rq().argv.?.words.?.word;
    const d = digits(s);
    var n = d.n;
    var a = rq().argv.?.next.?.words;
    if (n == 0 or d.rest != 0)
        a = copywords(@"var".vlook(s).val, a)
    else {
        var star = @"var".vlook("*").val;
        if (star != null and 1 <= n and n <= count(star)) {
            n -= 1;
            while (n > 0) : (n -= 1) star = star.?.next;
            a = newword(star.?.word, a);
        }
    }
    poplist();
    rq().argv.?.words = a;
}

pub fn Xqw() void {
    const a = rq().argv.?.words orelse {
        _ = pushword("");
        return;
    };
    if (a.next == null)
        return;
    var n: usize = 0;
    var p_: ?*Word = a;
    while (p_) |p| : (p_ = p.next)
        n += 1 + p.word.len;
    const s = rc.emalloc(n - 1);
    var d: usize = 0;
    @memcpy(s[0..a.word.len], a.word);
    d += a.word.len;
    p_ = a.next;
    while (p_) |p| : (p_ = p.next) {
        s[d] = ' ';
        d += 1;
        @memcpy(s[d..][0..p.word.len], p.word);
        d += p.word.len;
    }
    rc.a.free(a.word);
    freewords(a.next);
    a.word = s;
    a.next = null;
}

fn copynwords(a_: *Word, tail: ?*Word, n_: i32) ?*Word {
    var v: ?*Word = null;
    var end: *?*Word = &v;
    var a: ?*Word = a_;
    var n = n_;
    while (n > 0) : (n -= 1) {
        const w = newword(a.?.word, null);
        end.* = w;
        end = &w.next;
        a = a.?.next;
    }
    end.* = tail;
    return v;
}

fn subwords(val_: ?*Word, len: i32, sub_: ?*Word, a_: ?*Word) ?*Word {
    const sub = sub_ orelse return a_;
    const a = subwords(val_, len, sub.next, a_);
    const s = sub.word;
    var k: usize = 0;
    var m: i32 = 0;
    var n: i32 = 0;
    while (k < s.len and '0' <= s[k] and s[k] <= '9') : (k += 1)
        n = n *% 10 +% (s[k] - '0');
    if (k < s.len and s[k] == '-') {
        k += 1;
        if (k == s.len)
            m = len - n
        else {
            while (k < s.len and '0' <= s[k] and s[k] <= '9') : (k += 1)
                m = m *% 10 +% (s[k] - '0');
            m -= n;
        }
    }
    if (n < 1 or n > len or m < 0)
        return a;
    if (n + m > len)
        m = len - n;
    var val = val_;
    n -= 1;
    while (n > 0) : (n -= 1) val = val.?.next;
    return copynwords(val.?, a, m + 1);
}

fn Xsub() void {
    if (count(rq().argv.?.next.?.words) != 1) {
        Xerror1("$() variable name not singleton!");
        return;
    }
    const s = rq().argv.?.next.?.words.?.word;
    var a = rq().argv.?.next.?.next.?.words;
    const v = @"var".vlook(s).val;
    a = subwords(v, count(v), rq().argv.?.words, a);
    poplist();
    poplist();
    rq().argv.?.words = a;
}

fn Xcount() void {
    if (count(rq().argv.?.words) != 1) {
        Xerror1("$# variable name not singleton!");
        return;
    }
    var num: [12]u8 = undefined;
    var str: []u8 = undefined;
    const s = rq().argv.?.words.?.word;
    const d = digits(s);
    if (d.n == 0 or d.rest != 0) {
        str = rc.inttoascii(&num, count(@"var".vlook(s).val));
    } else {
        const a = @"var".vlook("*").val;
        str = rc.inttoascii(&num, if (a != null and 1 <= d.n and d.n <= count(a)) 1 else 0);
    }
    poplist();
    _ = pushword(str);
}

fn Xlocal() void {
    if (count(rq().argv.?.words) != 1) {
        Xerror1("local variable name must be singleton");
        return;
    }
    const r = rq();
    r.local = @"var".newvar(r.argv.?.words.?.word, r.local);
    poplist();
    r.local.?.val = Poplist();
    r.local.?.changed = true;
}

pub fn Xunlocal() void {
    const r = rq();
    const v = r.local orelse rc.panic("Xunlocal: no locals!", 0);
    r.local = v.next;
    const hid = @"var".vlook(v.name);
    hid.changed = true;
    @"var".freevar(v);
}

fn Xfn(end: u32) void {
    const r = rq();
    const pc = r.pc; // the body, after this instruction
    r.pc = end;
    var a_ = r.argv.?.words;
    while (a_) |a| : (a_ = a.next) {
        const v = @"var".gvlook(a.word);
        if (v.@"fn") |f|
            code.codefree(f);
        v.@"fn" = code.codecopy(r.code.?);
        v.pc = pc;
        v.fnchanged = true;
    }
    poplist();
}

fn Xdelfn() void {
    var a_ = rq().argv.?.words;
    while (a_) |a| : (a_ = a.next) {
        const v = @"var".gvlook(a.word);
        if (v.@"fn") |f|
            code.codefree(f);
        v.@"fn" = null;
        v.fnchanged = true;
    }
    poplist();
}

fn concstatus(s_: ?[]u8, t_: ?[]u8) ?[]u8 {
    const t = t_ orelse return s_;
    const s = s_ orelse return t;
    var n = s.len;
    const m = t.len;
    const extra: usize = if (n > 0) 1 else 0;
    const r = rc.erealloc(s, n + extra + m);
    if (n > 0) {
        r[n] = '|';
        n += 1;
    }
    @memcpy(r[n..][0..m], t);
    rc.a.free(t);
    return r;
}

fn Xpipewait() void {
    const old = Getstatus();
    const r = rq();
    if (r.pid == -1) {
        Setstatus(concstatus(r.status, old));
        r.status = null;
    } else {
        while (plan9.Waitfor(r.pid) < 0) {}
        r.pid = -1;
        Setstatus(concstatus(Getstatus(), old));
    }
}

var promptstr: []const u8 = "";

fn Xrdcmds() void {
    const p = rq();

    if (flag['s'] != null and !truestatus())
        pfmt(err, "status=%v\n", .{@"var".vlook("status").val});
    io.flushio(err);

    lex.lex = p.lex;
    const l = p.lex.?;
    if (p.iflag) {
        const prompt = @"var".vlook("prompt").val;
        promptstr = if (prompt) |pr| pr.word else "% ";
    }
    plan9.Noerror();
    lex.nerror = 0;
    if (syn.yyparse() != 0) {
        if (p.iflag and (!l.eof or plan9.Eintr())) {
            if (plan9.Eintr()) {
                io.pchr(err, '\n');
                l.eof = false;
            }
            p.pc -= 1; // go back for next command
        }
    } else {
        if (l.eof) {
            dontclose(l.input.fd);
            lex.freelexer(l);
            p.lex = null;
        } else p.pc -= 1; // re-execute Xrdcmds after codebuf runs
        trap.ntrap = 0; // avoid double-interrupts during blocked writes
        start(code.codebuf.?, 0, p.local, p.redir);
    }
    lex.lex = null;
    tree.freenodes();
}

pub fn pprompt() void {
    if (!rq().iflag)
        return;

    plan9.Prompt(promptstr);
    lex.doprompt = false;

    const prompt = @"var".vlook("prompt").val;
    if (prompt != null and prompt.?.next != null)
        promptstr = prompt.?.next.?.word
    else
        promptstr = "\t";
}

pub fn srcfile(p: *Thread) ?[]const u8 {
    return p.code.?.file;
}

pub fn Xerror1(s: []const u8) void {
    setstatus("error");
    rc.pfln(err, srcfile(rq()), rq().line);
    pfmt(err, ": %s\n", .{s});
    io.flushio(err);
    while (!rq().iflag) Xreturn();
}

pub fn Xerror2(s: []const u8, e: []const u8) void {
    setstatus(e);
    rc.pfln(err, srcfile(rq()), rq().line);
    pfmt(err, ": %s: %s\n", .{ s, e });
    io.flushio(err);
    while (!rq().iflag) Xreturn();
}

pub fn Xerror3(s: []const u8, m: []const u8, e: []const u8) void {
    setstatus(e);
    rc.pfln(err, srcfile(rq()), rq().line);
    pfmt(err, ": %s: %s: %s\n", .{ s, m, e });
    io.flushio(err);
    while (!rq().iflag) Xreturn();
}

pub fn Setstatus(s: ?[]u8) void {
    @"var".setvar("status", Newword(s orelse rc.estrdup(""), null));
}

pub fn setstatus(s: []const u8) void {
    Setstatus(rc.estrdup(s));
}

pub fn Getstatus() ?[]u8 {
    const status = @"var".vlook("status");
    const val = status.val orelse return null;
    status.val = null;
    status.changed = true;
    freewords(val.next);
    return Freeword(val);
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

fn Xfor(end: u32) void {
    const r = rq();
    const a = r.argv.?.words orelse {
        poplist();
        r.pc = end;
        return;
    };
    r.argv.?.words = a.next;
    a.next = null;
    freewords(r.local.?.val);
    r.local.?.val = a;
    r.local.?.changed = true;
}

fn Xglob() void {
    var a_ = rq().argv.?.words;
    while (a_) |a| {
        const x = a.next;
        glob.globword(a);
        a_ = x;
    }
}

fn Xsrcline(line: i32) void {
    rq().line = line;
}

/// The -r trace (pfnc.c): where, the pid, the code and the C's pc, the
/// instruction and the stack.
fn pfnc(f: *io.Io, t: *Thread) void {
    rc.pfln(f, srcfile(t), t.line);
    pfmt(f, " pid %d cycle %p %d ", .{ rc.libc.getpid(), t.code, t.code.?.wordpc(t.pc) });
    io.pstr(f, t.code.?.inst[t.pc].name());
    var a = t.argv;
    while (a) |l| : (a = l.next) pfmt(f, " (%v)", .{l.words});
    io.pchr(f, '\n');
    io.flushio(f);
}
