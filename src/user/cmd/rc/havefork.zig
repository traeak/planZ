//! rc's commands that fork: &, pipes, `{}, <{} and >{}, @{}, and the
//! fork before an exec.
//! from cmd/rc/havefork.c
//!
//! DIFF: the instructions' operands come as arguments; a child thread
//! starts at pc, which is already past the instruction (the C's pc+1 or
//! pc+2, past the operands).

const std = @import("std");
const rc = @import("rc.zig");
const io = @import("io.zig");
const exec = @import("exec.zig");
const @"var" = @import("var.zig");
const plan9 = @import("plan9.zig");
const simple = @import("simple.zig");

const rq = exec.rq;

var waitpids: std.ArrayList(i32) = .empty;

pub fn addwaitpid(pid: i32) void {
    waitpids.append(rc.a, pid) catch rc.panic("Can't realloc %d bytes\n", 0);
}

pub fn delwaitpid(pid: i32) void {
    var w: usize = 0;
    for (waitpids.items) |p| {
        if (p != pid) {
            waitpids.items[w] = p;
            w += 1;
        }
    }
    waitpids.items.len = w;
}

pub fn clearwaitpids() void {
    waitpids.items.len = 0;
}

pub fn havewaitpid(pid: i32) bool {
    return std.mem.indexOfScalar(i32, waitpids.items, pid) != null;
}

pub fn Xasync(end: u32) void {
    const pid = plan9.Fork();
    switch (pid) {
        -1 => exec.Xerror2("try again", plan9.Errstr()),
        0 => {
            clearwaitpids();
            exec.start(rq().code.?, rq().pc, rq().local, rq().redir);
            rq().ret = null;
        },
        else => {
            addwaitpid(pid);
            rq().pc = end;
            var npid: [12]u8 = undefined;
            @"var".setvar("apid", exec.newword(rc.inttoascii(&npid, pid), null));
        },
    }
}

pub fn Xpipe(lfd: i32, rfd: i32, right: u32, end: u32) void {
    const p = rq();
    const left = p.pc;
    const pfd = rc.libc.pipe() catch {
        exec.Xerror2("can't get pipe", plan9.Errstr());
        return;
    };
    const pid = plan9.Fork();
    switch (pid) {
        -1 => exec.Xerror2("try again", plan9.Errstr()),
        0 => {
            clearwaitpids();
            plan9.Close(pfd[rc.PRD]);
            exec.start(p.code.?, left, rq().local, rq().redir);
            rq().ret = null;
            exec.pushredir(rc.ROPEN, pfd[rc.PWR], lfd);
        },
        else => {
            addwaitpid(pid);
            plan9.Close(pfd[rc.PWR]);
            exec.start(p.code.?, right, rq().local, rq().redir);
            exec.pushredir(rc.ROPEN, pfd[rc.PRD], rfd);
            p.pc = end;
            p.pid = pid;
        },
    }
}

// Who should wait for the exit from the fork?

pub fn Xbackq(end: u32) void {
    const pfd = rc.libc.pipe() catch {
        exec.Xerror2("can't make pipe", plan9.Errstr());
        return;
    };
    const pid = plan9.Fork();
    switch (pid) {
        -1 => {
            exec.Xerror2("try again", plan9.Errstr());
            plan9.Close(pfd[rc.PRD]);
            plan9.Close(pfd[rc.PWR]);
        },
        0 => {
            clearwaitpids();
            plan9.Close(pfd[rc.PRD]);
            exec.start(rq().code.?, rq().pc, rq().local, rq().redir);
            exec.pushredir(rc.ROPEN, pfd[rc.PWR], 1);
        },
        else => {
            addwaitpid(pid);
            plan9.Close(pfd[rc.PWR]);

            const split = exec.Popword();
            exec.poplist();
            const f = io.openiofd(pfd[rc.PRD]);
            const l = rq().argv.?;
            const end_ = l.words;
            var link: *?*rc.Word = &l.words;
            while (io.rstr(f, split)) |s| {
                const w = exec.Newword(s, null);
                link.* = w;
                link = &w.next;
            }
            link.* = end_;
            io.closeio(f);
            rc.a.free(split);

            _ = plan9.Waitfor(pid);

            rq().pc = end;
        },
    }
}

pub fn Xpipefd(rtype: i32, end: u32) void {
    const p = rq();
    const pfd = rc.libc.pipe() catch {
        exec.Xerror2("can't get pipe", plan9.Errstr());
        return;
    };
    var sidefd: i32 = undefined;
    var mainfd: i32 = undefined;
    if (rtype == rc.READ) {
        sidefd = pfd[rc.PWR];
        mainfd = pfd[rc.PRD];
    } else {
        sidefd = pfd[rc.PRD];
        mainfd = pfd[rc.PWR];
    }
    const pid = plan9.Fork();
    switch (pid) {
        -1 => exec.Xerror2("try again", plan9.Errstr()),
        0 => {
            clearwaitpids();
            plan9.Close(mainfd);
            exec.start(p.code.?, p.pc, rq().local, rq().redir);
            exec.pushredir(rc.ROPEN, sidefd, if (rtype == rc.READ) 1 else 0);
            rq().ret = null;
        },
        else => {
            addwaitpid(pid);
            plan9.Close(sidefd);
            exec.pushredir(rc.ROPEN, mainfd, mainfd);
            exec.shuffleredir(); // shuffle redir to bottom of stack for Xpopredir()
            var name: [40]u8 = undefined;
            @memcpy(name[0..plan9.Fdprefix.len], plan9.Fdprefix);
            const n = rc.inttoascii(name[plan9.Fdprefix.len..], mainfd);
            _ = exec.pushword(name[0 .. plan9.Fdprefix.len + n.len]);
            p.pc = end;
        },
    }
}

pub fn Xsubshell(end: u32) void {
    const pid = plan9.Fork();
    switch (pid) {
        -1 => exec.Xerror2("try again", plan9.Errstr()),
        0 => {
            clearwaitpids();
            exec.start(rq().code.?, rq().pc, rq().local, rq().redir);
            rq().ret = null;
        },
        else => {
            addwaitpid(pid);
            while (plan9.Waitfor(pid) < 0) {}
            rq().pc = end;
        },
    }
}

pub fn execforkexec() i32 {
    const pid = plan9.Fork();
    switch (pid) {
        -1 => return -1,
        0 => {
            clearwaitpids();
            _ = exec.pushword("exec");
            simple.execexec();
            // does not return
        },
        else => {},
    }
    addwaitpid(pid);
    return pid;
}
