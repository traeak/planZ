//! virtio 1.0 ethernet driver
//! http://docs.oasis-open.org/virtio/virtio/v1.0/virtio-v1.0.html
//! from 9/port/ethervirtio10.c
//!
//! In contrast to ethervirtio.c, this driver handles the non-legacy
//! interface for virtio ethernet which uses mmio for all register accesses
//! and requires a laborate pci capability structure dance to get working.
//!
//! It is kind of pointless as it is most likely slower than
//! port i/o (harder to emulate on the pc platform).
//!
//! The reason why this driver is needed it is that vultr set the
//! disable-legacy=on option in the -device parameter for qemu
//! on their hypervisor.
//!
//! (In planZ it is the only virtio ethernet driver: port code does no
//! port i/o.)
//!
//! DIFF:
//!   - Interrupts are MSI-X, where the C relies on the interrupt pin.
//!     With MSI-X on, a virtio device interrupts for a queue only
//!     through the table entry chosen for that queue, so reset(), after
//!     intrenable has programmed and enabled the table, writes entry 0
//!     to Vconf_msixcfg and to every queue's Vconf_queuemsixvect and
//!     reads each back (msixvectors).  The ISR status register means
//!     nothing with MSI-X: interrupt() still reads it, which is
//!     harmless and acknowledges a pin interrupt, but looks at every
//!     queue whatever it says.
//!   - Registers are in memory only (see virtio10.zig), so the notify
//!     address has no I/O port case.
//!   - Everything the device shares (descriptors, both rings) is
//!     reached through volatile pointers; the C counts on its compiler
//!     keeping nothing in registers.  Every coherence() is kept.
//!   - The rings are page aligned, each in its own allocation; the C
//!     aligns them to 16, 2 and 4 bytes.  mallocalign here zeroes.
//!   - Errors: the `while(waserror());` of the kprocs became catches
//!     at the two places that can fail, qbread and sleep.  A sleep in
//!     txproc that is interrupted is retried with the packet still in
//!     hand; the C starts over at qbread and loses the block.
//!   - vctlcmd: the wait for the device's answer is retried when
//!     interrupted; the C's waserror loop would queue the command a
//!     second time.  The command header, data and ack are in one
//!     malloc'ed buffer reached through a volatile pointer, where the C
//!     hands the device addresses on the caller's stack.  It takes the
//!     data as a slice.
//!   - rxproc gives the device the room from rp to lim of a block; the
//!     C says BALLOC(b), which is lim-base and so more than there is
//!     after rp.  A used length shorter than the header or longer than
//!     the block is clamped instead of trusted.
//!   - reset() writes all six bytes of a configured address to the
//!     device.  The C has a stray semicolon after its for, so it
//!     writes one byte from past the end of the address to the
//!     (read-only) status register, which is to say nothing.
//!   - ifstat formats into a slice and returns the length (see netif).
//!   - promiscuous and multicast return error unions, as netif wants;
//!     they never fail.
//!   - An Ether's port, irq, mbps, link and arg are ether.isa.port,
//!     ether.isa.irq, ether.netif.mbps, ether.netif.link and
//!     ether.netif.arg (see devether).

const arch = @import("../arch.zig");
const fmt = @import("fmt");
const portdat = @import("portdat.zig");
const alloc = @import("alloc.zig");
const ab = @import("allocb.zig");
const qio = @import("qio.zig");
const proc = @import("proc.zig");
const taslock = @import("taslock.zig");
const ql = @import("qlock.zig");
const pci = @import("pci.zig");
const netif = @import("netif.zig");
const devether = @import("devether.zig");
const v10 = @import("virtio10.zig");
const p9 = @import("print.zig");

const print = p9.print;
const coherence = arch.coherence;
const ilock = taslock.ilock;
const iunlock = taslock.iunlock;
const qlock = ql.qlock;
const qunlock = ql.qunlock;
const sleep = proc.sleep;
const wakeup = proc.wakeup;
const kproc = proc.kproc;
const freeb = ab.freeb;
const BLEN = ab.BLEN;

const Error = proc.Error;
const Lock = portdat.Lock;
const QLock = portdat.QLock;
const Rendez = portdat.Rendez;
const KNAMELEN = portdat.KNAMELEN;
const Block = ab.Block;
const Bpool = ab.Bpool;
const Pcidev = pci.Pcidev;
const Ether = devether.Ether;
const Eaddrlen = devether.Eaddrlen;
const ETHERMAXTU = devether.ETHERMAXTU;

const Vio = v10.Vio;
const Vring = v10.Vring;
const Vdesc = v10.Vdesc;
const Vused = v10.Vused;
const vin8 = v10.vin8;
const vin16 = v10.vin16;
const vin32 = v10.vin32;
const vout8 = v10.vout8;
const vout16 = v10.vout16;
const vout32 = v10.vout32;
const vout64 = v10.vout64;
const virtiomapregs = v10.virtiomapregs;
const Vconf_devfeatsel = v10.Vconf_devfeatsel;
const Vconf_devfeat = v10.Vconf_devfeat;
const Vconf_drvfeatsel = v10.Vconf_drvfeatsel;
const Vconf_drvfeat = v10.Vconf_drvfeat;
const Vconf_msixcfg = v10.Vconf_msixcfg;
const Vconf_status = v10.Vconf_status;
const Vconf_queuesel = v10.Vconf_queuesel;
const Vconf_queuesize = v10.Vconf_queuesize;
const Vconf_queuemsixvect = v10.Vconf_queuemsixvect;
const Vconf_queueenable = v10.Vconf_queueenable;
const Vconf_queuenotifyoff = v10.Vconf_queuenotifyoff;
const Vconf_queuedesc = v10.Vconf_queuedesc;
const Vconf_queueavail = v10.Vconf_queueavail;
const Vconf_queueused = v10.Vconf_queueused;
const Vconf_sz = v10.Vconf_sz;
const Sacknowledge = v10.Sacknowledge;
const Sdriver = v10.Sdriver;
const Sdriverok = v10.Sdriverok;
const Sfeaturesok = v10.Sfeaturesok;
const Fversion1 = v10.Fversion1;

// flags in Qnetstatus
const Nlinkup = 1 << 0;
const Nannounce = 1 << 1;

// feat[0] bits
const Fmac: u32 = 1 << 5;
const Fstatus: u32 = 1 << 16;
const Fctrlvq: u32 = 1 << 17;
const Fctrlrx: u32 = 1 << 18;

// vring used flags
const Unonotify: u16 = 1;
// vring avail flags
const Rnointerrupt: u16 = 1;

// descriptor flags
const Dnext: u16 = 1;
const Dwrite: u16 = 2;
const Dindirect: u16 = 4;

// struct sizes
const VringSize = 4;
const VdescSize = 16;
const VusedSize = 8;
const VheaderSize = 12;

const Vrxq = 0;
const Vtxq = 1;
const Vctlq = 2;

// class/cmd for Vctlq
const CtrlRx = 0x00;
const CmdPromisc = 0x00;
const CmdAllmulti = 0x01;
const CtrlMac = 0x01;
const CmdMacTableSet = 0x00;
const CtrlVlan = 0x02;
const CmdVlanAdd = 0x00;
const CmdVlanDel = 0x01;

const Vnet_mac0 = 0;
const Vnet_status = 6;
const Vnet_sz = 8;

/// DIFF: the MSI-X table entry used for everything, and what the
/// device answers when it will not use the one it was given.
const Msixvect = 0;
const Nomsixvect = 0xFFFF;

const Vheader = extern struct {
    flags: u8,
    segtype: u8,
    hlen: u16,
    seglen: u16,
    csumstart: u16,
    csumend: u16,
};

const Vqueue = struct {
    r: Rendez = .{},

    qsize: usize = 0,
    qmask: usize = 0,

    desc: [*]volatile Vdesc = undefined,

    avail: *volatile Vring = undefined,
    availent: [*]volatile u16 = undefined,
    availevent: *volatile u16 = undefined,

    used: *volatile Vring = undefined,
    usedent: [*]volatile Vused = undefined,
    usedevent: *volatile u16 = undefined,
    lastused: u16 = 0,

    nintr: u32 = 0,
    nnote: u32 = 0,

    // notify register
    notify: Vio = .{},
};

const Ctlr = struct {
    lock: Lock = .{},

    ctllock: QLock = .{},

    attached: bool = false,

    // registers
    cfg: Vio = .{},
    dev: Vio = .{},
    isr: Vio = .{},
    notify: Vio = .{},
    notifyoffmult: u32 = 0,

    port: u64 = 0,
    pcidev: *Pcidev = undefined,
    next: ?*Ctlr = null,
    active: bool = false,
    feat: [2]u32 = @splat(0),
    nqueue: usize = 0,

    pool: Bpool = .{},

    // virtioether has 3 queues: rx, tx and ctl
    queue: [3]Vqueue = @splat(.{}),
};

var ctlrhead: ?*Ctlr = null;

fn ctlrof(edev: *Ether) *Ctlr {
    return @ptrCast(@alignCast(edev.ctlr.?));
}

fn vhasroom(v: ?*anyopaque) bool {
    const q: *Vqueue = @ptrCast(@alignCast(v.?));
    return q.lastused != q.used.idx;
}

fn vqnotify(ctlr: *Ctlr, x: u16) void {
    coherence();
    const q = &ctlr.queue[x];
    if (q.used.flags & Unonotify != 0)
        return;
    q.nnote +%= 1;
    vout16(&q.notify, 0, x);
}

fn txproc(v: ?*anyopaque) void {
    const edev: *Ether = @ptrCast(@alignCast(v.?));
    const ctlr = ctlrof(edev);
    const q = &ctlr.queue[Vtxq];

    const header = alloc.smalloc(VheaderSize);
    const blocks = alloc.snewslice(?*Block, q.qsize / 2);

    for (0..q.qsize / 2) |i| {
        var j = i << 1;
        q.desc[j].addr = arch.paddr(@intFromPtr(header));
        q.desc[j].len = VheaderSize;
        q.desc[j].next = @intCast(j | 1);
        q.desc[j].flags = Dnext;

        q.availent[i] = @intCast(j);
        q.availent[i + q.qsize / 2] = @intCast(j);

        j |= 1;
        q.desc[j].next = 0;
        q.desc[j].flags = 0;
    }

    q.avail.flags &= ~Rnointerrupt;

    // DIFF: while(waserror()); in the C, see the head of the file
    while (true) {
        const b = (qio.qbread(edev.oq.?, 1000000) catch continue) orelse
            break;
        var i: usize = undefined;
        while (true) {
            // retire completed packets
            while (q.lastused != q.used.idx) {
                const u = &q.usedent[q.lastused & q.qmask];
                i = (u.id & q.qmask) >> 1;
                if (blocks[i] == null)
                    break;
                freeb(blocks[i]);
                blocks[i] = null;
                q.lastused +%= 1;
            }

            // have free slot?
            i = q.avail.idx & (q.qmask >> 1);
            if (blocks[i] == null)
                break;

            // ring full, wait and retry
            if (!vhasroom(q))
                sleep(&q.r, vhasroom, q) catch {};
        }

        // slot is free, fill in descriptor
        blocks[i] = b;
        const j = (i << 1) | 1;
        q.desc[j].addr = arch.paddr(@intFromPtr(b.rp));
        q.desc[j].len = @intCast(BLEN(b));
        coherence();
        q.avail.idx +%= 1;
        vqnotify(ctlr, Vtxq);
    }

    proc.pexit("ether out queue closed", true);
}

fn rxproc(v: ?*anyopaque) void {
    const edev: *Ether = @ptrCast(@alignCast(v.?));
    const ctlr = ctlrof(edev);
    const q = &ctlr.queue[Vrxq];

    const header = alloc.smalloc(VheaderSize);
    const blocks = alloc.snewslice(?*Block, q.qsize / 2);

    ctlr.pool.size = ETHERMAXTU;
    ab.growbp(&ctlr.pool, q.qsize * 2);

    for (0..q.qsize / 2) |i| {
        var j = i << 1;
        q.desc[j].addr = arch.paddr(@intFromPtr(header));
        q.desc[j].len = VheaderSize;
        q.desc[j].next = @intCast(j | 1);
        q.desc[j].flags = Dwrite | Dnext;

        q.availent[i] = @intCast(j);
        q.availent[i + q.qsize / 2] = @intCast(j);

        j |= 1;
        q.desc[j].next = 0;
        q.desc[j].flags = Dwrite;
    }

    q.avail.flags &= ~Rnointerrupt;

    // DIFF: while(waserror()); in the C, see the head of the file
    while (true) {
        // replenish receive ring
        while (true) {
            const i = q.avail.idx & (q.qmask >> 1);
            if (blocks[i] != null)
                break;
            const b = ab.iallocbp(&ctlr.pool) orelse
                break;
            blocks[i] = b;
            const j = (i << 1) | 1;
            q.desc[j].addr = arch.paddr(@intFromPtr(b.rp));
            // DIFF: BALLOC(b) in the C, see the head of the file
            q.desc[j].len = @intCast(@intFromPtr(b.lim) - @intFromPtr(b.rp));
            coherence();
            q.avail.idx +%= 1;
            if (q.avail.idx == q.used.idx)
                break;
        }
        vqnotify(ctlr, Vrxq);

        // wait for any packets to complete
        if (!vhasroom(q))
            sleep(&q.r, vhasroom, q) catch {};

        // retire completed packets
        while (q.lastused != q.used.idx) {
            const u = &q.usedent[q.lastused & q.qmask];
            const i = (u.id & q.qmask) >> 1;
            const b = blocks[i] orelse
                break;

            blocks[i] = null;
            // DIFF: the length is clamped, see the head of the file
            var n: usize = u.len;
            n = if (n < VheaderSize) 0 else n - VheaderSize;
            b.wp = b.rp + @min(n, @intFromPtr(b.lim) - @intFromPtr(b.rp));
            devether.etheriq(edev, b);
            q.lastused +%= 1;
        }
    }
}

/// DIFF: hdr, data and ack are in one malloc'ed buffer, not on the
/// stack; see the head of the file.
fn vctlcmd(edev: *Ether, class: u8, cmd: u8, data: []const u8) i32 {
    const ctlr = ctlrof(edev);
    const q = &ctlr.queue[Vctlq];
    if (q.qsize < 3)
        return -1;

    const Nhdr = 2;
    const Nack = 1;
    const buf: [*]volatile u8 = alloc.smalloc(Nhdr + data.len + Nack);
    defer alloc.free(buf);
    const hdr = buf;
    const dat = buf + Nhdr;
    const ack = buf + Nhdr + data.len;

    qlock(&ctlr.ctllock);

    ack[0] = 0x55;
    hdr[0] = class;
    hdr[1] = cmd;
    for (data, 0..) |c, i|
        dat[i] = c;

    q.desc[0].addr = arch.paddr(@intFromPtr(hdr));
    q.desc[0].len = Nhdr;
    q.desc[0].next = 1;
    q.desc[0].flags = Dnext;

    q.desc[1].addr = arch.paddr(@intFromPtr(dat));
    q.desc[1].len = @intCast(data.len);
    q.desc[1].next = 2;
    q.desc[1].flags = Dnext;

    q.desc[2].addr = arch.paddr(@intFromPtr(ack));
    q.desc[2].len = Nack;
    q.desc[2].next = 0;
    q.desc[2].flags = Dwrite;

    const i = q.avail.idx & q.qmask;
    q.availent[i] = 0;
    coherence();

    q.avail.flags &= ~Rnointerrupt;
    q.avail.idx +%= 1;
    vqnotify(ctlr, Vctlq);
    // DIFF: an interrupted sleep is tried again; the C would start the
    // command over, with the first one still in the ring.
    while (!vhasroom(q))
        sleep(&q.r, vhasroom, q) catch {};
    q.lastused = q.used.idx;
    q.avail.flags |= Rnointerrupt;

    qunlock(&ctlr.ctllock);

    const a = ack[0];
    if (a != 0)
        print("#l%d: vctlcmd: %ux.%ux -> %ux\n", .{ edev.ctlrno, class, cmd, a });

    return a;
}

fn interrupt(_: *arch.Ureg, arg: ?*anyopaque) void {
    const edev: *Ether = @ptrCast(@alignCast(arg.?));
    const ctlr = ctlrof(edev);
    // DIFF: the C does the rest only if this has bit 0 set.  With MSI-X
    // the register is not used; reading it is harmless, and is what
    // takes a pin interrupt away.
    _ = vin8(&ctlr.isr, 0);
    for (ctlr.queue[0..ctlr.nqueue]) |*q| {
        if (vhasroom(q)) {
            q.nintr +%= 1;
            _ = wakeup(&q.r);
        }
    }
}

fn attach(edev: *Ether) Error!void {
    var name: [KNAMELEN]u8 = undefined;

    const ctlr = ctlrof(edev);
    ilock(&ctlr.lock);
    if (ctlr.attached) {
        iunlock(&ctlr.lock);
        return;
    }
    ctlr.attached = true;

    // enable the queues
    for (0..ctlr.nqueue) |i| {
        vout16(&ctlr.cfg, Vconf_queuesel, @intCast(i));
        vout16(&ctlr.cfg, Vconf_queueenable, 1);
    }

    // driver is ready
    vout8(&ctlr.cfg, Vconf_status, vin8(&ctlr.cfg, Vconf_status) | Sdriverok);

    iunlock(&ctlr.lock);

    // start kprocs
    kproc(fmt.snprint(&name, "#l%drx", .{edev.ctlrno}), rxproc, edev);
    kproc(fmt.snprint(&name, "#l%dtx", .{edev.ctlrno}), txproc, edev);
}

fn ifstat(a: ?*anyopaque, buf: []u8) Error!usize {
    if (buf.len == 0)
        return 0;
    const edev: *Ether = @ptrCast(@alignCast(a.?));
    const ctlr = ctlrof(edev);
    var s: fmt.Fmt = .{ .buf = buf };
    fmt.fmtprint(&s, "devfeat %32.32lub %32.32lub\n", .{ ctlr.feat[1], ctlr.feat[0] });
    fmt.fmtprint(&s, "devstatus %8.8ub\n", .{vin8(&ctlr.cfg, Vconf_status)});
    for (ctlr.queue[0..ctlr.nqueue], 0..) |*q, i| {
        fmt.fmtprint(&s, "vq%d %#p size %d avail->idx %d used->idx %d lastused %hud nintr %ud nnote %ud\n", .{
            i, q, q.qsize, q.avail.idx, q.used.idx, q.lastused, q.nintr, q.nnote,
        });
    }
    return s.n;
}

fn shutdown(edev: *Ether) void {
    const ctlr = ctlrof(edev);

    coherence();
    vout8(&ctlr.cfg, Vconf_status, 0);
    coherence();

    pci.pciclrbme(ctlr.pcidev);
}

fn promiscuous(arg: ?*anyopaque, on: bool) Error!void {
    const edev: *Ether = @ptrCast(@alignCast(arg.?));
    const ctlr = ctlrof(edev);

    if ((ctlr.feat[0] & (Fctrlvq | Fctrlrx)) != (Fctrlvq | Fctrlrx))
        return;

    const b = [1]u8{@intFromBool(on)};
    _ = vctlcmd(edev, CtrlRx, CmdPromisc, &b);
}

fn multicast(arg: ?*anyopaque, _: []const u8, _: bool) Error!void {
    const edev: *Ether = @ptrCast(@alignCast(arg.?));
    const ctlr = ctlrof(edev);

    if ((ctlr.feat[0] & (Fctrlvq | Fctrlrx)) != (Fctrlvq | Fctrlrx))
        return;

    const b = [1]u8{@intFromBool(edev.netif.nmaddr > 0)};
    _ = vctlcmd(edev, CtrlRx, CmdAllmulti, &b);
}

/// DIFF: page aligned, see the head of the file.
fn initqueue(q: *Vqueue, size: usize) i32 {
    const BY2PG = arch.mem.BY2PG;

    const d = alloc.mallocalign(VdescSize * size, BY2PG, 0, 0) orelse
        return -1;
    var p = alloc.mallocalign(VringSize + 2 * size + 2, BY2PG, 0, 0) orelse {
        alloc.free(d);
        return -1;
    };
    q.desc = @ptrCast(@alignCast(d));
    q.avail = @ptrCast(@alignCast(p));
    p += VringSize;
    q.availent = @ptrCast(@alignCast(p));
    p += @sizeOf(u16) * size;
    q.availevent = @ptrCast(@alignCast(p));
    p = alloc.mallocalign(VringSize + VusedSize * size + 2, BY2PG, 0, 0) orelse {
        alloc.free(q.avail);
        alloc.free(d);
        return -1;
    };
    q.used = @ptrCast(@alignCast(p));
    p += VringSize;
    q.usedent = @ptrCast(@alignCast(p));
    p += VusedSize * size;
    q.usedevent = @ptrCast(@alignCast(p));

    q.qsize = size;
    q.qmask = q.qsize - 1;

    q.lastused = 0;
    q.avail.idx = 0;
    q.used.idx = 0;

    q.avail.flags |= Rnointerrupt;

    return 0;
}

fn matchvirtiocfgcap(p: *Pcidev, cap: i32, off: i32, typ: i32) i32 {
    if (cap != 9 or pci.pcicfgr8(p, off + 3) != typ)
        return 1;

    // skip invalid or non memory bars
    const bar = pci.pcicfgr8(p, off + 4);
    if (bar < 0 or bar >= p.mem.len or
        p.mem[@intCast(bar)].size == 0)
        return 1;

    return 0;
}

fn virtiocap(p: *Pcidev, typ: i32) i32 {
    return pci.pcienumcaps(p, matchvirtiocfgcap, typ);
}

fn pciprobe() ?*Ctlr {
    var cfg: Vio = .{};

    var h: ?*Ctlr = null;
    var t: ?*Ctlr = null;

    // §4.1.2 PCI Device Discovery
    var prev: ?*Pcidev = null;
    while (pci.pcimatch(prev, 0x1AF4, 0x1041)) |p| {
        prev = p;
        // non-transitional devices will have a revision > 0
        if (p.rid == 0)
            continue;
        var cap = virtiocap(p, 1);
        if (cap < 0)
            continue;
        const bar = @as(usize, @intCast(pci.pcicfgr8(p, cap + 4))) % p.mem.len;
        if (virtiomapregs(p, cap, Vconf_sz, &cfg) == null)
            continue;
        const c = alloc.new(Ctlr) orelse {
            print("ethervirtio: no memory for Ctlr\n", .{});
            break;
        };
        c.* = .{};
        c.cfg = cfg;
        c.pcidev = p;
        const mask: u64 = if (p.mem[bar].bar & 1 != 0) ~@as(u64, 0x3) else ~@as(u64, 0xF);
        c.port = p.mem[bar].bar & mask;

        pci.pcienable(p);
        const good = dev: {
            if (virtiomapregs(p, virtiocap(p, 4), Vnet_sz, &c.dev) == null)
                break :dev false;
            if (virtiomapregs(p, virtiocap(p, 3), 0, &c.isr) == null)
                break :dev false;
            cap = virtiocap(p, 2);
            if (virtiomapregs(p, cap, 0, &c.notify) == null)
                break :dev false;
            c.notifyoffmult = pci.pcicfgr32(p, cap + 16);

            // device reset
            coherence();
            vout8(&cfg, Vconf_status, 0);
            while (vin8(&cfg, Vconf_status) != 0)
                arch.delay(1);
            vout8(&cfg, Vconf_status, Sacknowledge | Sdriver);

            // negotiate feature bits
            vout32(&cfg, Vconf_devfeatsel, 1);
            c.feat[1] = vin32(&cfg, Vconf_devfeat);

            vout32(&cfg, Vconf_devfeatsel, 0);
            c.feat[0] = vin32(&cfg, Vconf_devfeat);

            vout32(&cfg, Vconf_drvfeatsel, 1);
            vout32(&cfg, Vconf_drvfeat, c.feat[1] & Fversion1);

            vout32(&cfg, Vconf_drvfeatsel, 0);
            vout32(&cfg, Vconf_drvfeat, c.feat[0] & (Fmac | Fctrlvq | Fctrlrx));

            vout8(&cfg, Vconf_status, vin8(&cfg, Vconf_status) | Sfeaturesok);

            var i: usize = 0;
            while (i < c.queue.len) : (i += 1) {
                vout16(&cfg, Vconf_queuesel, @intCast(i));
                const n: usize = vin16(&cfg, Vconf_queuesize);
                if (n == 0 or (n & (n - 1)) != 0) {
                    if (i < 2)
                        print("ethervirtio: queue %d has invalid size %d\n", .{ i, n });
                    break;
                }
                if (initqueue(&c.queue[i], n) < 0)
                    break;
                // DIFF: registers are in memory only
                c.queue[i].notify = c.notify;
                c.queue[i].notify.mem += @as(usize, c.notifyoffmult) * vin16(&cfg, Vconf_queuenotifyoff);
                coherence();
                vout64(&cfg, Vconf_queuedesc, arch.paddr(@intFromPtr(c.queue[i].desc)));
                vout64(&cfg, Vconf_queueavail, arch.paddr(@intFromPtr(c.queue[i].avail)));
                vout64(&cfg, Vconf_queueused, arch.paddr(@intFromPtr(c.queue[i].used)));
            }
            if (i < 2) {
                print("ethervirtio: no queues\n", .{});
                break :dev false;
            }
            c.nqueue = i;
            break :dev true;
        };
        if (!good) {
            // Baddev:
            pci.pcidisable(p);
            // TODO, vunmap
            alloc.free(c);
            continue;
        }

        if (h == null)
            h = c
        else
            t.?.next = c;
        t = c;
    }

    return h;
}

/// DIFF: not in the C; see the head of the file.  Called after
/// intrenable, which turns MSI-X on and points every table entry at our
/// vector, and before the queues are enabled and the driver says it is
/// ready (attach).
fn msixvectors(edev: *Ether) void {
    const MSIXCtrl = 0x02;
    const MSIXEnable = 1 << 15;

    const ctlr = ctlrof(edev);
    const p = ctlr.pcidev;
    const off = pci.pcicap(p, pci.PciCapMSIX);
    if (off < 0 or (pci.pcicfgr16(p, off + MSIXCtrl) & MSIXEnable) == 0)
        return; // MSI or a pin: the device needs no telling

    vout16(&ctlr.cfg, Vconf_msixcfg, Msixvect);
    if (vin16(&ctlr.cfg, Vconf_msixcfg) == Nomsixvect)
        print("#l%d: virtio10: %T: no msi-x vector for configuration changes\n", .{ edev.ctlrno, pci.tbdf(p.tbdf) });
    for (0..ctlr.nqueue) |i| {
        vout16(&ctlr.cfg, Vconf_queuesel, @intCast(i));
        vout16(&ctlr.cfg, Vconf_queuemsixvect, Msixvect);
        if (vin16(&ctlr.cfg, Vconf_queuemsixvect) == Nomsixvect)
            print("#l%d: virtio10: %T: no msi-x vector for queue %d\n", .{ edev.ctlrno, pci.tbdf(p.tbdf), i });
    }
}

fn reset(edev: *Ether) i32 {
    const zeros: [Eaddrlen]u8 = @splat(0);

    if (ctlrhead == null)
        ctlrhead = pciprobe();

    var cp = ctlrhead;
    while (cp) |c| : (cp = c.next) {
        if (c.active)
            continue;
        if (edev.isa.port == 0 or edev.isa.port == c.port) {
            c.active = true;
            break;
        }
    }

    const ctlr = cp orelse
        return -1;

    edev.ctlr = ctlr;
    edev.isa.port = ctlr.port;
    edev.isa.irq = ctlr.pcidev.intl;
    edev.tbdf = ctlr.pcidev.tbdf;
    edev.netif.mbps = 1000;
    edev.netif.link = 1;

    if ((ctlr.feat[0] & Fmac) != 0 and @import("std").mem.eql(u8, &edev.ea, &zeros)) {
        for (0..Eaddrlen) |i|
            edev.ea[i] = vin8(&ctlr.dev, Vnet_mac0 + i);
    } else {
        // DIFF: the C's loop has an empty body, see the head of the file
        for (0..Eaddrlen) |i|
            vout8(&ctlr.dev, Vnet_mac0 + i, edev.ea[i]);
    }

    edev.netif.arg = edev;

    edev.attach = attach;
    edev.shutdown = shutdown;
    edev.netif.ifstat = ifstat;
    edev.netif.multicast = multicast;
    edev.netif.promiscuous = promiscuous;

    pci.pcisetbme(ctlr.pcidev);
    arch.intrenable(edev.isa.irq, interrupt, edev, edev.tbdf, netif.nifname(&edev.netif));
    msixvectors(edev);

    return 0;
}

pub fn ethervirtio10link() void {
    devether.addethercard("virtio10", reset);
}
