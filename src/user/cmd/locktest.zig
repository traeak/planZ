//! locktest - processes that share memory (rfork with RFMEM) over the
//! library's locks: Lock, QLock, RWLock, Rendez, the semaphores, the
//! atomic operations, and what each process keeps of its own (the
//! stack, privalloc's words, the pid, atexit's functions, the error
//! string).  The twin of tools/locktest.c, which is built in the guest
//! against stock libc and prints the same lines; after 9front's
//! libc/test/lock.c and atomic.c.
//!
//! Only the first process prints, and only what does not depend on
//! which process ran when.

const std = @import("std");
const libc = @import("libc");
const sys = libc.sys;

const print = libc.print;
const Lock = libc.Lock;
const QLock = libc.QLock;
const RWLock = libc.RWLock;
const Rendez = libc.Rendez;
const QLp = libc.QLp;
const Along = libc.Along;
const lock = libc.lock;
const unlock = libc.unlock;
const qlock = libc.qlock;
const qunlock = libc.qunlock;
const ainc = libc.ainc;
const agetl = libc.agetl;
const aswapl = libc.aswapl;

const NP = 10; // processes of a kind
const N = 2000; // turns each
const NQ = 8; // places in the queue
const NPROD = 4;
const NITEM = 500;
const NZ = 3;

fn spawn(comptime f: anytype, arg: anytype) i32 {
    return libc.spawn(0, f, arg) catch libc.sysfatal("rfork: %r", .{});
}

fn waitall(n: usize) void {
    for (0..n) |_| {
        const w = libc.wait() catch libc.sysfatal("wait: %r", .{});
        if (w.msg().len != 0)
            print("child: %s\n", .{w.msg()});
    }
}

fn sleep(ms: u32) void {
    _ = sys.sleep(ms);
}

fn b(x: bool) u8 {
    return @intFromBool(x);
}

/// A number that another process changes, read.
fn get(p: *const i32) i32 {
    return @atomicLoad(i32, p, .seq_cst);
}

/// how many wait in a queue
fn queued(lk: *Lock, head: *?*QLp) usize {
    var n: usize = 0;
    lock(lk);
    var p = head.*;
    while (p) |q| : (p = q.next)
        n += 1;
    unlock(lk);
    return n;
}

// Lock and QLock: a sum

var l: Lock = .{};
var ql: QLock = .{};
var counter: i32 = 0;

fn linc(a: i32) void {
    for (0..N) |_| {
        lock(&l);
        counter += a;
        unlock(&l);
    }
}

fn ldec(_: void) void {
    for (0..N) |_| {
        lock(&l);
        counter -= 1;
        unlock(&l);
    }
}

fn qinc(a: i32) void {
    for (0..N) |_| {
        qlock(&ql);
        counter += a;
        qunlock(&ql);
    }
}

fn qdec(_: void) void {
    for (0..N) |_| {
        qlock(&ql);
        counter -= 1;
        qunlock(&ql);
    }
}

fn locks() void {
    print("canlock %d", .{b(libc.canlock(&l))});
    unlock(&l);
    lock(&l);
    print(" %d", .{b(libc.canlock(&l))});
    unlock(&l);
    print(" %d\n", .{b(libc.canlock(&l))});
    unlock(&l);

    print("canqlock %d", .{b(libc.canqlock(&ql))});
    qunlock(&ql);
    qlock(&ql);
    print(" %d", .{b(libc.canqlock(&ql))});
    qunlock(&ql);
    print(" %d\n", .{b(libc.canqlock(&ql))});
    qunlock(&ql);

    counter = 0;
    var i: i32 = 1;
    while (i <= NP) : (i += 1) {
        _ = spawn(linc, i);
        _ = spawn(ldec, {});
    }
    waitall(2 * NP);
    print("lock: counter %d\n", .{get(&counter)});

    counter = 0;
    i = 1;
    while (i <= NP) : (i += 1) {
        _ = spawn(qinc, i);
        _ = spawn(qdec, {});
    }
    waitall(2 * NP);
    print("qlock: counter %d\n", .{get(&counter)});
}

// RWLock: writers keep two numbers the same, readers look

var rw: RWLock = .{};
var rwa: i32 = 0;
var rwb: i32 = 0;
var rwbad: i32 = 0;

fn writer(_: void) void {
    for (0..N) |i| {
        libc.wlock(&rw);
        rwa += 1;
        if (i & 63 == 0)
            sleep(0);
        rwb += 1;
        libc.wunlock(&rw);
    }
}

fn reader(_: void) void {
    for (0..N) |i| {
        libc.rlock(&rw);
        if (get(&rwa) != get(&rwb))
            _ = ainc(&rwbad);
        if (i & 127 == 0)
            sleep(0);
        if (get(&rwa) != get(&rwb))
            _ = ainc(&rwbad);
        libc.runlock(&rw);
    }
}

// the order the lock is given in
var loglk: Lock = .{};
var rwlog: [16]u8 = @splat(0);
var nlog: i32 = 0;
var go: Along = .{};

fn logc(c: u8) void {
    lock(&loglk);
    rwlog[@intCast(nlog)] = c;
    unlock(&loglk);
    _ = ainc(&nlog);
}

fn ordw(_: void) void {
    libc.wlock(&rw);
    logc('W');
    libc.wunlock(&rw);
}

fn ordr(c: u8) void {
    libc.rlock(&rw);
    logc(c);
    while (agetl(&go) == 0)
        sleep(1);
    libc.runlock(&rw);
}

fn thelog() []const u8 {
    return rwlog[0..@intCast(get(&nlog))];
}

fn rwlocks() void {
    print("canrlock %d", .{b(libc.canrlock(&rw))});
    print(" %d", .{b(libc.canrlock(&rw))});
    print(" canwlock %d", .{b(libc.canwlock(&rw))});
    libc.runlock(&rw);
    libc.runlock(&rw);
    print(" %d", .{b(libc.canwlock(&rw))});
    print(" canrlock %d", .{b(libc.canrlock(&rw))});
    print(" canwlock %d\n", .{b(libc.canwlock(&rw))});
    libc.wunlock(&rw);

    for (0..4) |_| {
        _ = spawn(writer, {});
        _ = spawn(reader, {});
    }
    waitall(8);
    print("rwlock: a %d b %d bad %d\n", .{ get(&rwa), get(&rwb), get(&rwbad) });

    // a writer that waits keeps new readers out, and goes next
    _ = aswapl(&go, 1);
    libc.rlock(&rw);
    _ = spawn(ordw, {});
    while (queued(&rw.lock, &rw.head) < 1)
        sleep(1);
    const cr = libc.canrlock(&rw);
    const cw = libc.canwlock(&rw);
    print("writer waits: canrlock %d canwlock %d", .{ b(cr), b(cw) });
    libc.runlock(&rw);
    waitall(1);
    print(" log %s\n", .{thelog()});

    // the writer lets go: the readers at the head of the queue go
    // together, the writer behind them after the last of them, and
    // the reader behind the writer after that
    @atomicStore(i32, &nlog, 0, .seq_cst);
    rwlog = @splat(0);
    _ = aswapl(&go, 0);
    libc.wlock(&rw);
    for (0..3) |i| {
        _ = spawn(ordr, @as(u8, 'R'));
        while (queued(&rw.lock, &rw.head) < i + 1)
            sleep(1);
    }
    _ = spawn(ordw, {});
    while (queued(&rw.lock, &rw.head) < 4)
        sleep(1);
    _ = spawn(ordr, @as(u8, 'r'));
    while (queued(&rw.lock, &rw.head) < 5)
        sleep(1);
    libc.wunlock(&rw);
    lock(&rw.lock);
    const readers = rw.readers;
    const nwriter = rw.writer;
    unlock(&rw.lock);
    print("wunlock: readers %d writer %d", .{ readers, nwriter });
    print(" queued %d", .{queued(&rw.lock, &rw.head)});
    while (get(&nlog) < 3)
        sleep(1);
    print(" canrlock %d", .{b(libc.canrlock(&rw))});
    _ = aswapl(&go, 1);
    waitall(5);
    print(" log %s\n", .{thelog()});
}

// Rendez: a queue of NQ places between producers and consumers

var qq: QLock = .{};
var nonempty: Rendez = .{};
var nonfull: Rendez = .{};
var qbuf: [NQ]i32 = undefined;
var qrp: usize = 0;
var qwp: usize = 0;
var qn: usize = 0;
var taken: usize = 0;
var qsum: i64 = 0;
var last: [NPROD]i32 = @splat(-1);
var qbad: usize = 0;

fn producer(id: i32) void {
    var i: i32 = 0;
    while (i < NITEM) : (i += 1) {
        qlock(&qq);
        while (qn == NQ)
            libc.rsleep(&nonfull);
        qbuf[qwp % NQ] = id * 1000 + i;
        qwp += 1;
        qn += 1;
        _ = libc.rwakeup(&nonempty);
        qunlock(&qq);
    }
}

fn consumer(_: void) void {
    while (true) {
        qlock(&qq);
        while (qn == 0 and taken < NPROD * NITEM)
            libc.rsleep(&nonempty);
        if (qn == 0) {
            qunlock(&qq);
            break;
        }
        const v = qbuf[qrp % NQ];
        qrp += 1;
        qn -= 1;
        taken += 1;
        qsum += v;
        const p: usize = @intCast(@divTrunc(v, 1000));
        if (@rem(v, 1000) <= last[p])
            qbad += 1;
        last[p] = @rem(v, 1000);
        if (taken == NPROD * NITEM)
            _ = libc.rwakeupall(&nonempty);
        _ = libc.rwakeup(&nonfull);
        qunlock(&qq);
    }
}

var sq: QLock = .{};
var sr: Rendez = .{};
var woke: i32 = 0;

fn sleeper(_: void) void {
    qlock(&sq);
    libc.rsleep(&sr);
    woke += 1;
    qunlock(&sq);
}

fn rendez() void {
    nonempty.l = &qq;
    nonfull.l = &qq;
    var i: i32 = 0;
    while (i < NPROD) : (i += 1) {
        _ = spawn(consumer, {});
        _ = spawn(producer, i);
    }
    waitall(2 * NPROD);
    qlock(&qq);
    print("queue: taken %d sum %d bad %d left %d\n", .{ taken, qsum, qbad, qn });
    qunlock(&qq);

    sr.l = &sq;
    qlock(&sq);
    print("rwakeup: none %d", .{b(libc.rwakeup(&sr))});
    qunlock(&sq);
    for (0..3) |_|
        _ = spawn(sleeper, {});
    while (queued(&sq.lock, &sr.head) < 3)
        sleep(1);
    qlock(&sq);
    print(" all %d", .{libc.rwakeupall(&sr)});
    print(" none %d", .{b(libc.rwakeup(&sr))});
    print(" woke %d", .{woke});
    qunlock(&sq);
    waitall(3);
    print(" woke %d\n", .{get(&woke)});
}

// semaphores

var sem: i32 = 0;
var semgot: i32 = 0;

fn semwaiter(_: void) void {
    if (libc.semacquire(&sem, true) catch false)
        _ = ainc(&semgot);
}

fn acq(r: libc.Error!bool) i32 {
    return if (r) |v| b(v) else |_| -1;
}

fn rel(r: libc.Error!i32) i32 {
    return r catch -1;
}

fn sems() void {
    for (0..5) |_|
        _ = spawn(semwaiter, {});
    print("sem: release %d", .{rel(libc.semrelease(&sem, 5))});
    waitall(5);
    print(" got %d sem %d", .{ get(&semgot), get(&sem) });
    print(" acquire %d", .{acq(libc.semacquire(&sem, false))});
    print(" tsemacquire %d", .{acq(libc.tsemacquire(&sem, 20))});
    print(" release %d", .{rel(libc.semrelease(&sem, 2))});
    print(" acquire %d", .{acq(libc.semacquire(&sem, false))});
    print(" tsemacquire %d", .{acq(libc.tsemacquire(&sem, 20))});
    print(" sem %d\n", .{get(&sem)});
}

// a process's own: the stack, privalloc's words, the pid, atexit, the
// error string

var priv: *usize = undefined;
var shared: i32 = 0;
var childpid: i32 = 0;
var cran: i32 = 0;
var dontran: i32 = 0;
var pran: i32 = 0;
var errbad: i32 = 0;

fn cexit() void {
    cran += 1;
}

fn cdont() void {
    dontran += 1;
}

fn pexit() void {
    pran += 1;
    print("atexit: the first process's ran, %d time\n", .{pran});
}

fn own(a: *i32) void {
    a.* = 2;
    priv.* = 2;
    shared = 2;
    childpid = @intCast(libc.getpid());
    _ = libc.atexit(cexit);
    _ = libc.atexit(cdont);
    libc.atexitdont(cdont);
}

fn errproc(id: i32) void {
    var wb: [32]u8 = undefined;
    var buf: [libc.ERRMAX]u8 = undefined;
    const want = libc.sprint(&wb, "process %d", .{id});
    libc.werrstr("%s", .{want});
    for (0..500) |i| {
        if (!std.mem.eql(u8, libc.sprint(&buf, "%r", .{}), want))
            _ = ainc(&errbad);
        if (i & 31 == 0)
            sleep(0);
    }
}

fn owns() void {
    var n: usize = 0;
    for (0..20) |_| {
        if (libc.privalloc()) |p| {
            n += 1;
            priv = p;
        }
    }
    print("privalloc: %d words\n", .{n});

    var local: i32 = 1;
    priv.* = 1;
    shared = 1;
    _ = libc.atexit(pexit);
    const pid = spawn(own, &local);
    waitall(1);
    const cpid = get(&childpid);
    print("own: stack %d private %d data %d pid %d %d\n", .{
        local,                                          priv.*, get(&shared), b(pid == cpid),
        b(@as(i32, @intCast(libc.getpid())) == cpid),
    });
    print("atexit: child's %d taken back %d first's %d\n", .{ get(&cran), get(&dontran), get(&pran) });

    libc.werrstr("the first process", .{});
    var i: i32 = 1;
    while (i <= NP) : (i += 1)
        _ = spawn(errproc, i);
    waitall(NP);
    print("errstr: bad %d mine %r\n", .{get(&errbad)});
}

// the library under several processes: malloc and the time zones

var membad: i32 = 0;
var tzp: [NP][NZ]?*const libc.Tzone = @splat(@splat(null));
const zname = [NZ]?[]const u8{ null, "US_Eastern", "CET" };

fn memproc(id: u8) void {
    var blk: [16]?[*]u8 = @splat(null);
    var sz: [16]usize = undefined;
    var r: u32 = @as(u32, id) *% 2654435761;
    for (0..2000) |_| {
        r = r *% 1103515245 +% 12345;
        const k = (r >> 16) % blk.len;
        if (blk[k]) |p| {
            for (p[0..sz[k]]) |c| {
                if (c != id) {
                    _ = ainc(&membad);
                    break;
                }
            }
            libc.free(p);
        }
        sz[k] = 1 + (r >> 8) % 700;
        blk[k] = libc.malloc(sz[k]);
        if (blk[k]) |p|
            @memset(p[0..sz[k]], id)
        else
            _ = ainc(&membad);
    }
    for (blk) |p|
        libc.free(p);
}

fn tzproc(id: usize) void {
    for (0..20) |_| {
        for (0..NZ) |k|
            @atomicStore(?*const libc.Tzone, &tzp[id][k], libc.tzload(zname[k]), .seq_cst);
    }
}

fn tz(i: usize, k: usize) ?*const libc.Tzone {
    return @atomicLoad(?*const libc.Tzone, &tzp[i][k], .seq_cst);
}

fn library() void {
    var id: u8 = 1;
    while (id <= NP) : (id += 1)
        _ = spawn(memproc, id);
    waitall(NP);
    print("malloc: bad %d\n", .{get(&membad)});

    for (0..NP) |i|
        _ = spawn(tzproc, i);
    waitall(NP);
    var bad: usize = 0;
    for (0..NP) |i| {
        for (0..NZ) |k| {
            if (tz(i, k) == null or tz(i, k) != tz(0, k))
                bad += 1;
        }
    }
    print("tzload: bad %d again %d other %d none %d\n", .{
        bad,                     b(libc.tzload("CET") == tz(0, 2)),
        b(tz(0, 1) != tz(0, 2)), b(libc.tzload("nosuchzone") == null),
    });
}

// the atomic operations (libc/test/atomic.c, with fewer processes)

var acount: Along = .{};
var done0: Along = .{};
var done1: Along = .{};
var val0: i32 = 0;
var val1: i32 = 0;
var atbad: i32 = 0;
var ncount: i32 = 0;

fn inc(p: *Along) void {
    for (0..10000) |_|
        _ = libc.aincl(p, 1);
}

fn dec(p: *Along) void {
    for (0..10000) |_|
        _ = libc.aincl(p, -1);
}

fn casinc(p: *Along) void {
    for (0..2000) |_| {
        while (true) {
            const v = agetl(p);
            if (libc.acasl(p, v, v + 1))
                break;
        }
    }
}

fn casdec(p: *Along) void {
    for (0..2000) |_| {
        while (true) {
            const v = agetl(p);
            if (libc.acasl(p, v, v - 1))
                break;
        }
    }
}

fn ninc(_: void) void {
    for (0..10000) |_|
        _ = ainc(&ncount);
}

fn ndec(_: void) void {
    for (0..10000) |_|
        _ = libc.adec(&ncount);
}

fn toggle0(_: void) void {
    val0 = 1;
    _ = aswapl(&done0, 1);
    while (agetl(&done1) != 1) {} // wait
    if (val1 != 1)
        _ = ainc(&atbad);
}

fn toggle1(_: void) void {
    val1 = 1;
    _ = aswapl(&done1, 1);
    while (agetl(&done0) != 1) {} // wait
    if (val0 != 1)
        _ = ainc(&atbad);
}

fn atomics() void {
    var al: Along = .{};
    var av: libc.Avlong = .{};
    var ap: libc.Aptr = .{};
    var i: i32 = 0;

    _ = aswapl(&al, 1);
    print("along: %d", .{agetl(&al)});
    print(" %d", .{libc.aincl(&al, 1)});
    print(" %d", .{libc.aincl(&al, -1)});
    print(" %d", .{b(libc.acasl(&al, 42, 123))});
    print(" %d", .{agetl(&al)});
    print(" %d", .{aswapl(&al, 77)});
    print(" %d", .{b(libc.acasl(&al, 77, 42))});
    print(" %d\n", .{agetl(&al)});

    _ = libc.aswapv(&av, 1);
    print("avlong: %d", .{libc.agetv(&av)});
    print(" %d", .{libc.aincv(&av, 1 << 40)});
    print(" %d", .{libc.aincv(&av, -1)});
    print(" %d", .{b(libc.acasv(&av, 42, 123))});
    print(" %d", .{libc.agetv(&av)});
    print(" %d", .{libc.aswapv(&av, 77)});
    print(" %d", .{b(libc.acasv(&av, 77, -42))});
    print(" %d\n", .{libc.agetv(&av)});

    _ = libc.aswapp(&ap, &av);
    print("aptr: %d", .{b(libc.agetp(&ap) == @as(?*anyopaque, &av))});
    print(" %d", .{b(libc.acasp(&ap, &al, &i))});
    print(" %d", .{b(libc.agetp(&ap) == @as(?*anyopaque, &av))});
    print(" %d", .{b(libc.acasp(&ap, &av, &i))});
    print(" %d", .{b(libc.agetp(&ap) == @as(?*anyopaque, &i))});
    print(" %d\n", .{b(libc.aswapp(&ap, null) == @as(?*anyopaque, &i))});

    var n: i32 = 5;
    print("ainc: %d", .{ainc(&n)});
    print(" %d", .{libc.adec(&n)});
    print(" %d\n", .{n});

    for (0..10) |_| {
        _ = spawn(inc, &acount);
        _ = spawn(dec, &acount);
    }
    waitall(20);
    print("aincl: counter %d\n", .{agetl(&acount)});

    for (0..20) |_| {
        _ = spawn(casinc, &acount);
        _ = spawn(casdec, &acount);
    }
    waitall(40);
    print("acasl: counter %d\n", .{agetl(&acount)});

    for (0..10) |_| {
        _ = spawn(ninc, {});
        _ = spawn(ndec, {});
    }
    waitall(20);
    print("ainc: counter %d\n", .{get(&ncount)});

    // do the atomics act as barriers?
    for (0..200) |_| {
        val0 = 0;
        val1 = 0;
        _ = aswapl(&done0, 0);
        _ = aswapl(&done1, 0);
        _ = spawn(toggle0, {});
        _ = spawn(toggle1, {});
        waitall(2);
    }
    print("barrier: bad %d\n", .{get(&atbad)});
}

pub fn main() void {
    locks();
    rwlocks();
    rendez();
    sems();
    owns();
    library();
    atomics();
    print("done\n", .{});
    libc.exits(null);
}
