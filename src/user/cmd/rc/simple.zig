//! rc's simple commands and builtins.
//! from cmd/rc/simple.c, and plan9.c's builtin table, execfinit and
//! execrfork
//!
//! DIFF:
//!   - A builtin is a name in an enum, run by a switch, where the C's
//!     table holds function pointers.
//!   - Fixed from C: `flag` indexes its table with any byte; the C's
//!     table has 128 entries, so a letter from 0x80 up reads and writes
//!     past it.  The table has 256 here.

const std = @import("std");
const rc = @import("rc.zig");
const io = @import("io.zig");
const exec = @import("exec.zig");
const @"var" = @import("var.zig");
const plan9 = @import("plan9.zig");
const code = @import("code.zig");
const lex = @import("lex.zig");
const getflags = @import("getflags.zig");
const havefork = @import("havefork.zig");

const Word = rc.Word;
const pfmt = io.pfmt;
const rq = exec.rq;
const flag = &getflags.flag;

/// plan9.c's Builtin table, in its order.
pub const Builtin = enum {
    cd,
    whatis,
    eval,
    exec,
    exit,
    shift,
    wait,
    dot,
    flag,
    finit,
    rfork,

    pub fn name(b: Builtin) []const u8 {
        return switch (b) {
            .dot => ".",
            inline else => |tag| @tagName(tag),
        };
    }
};

pub fn builtinfunc(name: []const u8) ?Builtin {
    for (std.enums.values(Builtin)) |b| {
        if (std.mem.eql(u8, name, b.name()))
            return b;
    }
    return null;
}

/// Run a builtin, as the C calls its function.
pub fn run(b: Builtin) void {
    switch (b) {
        .cd => execcd(),
        .whatis => execwhatis(),
        .eval => execeval(),
        .exec => execexec(),
        .exit => execexit(),
        .shift => execshift(),
        .wait => execwait(),
        .dot => execdot(),
        .flag => execflag(),
        .finit => execfinit(),
        .rfork => execrfork(),
    }
}

/// libc's atoi: strtol(s, nil, 10), a 32-bit long.
fn atoi(s: []const u8) i32 {
    return rc.libc.strtol32(s, 10).v;
}

/// Search through the following code to see if we're just going to exit.
pub fn exitnext() bool {
    var i = exec.ifnot;
    var p = rq();
    var c = p.pc;
    while (true) {
        switch (p.code.?.inst[c]) {
            .popredir, .unlocal, .eflag, .srcline => c += 1,
            .wastrue => {
                c += 1;
                i = false;
            },
            .ifnot => |to| {
                if (i)
                    c += 1
                else
                    c = to;
            },
            .@"return" => {
                p = p.ret orelse return true;
                c = p.pc;
            },
            .exit => return true,
            else => return false,
        }
    }
}

pub fn Xsimple() void {
    var a = rq().argv.?.words orelse {
        exec.Xerror1("empty argument list");
        return;
    };
    if (flag['x'] != null)
        pfmt(exec.err, "%v\n", .{a}); // wrong, should do redirs
    const v = @"var".gvlook(a.word);
    if (v.@"fn" != null)
        execfunc(v)
    else {
        if (std.mem.eql(u8, a.word, "builtin")) {
            a = a.next orelse {
                exec.Xerror1("builtin: empty argument list");
                return;
            };
            exec.popword(); // "builtin"
        }
        if (builtinfunc(a.word)) |f| {
            run(f);
            return;
        }
        if (exitnext() and exec.trapexit() == null) {
            // fork and wait is redundant
            _ = exec.pushword("exec");
            execexec();
            // does not return
        } else {
            const pid = havefork.execforkexec();
            if (pid < 0) {
                exec.Xerror2("try again", plan9.Errstr());
                return;
            }
            exec.poplist();

            // interrupts don't get us out
            while (plan9.Waitfor(pid) < 0) {}
        }
    }
}

fn doredir(rp_: ?*rc.Redir) void {
    const rp = rp_ orelse return;

    doredir(rp.next);

    switch (rp.type) {
        rc.RDUP => _ = plan9.Dup(rp.from, rp.to),
        rc.ROPEN => {
            if (rp.from != rp.to) {
                _ = plan9.Dup(rp.from, rp.to);
                plan9.Close(rp.from);
            }
        },
        rc.RCLOSE => plan9.Close(rp.to),
        else => {},
    }
}

var nullpath_s: [0]u8 = .{};
var nullpath: Word = .{ .word = &nullpath_s, .next = null };

pub fn searchpath(w: []const u8, v: []const u8) ?*Word {
    const at = struct {
        fn f(s: []const u8, i: usize) u8 {
            return if (i < s.len) s[i] else 0;
        }
    }.f;
    if (at(w, 0) != 0 and w[0] != '/' and w[0] != '#' and
        (w[0] != '.' or (at(w, 1) != 0 and w[1] != '/' and (w[1] != '.' or at(w, 2) != 0 and w[2] != '/'))))
    {
        if (@"var".vlook(v).val) |path|
            return path;
    }
    return &nullpath;
}

pub fn makepath(dir: []const u8, file_: []const u8) []u8 {
    var n = dir.len;
    if (n == 0) return rc.estrdup(file_);
    while (n > 0 and dir[n - 1] == '/') n -= 1;
    var file = file_;
    while (file.len > 0 and file[0] == '/') file = file[1..];
    const path = rc.emalloc(n + 1 + file.len);
    @memcpy(path[0..n], dir[0..n]);
    path[n] = '/';
    @memcpy(path[n + 1 ..], file);
    return path;
}

fn mkargv(a_: ?*Word) [][]const u8 {
    const argv = rc.a.alloc([]const u8, @intCast(exec.count(a_) + 1)) catch rc.panic("Can't malloc %d bytes", 0);
    var k: usize = 1;
    var a = a_;
    while (a) |w| : (a = w.next) {
        argv[k] = w.word;
        k += 1;
    }
    return argv;
}

pub fn execexec() void {
    exec.popword(); // "exec"
    const words = rq().argv.?.words orelse {
        exec.Xerror1("exec: empty argument list");
        return;
    };
    const argv = mkargv(words);
    plan9.Updenv();
    doredir(rq().redir);
    var path = searchpath(argv[1], "path");
    while (path) |p| : (path = p.next) {
        argv[0] = makepath(p.word, argv[1]);
        plan9.Exec(argv);
    }
    exec.setstatus(plan9.Errstr());
    rc.pfln(exec.err, exec.srcfile(rq()), rq().line);
    pfmt(exec.err, ": %s: %s\n", .{ argv[1], exec.getstatus() });
    exec.Xexit();
}

pub fn execfunc(func: *rc.Var) void {
    exec.popword(); // name
    exec.startfunc(func, exec.Poplist(), rq().local, rq().redir);
}

fn execcd() void {
    var a = rq().argv.?.words;

    exec.setstatus("can't cd");
    switch (exec.count(a)) {
        2 => {
            a = a.?.next;
            var cdpath = searchpath(a.?.word, "cdpath");
            while (cdpath) |c| : (cdpath = c.next) {
                const dir = makepath(c.word, a.?.word);
                if (plan9.Chdir(dir) >= 0) {
                    if (c.word.len != 0 and !std.mem.eql(u8, c.word, "."))
                        pfmt(exec.err, "%s\n", .{dir});
                    rc.a.free(dir);
                    exec.setstatus("");
                    break;
                }
                rc.a.free(dir);
            }
            if (cdpath == null)
                pfmt(exec.err, "Can't cd %s: %s\n", .{ a.?.word, plan9.Errstr() });
        },
        1 => {
            if (@"var".vlook("home").val) |h| {
                if (plan9.Chdir(h.word) >= 0)
                    exec.setstatus("")
                else
                    pfmt(exec.err, "Can't cd %s: %s\n", .{ h.word, plan9.Errstr() });
            } else pfmt(exec.err, "Can't cd -- $home empty\n", .{});
        },
        else => pfmt(exec.err, "Usage: cd [directory]\n", .{}),
    }
    exec.poplist();
}

fn execexit() void {
    const n = exec.count(rq().argv.?.words);
    if (n > 2)
        pfmt(exec.err, "Usage: exit [status]\nExiting anyway\n", .{});
    if (n >= 2)
        exec.setstatus(rq().argv.?.words.?.next.?.word);
    exec.Xexit();
}

fn execshift() void {
    var n: i32 = undefined;
    switch (exec.count(rq().argv.?.words)) {
        2 => n = atoi(rq().argv.?.words.?.next.?.word),
        1 => n = 1,
        else => {
            pfmt(exec.err, "Usage: shift [n]\n", .{});
            exec.setstatus("shift usage");
            exec.poplist();
            return;
        },
    }
    const star = @"var".vlook("*");
    while (n > 0 and star.val != null) : (n -= 1) {
        const a = star.val.?.next;
        rc.a.free(exec.Freeword(star.val.?));
        star.val = a;
        star.changed = true;
    }
    exec.setstatus("");
    exec.poplist();
}

fn mapfd(fd_: i32) i32 {
    var fd = fd_;
    var rp_ = rq().redir;
    while (rp_) |rp| : (rp_ = rp.next) {
        if (rp.to == fd)
            fd = rp.from;
    }
    return fd;
}

var rdcmds: ?*code.Code = null;

pub fn execcmds(input: *io.Io, file: ?[]u8, local: ?*rc.Var, redir: ?*rc.Redir) void {
    const rd = rdcmds orelse blk: {
        const c = rc.new(code.Code);
        c.* = .{
            .ref = 1,
            .file = rc.estrdup("*rdcmds*"),
            .inst = rc.a.dupe(code.Inst, &.{ .rdcmds, .@"return" }) catch rc.panic("Can't malloc %d bytes", 0),
        };
        rdcmds = c;
        break :blk c;
    };

    if (exitnext()) exec.turfstack(local);

    exec.start(rd, 0, local, redir);
    rq().lex = lex.newlexer(input, file);
}

fn execeval() void {
    exec.popword(); // "eval"

    if (rq().argv.?.words == null) {
        exec.Xerror1("Usage: eval cmd ...");
        return;
    }
    exec.Xqw(); // make into single word
    const w = exec.Popword();
    const cmds = rc.erealloc(w, w.len + 1);
    cmds[cmds.len - 1] = '\n';
    exec.poplist();

    const f = io.openiostr();
    rc.pfln(f, exec.srcfile(rq()), rq().line);
    io.pstr(f, " *eval*");

    execcmds(io.openiocore(cmds), io.closeiostr(f), rq().local, rq().redir);
}

fn execdot() void {
    exec.popword(); // "."

    var bflag = false;
    var iflag = false;
    var qflag = false;
    usage: {
        while (rq().argv.?.words) |w| {
            if (w.word.len == 0 or w.word[0] != '-') break;
            const f = w.word[1..];
            if (f.len > 0 and f[0] == '-') {
                exec.popword();
                break;
            }
            for (f) |c| {
                switch (c) {
                    'b' => bflag = true,
                    'i' => iflag = true,
                    'q' => qflag = true,
                    else => break :usage,
                }
            }
            exec.popword();
        }

        // get input file
        if (rq().argv.?.words == null)
            break :usage;
        const argv = exec.Poplist().?;

        var file: ?[]u8 = null;
        var fd: i32 = -1;
        var path = searchpath(argv.word, "path");
        while (path) |p| : (path = p.next) {
            file = makepath(p.word, argv.word);
            fd = plan9.Open(file.?, 0);
            if (fd >= 0)
                break;
            if (std.mem.eql(u8, file.?, "/dev/stdin")) { // for sun & ucb
                fd = plan9.Dup1(0);
                if (fd >= 0)
                    break;
            }
            rc.a.free(file.?);
        }
        if (fd < 0) {
            if (!qflag)
                exec.Xerror3(". can't open", argv.word, plan9.Errstr());
            exec.freewords(argv);
            return;
        }

        execcmds(io.openiofd(fd), file, null, rq().redir);
        exec.pushredir(rc.RCLOSE, -1, fd);
        const r = rq();
        r.lex.?.qflag = qflag;
        r.iflag = iflag;
        if (iflag or !bflag and flag['b'] == null) {
            r.lex.?.peekc = io.EOF;
            r.lex.?.epilog = "";
        }

        r.local = @"var".newvar("*", r.local);
        r.local.?.val = argv.next;
        argv.next = null;
        r.local.?.changed = true;

        r.local = @"var".newvar("0", r.local);
        r.local.?.val = argv;
        r.local.?.changed = true;
        return;
    }
    exec.Xerror1("Usage: . [-biq] file [arg ...]");
}

fn execflag() void {
    const w = rq().argv.?.words.?;
    switch (exec.count(w)) {
        2 => {
            const letter = w.next.?.word;
            const c: u8 = if (letter.len > 0) letter[0] else 0;
            exec.setstatus(if (flag[c] != null) "" else "flag not set");
        },
        3 => {
            const letter = w.next.?.word;
            const val = w.next.?.next.?.word;
            if (letter.len == 1 and std.mem.eql(u8, val, "+")) {
                flag[letter[0]] = getflags.flagset;
                exec.setstatus("");
            } else if (letter.len == 1 and std.mem.eql(u8, val, "-")) {
                flag[letter[0]] = null;
                exec.setstatus("");
            } else {
                exec.Xerror1("Usage: flag [letter] [+-]");
                return;
            }
        },
        else => {
            exec.Xerror1("Usage: flag [letter] [+-]");
            return;
        },
    }
    exec.poplist();
}

fn execwhatis() void { // mildly wrong -- should fork before writing
    var a_ = rq().argv.?.words.?.next;
    if (a_ == null) {
        exec.Xerror1("Usage: whatis name ...");
        return;
    }
    exec.setstatus("");
    const out = io.openiofd(mapfd(1));
    while (a_) |a| : (a_ = a.next) {
        var found = false;
        var v = @"var".vlook(a.word);
        if (v.val) |val| {
            pfmt(out, "%s=", .{a.word});
            if (val.next == null)
                pfmt(out, "%q\n", .{val.word})
            else {
                var sep: u8 = '(';
                var b_: ?*Word = val;
                while (b_) |b| : (b_ = b.next) {
                    pfmt(out, "%c%q", .{ sep, b.word });
                    sep = ' ';
                }
                io.pstr(out, ")\n");
            }
            found = true;
        }
        v = @"var".gvlook(a.word);
        if (v.@"fn") |f|
            pfmt(out, "fn %q %s\n", .{ v.name, f.inst[v.pc - 1].@"fn".str })
        else if (builtinfunc(a.word) != null)
            pfmt(out, "builtin %s\n", .{a.word})
        else {
            var path = searchpath(a.word, "path");
            while (path) |p| : (path = p.next) {
                const file = makepath(p.word, a.word);
                if (plan9.Executable(file)) {
                    pfmt(out, "%s\n", .{file});
                    rc.a.free(file);
                    break;
                }
                rc.a.free(file);
            }
            if (path == null and !found)
                exec.setstatus("not found");
        }
        io.flushio(out);
    }
    exec.poplist();
    rc.a.free(io.closeiostr(out)); // don't close fd
}

fn execwait() void {
    switch (exec.count(rq().argv.?.words)) {
        2 => _ = plan9.Waitfor(atoi(rq().argv.?.words.?.next.?.word)),
        1 => _ = plan9.Waitfor(-1),
        else => {
            exec.Xerror1("Usage: wait [pid]");
            return;
        },
    }
    exec.poplist();
}

/// finit could be removed but is kept for backwards compatibility, see:
/// rcmain.plan9
fn execfinit() void {
    const cmds = rc.estrdup("for(i in '/env/fn#'*){. -bq $i}\n");
    const line = rq().line;
    exec.poplist();
    execcmds(io.openiocore(cmds), if (exec.srcfile(rq())) |f| rc.estrdup(f) else null, rq().local, rq().redir);
    rq().lex.?.line = line;
    rq().lex.?.qflag = true;
}

fn execrfork() void {
    const L = rc.libc.sys;
    var arg: u32 = 0;
    const w = rq().argv.?.words.?;
    usage: {
        switch (exec.count(w)) {
            1 => arg = L.RFENVG | L.RFNAMEG | L.RFNOTEG,
            2 => {
                for (w.next.?.word) |c| {
                    arg |= switch (c) {
                        'n' => L.RFNAMEG,
                        'N' => L.RFCNAMEG,
                        'm' => L.RFNOMNT,
                        'e' => L.RFENVG,
                        'E' => L.RFCENVG,
                        's' => L.RFNOTEG,
                        'f' => L.RFFDG,
                        'F' => L.RFCFDG,
                        else => break :usage,
                    };
                }
            },
            else => break :usage,
        }
        if (plan9.Rfork(arg) < 0) {
            pfmt(exec.err, "%s: %s failed\n", .{ rc.argv0, w.word });
            exec.setstatus("rfork failed");
        } else {
            if (arg & L.RFCFDG != 0) {
                var rp_ = rq().redir;
                while (rp_) |rp| : (rp_ = rp.next) {
                    rp.from = -1;
                    rp.to = -1;
                    rp.type = 0;
                }
            }
            exec.setstatus("");
        }
        exec.poplist();
        return;
    }
    pfmt(exec.err, "Usage: %s [fnesFNEm]\n", .{w.word});
    exec.setstatus("rfork usage");
    exec.poplist();
}
