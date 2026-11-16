//! threadtest - the thread library: threads and their order, channels,
//! alt, chanclose, threadint and threadkill, QLock and Rendez between
//! threads, notes, procs, procexec, and the I/O procs.  The twin of
//! tools/threadtest.c, which is built in the guest against stock
//! libthread and prints the same lines.
//!
//! Only the first proc prints.  Everything up to "procs" runs in one
//! proc, so that alt's random choices (libc's nrand) are the same in
//! both programs.  It exits through threadexitsall with the status
//! "bye".

const std = @import("std");
const libc = @import("libc");
const thread = @import("thread");
const sys = libc.sys;
const chan = thread.chan;

pub const main = thread.main;
pub const mainstacksize = 32 * 1024;

const STACK = 16 * 1024;
const Channel = thread.Channel;
const Alt = thread.Alt;
const yield = thread.yield;
const threadcreate = thread.threadcreate;
const proccreate = thread.proccreate;
const recvul = chan.recvul;
const sendul = chan.sendul;
const nbrecvul = chan.nbrecvul;
const nbsendul = chan.nbsendul;
const print = libc.print;

var logbuf: [1024]u8 = undefined;
var logn: usize = 0;

fn lg(comptime format: []const u8, args: anytype) void {
    logn += libc.sprint(logbuf[logn..], format, args).len;
}

fn flush(name: []const u8) void {
    print("%s:%s\n", .{ name, logbuf[0..logn] });
    logn = 0;
}

fn yields(n: usize) void {
    for (0..n) |_|
        yield();
}

fn b(x: bool) u8 {
    return @intFromBool(x);
}

fn ul(n: usize) *Channel {
    return chan.chancreate(@sizeOf(u32), n).?;
}

/// The C's chanclose: 0, or -1 if it was closed already.
fn chanclose(c: *Channel) i32 {
    return if (chan.chanclose(c)) 0 else -1;
}

fn mypid() i32 {
    return @intCast(libc.getpid());
}

// threads: the order they run in, ids, groups, names, data

var ndone: usize = 0;

fn abc(a: u8) void {
    for (0..3) |i| {
        lg(" %c%d", .{ a, i });
        yield();
    }
    ndone += 1;
}

var kidgrp: i32 = 0;
var kidid: i32 = 0;

fn kid(_: void) void {
    var nb: [32]u8 = undefined;
    kidgrp = thread.threadgetgrp();
    kidid = thread.threadid();
    thread.threaddata().* = 22;
    thread.procdata().* = 5;
    thread.threadsetname(libc.sprint(&nb, "kid %d", .{1}));
    lg(" name %s", .{thread.threadgetname().?});
    ndone += 1;
}

fn threads() void {
    var id: [3]i32 = undefined;

    lg(" main %d", .{thread.threadid()});
    for (0..3) |i|
        id[i] = threadcreate(abc, @as(u8, @intCast('a' + i)), STACK);
    lg(" ids %d %d %d", .{ id[0], id[1], id[2] });
    while (ndone < 3) {
        lg(" m", .{});
        yield();
    }
    flush("order");

    ndone = 0;
    const og = thread.threadsetgrp(7);
    thread.threaddata().* = 11;
    const i = threadcreate(kid, {}, STACK);
    yields(2);
    lg(" grp %d %d %d id %d", .{ og, thread.threadgetgrp(), kidgrp, b(kidid == i) });
    lg(" data %d %d", .{ thread.threaddata().*, thread.procdata().* });
    lg(" name %s", .{thread.threadgetname().?});
    lg(" pid %d %d %d", .{ b(thread.threadpid(0) == mypid()), b(thread.threadpid(thread.threadid()) == mypid()), thread.threadpid(i) });
    _ = thread.threadsetgrp(0);
    flush("ids");
}

// channels with and without a buffer

var c0: *Channel = undefined;
var c3: *Channel = undefined;

fn sender(_: void) void {
    var i: u32 = 1;
    while (i <= 4) : (i += 1) {
        lg(" s%d", .{i});
        _ = sendul(c0, i);
    }
    lg(" s.", .{});
}

fn rcvr(a: u8) void {
    var v: u32 = 0;
    const r = chan.recv(c0, &v);
    lg(" %c=%d,%d", .{ a, r, if (r > 0) v else 0 });
    ndone += 1;
}

fn chans() void {
    var v: u32 = 0;

    c0 = ul(0);
    c3 = ul(3);
    _ = threadcreate(sender, {}, STACK);
    for (0..4) |_| {
        v = recvul(c0);
        lg(" r%d", .{v});
    }
    yield();
    flush("unbuffered");

    var i: u32 = 1;
    while (i <= 5) : (i += 1)
        lg(" %d", .{nbsendul(c3, i)});
    lg(" /", .{});
    for (0..5) |_|
        lg(" %d", .{nbrecvul(c3)});
    const s = chan.nbsend(c0, &v);
    const r = chan.nbrecv(c0, &v);
    lg(" / %d %d", .{ s, r });
    flush("buffered");

    // three wait to receive; which gets which value is alt's choice
    ndone = 0;
    for (0..3) |k|
        _ = threadcreate(rcvr, @as(u8, @intCast('x' + k)), STACK);
    yield();
    i = 1;
    while (i <= 3) : (i += 1)
        _ = sendul(c0, 10 * i);
    while (ndone < 3)
        yield();
    flush("waiters");
}

// alt

fn alts() void {
    var v: u32 = 0;
    var w: u32 = 0;

    const a1 = ul(1);
    const a2 = ul(1);
    var a: [5]Alt = @splat(.{});
    a[0] = .{ .c = a1, .v = &v, .op = .CHANRCV };
    a[1] = .{ .c = a2, .v = &v, .op = .CHANRCV };
    a[2].op = .CHANEND;
    for (0..24) |_| {
        _ = nbsendul(a1, 1);
        _ = nbsendul(a2, 2);
        lg("%d", .{thread.alt(&a)});
    }
    flush("alt choice");

    _ = nbrecvul(a1);
    _ = nbrecvul(a2);
    a[2].op = .CHANNOBLK;
    lg(" %d", .{thread.alt(&a)});
    a[0].op = .CHANNOP;
    _ = sendul(a1, 5);
    _ = sendul(a2, 6);
    var r = thread.alt(&a);
    lg(" %d,%d", .{ r, v });
    a[0].op = .CHANRCV;
    a[1].op = .CHANNOP;
    r = thread.alt(&a);
    lg(" %d,%d", .{ r, v });
    // a send and a receive: only the send can go
    w = 9;
    a[0] = .{ .c = a1, .v = &v, .op = .CHANRCV };
    a[1] = .{ .c = a2, .v = &w, .op = .CHANSND };
    a[2].op = .CHANEND;
    lg(" %d", .{thread.alt(&a)});
    // both can go: the choice is alt's
    a[0].c = a2;
    a[1].c = a1;
    lg(" %d", .{thread.alt(&a)});
    lg(" %d", .{nbrecvul(a1)});
    lg(" %d", .{nbrecvul(a2)});
    a[0].c = null;
    lg(" %d", .{thread.alt(&a)});
    flush("alt");
    chan.chanfree(a1);
    chan.chanfree(a2);
}

// chanclose

var cc: *Channel = undefined;

fn closedrcv(_: void) void {
    var v: u32 = 0;
    lg(" blocked=%d", .{chan.recv(cc, &v)});
    ndone += 1;
}

fn closes() void {
    var v: u32 = 0;

    const c = ul(3);
    _ = sendul(c, 1);
    _ = sendul(c, 2);
    lg(" %d", .{chan.chanclosing(c)});
    lg(" %d", .{chanclose(c)});
    lg(" %d", .{chan.chanclosing(c)});
    v = 0;
    var r = chan.recv(c, &v);
    lg(" %d,%d", .{ r, v });
    lg(" %d", .{chan.chanclosing(c)});
    r = chan.nbrecv(c, &v);
    lg(" %d,%d", .{ r, v });
    lg(" %d", .{chan.recv(c, &v)});
    lg(" %d", .{chan.nbrecv(c, &v)});
    lg(" %d", .{chan.send(c, &v)});
    lg(" %d", .{chan.nbsend(c, &v)});
    lg(" %d", .{chanclose(c)});
    lg(" %d", .{chan.chanclosing(c)});
    flush("close");

    ndone = 0;
    cc = ul(0);
    _ = threadcreate(closedrcv, {}, STACK);
    yield();
    lg(" %d", .{chanclose(cc)});
    while (ndone < 1)
        yield();

    // all of an alt's channels closed: the last one, then nothing
    const d = ul(0);
    _ = chanclose(d);
    var a: [3]Alt = @splat(.{});
    a[0] = .{ .c = c, .v = &v, .op = .CHANRCV };
    a[1] = .{ .c = d, .v = &v, .op = .CHANSND };
    a[2].op = .CHANEND;
    lg(" alt %d", .{thread.alt(&a)});
    lg(" %d", .{b(a[1].closed)});
    lg(" %d", .{thread.alt(&a)});
    a[1].op = .CHANNOP;
    lg(" %d", .{thread.alt(&a)});
    flush("closed");
    chan.chanfree(c);
    chan.chanfree(d);
    chan.chanfree(cc);
}

// threadint, threadkill, threadkillgrp

var ic: *Channel = undefined;
var kc: *Channel = undefined;
var gc: *Channel = undefined;
var woken: i32 = 0;

fn victim(a: u8) void {
    var v: u32 = 0;
    var r = chan.recv(ic, &v);
    lg(" %c:%d", .{ a, r });
    woken += 1;
    r = chan.recv(ic, &v);
    lg(" %c:%d,%d", .{ a, r, v });
    woken += 1;
}

fn killvictim(_: void) void {
    var v: u32 = 0;
    _ = chan.recv(kc, &v);
    woken += 100;
}

fn grpvictim(_: void) void {
    var v: u32 = 0;
    _ = chan.recv(gc, &v);
    woken += 1;
}

fn kills() void {
    ic = ul(0);
    woken = 0;
    kc = ul(0);
    const a = threadcreate(victim, @as(u8, 'a'), STACK);
    const k = threadcreate(killvictim, {}, STACK);
    yield();
    thread.threadint(a);
    yields(2);
    lg(" woken %d", .{woken});
    _ = sendul(ic, 7);
    yields(2);
    lg(" woken %d", .{woken});
    thread.threadkill(k);
    yields(3);
    lg(" killed: woken %d pid %d %d", .{ woken, thread.threadpid(a), thread.threadpid(k) });
    flush("int");

    // a channel that a killed thread waited on is not used again:
    // its place in the channel's queue stays, and the next to meet
    // it would wait for ever
    woken = 0;
    gc = ul(0);
    _ = thread.threadsetgrp(9);
    for (0..3) |_|
        _ = threadcreate(grpvictim, {}, STACK);
    _ = thread.threadsetgrp(0);
    yield();
    thread.threadintgrp(9);
    yields(3);
    lg(" intgrp %d", .{woken});
    gc = ul(0);
    _ = thread.threadsetgrp(9);
    for (0..3) |_|
        _ = threadcreate(grpvictim, {}, STACK);
    _ = thread.threadsetgrp(0);
    yield();
    thread.threadkillgrp(9);
    yields(3);
    lg(" killgrp %d", .{woken});
    flush("grp");
}

// libc's QLock and Rendez between threads, Ref, chanprint

var tq: libc.QLock = .{};
var tr: libc.Rendez = .{};
var ready = false;
var ref: thread.Ref = .{};
var pc: thread.Chan([]u8) = undefined;

fn holder(_: void) void {
    libc.qlock(&tq);
    lg(" h1", .{});
    yield();
    lg(" h2", .{});
    libc.qunlock(&tq);
    lg(" h3", .{});
    ndone += 1;
}

fn waiter(_: void) void {
    lg(" w1", .{});
    libc.qlock(&tq);
    lg(" w2", .{});
    while (!ready)
        libc.rsleep(&tr);
    lg(" w3", .{});
    libc.qunlock(&tq);
    ndone += 1;
}

fn printer(_: void) void {
    lg(" sent %d", .{thread.chanprint(pc.c, "%d-%s", .{ 7, "seven" })});
    ndone += 1;
}

fn qlocks() void {
    ndone = 0;
    tr.l = &tq;
    _ = threadcreate(holder, {}, STACK);
    _ = threadcreate(waiter, {}, STACK);
    yields(4);
    libc.qlock(&tq);
    lg(" m1 %d", .{b(libc.rwakeup(&tr))});
    ready = true;
    libc.qunlock(&tq);
    while (ndone < 2)
        yield();
    lg(" %d", .{b(libc.canqlock(&tq))});
    libc.qunlock(&tq);
    flush("qlock");

    thread.incref(&ref);
    thread.incref(&ref);
    lg(" %d", .{thread.decref(&ref)});
    lg(" %d", .{thread.decref(&ref)});
    thread.needstack(100);
    ndone = 0;
    pc = .create(0);
    _ = threadcreate(printer, {}, STACK);
    const s = pc.recv() catch unreachable;
    lg(" got %s", .{s});
    libc.allocator.free(s);
    while (ndone < 1)
        yield();
    flush("ref");
}

// notes

var gotnote: [libc.ERRMAX]u8 = undefined;
var gotlen: usize = 0;
var nnote: i32 = 0;

fn onnote(_: ?*anyopaque, s: []const u8) bool {
    if (!std.mem.startsWith(u8, s, "test"))
        return false;
    @memcpy(gotnote[0..s.len], s);
    gotlen = s.len;
    nnote += 1;
    return true;
}

fn notes() void {
    lg(" %d", .{b(thread.threadnotify(onnote, true))});
    libc.postnote(libc.PNPROC, libc.getpid(), "test one") catch {};
    lg(" %d %s", .{ nnote, gotnote[0..gotlen] });
    libc.postnote(libc.PNPROC, libc.getpid(), "test two") catch {};
    lg(" %d %s", .{ nnote, gotnote[0..gotlen] });
    lg(" %d", .{b(thread.threadnotify(onnote, false))});
    lg(" %d", .{b(thread.threadnotify(onnote, false))});
    flush("note");
}

// procs

var req: thread.Chan(u32) = undefined;
var rep: thread.Chan(u32) = undefined;
var many: thread.Chan(u32) = undefined;
var intc: *Channel = undefined;
var msgc: *Channel = undefined;

fn doubler(_: void) void {
    thread.procdata().* = 77;
    while (true) {
        const v = req.recv() catch 0;
        if (v == 0)
            break;
        rep.send(2 * v) catch {};
    }
    rep.send(libc.getpid()) catch {};
    thread.threadexits(null);
}

fn producer(id: u32) void {
    var i: u32 = 0;
    while (i < 100) : (i += 1)
        many.send(id * 1000 + i) catch {};
}

fn intproc(_: void) void {
    var v: u32 = 0;
    _ = sendul(msgc, 1);
    var r = chan.recv(intc, &v);
    _ = sendul(msgc, @bitCast(r));
    r = chan.recv(intc, &v); // killed here
    _ = sendul(msgc, @bitCast(100 + r));
}

fn closer(fd: i32) void {
    _ = sys.close(fd);
    _ = sendul(msgc, 0);
}

fn procs() void {
    var last: [4]i32 = @splat(-1);

    req = .create(0);
    rep = .create(0);
    var id = proccreate(doubler, {}, STACK);
    var i: u32 = 1;
    while (i <= 5) : (i += 1) {
        req.send(i) catch {};
        lg(" %d", .{rep.recv() catch 0});
    }
    lg(" pid %d %d", .{ b(thread.threadpid(id) > 0), b(thread.threadpid(id) != mypid()) });
    const ppid = thread.threadpid(id);
    req.send(0) catch {};
    lg(" %d", .{b((rep.recv() catch 0) == @as(u32, @bitCast(ppid)))});
    lg(" data %d", .{thread.procdata().*});
    flush("proc");

    many = .create(4);
    i = 0;
    while (i < 4) : (i += 1)
        _ = proccreate(producer, i, STACK);
    var sum: u32 = 0;
    var bad: u32 = 0;
    for (0..400) |_| {
        const v = many.recv() catch 0;
        sum += v;
        if (@as(i32, @intCast(v % 1000)) <= last[v / 1000])
            bad += 1;
        last[v / 1000] = @intCast(v % 1000);
    }
    lg(" sum %d bad %d", .{ sum, bad });
    flush("procs");

    // a thread of another proc, waiting: interrupted, then killed
    intc = ul(0);
    msgc = ul(0);
    id = proccreate(intproc, {}, STACK);
    _ = recvul(msgc);
    _ = sys.sleep(300);
    thread.threadint(id);
    lg(" int %d", .{@as(i32, @bitCast(recvul(msgc)))});
    _ = sys.sleep(300);
    thread.threadkill(id);
    _ = sys.sleep(300);
    lg(" killed %d", .{thread.threadpid(id)});
    flush("procint");

    // file descriptors: shared, and with RFFDG the proc's own
    const p = libc.pipe() catch libc.sysfatal("pipe: %r", .{});
    var fd: i32 = @intCast(sys.dup(p[1], -1));
    _ = proccreate(closer, fd, STACK);
    _ = recvul(msgc);
    lg(" shared %d", .{sys.write(fd, "x")});
    fd = @intCast(sys.dup(p[1], -1));
    _ = thread.procrfork(closer, fd, STACK, sys.RFFDG);
    _ = recvul(msgc);
    lg(" own %d", .{sys.write(fd, "x")});
    _ = sys.close(fd);
    _ = sys.close(p[0]);
    _ = sys.close(p[1]);
    flush("rfork");
}

// procexec and threadwaitchan

var pidc: *Channel = undefined;
var errc: thread.Chan([]u8) = undefined;
var eargs: []const []const u8 = &.{};
var eprog: []const u8 = "";

fn execproc(_: void) void {
    var err: [libc.ERRMAX]u8 = undefined;

    thread.procexec(pidc, eprog, eargs);
    const s = libc.allocator.dupe(u8, libc.rerrstr(&err)) catch unreachable;
    errc.send(s) catch {};
}

fn execs() void {
    const none = ~@as(u32, 0);
    const wc = thread.threadwaitchan();
    pidc = ul(0);
    errc = .create(0);

    eprog = "/bin/echo";
    eargs = &.{ "echo", "exec:", "echo ran" };
    _ = proccreate(execproc, {}, STACK);
    var pid = recvul(pidc);
    var w = wc.recv() catch unreachable;
    lg(" pid %d %d msg [%s]", .{ b(pid != none), b(@as(u32, @bitCast(w.pid)) == pid), w.msg() });
    libc.allocator.destroy(w);

    eprog = "/bin/test";
    eargs = &.{ "test", "-e", "/no/such/file" };
    _ = proccreate(execproc, {}, STACK);
    pid = recvul(pidc);
    w = wc.recv() catch unreachable;
    lg(" pid %d %d failed %d", .{ b(pid != none), b(@as(u32, @bitCast(w.pid)) == pid), b(w.msg().len != 0) });
    libc.allocator.destroy(w);

    eprog = "/no/such/program";
    _ = proccreate(execproc, {}, STACK);
    pid = recvul(pidc);
    const s = errc.recv() catch unreachable;
    lg(" pid %d err [%s]", .{ b(pid != none), s });
    libc.allocator.free(s);
    flush("procexec");
}

// I/O procs

var io: *thread.Ioproc = undefined;
var iop: [2]i32 = undefined;
var ioc: *Channel = undefined;

/// The C's count, or -1.
fn cnt(r: libc.Error!usize) i64 {
    return if (r) |n| @intCast(n) else |_| -1;
}

fn ok(r: libc.Error!void) i32 {
    return if (r) |_| 0 else |_| -1;
}

fn ioreader(_: void) void {
    var buf: [16]u8 = undefined;
    var err: [libc.ERRMAX]u8 = undefined;

    const n = cnt(thread.ioread(io, iop[0], &buf));
    const e = libc.rerrstr(&err);
    lg(" read %d [%s]", .{ n, if (n < 0) e else "" });
    _ = sendul(ioc, 0);
}

fn ios() void {
    var buf: [16]u8 = undefined;

    io = thread.ioproc();
    iop = libc.pipe() catch libc.sysfatal("pipe: %r", .{});
    lg(" write %d", .{cnt(thread.iowrite(io, iop[1], "hello"))});
    var n = thread.ioread(io, iop[0], &buf) catch 0;
    lg(" read %d %s", .{ n, buf[0..n] });
    _ = thread.iowrite(io, iop[1], "abc") catch 0;
    _ = thread.iowrite(io, iop[1], "def") catch 0;
    n = thread.ioreadn(io, iop[0], buf[0..6]) catch 0;
    lg(" readn %d %s", .{ n, buf[0..n] });
    lg(" sleep %d", .{ok(thread.iosleep(io, 10))});
    lg(" flush %d", .{ok(thread.ioflush(io))});
    const fd = thread.ioopen(io, "/dev/null", sys.OREAD) catch -1;
    lg(" open %d", .{b(fd >= 0)});
    lg(" close %d", .{ok(thread.ioclose(io, fd))});
    lg(" open %d", .{thread.ioopen(io, "/no/such/file", sys.OREAD) catch -1});
    flush("io");

    // a read that waits, broken off by threadint
    ioc = ul(0);
    const id = threadcreate(ioreader, {}, STACK);
    yields(3); // until it waits for the I/O proc's answer
    _ = sys.sleep(300);
    thread.threadint(id);
    _ = recvul(ioc);
    lg(" write %d", .{cnt(thread.iowrite(io, iop[1], "again"))});
    n = thread.ioread(io, iop[0], &buf) catch 0;
    lg(" read %d %s", .{ n, buf[0..n] });
    thread.closeioproc(io);
    flush("iointr");
}

// the end: threadexitsall from another proc, with threads and procs
// left waiting

var never: *Channel = undefined;

fn stuck(_: void) void {
    _ = recvul(never);
}

fn ender(_: void) void {
    thread.threadexitsall("bye");
}

/// With an argument, the main thread's stack use is printed at the
/// end (the C has no such line: for looking, not for the comparison).
pub fn threadmain(args: []const []const u8) void {
    threads();
    chans();
    alts();
    closes();
    kills();
    qlocks();
    notes();
    print("procs\n", .{});
    procs();
    execs();
    ios();
    never = ul(0);
    _ = threadcreate(stuck, {}, STACK);
    _ = proccreate(stuck, {}, STACK);
    print("done\n", .{});
    if (args.len > 1)
        print("main stack: %d of %d used\n", .{ thread.stackused(), mainstacksize });
    _ = proccreate(ender, {}, STACK);
    _ = recvul(never);
    print("not reached\n", .{});
}
