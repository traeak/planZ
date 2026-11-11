//! NVMe disk driver: NVM Express controllers on PCI, one unit per
//! namespace.
//! from 9/port/sdnvme.c
//!
//! DIFF:
//!   - Interrupts.  The C masks the controller's interrupts through the
//!     INTMS/INTMC registers: while nvmeintr runs, while the controller
//!     is disabled, and to enable each completion queue.  Here a device
//!     interrupts by message only, and intrenable programs MSI or, for a
//!     device without it, every entry of the MSI-X table with the one
//!     vector.  With MSI-X enabled INTMS and INTMC are undefined and
//!     must not be touched, so every access to them is skipped when
//!     Ctlr.msix is set (the MSI-X enable bit, read after intrenable);
//!     with MSI they are used exactly as in the C.  Ctlr.ints is kept
//!     either way: it is what stops nvmeintr from touching a controller
//!     that is not set up.  The one completion queue for I/O (CQID 1) is
//!     created with interrupt vector 0 as in the C, so it and the admin
//!     queue both use table entry 0; all entries carry the same message
//!     anyway.
//!   - nvmeintr is the handler proper and nvmepoll its body, because
//!     wcmd calls it without a Ureg (nvmeintr(nil, ctlr) in the C).
//!   - nvmepoll ignores a completion that names a submission queue which
//!     does not exist, where the C would index outside its arrays.
//!   - Errors.  `while(waserror());` around the tsleeps in wcmd is
//!     `catch {}` on each of them.  checkstatus returns the error it
//!     raises in C.  The waserror in nvmeenable is the catch around
//!     nvmeenable1, which holds the part it protected.  nvmerio cannot
//!     raise an error (SDifc.rio returns a status), so where the C lets
//!     nvmebio's error() pass through it, the Zig returns SDeio, which
//!     devsd turns into Eio.
//!   - dmaflush is gone: arch.zig has no such service, and no platform
//!     so far needs one (memory is coherent with device DMA).
//!     PCIWADDR is arch.paddr.
//!   - The queues, the registers and a command's entry are accessed
//!     through volatile pointers.
//!   - SQ.wait is a slice; an SQ's Lock and the Ctlr's QLock are named
//!     fields.  Bad in nvmepnpctlrs is a local function instead of a
//!     label.
//!   - The namespace's LBA size shift is cut to 5 bits in nvmeonline
//!     (a shift by more is undefined in C and a trap here).
//!   - readsmart's two waserror blocks are defers.
//!   - Real hardware.  None of this is in the C:
//!       * nvmeenable waits for CSTS.RDY to clear (the controller was
//!         disabled in nvmepnp, perhaps while the firmware had it
//!         running) before it sets the admin queues and CC.EN; the wait
//!         is bounded by CAP.TO.
//!       * setupqueues asks for its queues with Set Features (Number of
//!         Queues) before creating them, as the specification wants, and
//!         creates no more submission queues than were granted.
//!       * A transfer is no longer than the controller's MDTS allows.
//!         With 64K pages the C sends up to 128K whatever MDTS says.
//!       * qcmd clears command words 10 to 15; the C leaves in them
//!         whatever the entry's last command had there.
//!       * wcmd gives up on an admin command after Admto ms (status
//!         Timeout, never a real one: a status has 15 bits), so a
//!         controller that does not answer fails nvmeenable instead of
//!         stopping the boot.  The data buffer of such a command is not
//!         freed.  An i/o command is waited for for ever, as in C, with
//!         a message every Admto ms.
//!       * Messages: the model and serial number at nvmeenable, each
//!         name space's size the first time it comes on line, and "no
//!         interrupts; polling" when a command had to be found by wcmd's
//!         poll before any interrupt was ever seen.

const std = @import("std");
const arch = @import("../arch.zig");
const alloc = @import("alloc.zig");
const proc = @import("proc.zig");
const portdat = @import("portdat.zig");
const taslock = @import("taslock.zig");
const ql = @import("qlock.zig");
const pci = @import("pci.zig");
const devsd = @import("devsd.zig");
const devcons = @import("devcons.zig");
const p9 = @import("print.zig");
const fmt = @import("fmt");

const print = p9.print;
const panic = p9.panic;

const Error = proc.Error;
const Lock = portdat.Lock;
const QLock = portdat.QLock;
const Rendez = portdat.Rendez;
const Chan = portdat.Chan;
const Pcidev = pci.Pcidev;
const SDev = devsd.SDev;
const SDunit = devsd.SDunit;
const SDreq = devsd.SDreq;
const SDifc = devsd.SDifc;
const SDok = devsd.SDok;
const SDeio = devsd.SDeio;
const SDnostatus = devsd.SDnostatus;
const SDwrite = devsd.SDwrite;
const ilock = taslock.ilock;
const iunlock = taslock.iunlock;
const lock = taslock.lock;
const unlock = taslock.unlock;
const qlock = ql.qlock;
const qunlock = ql.qunlock;
const MAXMACH = arch.mem.MAXMACH;
const READSTR = portdat.READSTR;

const WS = struct {
    cdw0: u32 = 0,
    status: u16 = 0,
    sleep: *Rendez = undefined,
    link: *?*WS = undefined,
    queue: *SQ = undefined,
};

const CQ = struct {
    head: u32 = 0,
    mask: u32 = 0,
    shift: u32 = 0,
    base: ?[*]volatile u32 = null,
    ctlr: ?*Ctlr = null,
};

const SQ = struct {
    tail: u32 = 0,
    mask: u32 = 0,
    shift: u32 = 0,
    base: ?[*]volatile u32 = null,
    wait: []?*WS = &.{},
    ctlr: ?*Ctlr = null,
    lock: Lock = .{},
};

const Ctlr = struct {
    qlock: QLock = .{},

    intr: Lock = .{},
    ints: u32 = 0,
    irqc: [2]u32 = @splat(0),

    /// DIFF: MSI-X is on, so INTMS and INTMC must be left alone.
    msix: bool = false,
    /// DIFF: interrupts taken, and whether their absence was reported.
    nintr: u32 = 0,
    nointr: bool = false,
    /// DIFF: the most bytes in one transfer (MDTS); 0 is no limit.
    maxxfer: u64 = 0,
    /// DIFF: for messages.
    sdev: ?*SDev = null,
    /// DIFF: name spaces whose size has been printed, by unit number.
    shown: [1024 / 32]u32 = @splat(0),

    pci: *Pcidev,
    reg: [*]volatile u32,

    cap: u64 = 0,
    ident: ?[*]u8 = null,
    nsid: ?[*]u32 = null,
    nnsid: usize = 0,

    mps: u32 = 0, // mps = 1<<mpsshift
    mpsshift: u32 = 0,
    dstrd: u32 = 0,

    nsq: u32 = 0,

    cq: [1 + 1]CQ = @splat(.{}),
    sq: [1 + MAXMACH]SQ = @splat(.{}),

    next: ?*Ctlr = null,
};

// controller registers
const Cap0 = 0;
const Cap1 = 1;
const Ver = 2;
const IntMs = 3;
const IntMc = 4;
const CCfg = 5;

const CSts = 0x1C / 4;
const Nssr = CSts + 1;
const AQAttr = CSts + 2;
const ASQBase0 = CSts + 3;
const ASQBase1 = CSts + 4;
const ACQBase0 = CSts + 5;
const ACQBase1 = CSts + 6;

const DBell = 0x1000 / 4;

/// DIFF: wcmd's status for a command it gave up on.
const Timeout = 0xFFFF;
/// DIFF: how long wcmd waits for an admin command, in ms.
const Admto = 10 * 1000;

/// DIFF: the controller's name for messages.
fn cname(ctlr: *Ctlr) []const u8 {
    if (ctlr.sdev) |sd|
        return sd.namestr();
    return "nvme";
}

/// DIFF: an identify string without the blanks it is padded with.
fn idstr(s: []const u8) []const u8 {
    return std.mem.trim(u8, std.mem.sliceTo(s, 0), " ");
}

/// DIFF: whether the device's MSI-X capability is enabled.
fn msixon(p: *Pcidev) bool {
    const off = pci.pcicap(p, pci.PciCapMSIX);
    return off >= 0 and (pci.pcicfgr16(p, off + 2) & 0x8000) != 0;
}

/// The number of sq in ctlr.sq (sq - ctlr->sq).
fn sqno(ctlr: *Ctlr, sq: *SQ) usize {
    return (@intFromPtr(sq) - @intFromPtr(&ctlr.sq[0])) / @sizeOf(SQ);
}

fn qcmd(ws: *WS, ctlr: *Ctlr, adm: bool, opc: u32, nsid: u32, data: ?[*]u8, len: usize) [*]volatile u32 {
    var sq: *SQ = undefined;

    if (adm)
        qlock(&ctlr.qlock);
    retry: while (true) {
        if (!adm) {
            _ = arch.splhi();
            sq = &ctlr.sq[1 + (@as(u32, @intCast(arch.m().machno)) % ctlr.nsq)];
            if (arch.conf.nmach > ctlr.nsq)
                lock(&sq.lock);
        } else {
            sq = &ctlr.sq[0];
        }
        ws.sleep = &arch.up().?.sleep;
        ws.queue = sq;
        ws.link = &sq.wait[sq.tail & sq.mask];
        while (ws.link.* != null) {
            // should be very rare
            if (!adm) {
                if (arch.conf.nmach > ctlr.nsq)
                    unlock(&sq.lock);
                proc.sched();
                continue :retry;
            }
            proc.sched();
        }
        break;
    }
    ws.link.* = ws;

    const cid = sq.tail;
    sq.tail +%= 1;
    const e = sq.base.? + ((cid & sq.mask) << 4);
    e[0] = opc | cid << 16;
    e[1] = nsid;
    e[2] = 0;
    e[3] = 0;
    e[4] = 0;
    e[5] = 0;
    // DIFF: the C leaves these as the entry's last command had them.
    for (10..16) |i| e[i] = 0;
    var pa: u64 = 0;
    if (len > 0) {
        pa = arch.paddr(@intFromPtr(data.?));
        e[6] = @truncate(pa);
        e[7] = @truncate(pa >> 32);
        if (len > ctlr.mps - (pa & (ctlr.mps - 1)))
            pa += ctlr.mps - (pa & (ctlr.mps - 1))
        else
            pa = 0;
    } else {
        e[6] = 0;
        e[7] = 0;
        pa = 0;
    }
    e[8] = @truncate(pa);
    e[9] = @truncate(pa >> 32);
    return e;
}

fn nvmeintr(_: *arch.Ureg, arg: ?*anyopaque) void {
    const ctlr: *Ctlr = @ptrCast(@alignCast(arg.?));
    ctlr.nintr +%= 1; // DIFF
    nvmepoll(ctlr);
}

/// DIFF: the body of nvmeintr.
fn nvmepoll(ctlr: *Ctlr) void {
    if (ctlr.ints == 0)
        return;

    ilock(&ctlr.intr);
    if (!ctlr.msix)
        ctlr.reg[IntMs] = ctlr.ints;
    var qi: usize = ctlr.cq.len;
    while (qi > 0) {
        qi -= 1;
        const cq = &ctlr.cq[qi];
        const base = cq.base orelse continue;
        const phaseshift: u5 = @intCast(16 - cq.shift);
        while (true) {
            const e = base + ((cq.head & cq.mask) << 2);
            if (((e[3] ^ (cq.head << phaseshift)) & 0x10000) == 0)
                break;

            if (false) p9.iprint("nvmeintr: cq%d [%.4ux] %.8ux %.8ux %.8ux %.8ux\n", .{
                qi,   cq.head & cq.mask,
                e[0], e[1],
                e[2], e[3],
            });

            // DIFF: the C trusts the device.
            const sqid = e[2] >> 16;
            if (sqid < ctlr.sq.len and ctlr.sq[sqid].wait.len != 0) {
                const sq = &ctlr.sq[sqid];
                const wp = &sq.wait[e[3] & sq.mask];
                if (wp.*) |ws| {
                    if (ws.link == wp) {
                        const z = ws.sleep;
                        ws.cdw0 = e[0];
                        ws.status = @truncate(e[3] >> 17);
                        wp.* = null;
                        _ = proc.wakeup(z);
                    }
                }
            }
            cq.head +%= 1;
            ctlr.reg[DBell + ((qi * 2 + 1) << @intCast(ctlr.dstrd))] = cq.head & cq.mask;
        }
    }
    if (!ctlr.msix)
        ctlr.reg[IntMc] = ctlr.ints;
    iunlock(&ctlr.intr);
}

fn wdone(arg: ?*anyopaque) bool {
    const ws: *WS = @ptrCast(@alignCast(arg.?));
    return @as(*volatile ?*WS, ws.link).* != ws;
}

fn wcmd(ws: *WS, e: ?[*]volatile u32) u32 {
    const sq = ws.queue;
    const ctlr = sq.ctlr.?;

    _ = e;
    arch.coherence();
    ctlr.reg[DBell + ((sqno(ctlr, sq) * 2 + 0) << @intCast(ctlr.dstrd))] = sq.tail & sq.mask;
    if (sq != &ctlr.sq[0]) {
        if (sq != &ctlr.sq[1 + (@as(u32, @intCast(arch.m().machno)) % ctlr.nsq)])
            panic("nvme: wcmd: not this processor's queue", .{});
        if (arch.conf.nmach > ctlr.nsq)
            unlock(&sq.lock);
        _ = arch.spllo();
    } else {
        qunlock(&ctlr.qlock);
    }
    // not interruptible: the controller still has the buffers
    proc.tsleep(ws.sleep, wdone, ws, 5) catch {};
    // DIFF: the C's loop is the poll and the tsleep alone.
    var t0 = arch.MACHP(0).ticks;
    while (!wdone(ws)) {
        nvmepoll(ctlr);
        if (wdone(ws)) {
            if (ctlr.nintr == 0 and !ctlr.nointr) {
                ctlr.nointr = true;
                print("%s: nvme: no interrupts; polling\n", .{cname(ctlr)});
            }
            break;
        }
        if (arch.MACHP(0).ticks -% t0 >= Admto * arch.mem.HZ / 1000) {
            t0 = arch.MACHP(0).ticks;
            print("%s: nvme: command timeout; sq %lud csts %ux\n", .{ cname(ctlr), sqno(ctlr, sq), ctlr.reg[CSts] });
            if (sq == &ctlr.sq[0]) {
                ilock(&ctlr.intr);
                const lost = ws.link.* == ws;
                if (lost)
                    ws.link.* = null;
                iunlock(&ctlr.intr);
                if (lost)
                    return Timeout;
                break;
            }
        }
        proc.tsleep(ws.sleep, wdone, ws, 10) catch {};
    }
    return @as(*volatile u16, &ws.status).*;
}

fn checkstatus(status: u32, info: []const u8) Error!void {
    if (status == 0)
        return;
    return proc.errorf("%s: status %ux", .{ info, status });
}

fn nvmebio(u: *SDunit, _: u32, write: bool, a: []u8, nb: usize, bno: u64) Error!isize {
    const ctlr: *Ctlr = @ptrCast(@alignCast(u.dev.ctlr.?));
    const nsid = ctlr.nsid.?[u.subno];
    const s: usize = u.secsize;
    var p: [*]u8 = a.ptr;
    var count = nb;
    var lba = bno;
    var ws: WS = .{};
    while (count > 0) {
        const m = (2 * @as(usize, ctlr.mps) - (@intFromPtr(p) & (ctlr.mps - 1))) / s;
        var n = count;
        if (n > m)
            n = m;
        // DIFF: MDTS
        if (ctlr.maxxfer != 0 and n > ctlr.maxxfer / s)
            n = @intCast(ctlr.maxxfer / s);
        if (n == 0)
            return error.Eio;
        const e = qcmd(&ws, ctlr, false, if (write) 0x01 else 0x02, nsid, p, n * s);
        e[10] = @truncate(lba);
        e[11] = @truncate(lba >> 32);
        e[12] = @intCast(n - 1);
        e[13] = @as(u32, @intFromBool(count > n)) << 6; // sequential request
        e[14] = 0;
        e[15] = 0;
        try checkstatus(wcmd(&ws, e), if (write) "write" else "read");
        p += n * s;
        count -= n;
        lba += n;
    }
    return @intCast(@intFromPtr(p) - @intFromPtr(a.ptr));
}

fn nvmerio(r: *SDreq) i32 {
    const u = r.unit;
    if (r.cmd[0] == 0x35 or r.cmd[0] == 0x91)
        return devsd.sdsetsense(r, SDok, 0, 0, 0);
    var i = devsd.sdfakescsi(r);
    if (i != SDnostatus) {
        r.status = i;
        return i;
    }
    var lba: u64 = undefined;
    var count: u32 = undefined;
    var rw: bool = undefined;
    i = devsd.sdfakescsirw(r, &lba, &count, &rw);
    if (i != SDnostatus)
        return i;
    // sdfakescsirw has answered already if there is no data.
    const data = r.data.?[0 .. @as(usize, count) * u.secsize];
    // DIFF: the C lets nvmebio's error() pass through.
    const n = nvmebio(u, r.lun, rw == SDwrite, data, count, lba) catch {
        r.status = SDeio;
        return SDeio;
    };
    r.rlen = @intCast(n);
    r.status = SDok;
    return SDok;
}

fn get64(p: [*]const u8) u64 {
    return std.mem.readInt(u64, p[0..8], .little);
}

fn readsmart(u: *SDunit, _: *Chan, a: []u8, off: i64) Error!usize {
    const ctlr: *Ctlr = @ptrCast(@alignCast(u.dev.ctlr.?));
    var ws: WS = .{};

    const buf = alloc.smalloc(READSTR)[0..READSTR];
    defer alloc.free(buf);
    var p: usize = 0;

    const info = alloc.mallocalign(0x1000, ctlr.mps, 0, 0) orelse return error.Enomem;
    // DIFF: a controller that did not answer still has the buffer.
    var st: u32 = 0;
    defer if (st != Timeout) alloc.free(info);

    // Log Page Attributes (LPA) Bit0: If set to '1' then te controller
    // supports SMART / Health information log page on a per namespace basis.
    const nsid: u32 = if ((ctlr.ident.?[261] & 1) != 0) ctlr.nsid.?[u.subno] else 0xffffffff;

    const q = qcmd(&ws, ctlr, true, 0x02, nsid, info, 0x1000);
    q[10] = (512 / 4) << 16 | 0x2;
    q[11] = 0;
    q[12] = 0;
    q[13] = 0;
    q[14] = 0;
    st = wcmd(&ws, q);
    try checkstatus(st, "read SMART/health info");

    p += fmt.snprint(buf[p..], "Critical Warning:\t", .{}).len;
    if (info[0] & (1 << 0) != 0)
        p += fmt.snprint(buf[p..], "Available Spare,", .{}).len;
    if (info[0] & (1 << 1) != 0)
        p += fmt.snprint(buf[p..], "Temperature Exceeded,", .{}).len;
    if (info[0] & (1 << 2) != 0)
        p += fmt.snprint(buf[p..], "Reliability Degraded,", .{}).len;
    if (info[0] & (1 << 3) != 0)
        p += fmt.snprint(buf[p..], "Read only mode,", .{}).len;
    if (info[0] & (1 << 4) != 0)
        p += fmt.snprint(buf[p..], "Backup failed,", .{}).len;
    buf[p - 1] = '\n';

    p += fmt.snprint(buf[p..], "Temperature:\t%d\n", .{@as(i32, @as(u16, info[2]) << 8 | info[1]) - 273}).len;

    p += fmt.snprint(buf[p..], "Available Spare:\t%d%%\n", .{info[3]}).len;
    p += fmt.snprint(buf[p..], "Available Spare Threshold:\t%d%%\n", .{info[4]}).len;

    p += fmt.snprint(buf[p..], "Percentage Used:\t%d%%\n", .{info[5]}).len;

    p += fmt.snprint(buf[p..], "Data Units Read:\t%llud\n", .{get64(info + 32)}).len;
    p += fmt.snprint(buf[p..], "Data Units Written:\t%llud\n", .{get64(info + 48)}).len;
    p += fmt.snprint(buf[p..], "Host Read Commands:\t%llud\n", .{get64(info + 64)}).len;
    p += fmt.snprint(buf[p..], "Host Write Commands:\t%llud\n", .{get64(info + 80)}).len;
    p += fmt.snprint(buf[p..], "Controller Busy Time:\t%llud:%.2d\n", .{ get64(info + 96) / 60, @as(i32, @intCast(get64(info + 96) % 60)) }).len;
    p += fmt.snprint(buf[p..], "Power Cycles:\t%llud\n", .{get64(info + 112)}).len;
    p += fmt.snprint(buf[p..], "Power On Hours:\t%llud\n", .{get64(info + 128)}).len;
    p += fmt.snprint(buf[p..], "Unsafe Shutdowns:\t%llud\n", .{get64(info + 144)}).len;
    p += fmt.snprint(buf[p..], "Media Errors:\t%llud\n", .{get64(info + 160)}).len;

    // (ulong)off
    return devcons.readstr(@as(u32, @truncate(@as(u64, @bitCast(off)))), a, buf[0..p]);
}

fn nvmeverify(u: *SDunit) i32 {
    const ctlr: *Ctlr = @ptrCast(@alignCast(u.dev.ctlr.?));

    if (u.subno >= ctlr.nnsid)
        return 0;
    _ = devsd.sdaddfile(u, "smart", 0o440, proc.eve, readsmart, null);
    return 1;
}

fn nvmeonline(u: *SDunit) i32 {
    var ws: WS = .{};

    if (u.sectors != 0)
        return 1;

    const ctlr: *Ctlr = @ptrCast(@alignCast(u.dev.ctlr.?));
    const info = alloc.mallocalign(0x1000, ctlr.mps, 0, 0) orelse return 0;

    const e = qcmd(&ws, ctlr, true, 0x06, ctlr.nsid.?[u.subno], info, 0x1000);
    e[10] = 0; // identify namespace
    const st = wcmd(&ws, e);
    if (st != 0) {
        // DIFF: a controller that did not answer still has the buffer.
        if (st != Timeout)
            alloc.free(info);
        return 0;
    }
    u.sectors = get64(info);
    const p = info + (128 + 4 * @as(usize, info[26] & 15));
    const lbaf = std.mem.readInt(u32, p[0..4], .little);
    // DIFF: the shift is cut to 5 bits.
    u.secsize = @as(u32, 1) << @truncate((lbaf >> 16) & 0xFF);
    alloc.free(info);

    @memset(&u.inquiry, 0);
    u.inquiry[2] = 2;
    u.inquiry[3] = 2;
    u.inquiry[4] = u.inquiry.len - 4;
    @memcpy(u.inquiry[8..][0..20], ctlr.ident.?[24..][0..20]);

    // DIFF: say what was found, once.
    if (u.subno < 1024 and ctlr.shown[u.subno / 32] & @as(u32, 1) << @truncate(u.subno) == 0) {
        ctlr.shown[u.subno / 32] |= @as(u32, 1) << @truncate(u.subno);
        print("%s: nvme ns %ud: %,llud sectors of %lud\n", .{ u.perm.name, ctlr.nsid.?[u.subno], u.sectors, u.secsize });
    }

    return 2;
}

fn nvmerctl(u: *SDunit, buf: []u8) usize {
    const ctlr: *Ctlr = @ptrCast(@alignCast(u.dev.ctlr orelse return 0));
    const ident = ctlr.ident orelse return 0;
    var p: usize = 0;

    p += fmt.snprint(buf[p..], "model\t%.40s\n", .{std.mem.sliceTo(ident[24..][0..40], 0)}).len;
    p += fmt.snprint(buf[p..], "serial\t%.20s\n", .{std.mem.sliceTo(ident[4..][0..20], 0)}).len;
    p += fmt.snprint(buf[p..], "firm\t%.8s\n", .{std.mem.sliceTo(ident[64..][0..8], 0)}).len;
    p += fmt.snprint(buf[p..], "geometry %llud %lud\n", .{ u.sectors, u.secsize }).len;

    return p;
}

fn cqalloc(ctlr: *Ctlr, cq: *CQ, lgsize: u32) Error![*]volatile u32 {
    cq.ctlr = ctlr;
    cq.head = 0;
    cq.shift = lgsize - 4;
    cq.mask = (@as(u32, 1) << @intCast(cq.shift)) - 1;
    const size = @as(usize, 1) << @intCast(lgsize);
    const base = alloc.mallocalign(size, ctlr.mps, 0, 0) orelse return error.Enomem;
    @memset(base[0..size], 0);
    cq.base = @ptrCast(@alignCast(base));
    return cq.base.?;
}

fn sqalloc(ctlr: *Ctlr, sq: *SQ, lgsize: u32) Error![*]volatile u32 {
    sq.ctlr = ctlr;
    sq.tail = 0;
    sq.shift = lgsize - 6;
    sq.mask = (@as(u32, 1) << @intCast(sq.shift)) - 1;
    const size = @as(usize, 1) << @intCast(lgsize);
    const base = alloc.mallocalign(size, ctlr.mps, 0, 0) orelse return error.Enomem;
    sq.base = @ptrCast(@alignCast(base));
    sq.wait = alloc.newslice(?*WS, sq.mask + 1) orelse return error.Enomem;
    @memset(sq.wait, null);
    @memset(base[0..size], 0);
    return sq.base.?;
}

fn setupqueues(ctlr: *Ctlr) Error!void {
    var ws: WS = .{};

    var mqes: u32 = 1 + @as(u32, @truncate(ctlr.cap & 0xFFFF));
    if (mqes < 2)
        mqes = 2;
    var lgsqsize: u32 = 0;
    while (@as(u32, 1) << @intCast(lgsqsize) < mqes) lgsqsize += 1;
    if (lgsqsize > 12 - 6)
        lgsqsize = 12 - 6;
    var nsq: u32 = arch.conf.nmach;

    // DIFF: Set Features, Number of Queues: nsq submission queues and
    // one completion queue (both counts are zero based).  The answer is
    // what the controller allocated, which can be fewer or more.  A
    // controller that refuses is left to refuse the queues themselves.
    var e = qcmd(&ws, ctlr, true, 0x09, 0, null, 0);
    e[10] = 0x07;
    e[11] = nsq - 1;
    const nqst = wcmd(&ws, e);
    if (nqst == Timeout)
        try checkstatus(nqst, "set number of queues");
    if (nqst == 0) {
        const nsqa = (ws.cdw0 & 0xFFFF) + 1;
        if (nsq > nsqa)
            nsq = nsqa;
    }

    var lgcqsize: u32 = undefined;
    while (true) {
        lgcqsize = lgsqsize;
        if (lgcqsize == 0)
            break;
        while (nsq >= @as(u32, 1) << @intCast(lgcqsize))
            nsq >>= 1;
        while (@as(u32, 1) << @intCast(lgcqsize) < nsq << @intCast(lgsqsize))
            lgcqsize += 1;
        if (@as(u32, 1) << @intCast(lgcqsize) <= mqes)
            break;
        lgsqsize -= 1;
    }
    lgsqsize += 6;
    lgcqsize += 4;

    // CQID1: shared completion queue
    const cqid = 1;
    const cq = &ctlr.cq[cqid];
    _ = try cqalloc(ctlr, cq, lgcqsize);
    e = qcmd(&ws, ctlr, true, 0x05, 0, @ptrCast(@volatileCast(cq.base.?)), @as(usize, 1) << @intCast(lgcqsize));
    e[10] = cqid | cq.mask << 16;
    e[11] = 3; // IEN | PC
    try checkstatus(wcmd(&ws, e), "create completion queue");

    var st: u32 = 0;

    // SQID[1..nmach]: submission queue per cpu
    var i: u32 = 1;
    while (i <= nsq) : (i += 1) {
        const sq = &ctlr.sq[i];
        _ = try sqalloc(ctlr, sq, lgsqsize);
        e = qcmd(&ws, ctlr, true, 0x01, 0, @ptrCast(@volatileCast(sq.base.?)), @as(usize, 1) << @intCast(lgsqsize));
        e[10] = i | sq.mask << 16;
        e[11] = cqid << 16 | 1; // CQID<<16 | PC
        st = wcmd(&ws, e);
        if (st != 0) {
            alloc.free(sq.base);
            alloc.free(sq.wait);
            sq.* = .{};
            break;
        }
    }

    ctlr.nsq = i - 1;
    if (ctlr.nsq < 1)
        try checkstatus(st, "create submission queues");

    ilock(&ctlr.intr);
    ctlr.ints |= 1 << cqid;
    if (!ctlr.msix)
        ctlr.reg[IntMc] = ctlr.ints;
    iunlock(&ctlr.intr);
}

fn identify(ctlr: *Ctlr) Error!void {
    var ws: WS = .{};

    if (ctlr.ident == null)
        ctlr.ident = alloc.mallocalign(0x1000, ctlr.mps, 0, 0) orelse return error.Enomem;
    if (ctlr.nsid == null)
        ctlr.nsid = @ptrCast(@alignCast(alloc.mallocalign(0x1000, ctlr.mps, 0, 0) orelse return error.Enomem));

    var e = qcmd(&ws, ctlr, true, 0x06, 0, ctlr.ident, 0x1000);
    e[10] = 1; // identify controller
    try checkstatus(wcmd(&ws, e), "identify controller");

    e = qcmd(&ws, ctlr, true, 0x06, 0, @ptrCast(ctlr.nsid), 0x1000);
    e[10] = 2; // namespace list
    if (wcmd(&ws, e) != 0)
        ctlr.nsid.?[0] = 1; // assume namespace #1

    ctlr.nnsid = 0;
    while (ctlr.nnsid < 1024 and ctlr.nsid.?[ctlr.nnsid] != 0)
        ctlr.nnsid += 1;

    // DIFF: MDTS, a power of two of the smallest page (CAP.MPSMIN).
    const mdts = ctlr.ident.?[77];
    ctlr.maxxfer = 0;
    if (mdts != 0 and mdts < 32)
        ctlr.maxxfer = @as(u64, 1) << @intCast(12 + ((ctlr.cap >> 48) & 15) + mdts);
}

fn nvmedisable(sd: *SDev) i32 {
    var namebuf: [32]u8 = undefined;

    const ctlr: *Ctlr = @ptrCast(@alignCast(sd.ctlr.?));

    // mask interrupts
    ilock(&ctlr.intr);
    ctlr.ints = 0;
    if (!ctlr.msix)
        ctlr.reg[IntMs] = ~ctlr.ints;
    iunlock(&ctlr.intr);

    // notify normal power off
    ctlr.reg[CCfg] = (ctlr.reg[CCfg] & ~@as(u32, 3 << 14)) | 1 << 14;
    var i: usize = 0;
    while (i < 3000) : (i += 1) {
        if ((ctlr.reg[CSts] & 0xc) == 0x8)
            break;
        arch.delay(1);
    }

    // disable controller
    ctlr.reg[CCfg] = 0;
    i = 0;
    while (i < 1000) : (i += 1) {
        if ((ctlr.reg[CSts] & 1) == 0)
            break;
        arch.delay(1);
    }

    const name = fmt.snprint(&namebuf, "%s (%s)", .{ sd.namestr(), sd.ifc.name });
    arch.intrdisable(ctlr.pci.intl, nvmeintr, ctlr, ctlr.pci.tbdf, name);
    ctlr.msix = msixon(ctlr.pci);

    pci.pciclrbme(ctlr.pci); // dma disable

    for (&ctlr.sq) |*sq| {
        alloc.free(sq.base);
        if (sq.wait.len != 0)
            alloc.free(sq.wait);
    }
    for (&ctlr.cq) |*cq|
        alloc.free(cq.base);

    for (&ctlr.sq) |*sq| sq.* = .{};
    for (&ctlr.cq) |*cq| cq.* = .{};

    alloc.free(ctlr.ident);
    ctlr.ident = null;
    alloc.free(ctlr.nsid);
    ctlr.nsid = null;
    ctlr.nnsid = 0;

    return 1;
}

fn nvmeenable(sd: *SDev) i32 {
    var namebuf: [32]u8 = undefined;

    const ctlr: *Ctlr = @ptrCast(@alignCast(sd.ctlr.?));

    const name = fmt.snprint(&namebuf, "%s (%s)", .{ sd.namestr(), sd.ifc.name });
    arch.intrenable(ctlr.pci.intl, nvmeintr, ctlr, ctlr.pci.tbdf, name);
    // DIFF: see the top of the file
    ctlr.msix = msixon(ctlr.pci);

    nvmeenable1(ctlr, name) catch |err| {
        print("%s: %s\n", .{ name, proc.errtext(err) });
        _ = nvmedisable(sd);
        sd.nunit = 0; // hack: prevent further probing
        return 0;
    };

    return 1;
}

/// DIFF: what the waserror in nvmeenable protects.
fn nvmeenable1(ctlr: *Ctlr, name: []const u8) Error!void {
    // DIFF: nvmepnp cleared CC.EN; the queues may not be set and the
    // controller may not be enabled again before it says it has stopped.
    var to: i32 = (@as(i32, @intCast((ctlr.cap >> 24) & 255)) + 1) * 500;
    while (ctlr.reg[CSts] & 1 != 0) : (to -= 10) {
        if (to <= 0)
            return proc.errorf("controller disable timeout: csts %ux", .{ctlr.reg[CSts]});
        try proc.tsleep(&arch.up().?.sleep, proc.return0, null, 10);
    }

    var pa = arch.paddr(@intFromPtr(try cqalloc(ctlr, &ctlr.cq[0], ctlr.mpsshift)));
    ctlr.reg[ACQBase0] = @truncate(pa);
    ctlr.reg[ACQBase1] = @truncate(pa >> 32);

    pa = arch.paddr(@intFromPtr(try sqalloc(ctlr, &ctlr.sq[0], ctlr.mpsshift)));
    ctlr.reg[ASQBase0] = @truncate(pa);
    ctlr.reg[ASQBase1] = @truncate(pa >> 32);

    ctlr.reg[AQAttr] = ctlr.sq[0].mask | ctlr.cq[0].mask << 16;

    // dma enable
    pci.pcisetbme(ctlr.pci);

    // enable interrupt
    ilock(&ctlr.intr);
    ctlr.ints = 1;
    if (!ctlr.msix)
        ctlr.reg[IntMc] = ctlr.ints;
    iunlock(&ctlr.intr);

    // enable controller
    ctlr.reg[CCfg] = 1 | (ctlr.mpsshift - 12) << 7 | 6 << 16 | 4 << 20;

    to = @intCast((ctlr.cap >> 24) & 255);
    while (true) : (to -= 1) {
        if (to < 0) {
            if (ctlr.reg[CSts] & 2 != 0)
                return proc.errorf("fatal controller status during initialization", .{});
            return proc.errorf("controller initialization timeout", .{});
        }
        try proc.tsleep(&arch.up().?.sleep, proc.return0, null, 500);
        if ((ctlr.reg[CSts] & 3) == 1)
            break;
    }
    // Ready:
    try identify(ctlr);
    try setupqueues(ctlr);
    // DIFF: the C prints the queues only.
    print("%s: %s %s: %d submit queues, %d namespaces\n", .{
        name,     idstr(ctlr.ident.?[24..][0..40]), idstr(ctlr.ident.?[4..][0..20]),
        ctlr.nsq, ctlr.nnsid,
    });
}

/// DIFF: the C's Bad label.
fn bad(p: *Pcidev, ctlr: *Ctlr, reg: ?usize) void {
    if (reg) |va|
        arch.vunmap(va, @intCast(p.mem[0].size));
    pci.pcidisable(p);
    alloc.free(ctlr);
}

fn nvmepnpctlrs() ?*Ctlr {
    var h: ?*Ctlr = null;
    var t: ?*Ctlr = null;
    var pp: ?*Pcidev = null;
    while (true) {
        pp = pci.pcimatch(pp, 0, 0);
        const p = pp orelse break;
        if (p.ccrb != 1 or p.ccru != 8 or p.ccrp != 2)
            continue;
        if (p.mem[0].size == 0 or (p.mem[0].bar & 1) != 0)
            continue;
        const ctlr = alloc.new(Ctlr) orelse {
            print("nvme: no memory for Ctlr\n", .{});
            break;
        };
        pci.pcienable(p);
        const reg = arch.vmap(p.mem[0].bar & ~@as(u64, 0xF), @intCast(p.mem[0].size)) orelse {
            print("nvme: can't vmap bar0\n", .{});
            bad(p, ctlr, null);
            continue;
        };
        ctlr.* = .{ .pci = p, .reg = @ptrFromInt(reg) };
        ctlr.cap = ctlr.reg[Cap0];
        ctlr.cap |= @as(u64, ctlr.reg[Cap1]) << 32;

        // mask interrupts
        ctlr.ints = 0;
        ctlr.msix = msixon(p);
        if (!ctlr.msix)
            ctlr.reg[IntMs] = ~ctlr.ints;

        // disable controller
        ctlr.reg[CCfg] = 0;

        if ((ctlr.cap & (1 << 37)) == 0) {
            print("nvme: doesnt support NVM commactlr set: %ux\n", .{@as(u32, @truncate(ctlr.cap >> 37)) & 0xFF});
            bad(p, ctlr, reg);
            continue;
        }

        // use 64K page size when possible
        ctlr.dstrd = @truncate((ctlr.cap >> 32) & 15);
        var i: u32 = @truncate((ctlr.cap >> 48) & 15);
        while (i < ((ctlr.cap >> 52) & 15)) : (i += 1) {
            if (i >= 16 - 12) // 64K
                break;
        }
        ctlr.mpsshift = i + 12;
        ctlr.mps = @as(u32, 1) << @intCast(ctlr.mpsshift);

        if (h == null)
            h = ctlr
        else
            t.?.next = ctlr;
        t = ctlr;
    }

    return h;
}

fn nvmepnp() ?*SDev {
    var h: ?*SDev = null;
    var t: ?*SDev = null;

    var id: u8 = 'N';
    var cp = nvmepnpctlrs();
    while (cp) |ctlr| : (cp = ctlr.next) {
        const s = alloc.new(SDev) orelse break;
        s.* = .{ .ifc = &sdnvmeifc, .ctlr = ctlr, .idno = id, .nunit = 1024 };
        ctlr.sdev = s; // DIFF
        id += 1;
        if (h != null)
            t.?.next = s
        else
            h = s;
        t = s;
    }

    return h;
}

pub const sdnvmeifc: SDifc = .{
    .name = "nvme",
    .pnp = nvmepnp,
    .enable = nvmeenable,
    .disable = nvmedisable,
    .verify = nvmeverify,
    .online = nvmeonline,
    .rio = nvmerio,
    .rctl = nvmerctl,
    .bio = nvmebio,
};
