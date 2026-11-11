//! The device #b: /dev/scancode and /dev/leds, and the i8042 keyboard
//! controller with its auxiliary (PS/2 mouse) port.
//! keyboard input
//! from 9/pc/devkbd.c
//!
//! DIFF:
//!   - Errors are Zig error returns.  The waserror in kbdopen, which
//!     gives the reference back when devopen fails, is an errdefer.
//!     i8042auxenable returns the "no PS2 controller" error.
//!   - kbdreset first looks at the status port: a machine without an
//!     i8042 (many boards since about 2010) reads 0xFF there, a value
//!     no working controller shows (it has both error bits and the
//!     busy bit set).  Such a machine is left with nokbd set, without
//!     the second that flushdata would otherwise spend finding out.
//!   - The two ioalloc calls are gone: planZ keeps no table of I/O
//!     port ranges.
//!   - i8042intr takes an optional Ureg because kbdpoll calls it with
//!     none; i8042interrupt is the handler of the type irq.zig wants.
//!   - kbdbread returns an empty Block where the C returns nil:
//!     Dev.bread cannot return null (as in devpipe).
//!   - The polled mode's test `polltimer != nil` in i8042auxenable is
//!     kept; nothing else changes with *kbdpoll.
//!   - i8042reset is ported but nothing calls it yet: planZ has no
//!     reboot path (devcons `reboot` is still a stub).

const std = @import("std");
const fcall = @import("fcall");
const l = @import("l.zig");
const dat = @import("dat.zig");
const irq = @import("irq.zig");
const mmu = @import("mmu.zig");
const clock = @import("clock.zig");
const bootargs = @import("bootargs.zig");
const portdat = @import("../../port/portdat.zig");
const taslock = @import("../../port/taslock.zig");
const proc = @import("../../port/proc.zig");
const qio = @import("../../port/qio.zig");
const ab = @import("../../port/allocb.zig");
const netif = @import("../../port/netif.zig");
const portclock = @import("../../port/portclock.zig");
const devcons = @import("../../port/devcons.zig");
const devmod = @import("../../port/dev.zig");
const p9 = @import("../../port/print.zig");

const print = p9.print;
const panic = p9.panic;
const inb = l.inb;
const outb = l.outb;
const delay = clock.delay;
const ilock = taslock.ilock;
const iunlock = taslock.iunlock;
const incref = portdat.incref;
const decref = portdat.decref;
const getconf = bootargs.getconf;

const Error = proc.Error;
const Ureg = dat.Ureg;
const Lock = portdat.Lock;
const Ref = portdat.Ref;
const Timer = portdat.Timer;
const Chan = portdat.Chan;
const Walkqid = portdat.Walkqid;
const Queue = qio.Queue;
const Block = ab.Block;
const Dirtab = devmod.Dirtab;

const Data = 0x60; // data port

const Status = 0x64; // status port
const Inready = 0x01; //  input character ready
const Outbusy = 0x02; //  output busy
const Sysflag = 0x04; //  system flag
const Cmddata = 0x08; //  cmd==0, data==1
const Inhibit = 0x10; //  keyboard/mouse inhibited
const Minready = 0x20; //  mouse character ready
const Rtimeout = 0x40; //  general timeout
const Parity = 0x80;

const Cmd = 0x64; // command port (write only)

// controller command byte
const Cscs1 = 1 << 6; // scan code set 1
const Cauxdis = 1 << 5; // mouse disable
const Ckbddis = 1 << 4; // kbd disable
const Csf = 1 << 2; // system flag
const Cauxint = 1 << 1; // mouse interrupt enable
const Ckbdint = 1 << 0; // kbd interrupt enable

const Qdir = 0;
const Qscancode = 1;
const Qleds = 2;

const kbdtab = [_]Dirtab{
    .{ .name = ".", .qid = .{ .path = Qdir, .vers = 0, .type = fcall.QTDIR }, .length = 0, .perm = 0o555 },
    .{ .name = "scancode", .qid = .{ .path = Qscancode, .vers = 0 }, .length = 0, .perm = 0o440 },
    .{ .name = "leds", .qid = .{ .path = Qleds, .vers = 0 }, .length = 0, .perm = 0o220 },
};

/// What the auxiliary port's bytes are given to: putc(c, shift).
pub const Auxputc = *const fn (c: i32, shift: i32) void;

var i8042lock: Lock = .{};
var polltimer: ?*Timer = null;
var ccc: i32 = 0;
var auxputc: ?Auxputc = null;
var nokbd: bool = true; // flag: no PS/2 keyboard

var kbd: struct {
    ref: Ref = .{},
    q: *Queue = undefined,
} = .{};

///  wait for output no longer busy
fn outready() i32 {
    var tries: i32 = 0;
    var status: i32 = undefined;
    while (true) : (tries += 1) {
        status = inb(Status);
        if (status & Outbusy == 0)
            break;
        if (tries > 500)
            return -1;
        delay(2);
    }
    return status;
}

///  wait for input
fn inready() i32 {
    var tries: i32 = 0;
    var status: i32 = undefined;
    while (true) : (tries += 1) {
        status = inb(Status);
        if (status & Inready != 0)
            break;
        if (tries > 500)
            return -1;
        delay(2);
    }
    return status;
}

fn ackdata(status: i32) i32 {
    if (status < 0 or (status & Inready) == 0)
        return -1;

    return inb(Data);
}

fn indata() i32 {
    return ackdata(inready());
}

///  wait for a quiescent controller
fn flushdata() i32 {
    var tries: i32 = 0;
    while (true) : (tries += 1) {
        const status: i32 = inb(Status);
        if (status & (Outbusy | Inready) == 0)
            break;
        _ = ackdata(status);
        if (tries > 1000)
            return -1;
        delay(1);
    }
    return 0;
}

fn outdata(data: i32) i32 {
    if (outready() < 0)
        return -1;
    outb(Data, @truncate(@as(u32, @bitCast(data))));
    return 0;
}

fn outcmd(cmd: i32, data: i32) i32 {
    if (outready() < 0)
        return -1;
    outb(Cmd, @truncate(@as(u32, @bitCast(cmd))));
    if (data >= 0 and outdata(data) < 0)
        return -1;
    if (outready() < 0)
        return -1;
    return 0;
}

fn readccc() i32 {
    if (outcmd(0x20, -1) < 0)
        return -1;
    return indata();
}

fn writeccc(data: i32) i32 {
    return outcmd(0x60, data);
}

///  ask 8042 to reset the machine
pub fn i8042reset() void {
    if (nokbd)
        return;

    @as(*align(1) volatile u16, @ptrFromInt(mmu.kaddr(0x472))).* = 0x1234; // BIOS warm-boot flag

    //
    //  newer reset the machine command
    //
    ilock(&i8042lock);
    _ = outcmd(0xFE, -1);
    iunlock(&i8042lock);

    //
    //  Pulse it by hand (old somewhat reliable)
    //
    var x: i32 = 0xDF;
    for (0..5) |_| {
        ilock(&i8042lock);
        x ^= 1;
        _ = outcmd(0xD1, x);
        iunlock(&i8042lock);

        delay(100);
    }
}

pub fn i8042auxcmd(cmd_: i32) i32 {
    var c: i32 = 0;
    var tries: i32 = 0;
    const cmd = cmd_ & 0xFF;

    if (nokbd)
        return -1;

    ilock(&i8042lock);
    while (true) {
        if (tries > 2)
            break;
        tries += 1;
        if (outcmd(0xD4, cmd) < 0)
            break;
        c = indata();
        if (c < 0)
            break;
        if (!(c == 0xFE or c == 0))
            break;
    }
    iunlock(&i8042lock);

    if (c != 0xFA) {
        print("i8042: %2.2ux returned to the %2.2ux command (pc=%#p)\n", .{ @as(u32, @bitCast(c)), @as(u32, @bitCast(cmd)), @returnAddress() });
        return -1;
    }
    return 0;
}

var oldleds: i32 = -1;

/// set keyboard's leds for lock states (scroll, numeric, caps).
///
/// at least one keyboard (from Qtronics) also sets its numeric-lock
/// behaviour to match the led state, though it has no numeric keypad,
/// and some BIOSes bring the system up with numeric-lock set and no
/// setting to change that.  this combination steals the keys for these
/// characters and makes it impossible to generate them: uiolkjm&*().
/// thus we'd like to be able to force the numeric-lock led (and behaviour) off.
fn setleds(leds_: i32) void {
    var leds = leds_;
    if (nokbd or leds == oldleds)
        return;

    leds &= 7;
    ilock(&i8042lock);
    while (true) {
        if (outdata(0xED) < 0) // `reset keyboard lock states'
            break;
        if (outdata(leds) < 0)
            break;
        oldleds = leds;
        break;
    }
    iunlock(&i8042lock);
}

///  keyboard interrupt
fn i8042intr(_: ?*Ureg, _: ?*anyopaque) void {
    var tries: i32 = 0;
    while (tries < 16) : (tries += 1) {
        ilock(&i8042lock);
        const status: i32 = inb(Status);
        if (status & Inready == 0) {
            iunlock(&i8042lock);
            break;
        }
        const c: u8 = @truncate(@as(u32, @bitCast(ackdata(status))));
        iunlock(&i8042lock);

        //
        //  if it's the aux port...
        //
        if (status & Minready != 0) {
            if (auxputc) |putc|
                putc(c, 0);
        } else {
            _ = qio.qproduce(kbd.q, &.{c});
        }
    }
}

/// The handler given to intrenable (see DIFF).
fn i8042interrupt(ureg: *Ureg, arg: ?*anyopaque) void {
    i8042intr(ureg, arg);
}

pub fn i8042auxenable(putc: Auxputc) Error!void {
    if (nokbd)
        return proc.errorf("no PS2 controller", .{});

    ilock(&i8042lock);

    // already enabled?
    if ((ccc & (Cauxdis | Cauxint)) == Cauxint) {
        auxputc = putc;
        iunlock(&i8042lock);
        return;
    }

    // enable kbd/aux xfers and interrupts
    ccc &= ~@as(i32, Cauxdis);
    ccc |= Cauxint;
    if (writeccc(ccc) < 0) {
        iunlock(&i8042lock);
        print("i8042: aux init failed: writing ccc\n", .{});
        return;
    }
    if (outcmd(0xA8, -1) < 0) { // auxiliary device enable
        iunlock(&i8042lock);
        print("i8042: aux init failed: aux device enable\n", .{});
        return;
    }
    auxputc = putc;
    iunlock(&i8042lock);

    if (polltimer != null)
        return;

    irq.intrenable(dat.IrqAUX, i8042interrupt, null, dat.BUSUNKNOWN, "kbdaux");
}

fn kbdpoll() void {
    if (nokbd or qio.qlen(kbd.q) > 0)
        return;
    i8042intr(null, null);
}

fn kbdshutdown() void {
    if (nokbd)
        return;

    ilock(&i8042lock);

    // disable kbd and aux xfers and interrupts
    ccc &= ~@as(i32, Ckbdint | Cauxint);
    ccc |= (Cauxdis | Ckbddis);
    _ = writeccc(ccc);

    iunlock(&i8042lock);
}

fn kbdattach(spec: []const u8) Error!*Chan {
    return devmod.devattach('b', spec);
}

fn kbdwalk(c: *Chan, nc: ?*Chan, name: []const []const u8) Error!*Walkqid {
    return devmod.devwalk(c, nc, name, &kbdtab, devmod.devgen);
}

fn kbdstat(c: *Chan, dp: []u8) Error!usize {
    return devmod.devstat(c, dp, &kbdtab, devmod.devgen);
}

fn kbdopen(c: *Chan, omode: u32) Error!*Chan {
    if (!devcons.iseve())
        return error.Eperm;
    if (c.qid.path == Qscancode) {
        errdefer _ = decref(&kbd.ref);
        if (incref(&kbd.ref) != 1)
            return error.Einuse;
        return devmod.devopen(c, omode, &kbdtab, devmod.devgen);
    }
    return devmod.devopen(c, omode, &kbdtab, devmod.devgen);
}

fn kbdclose(c: *Chan) Error!void {
    if ((c.flag & portdat.COPEN) != 0 and c.qid.path == Qscancode)
        _ = decref(&kbd.ref);
}

fn kbdbread(c: *Chan, n: usize, off: u64) Error!*Block {
    if (c.qid.path == Qscancode) {
        kbdpoll();
        return try qio.qbread(kbd.q, n) orelse ab.allocb(0);
    }
    return devmod.devbread(c, n, off);
}

fn kbdread(c: *Chan, a: []u8, _: i64) Error!usize {
    if (c.qid.path == Qscancode) {
        kbdpoll();
        return qio.qread(kbd.q, a);
    }
    if (c.qid.path == Qdir)
        return devmod.devdirread(c, a, &kbdtab, devmod.devgen);
    return error.Egreg;
}

fn kbdwrite(c: *Chan, a: []const u8, _: i64) Error!usize {
    var tmp: [8 + 1]u8 = undefined;

    if (c.qid.path != Qleds)
        return error.Egreg;

    const n = @min(a.len, tmp.len - 1);
    @memcpy(tmp[0..n], a[0..n]);

    setleds(netif.atoi(std.mem.sliceTo(tmp[0..n], 0)));

    return a.len;
}

fn kbdreset() void {
    kbd.q = qio.qopen(1024, qio.Qcoalesce, null, null) orelse
        panic("kbdreset", .{});
    qio.qnoblock(kbd.q, true);

    if (getconf("*nokbd") != null)
        return;

    // DIFF: nothing answers at the status port (see the header).
    if (inb(Status) == 0xFF) {
        print("i8042: no controller\n", .{});
        return;
    }

    ilock(&i8042lock);

    // wait for a quiescent controller
    if (flushdata() < 0) {
        iunlock(&i8042lock);
        print("i8042: kbd init failed: flushdata timeout\n", .{});
        return;
    }

    ccc = readccc();
    if (ccc < 0) {
        print("i8042: could not read ccc\n", .{});
        ccc = 0;
    }

    // enable kbd xfers and interrupts
    ccc &= ~@as(i32, Ckbddis);
    ccc |= Csf | Ckbdint | Cscs1;

    // disable ps2 mouse
    ccc &= ~@as(i32, Cauxint);
    ccc |= Cauxdis;

    if (writeccc(ccc) < 0) {
        iunlock(&i8042lock);
        print("i8042: kbd init failed: writing ccc\n", .{});
        return;
    }

    nokbd = false;
    iunlock(&i8042lock);

    if (getconf("*kbdpoll") != null) {
        polltimer = portclock.addclock0link(kbdpoll, 50);
        return;
    }
    irq.intrenable(dat.IrqKBD, i8042interrupt, null, dat.BUSUNKNOWN, "kbd");
}

pub const kbddevtab: devmod.Dev = .{
    .dc = 'b',
    .name = "kbd",

    .reset = kbdreset,
    .shutdown = kbdshutdown,
    .attach = kbdattach,
    .walk = kbdwalk,
    .stat = kbdstat,
    .open = kbdopen,
    .close = kbdclose,
    .read = kbdread,
    .bread = kbdbread,
    .write = kbdwrite,
};
