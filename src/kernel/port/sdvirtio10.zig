//! virtio 1.0 disk driver: virtio-blk and virtio-scsi over virtio-pci.
//! http://docs.oasis-open.org/virtio/virtio/v1.0/virtio-v1.0.html
//! from 9/port/sdvirtio10.c
//!
//! In contrast to sdvirtio.c, this driver handles the non-legacy
//! interface for virtio disk which uses mmio for all register accesses
//! and requires a laborate pci capability structure dance to get working.
//!
//! It is kind of pointless as it is most likely slower than
//! port i/o (harder to emulate on the pc platform).
//!
//! The reason why this driver is needed it is that vultr set the
//! disable-legacy=on option in the -device parameter for qemu
//! on their hypervisor.
//!
//! (planZ uses it for a different reason: it is the only virtio
//! interface without port I/O; see "Portability rules" in PLAN.md.)
//!
//! DIFF:
//!   - MSI-X.  The C relies on the interrupt pin.  Here interrupts are
//!     messages only, and with MSI-X on a virtio device interrupts for
//!     a queue only through the table entry chosen for that queue.
//!     vioenable therefore writes Vconf_msixcfg and, for each queue,
//!     Vconf_queuemsixvect (entry 0 for all; intrenable has programmed
//!     every table entry with the one vector), after intrenable and
//!     before the queues are enabled and DRIVER_OK is set, and reads
//!     each back; a refusal (0xFFFF) is reported and the driver then
//!     runs on vqio's one-second poll.
//!   - viointerrupt always scans the used ring.  The C returns unless
//!     bit 0 of the ISR status is set; with MSI-X that register is not
//!     meaningful.  It is still read, which is harmless and
//!     acknowledges a pin interrupt should one ever be used.
//!   - Registers are in memory only (see virtio10.zig), so the Vio_port
//!     branch for the queue's notify address is gone.
//!   - Errors.  `while(waserror());` around tsleep in vqio is
//!     `catch continue`; the `if(!waserror()) tsleep` waits for free
//!     descriptors are `catch {}`.  viobio returns error.Eio where the C
//!     calls error(Eio).  viorio cannot raise an error (SDifc.rio
//!     returns a status), so where the C lets viobio's error() pass
//!     through it, the Zig returns SDeio, which devsd turns into Eio.
//!   - Vqueue.rock is a slice allocated beside the Vqueue, not a
//!     flexible array member at its end.
//!   - Vqueue.free is a u16 with 0xFFFF for the end of the free list.
//!     The C keeps an int that starts as -1 but passes through the u16
//!     Vdesc.next, so it is 0xFFFF there too after the first use.
//!   - Everything the device reads or writes behind the compiler's
//!     back (the rings, the request header, the status byte, the scsi
//!     response) is accessed through volatile pointers; the Rock's done
//!     flag is atomic.
//!   - vqio has a second coherence(), between publishing the new avail
//!     index and reading used->flags to decide whether to notify.  The
//!     specification asks for a barrier there; the C has none (and on
//!     the PC needs none in practice, and has the one-second poll).
//!   - vqinterrupt ignores a used entry whose id is not a descriptor
//!     number, where the C would index outside its arrays.
//!   - Baddev in viopnpdevs is a local function instead of a label.
//!     The two "break if no memory" paths of viopnp are unchanged.

const std = @import("std");
const arch = @import("../arch.zig");
const alloc = @import("alloc.zig");
const proc = @import("proc.zig");
const portdat = @import("portdat.zig");
const taslock = @import("taslock.zig");
const pci = @import("pci.zig");
const devsd = @import("devsd.zig");
const sdscsi = @import("sdscsi.zig");
const virtio = @import("virtio10.zig");
const p9 = @import("print.zig");
const fmt = @import("fmt");

const print = p9.print;

const Error = proc.Error;
const Lock = portdat.Lock;
const Rendez = portdat.Rendez;
const Pcidev = pci.Pcidev;
const SDev = devsd.SDev;
const SDunit = devsd.SDunit;
const SDreq = devsd.SDreq;
const SDifc = devsd.SDifc;
const SDok = devsd.SDok;
const SDcheck = devsd.SDcheck;
const SDeio = devsd.SDeio;
const SDnostatus = devsd.SDnostatus;
const SDwrite = devsd.SDwrite;
const SDvalidsense = devsd.SDvalidsense;
const Vio = virtio.Vio;
const Vring = virtio.Vring;
const Vdesc = virtio.Vdesc;
const Vused = virtio.Vused;
const vin8 = virtio.vin8;
const vin16 = virtio.vin16;
const vin32 = virtio.vin32;
const vin64 = virtio.vin64;
const vout8 = virtio.vout8;
const vout16 = virtio.vout16;
const vout32 = virtio.vout32;
const vout64 = virtio.vout64;
const virtiomapregs = virtio.virtiomapregs;
const virtiounmap = virtio.virtiounmap;
const ilock = taslock.ilock;
const iunlock = taslock.iunlock;
const BY2PG = arch.mem.BY2PG;
const PGROUND = arch.mem.PGROUND;

// device types
const TypBlk = 2;
const TypSCSI = 8;

// status flags
const Acknowledge = 1;
const Driver = 2;
const FeaturesOk = 8;
const DriverOk = 4;
const Failed = 0x80;

// descriptor flags
const Next = 1;
const Write = 2;
const Indirect = 4;

// struct sizes
const VringSize = 4;

const CDBSIZE = 32;
const SENSESIZE = 96;

const Vscsi_num_queues = 0;
const Vscsi_seg_max = 4;
const Vscsi_max_sectors = 8;
const Vscsi_cmd_per_lun = 12;
const Vscsi_event_info_size = 16;
const Vscsi_sense_size = 20;
const Vscsi_cdb_size = 24;
const Vscsi_max_channel = 28;
const Vscsi_max_target = 30;
const Vscsi_max_lun = 32;
const Vscsi_sz = 36;

const Vblk_capacity = 0;
const Vblk_sz = 8;

/// DIFF: no MSI-X table entry (the value a device gives back when it
/// refuses one), and the entry this driver uses for everything.
const Novector = 0xFFFF;
const Msixent = 0;

const Vqueue = struct {
    lock: Lock = .{},

    dev: *Vdev = undefined,
    notify: Vio = .{},
    idx: u16 = 0,

    size: u32,

    free: u16,
    nfree: u32,

    desc: [*]volatile Vdesc,

    avail: *volatile Vring,
    availent: [*]volatile u16,
    availevent: *volatile u16,

    used: *volatile Vring,
    usedent: [*]volatile Vused,
    usedevent: *volatile u16,
    lastused: u16 = 0,

    rock: []?*Rock,
};

const Vdev = struct {
    typ: i32,

    pci: *Pcidev,

    port: u64,
    feat: [2]u32 = @splat(0),

    nqueue: usize = 0,
    queue: [16]?*Vqueue = @splat(null),

    dev: Vio = .{}, // device specific config (for scsi)

    // registers
    cfg: Vio,
    isr: Vio = .{},
    notify: Vio = .{},
    notifyoffmult: u32 = 0,

    next: ?*Vdev = null,
};

fn mkvqueue(size: u32) ?*Vqueue {
    const q = alloc.new(Vqueue);
    const rock = alloc.newslice(?*Rock, size);
    const mem = alloc.mallocalign(
        PGROUND(@sizeOf(Vdesc) * size +
            VringSize +
            @sizeOf(u16) * size +
            @sizeOf(u16)) +
            PGROUND(VringSize +
                @sizeOf(Vused) * size +
                @sizeOf(u16)),
        BY2PG,
        0,
        0,
    );
    if (mem == null or q == null or rock == null) {
        print("virtio: no memory for Vqueue\n", .{});
        alloc.free(mem);
        if (rock) |r| alloc.free(r);
        alloc.free(q);
        return null;
    }
    @memset(rock.?, null);

    var p = mem.?;
    const desc: [*]volatile Vdesc = @ptrCast(@alignCast(p));
    p += @sizeOf(Vdesc) * size;
    const avail: *volatile Vring = @ptrCast(@alignCast(p));
    p += VringSize;
    const availent: [*]volatile u16 = @ptrCast(@alignCast(p));
    p += @sizeOf(u16) * size;
    const availevent: *volatile u16 = @ptrCast(@alignCast(p));
    p += @sizeOf(u16);

    p = @ptrFromInt(PGROUND(@intFromPtr(p)));
    const used: *volatile Vring = @ptrCast(@alignCast(p));
    p += VringSize;
    const usedent: [*]volatile Vused = @ptrCast(@alignCast(p));
    p += @sizeOf(Vused) * size;
    const usedevent: *volatile u16 = @ptrCast(@alignCast(p));

    q.?.* = .{
        .size = size,
        .free = 0xFFFF,
        .nfree = size,
        .desc = desc,
        .avail = avail,
        .availent = availent,
        .availevent = availevent,
        .used = used,
        .usedent = usedent,
        .usedevent = usedevent,
        .rock = rock.?,
    };
    var i: u16 = 0;
    while (i < size) : (i += 1) {
        desc[i].next = q.?.free;
        q.?.free = i;
    }

    return q;
}

fn matchvirtiocfgcap(p: *Pcidev, cap: i32, off: i32, typ: i32) i32 {
    if (cap != 9 or pci.pcicfgr8(p, off + 3) != typ)
        return 1;

    // skip invalid bars
    const bar = pci.pcicfgr8(p, off + 4);
    if (bar < 0 or bar >= p.mem.len or p.mem[@intCast(bar)].size == 0)
        return 1;

    return 0;
}

fn virtiocap(p: *Pcidev, typ: i32) i32 {
    return pci.pcienumcaps(p, matchvirtiocfgcap, typ);
}

/// DIFF: the C's Baddev label.
fn baddev(p: *Pcidev, vd: *Vdev) void {
    pci.pcidisable(p);
    // TODO: vunmap
    alloc.free(vd);
}

fn viopnpdevs(typ: i32) ?*Vdev {
    var h: ?*Vdev = null;
    var t: ?*Vdev = null;
    var pp: ?*Pcidev = null;
    while (true) {
        pp = pci.pcimatch(pp, 0x1AF4, 0x1040 + typ);
        const p = pp orelse break;
        if (p.rid == 0)
            continue;
        var cap = virtiocap(p, 1);
        if (cap < 0)
            continue;
        const bar = @as(usize, @intCast(pci.pcicfgr8(p, cap + 4))) % p.mem.len;
        var cfg: Vio = .{};
        if (virtiomapregs(p, cap, virtio.Vconf_sz, &cfg) == null)
            continue;
        const vd = alloc.new(Vdev) orelse {
            print("virtio: no memory for Vdev\n", .{});
            break;
        };
        const mask: u64 = if (p.mem[bar].bar & 1 != 0) ~@as(u64, 0x3) else ~@as(u64, 0xF);
        vd.* = .{
            .port = p.mem[bar].bar & mask,
            .typ = typ,
            .pci = p,
            .cfg = cfg,
        };
        pci.pcienable(p);

        if (virtiomapregs(p, virtiocap(p, 3), 0, &vd.isr) == null) {
            baddev(p, vd);
            continue;
        }
        cap = virtiocap(p, 2);
        if (virtiomapregs(p, cap, 0, &vd.notify) == null) {
            baddev(p, vd);
            continue;
        }
        vd.notifyoffmult = pci.pcicfgr32(p, cap + 16);

        // reset
        arch.coherence();
        vout8(&cfg, virtio.Vconf_status, 0);
        while (vin8(&cfg, virtio.Vconf_status) != 0)
            arch.delay(1);
        vout8(&cfg, virtio.Vconf_status, Acknowledge | Driver);

        // negotiate feature bits
        vout32(&cfg, virtio.Vconf_devfeatsel, 1);
        vd.feat[1] = vin32(&cfg, virtio.Vconf_devfeat);

        vout32(&cfg, virtio.Vconf_devfeatsel, 0);
        vd.feat[0] = vin32(&cfg, virtio.Vconf_devfeat);

        vout32(&cfg, virtio.Vconf_drvfeatsel, 1);
        vout32(&cfg, virtio.Vconf_drvfeat, vd.feat[1] & 1);

        vout32(&cfg, virtio.Vconf_drvfeatsel, 0);
        vout32(&cfg, virtio.Vconf_drvfeat, 0);

        vout8(&cfg, virtio.Vconf_status, vin8(&cfg, virtio.Vconf_status) | FeaturesOk);

        var i: usize = 0;
        while (i < vd.queue.len) : (i += 1) {
            vout16(&cfg, virtio.Vconf_queuesel, @intCast(i));
            const n: u32 = vin16(&cfg, virtio.Vconf_queuesize);
            if (n == 0 or (n & (n - 1)) != 0)
                break;
            const q = mkvqueue(n) orelse break;
            q.notify = vd.notify;
            // DIFF: memory only, no Vio_port case.
            q.notify.mem += @as(usize, vd.notifyoffmult) * vin16(&cfg, virtio.Vconf_queuenotifyoff);
            q.dev = vd;
            q.idx = @intCast(i);
            vd.queue[i] = q;
            arch.coherence();
            vout64(&cfg, virtio.Vconf_queuedesc, arch.paddr(@intFromPtr(q.desc)));
            vout64(&cfg, virtio.Vconf_queueavail, arch.paddr(@intFromPtr(q.avail)));
            vout64(&cfg, virtio.Vconf_queueused, arch.paddr(@intFromPtr(q.used)));
        }
        vd.nqueue = i;

        if (h == null)
            h = vd
        else
            t.?.next = vd;
        t = vd;
    }

    return h;
}

const Rock = struct {
    done: u32, // DIFF: read and written atomically
    sleep: ?*Rendez,
};

fn vqinterrupt(q: *Vqueue) void {
    const m = q.size - 1;

    ilock(&q.lock);
    while ((q.lastused ^ q.used.idx) & m != 0) {
        var id: u32 = q.usedent[q.lastused & m].id;
        q.lastused +%= 1;
        // DIFF: the C trusts the device.
        if (id >= q.size)
            continue;
        if (q.rock[id]) |r| {
            q.rock[id] = null;
            const z = r.sleep;
            @atomicStore(u32, &r.done, 1, .release); // hands off
            if (z) |rz|
                _ = proc.wakeup(rz);
        }
        while (true) {
            const free = id;
            id = q.desc[free].next;
            q.desc[free].next = q.free;
            q.free = @intCast(free);
            q.nfree += 1;
            if (q.desc[free].flags & Next == 0 or id >= q.size)
                break;
        }
    }
    iunlock(&q.lock);
}

fn viointerrupt(_: *arch.Ureg, arg: ?*anyopaque) void {
    const vd: *Vdev = @ptrCast(@alignCast(arg.?));

    // DIFF: the C does nothing unless bit 0 is set here; with MSI-X
    // the ISR status says nothing, so the ring is always looked at.
    _ = vin8(&vd.isr, 0);
    vqinterrupt(vd.queue[if (vd.typ == TypSCSI) 2 else 0].?);
}

fn viodone(arg: ?*anyopaque) bool {
    const r: *Rock = @ptrCast(@alignCast(arg.?));
    return @atomicLoad(u32, &r.done, .acquire) != 0;
}

/// Called with q locked; unlocks it.
fn vqio(q: *Vqueue, head: u16) void {
    var rock: Rock = .{
        .done = 0,
        .sleep = &arch.up().?.sleep,
    };
    q.rock[head] = &rock;
    q.availent[q.avail.idx & (q.size - 1)] = head;
    arch.coherence();
    q.avail.idx +%= 1;
    iunlock(&q.lock);
    arch.coherence(); // DIFF: see the top of the file
    if ((q.used.flags & 1) == 0)
        vout16(&q.notify, 0, q.idx);
    while (!viodone(&rock)) {
        // not interruptible: the device still has the buffers
        proc.tsleep(rock.sleep.?, viodone, &rock, 1000) catch continue;

        if (!viodone(&rock))
            vqinterrupt(q);
    }
}

fn vioblkreq(vd: *Vdev, typ: u32, a: ?[*]u8, count: usize, secsize: usize, lba: u64) i32 {
    const Vioblkreqhdr = extern struct {
        typ: u32,
        prio: u32,
        lba: u64,
    };
    var req_: Vioblkreqhdr = undefined;
    var status_: u8 = undefined;
    // DIFF: the device reads one and writes the other
    const req: *volatile Vioblkreqhdr = &req_;
    const status: *volatile u8 = &status_;

    var need: u32 = 2;
    if (a != null)
        need = 3;

    status.* = 0xFF;
    req.typ = typ;
    req.prio = 0;
    req.lba = lba;

    const q = vd.queue[0].?;
    ilock(&q.lock);
    while (q.nfree < need) {
        iunlock(&q.lock);

        proc.tsleep(&arch.up().?.sleep, proc.return0, null, 500) catch {};

        ilock(&q.lock);
    }

    const head = q.free;
    var free = q.free;

    var d = &q.desc[free];
    free = d.next;
    d.addr = arch.paddr(@intFromPtr(req));
    d.len = @sizeOf(Vioblkreqhdr);
    d.flags = Next;

    if (a) |data| {
        d = &q.desc[free];
        free = d.next;
        d.addr = arch.paddr(@intFromPtr(data));
        d.len = @intCast(secsize * count);
        d.flags = if (typ != 0) Next else (Write | Next);
    }

    d = &q.desc[free];
    free = d.next;
    d.addr = arch.paddr(@intFromPtr(status));
    d.len = @sizeOf(u8);
    d.flags = Write;

    q.free = free;
    q.nfree -= need;

    // queue io, unlock and wait for completion
    vqio(q, head);

    return status.*;
}

fn vioscsireq(r: *SDreq) i32 {
    const Nresp = 4 + 4 + 2 + 2 + SENSESIZE;
    const Nreq = 8 + 8 + 3 + CDBSIZE;
    var resp_: [Nresp]u8 = undefined;
    var req_: [Nreq]u8 = undefined;
    // DIFF: the device reads one and writes the other
    const resp: *volatile [Nresp]u8 = &resp_;
    const req: *volatile [Nreq]u8 = &req_;

    const u = r.unit;
    const vd: *Vdev = @ptrCast(@alignCast(u.dev.ctlr.?));

    for (resp) |*b| b.* = 0;
    for (req) |*b| b.* = 0;
    req[0] = 1;
    req[1] = @truncate(u.subno);
    req[2] = @truncate(r.lun >> 8);
    req[3] = @truncate(r.lun & 0xFF);
    const tag: [8]u8 = @bitCast(@as(u64, @intFromPtr(r)));
    for (tag, 0..) |b, i| req[8 + i] = b;

    for (r.cmd[0..r.clen], 0..) |b, i| req[8 + 8 + 3 + i] = b;

    const q = vd.queue[2].?;
    ilock(&q.lock);
    while (q.nfree < 3) {
        iunlock(&q.lock);

        proc.tsleep(&arch.up().?.sleep, proc.return0, null, 500) catch {};

        ilock(&q.lock);
    }

    const head = q.free;
    var free = q.free;

    var d = &q.desc[free];
    free = d.next;
    d.addr = arch.paddr(@intFromPtr(req));
    d.len = 8 + 8 + 3 + vin32(&vd.dev, Vscsi_cdb_size);
    d.flags = Next;

    if (r.write and r.dlen > 0) {
        d = &q.desc[free];
        free = d.next;
        d.addr = arch.paddr(@intFromPtr(r.data.?));
        d.len = @intCast(r.dlen);
        d.flags = Next;
    }

    d = &q.desc[free];
    free = d.next;
    d.addr = arch.paddr(@intFromPtr(resp));
    d.len = 4 + 4 + 2 + 2 + vin32(&vd.dev, Vscsi_sense_size);
    d.flags = Write;

    if (!r.write and r.dlen > 0) {
        d.flags |= Next;

        d = &q.desc[free];
        free = d.next;
        d.addr = arch.paddr(@intFromPtr(r.data.?));
        d.len = @intCast(r.dlen);
        d.flags = Write;
    }

    q.free = free;
    q.nfree -= 2 + @as(u32, @intFromBool(r.dlen > 0));

    // queue io, unlock and wait for completion
    vqio(q, head);

    // response+status
    r.status = resp[10];
    if (resp[11] != 0)
        r.status = SDcheck;

    // sense_len
    var len: usize = @as(u32, resp[0]) | @as(u32, resp[1]) << 8 | @as(u32, resp[2]) << 16 | @as(u32, resp[3]) << 24;
    if (len > 0) {
        if (len > r.sense.len)
            len = r.sense.len;
        for (r.sense[0..len], 0..) |*b, i| b.* = resp[4 + 4 + 2 + 2 + i];
        r.flags |= SDvalidsense;
    }

    // data residue
    len = @as(u32, resp[4]) | @as(u32, resp[5]) << 8 | @as(u32, resp[6]) << 16 | @as(u32, resp[7]) << 24;
    if (len > r.dlen)
        r.rlen = 0
    else
        r.rlen = r.dlen - len;

    return r.status;
}

fn viobio(u: *SDunit, lun: u32, write: bool, data: []u8, nb: usize, bno: u64) Error!isize {
    const vd: *Vdev = @ptrCast(@alignCast(u.dev.ctlr.?));
    if (vd.typ == TypSCSI)
        return sdscsi.scsibio(u, lun, write, data, nb, bno);

    const max = 32;
    const ss: usize = u.secsize;
    var ret: usize = 0;
    var count = nb;
    var lba = bno;
    while (count > 0) {
        var cc = count;
        if (cc > max)
            cc = max;
        if (vioblkreq(vd, @intFromBool(write), data.ptr + ret, cc, ss, lba) != 0)
            return error.Eio;
        ret += cc * ss;
        count -= cc;
        lba += cc;
    }
    return @intCast(ret);
}

fn viorio(r: *SDreq) i32 {
    const u = r.unit;
    const vd: *Vdev = @ptrCast(@alignCast(u.dev.ctlr.?));
    if (vd.typ == TypSCSI)
        return vioscsireq(r);
    if (r.cmd[0] == 0x35 or r.cmd[0] == 0x91) {
        if (vioblkreq(vd, 4, null, 0, 0, 0) != 0)
            return devsd.sdsetsense(r, SDcheck, 3, 0xc, 2);
        return devsd.sdsetsense(r, SDok, 0, 0, 0);
    }
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
    // DIFF: the C lets viobio's error(Eio) pass through.
    const n = viobio(u, r.lun, rw == SDwrite, data, count, lba) catch {
        r.status = SDeio;
        return SDeio;
    };
    r.rlen = @intCast(n);
    r.status = SDok;
    return SDok;
}

fn vioonline(u: *SDunit) i32 {
    const vd: *Vdev = @ptrCast(@alignCast(u.dev.ctlr.?));
    if (vd.typ == TypSCSI)
        return sdscsi.scsionline(u);

    const cap = vin64(&vd.dev, Vblk_capacity);
    if (u.sectors != cap) {
        u.sectors = cap;
        u.secsize = 512;
        return 2;
    }
    return 1;
}

fn vioverify(u: *SDunit) i32 {
    const vd: *Vdev = @ptrCast(@alignCast(u.dev.ctlr.?));
    if (vd.typ == TypSCSI)
        return sdscsi.scsiverify(u);

    return 1;
}

fn vioenable(sd: *SDev) i32 {
    var namebuf: [32]u8 = undefined;

    const vd: *Vdev = @ptrCast(@alignCast(sd.ctlr.?));
    pci.pcisetbme(vd.pci);
    const name = fmt.snprint(&namebuf, "%s (%s)", .{ sd.namestr(), sd.ifc.name });
    arch.intrenable(vd.pci.intl, viointerrupt, vd, vd.pci.tbdf, name);
    arch.coherence();

    // DIFF: with MSI-X the device must be told which table entry to
    // use for configuration changes and for each queue; intrenable
    // has pointed them all at our vector.
    const msix = pci.pcicap(vd.pci, pci.PciCapMSIX) >= 0;
    if (msix) {
        vout16(&vd.cfg, virtio.Vconf_msixcfg, Msixent);
        if (vin16(&vd.cfg, virtio.Vconf_msixcfg) == Novector)
            print("%s: %T: no msi-x vector for config\n", .{ name, pci.tbdf(vd.pci.tbdf) });
    }

    var i: usize = 0;
    while (i < vd.nqueue) : (i += 1) {
        vout16(&vd.cfg, virtio.Vconf_queuesel, @intCast(i));
        if (msix) {
            vout16(&vd.cfg, virtio.Vconf_queuemsixvect, Msixent);
            if (vin16(&vd.cfg, virtio.Vconf_queuemsixvect) == Novector)
                print("%s: %T: no msi-x vector for queue %d\n", .{ name, pci.tbdf(vd.pci.tbdf), i });
        }
        vout16(&vd.cfg, virtio.Vconf_queueenable, 1);
    }
    vout8(&vd.cfg, virtio.Vconf_status, vin8(&vd.cfg, virtio.Vconf_status) | DriverOk);

    return 1;
}

fn viodisable(sd: *SDev) i32 {
    var namebuf: [32]u8 = undefined;

    const vd: *Vdev = @ptrCast(@alignCast(sd.ctlr.?));
    const name = fmt.snprint(&namebuf, "%s (%s)", .{ sd.namestr(), sd.ifc.name });
    arch.intrdisable(vd.pci.intl, viointerrupt, vd, vd.pci.tbdf, name);
    pci.pciclrbme(vd.pci);
    return 1;
}

fn viopnp() ?*SDev {
    var h: ?*SDev = null;
    var t: ?*SDev = null;

    var id: u8 = 'F';
    var vdp = viopnpdevs(TypBlk);
    while (vdp) |vd| : (vdp = vd.next) {
        if (vd.nqueue == 0)
            continue;

        if (virtiomapregs(vd.pci, virtiocap(vd.pci, 4), Vblk_sz, &vd.dev) == null)
            break;
        const s = alloc.new(SDev) orelse break;
        s.* = .{ .ifc = &sdvirtio10ifc, .ctlr = vd, .idno = id, .nunit = 1 };
        id += 1;
        if (h != null)
            t.?.next = s
        else
            h = s;
        t = s;
    }

    id = '0';
    vdp = viopnpdevs(TypSCSI);
    while (vdp) |vd| : (vdp = vd.next) {
        if (vd.nqueue < 3)
            continue;

        if (virtiomapregs(vd.pci, virtiocap(vd.pci, 4), Vscsi_sz, &vd.dev) == null)
            break;
        if (vin16(&vd.dev, Vscsi_max_target) == 0) {
            virtiounmap(&vd.dev, Vscsi_sz);
            continue;
        }
        if ((vin32(&vd.dev, Vscsi_cdb_size) > CDBSIZE) or (vin32(&vd.dev, Vscsi_sense_size) > SENSESIZE)) {
            print("sdvirtio: cdb %ud or sense size %ud too big\n", .{
                vin32(&vd.dev, Vscsi_cdb_size), vin32(&vd.dev, Vscsi_sense_size),
            });
            virtiounmap(&vd.dev, Vscsi_sz);
            continue;
        }

        const s = alloc.new(SDev) orelse break;
        s.* = .{ .ifc = &sdvirtio10ifc, .ctlr = vd, .idno = id, .nunit = vin16(&vd.dev, Vscsi_max_target) };
        id += 1;

        if (h != null)
            t.?.next = s
        else
            h = s;
        t = s;
    }
    return h;
}

pub const sdvirtio10ifc: SDifc = .{
    .name = "virtio10",
    .pnp = viopnp,
    .enable = vioenable,
    .disable = viodisable,
    .verify = vioverify,
    .online = vioonline,
    .rio = viorio,
    .bio = viobio,
};
