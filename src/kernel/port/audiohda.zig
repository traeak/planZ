//! Intel High Definition Audio controllers and their codecs.
//! from 9/pc/audiohda.c
//!
//! DIFF:
//!   - No #P/hdacmd.  The C adds it with addarchfile, which planZ does
//!     not have (no devarch), and nothing in 9front uses it; so Ctlr has
//!     no q and there is no lastcard.
//!   - hdacmd runs under a lock of the controller's (cmdlock).  In the
//!     C two processes can send commands at once (one reading volume
//!     while another writes audioctl, each under its own Audiochan's
//!     lock) and take the same CORB slot.  The C's QLock, used only by
//!     the dropped hdacmdwrite, is gone.  A Lock, not a QLock, because
//!     commands are sent from audioreset, before there are processes.
//!   - hdamatch skips an HDA function on a device whose function 0 is a
//!     display controller, such as a graphics card's HDMI/DP audio.
//!     For now only the board's own audio is wanted; see PLAN.md.
//!   - Widget's union of pin/pincap and convrate/convfmt is two plain
//!     fields; convrate and convfmt are never used.
//!   - Registers are reached through volatile pointers.  The ring
//!     indices, which the interrupt routine changes, are read and
//!     written atomically.
//!   - An Audio's entries return Zig errors (see audioif.zig);
//!     hdastatus formats into a slice.
//!
//! Fixed from C: Agetright, see there.

const std = @import("std");
const arch = @import("../arch.zig");
const fmt = @import("fmt");
const portdat = @import("portdat.zig");
const alloc = @import("alloc.zig");
const xalloc = @import("xalloc.zig");
const proc = @import("proc.zig");
const taslock = @import("taslock.zig");
const parse = @import("parse.zig");
const lib = @import("lib.zig");
const netif = @import("netif.zig");
const pci = @import("pci.zig");
const devaudio = @import("devaudio.zig");
const audioif = @import("audioif.zig");
const p9 = @import("print.zig");

const print = p9.print;
const ilock = taslock.ilock;
const iunlock = taslock.iunlock;
const lock = taslock.lock;
const unlock = taslock.unlock;

const Error = proc.Error;
const Lock = portdat.Lock;
const Rendez = portdat.Rendez;
const Pcidev = pci.Pcidev;
const Audio = audioif.Audio;
const Volume = audioif.Volume;

const Gcap = 0x00;
const Gctl = 0x08;
const Rst = 1;
const Flush = 2;
const Acc = 1 << 8;
const Wakeen = 0x0c;
const Statests = 0x0e;
const Sdiwake = 1 | 2 | 4;
const Intctl = 0x20;
const Gie = 1 << 31;
const Cie = 1 << 30;
const Intsts = 0x24;
const Gis = 1 << 31;
const Cis = 1 << 30;
const Walclk = 0x30;
const Corblbase = 0x40;
const Corbubase = 0x44;
const Corbwp = 0x48;
const Corbrp = 0x4a;
const Corbptrrst = 1 << 15;
const Corbctl = 0x4c;
const Corbdma = 2;
const Corbint = 1;
const Corbsts = 0x4d;
const Cmei = 1;
const Corbsz = 0x4e;
const Rirblbase = 0x50;
const Rirbubase = 0x54;
const Rirbwp = 0x58;
const Rirbptrrst = 1 << 15;
const Rintcnt = 0x5a;
const Rirbctl = 0x5c;
const Rirbover = 4;
const Rirbdma = 2;
const Rirbint = 1;
const Rirbsts = 0x5d;
const Rirbrover = 4;
const Rirbrint = 1;
const Rirbsz = 0x5e;
const Immcmd = 0x60;
const Immresp = 0x64;
const Immstat = 0x68;
const Dplbase = 0x70;
const Dpubase = 0x74;
// Warning: Sdctl is 24bit register
const Sdctl0 = 0x80;
const Srst = 1 << 0;
const Srun = 1 << 1;
const Scie = 1 << 2;
const Seie = 1 << 3;
const Sdie = 1 << 4;
const Stagbit = 20;
const Sdsts = 0x03;
const Scompl = 1 << 2;
const Sfifoerr = 1 << 3;
const Sdescerr = 1 << 4;
const Sfifordy = 1 << 5;
const Sdlpib = 0x04;
const Sdcbl = 0x08;
const Sdlvi = 0x0c;
const Sdfifow = 0x0e;
const Sdfifos = 0x10;
const Sdfmt = 0x12;
const Fmtmono = 0;
const Fmtstereo = 1;
const Fmtsampw = 1 << 4;
const Fmtsampb = 0 << 4;
const Fmtdiv1 = 0 << 8;
const Fmtmul1 = 0 << 11;
const Fmtbase441 = 1 << 14;
const Fmtbase48 = 0 << 14;
const Sdbdplo = 0x18;
const Sdbdphi = 0x1c;

const Bufsize = 64 * 1024 * 4;
const Nblocks = 256;
const Blocksize = Bufsize / Nblocks;
const BytesPerSample = 4;

const Maxrirbwait = 1000; // microseconds
const Maxwaitup = 500; // microseconds
const Codecdelay = 1000; // microseconds

// 12-bit cmd + 8-bit payload
const Getparm = 0xf00;
const Vendorid = 0x00;
const Revid = 0x02;
const Subnodecnt = 0x04;
const Fungrtype = 0x05;
const Graudio = 0x01;
const Grmodem = 0x02;
const Fungrcap = 0x08;
const Widgetcap = 0x09;
const Waout = 0;
const Wain = 1;
const Wamix = 2;
const Wasel = 3;
const Wpin = 4;
const Wpower = 5;
const Wknob = 6;
const Wbeep = 7;
const Winampcap = 0x0002;
const Woutampcap = 0x0004;
const Wampovrcap = 0x0008;
const Wfmtovrcap = 0x0010;
const Wstripecap = 0x0020;
const Wproccap = 0x0040;
const Wunsolcap = 0x0080;
const Wconncap = 0x0100;
const Wdigicap = 0x0200;
const Wpwrcap = 0x0400;
const Wlrcap = 0x0800;
const Wcpcap = 0x1000;
const Streamrate = 0x0a;
const Streamfmt = 0x0b;
const Pincap = 0x0c;
const Psense = 1 << 0;
const Ptrigreq = 1 << 1;
const Pdetect = 1 << 2;
const Pheadphone = 1 << 3;
const Pout = 1 << 4;
const Pin = 1 << 5;
const Pbalanced = 1 << 6;
const Phdmi = 1 << 7;
const Peapd = 1 << 16;
const Inampcap = 0x0d;
const Outampcap = 0x12;
const Connlistlen = 0x0e;
const Powerstates = 0x0f;
const Processcap = 0x10;
const Gpiocount = 0x11;
const Knobcap = 0x13;
const Getconn = 0xf01;
const Setconn = 0x701;
const Getconnlist = 0xf02;
const Getstate = 0xf03;
const Setstate = 0x703;
const Setpower = 0x705;
const Getpower = 0xf05;
const Getstream = 0xf06;
const Setstream = 0x706;
const Getpinctl = 0xf07;
const Setpinctl = 0x707;
const Pinctlin = 1 << 5;
const Pinctlout = 1 << 6;
const Pinctlhphn = 1 << 7;
const Getunsolresp = 0xf08;
const Setunsolresp = 0x708;
const Getpinsense = 0xf09;
const Exepinsense = 0x709;
const Getgpi = 0xf10;
const Setgpi = 0x710;
const Getbeep = 0xf0a;
const Setbeep = 0x70a;
const Seteapd = 0x70c;
const Btlenable = 1;
const Eapdenable = 2;
const LRswap = 4;
const Getknob = 0xf0f;
const Setknob = 0x70f;
const Getdefault = 0xf1c;
const Funreset = 0x7ff;
const Getchancnt = 0xf2d;
const Setchancnt = 0x72d;

// 4-bit cmd + 16-bit payload
const Getcoef = 0xd;
const Setcoef = 0x5;
const Getproccoef = 0xc;
const Setproccoef = 0x4;
const Getamp = 0xb;
const Setamp = 0x3;
const Asetout = 1 << 15;
const Asetin = 1 << 14;
const Asetleft = 1 << 13;
const Asetright = 1 << 12;
const Asetmute = 1 << 7;
const Asetidx = 8;
const Agetin = 0 << 15;
const Agetout = 1 << 15;
const Agetleft = 1 << 13;
/// Fixed from C, which has 1<<15: that is Agetout, so getinamp read
/// the right channel of the output amplifier.  In Get Amplifier
/// Gain/Mute, bit 13 set is left and clear is right.
const Agetright = 0 << 13;
const Agetidx = 0;
const Again = 0;
const Againmask = 0x7f;
const Getconvfmt = 0xa;
const Setconvfmt = 0x2;

const Maxcodecs = 16;
const Maxwidgets = 256;

const Ring = struct {
    r: Rendez = .{},

    buf: ?[*]u8 = null,
    nbuf: u32 = 0,

    ri: u32 = 0,
    wi: u32 = 0,
};

const Stream = struct {
    ring: Ring = .{},

    blds: ?[*]volatile Bld = null,

    sdctl: u32 = 0,
    sdintr: u32 = 0,
    sdnum: u32 = 0,

    afmt: u32 = 0,
    atag: u32 = 0,
    active: bool = false,

    pin: u32 = 0,
    cad: u32 = 0,

    conv: ?*Widget = null, // DAC or ADC
    jack: ?*Widget = null, // the pin jack
};

const Id = struct {
    ctlr: *Ctlr,
    codec: u32 = 0,
    nid: u32 = 0,
};

const Widget = struct {
    id: Id,
    fg: *Fungroup,
    cap: u32 = 0,
    type: u32 = 0,
    nlist: u32 = 0,
    list: ?[*]?*Widget = null,
    pin: u32 = 0,
    pincap: u32 = 0,
    next: ?*Widget = null, // next in function group
    path: ?*Widget = null, // next in audio path

    link: ?*Widget = null, // temporary for findpath
};

const Fungroup = struct {
    id: Id,
    codec: *Codec,
    type: u32 = 0,
    first: ?*Widget = null,
    next: ?*Fungroup = null,
};

const Codec = struct {
    id: Id,
    vid: u32 = 0,
    rid: u32 = 0,
    widgets: [Maxwidgets]?*Widget = @splat(null),
    fgroup: ?*Fungroup = null,
};

// hardware structures

const Bld = extern struct {
    addrlo: u32,
    addrhi: u32,
    len: u32,
    flags: u32,
};

const Ctlr = struct {
    next: ?*Ctlr = null,
    no: i32 = 0,

    lock: Lock = .{}, // interrupt lock
    cmdlock: Lock = .{}, // command lock

    adev: ?*Audio = null,

    port: u64 = 0,
    pcidev: ?*Pcidev = null,

    mem: usize = 0,
    size: usize = 0,

    corb: [*]volatile u32 = undefined,
    corbsize: u32 = 0,
    rirb: [*]volatile u32 = undefined,
    rirbsize: u32 = 0,

    sout: Stream = .{},
    sin: Stream = .{},

    iss: u32 = 0,
    oss: u32 = 0,
    bss: u32 = 0,

    codecmask: u32 = 0,
    codec: [Maxcodecs]?*Codec = @splat(null),
};

fn csr32r(c: *Ctlr, r: u32) u32 {
    return @as(*volatile u32, @ptrFromInt(c.mem + r)).*;
}
fn csr16r(c: *Ctlr, r: u32) u16 {
    return @as(*volatile u16, @ptrFromInt(c.mem + r)).*;
}
fn csr8r(c: *Ctlr, r: u32) u8 {
    return @as(*volatile u8, @ptrFromInt(c.mem + r)).*;
}
fn csr32w(c: *Ctlr, r: u32, v: u32) void {
    @as(*volatile u32, @ptrFromInt(c.mem + r)).* = v;
}
fn csr16w(c: *Ctlr, r: u32, v: u16) void {
    @as(*volatile u16, @ptrFromInt(c.mem + r)).* = v;
}
fn csr8w(c: *Ctlr, r: u32, v: u8) void {
    @as(*volatile u8, @ptrFromInt(c.mem + r)).* = v;
}

/// PCIWADDR
fn pciwaddr(va: usize) u64 {
    return arch.paddr(va);
}

const widtype = [_][]const u8{
    "aout",
    "ain",
    "amix",
    "asel",
    "pin",
    "power",
    "knob",
    "beep",
};

const pinport = [_][]const u8{
    "jack",
    "nothing",
    "fix",
    "jack+fix",
};

const pinfunc = [_][]const u8{
    "lineout",
    "speaker",
    "hpout",
    "cd",
    "spdifout",
    "digiout",
    "modemline",
    "modemhandset",
    "linein",
    "aux",
    "micin",
    "telephony",
    "spdifin",
    "digiin",
    "resvd",
    "other",
};

const pincol = [_][]const u8{
    "?",
    "black",
    "grey",
    "blue",
    "green",
    "red",
    "orange",
    "yellow",
    "purple",
    "pink",
    "resvd",
    "resvd",
    "resvd",
    "resvd",
    "white",
    "other",
};

const pinloc = [_][]const u8{
    "N/A",
    "rear",
    "front",
    "left",
    "right",
    "top",
    "bottom",
    "special",
    "special",
    "special",
    "resvd",
    "resvd",
    "resvd",
    "resvd",
    "resvd",
    "resvd",
};

const pinloc2 = [_][]const u8{
    "ext",
    "int",
    "sep",
    "other",
};

fn waitup8(ctlr: *Ctlr, reg: u32, mask: u8, set: u8) i32 {
    for (0..Maxwaitup) |_| {
        if ((csr8r(ctlr, reg) & mask) == set)
            return 0;
        arch.microdelay(1);
    }
    print("#A%d: waitup timeout for reg=%x, mask=%x, set=%x\n", .{ ctlr.no, reg, mask, set });
    return -1;
}

fn waitup16(ctlr: *Ctlr, reg: u32, mask: u16, set: u16) i32 {
    for (0..Maxwaitup) |_| {
        if ((csr16r(ctlr, reg) & mask) == set)
            return 0;
        arch.microdelay(1);
    }
    print("#A%d: waitup timeout for reg=%x, mask=%x, set=%x\n", .{ ctlr.no, reg, mask, set });
    return -1;
}

fn waitup32(ctlr: *Ctlr, reg: u32, mask: u32, set: u32) i32 {
    for (0..Maxwaitup) |_| {
        if ((csr32r(ctlr, reg) & mask) == set)
            return 0;
        arch.microdelay(1);
    }
    print("#A%d: waitup timeout for reg=%x, mask=%x, set=%x\n", .{ ctlr.no, reg, mask, set });
    return -1;
}

fn hdacmd(ctlr: *Ctlr, request: u32, reply: *[2]u32) i32 {
    // DIFF: under cmdlock, see the header
    lock(&ctlr.cmdlock);
    defer unlock(&ctlr.cmdlock);

    var re: u32 = csr16r(ctlr, Rirbwp);
    const rp: u32 = csr16r(ctlr, Corbrp);
    const wp: u32 = (@as(u32, csr16r(ctlr, Corbwp)) + 1) % ctlr.corbsize;
    if (rp == wp) {
        print("#A%d: corb full\n", .{ctlr.no});
        return -1;
    }
    ctlr.corb[wp] = request;
    arch.coherence();
    csr16w(ctlr, Corbwp, @intCast(wp));

    var ret: i32 = 0;
    for (0..Maxrirbwait) |_| {
        if (csr16r(ctlr, Rirbwp) != re) {
            re = (re + 1) % ctlr.rirbsize;
            reply[0] = ctlr.rirb[re * 2];
            reply[1] = ctlr.rirb[re * 2 + 1];
            ret = 1;
            break;
        }
        arch.microdelay(1);
    }

    // reset intcnt for qemu
    csr8w(ctlr, Rirbsts, Rirbrover | Rirbrint);

    return ret;
}

fn cmderr(id: Id, verb: u32, par: u32, ret: *u32) i32 {
    var q: u32 = (id.codec << 28) | (id.nid << 20);
    if ((verb & 0x700) == 0x700)
        q |= (verb << 8) | par
    else
        q |= (verb << 16) | par;
    var w: [2]u32 = undefined;
    if (hdacmd(id.ctlr, q, &w) != 1)
        return -1;
    if (w[1] != id.codec)
        return -1;
    ret.* = w[0];
    return 0;
}

fn cmd(id: Id, verb: u32, par: u32) u32 {
    var w: u32 = undefined;
    if (cmderr(id, verb, par, &w) == -1)
        return ~@as(u32, 0);
    return w;
}

fn newnid(id: Id, nid: u32) Id {
    var n = id;
    n.nid = nid;
    return n;
}

fn getoutamprange(w: *Widget) u32 {
    if ((w.cap & Woutampcap) == 0)
        return 0;
    const r = if ((w.cap & Wampovrcap) == 0)
        cmd(w.fg.id, Getparm, Outampcap)
    else
        cmd(w.id, Getparm, Outampcap);
    return (r >> 8) & 0x7f;
}

fn getoutamp(w: *Widget, vol: *[2]i32) void {
    vol[0] = 0;
    vol[1] = 0;
    if ((w.cap & Woutampcap) == 0)
        return;
    vol[0] = @intCast(cmd(w.id, Getamp, Agetout | Agetleft) & Againmask);
    vol[1] = @intCast(cmd(w.id, Getamp, Agetout | Agetright) & Againmask);
}

/// vol is 0...range or null for 0dB; mute is 0/1
fn setoutamp(w: *Widget, mute: bool, vol: ?*const [2]i32) void {
    if ((w.cap & Woutampcap) == 0)
        return;
    const r = if ((w.cap & Wampovrcap) == 0)
        cmd(w.fg.id, Getparm, Outampcap)
    else
        cmd(w.id, Getparm, Outampcap);
    const zerodb = r & 0x7f;

    for (0..2) |i| {
        var q: u32 = Asetout | @as(u32, if (i == 0) Asetleft else Asetright);
        if (mute)
            q |= Asetmute
        else if (vol) |v|
            q |= @as(u32, @bitCast(v[i])) << Again
        else
            q |= zerodb << Again;
        _ = cmd(w.id, Setamp, q);
    }
}

fn getinamprange(w: *Widget) u32 {
    if ((w.cap & Winampcap) == 0)
        return 0;
    const r = if ((w.cap & Wampovrcap) == 0)
        cmd(w.fg.id, Getparm, Inampcap)
    else
        cmd(w.id, Getparm, Inampcap);
    return (r >> 8) & 0x7f;
}

fn getinamp(w: *Widget, vol: *[2]i32) void {
    vol[0] = 0;
    vol[1] = 0;
    if ((w.cap & Winampcap) == 0)
        return;
    vol[0] = @intCast(cmd(w.id, Getamp, Agetin | Agetleft) & Againmask);
    vol[1] = @intCast(cmd(w.id, Getamp, Agetin | Agetright) & Againmask);
}

/// vol is 0...range or null for 0dB; mute is 0/1; in is widget or null for all
fn setinamp(w: *Widget, in: ?*Widget, mute: bool, vol: ?*const [2]i32) void {
    if ((w.cap & Winampcap) == 0)
        return;
    const r = if ((w.cap & Wampovrcap) == 0)
        cmd(w.fg.id, Getparm, Inampcap)
    else
        cmd(w.id, Getparm, Inampcap);
    const zerodb = r & 0x7f;

    for (0..2) |i| {
        var q: u32 = Asetin | @as(u32, if (i == 0) Asetleft else Asetright);
        if (mute)
            q |= Asetmute
        else if (vol) |v|
            q |= @as(u32, @bitCast(v[i])) << Again
        else
            q |= zerodb << Again;
        for (0..w.nlist) |j| {
            if (in == null or w.list.?[j] == in)
                _ = cmd(w.id, Setamp, q | (@as(u32, @intCast(j)) << Asetidx));
        }
    }
}

fn findpath(jack: *Widget, typ: u32, route_: ?[]const u8) ?*Widget {
    var q: [Maxwidgets]*Widget = undefined;
    const fg = jack.fg;

    var l: usize = 0;
    var r: usize = 0;
    var wp = fg.first;
    while (wp) |w| : (wp = w.next)
        w.link = null;

    if (route_) |route0| if (route0.len > 0) {
        var route = route0;
        var w = jack;
        while (route.len > 0 and route[0] == ',') {
            route = route[1..];
            const s = netif.strtoul(route, 0);
            route = route[s.n..];
            const i = s.v;
            if (i >= Maxwidgets)
                return null;
            const to = fg.codec.widgets[i] orelse return null;
            if (to.fg != fg or to.link != null)
                return null;
            if (typ == Waout)
                to.link = w
            else
                w.link = to;
            w = to;
        }
        if (w == jack or w.type != typ)
            return null;
        return w;
    };

    if (typ == Waout) {
        q[r] = jack;
        r += 1;
        jack.link = jack;
    } else {
        wp = fg.first;
        while (wp) |w| : (wp = w.next) {
            if (w.type == typ) {
                q[r] = w;
                r += 1;
                w.link = w;
            }
        }
    }

    while (l < r) {
        const w = q[l];
        l += 1;
        if (typ == Waout) {
            if (w.type == typ)
                return w;
        } else if (w == jack) {
            var x = jack.link;
            while (x) |y| : (x = y.link) {
                if (y.type == typ)
                    return y;
            }
            break;
        }
        for (0..w.nlist) |i| {
            const to = w.list.?[i] orelse continue;
            if (to.link != null)
                continue;
            to.link = w;
            q[r] = to;
            r += 1;
        }
    }

    return null;
}

fn disconnectpath(from_: ?*Widget, to: *Widget) void {
    var from = from_;
    while (from) |f| {
        if (f == to)
            break;
        const next = f.path;
        f.path = null;
        setoutamp(f, true, null);
        if (next) |n|
            setinamp(n, f, true, null);
        from = next;
    }
    setoutamp(to, true, null);
}

fn muteall(ctlr: *Ctlr) void {
    for (ctlr.codec) |codec| {
        const c = codec orelse continue;
        var fgp = c.fgroup;
        while (fgp) |fg| : (fgp = fg.next) {
            var wp = fg.first;
            while (wp) |w| : (wp = w.next) {
                setinamp(w, null, true, null);
                setoutamp(w, true, null);
                switch (w.type) {
                    Wain, Waout => _ = cmd(w.id, Setstream, 0),
                    Wpin => _ = cmd(w.id, Setpinctl, 0),
                    else => {},
                }
            }
        }
    }
}

fn connectpath(from_: ?*Widget, to: *Widget) void {
    var from = from_;
    while (from) |f| {
        if (f == to)
            break;
        const next = f.link;
        f.path = next;
        setoutamp(f, false, null);
        if (next) |n| {
            setinamp(n, f, false, null);
            for (0..n.nlist) |i| {
                if (n.list.?[i] == f) {
                    _ = cmd(n.id, Setconn, @intCast(i));
                    break;
                }
            }
        }
        from = next;
    }
    setoutamp(to, false, null);
}

fn addconn(w: *Widget, nid: u32) void {
    var src: ?*Widget = null;
    if (nid < Maxwidgets)
        src = w.fg.codec.widgets[nid];
    if (src == null or src.?.fg != w.fg) {
        print("hda: invalid connection %d:%s[%d] -> %d\n", .{ w.id.nid, widtype[w.type & 7], w.nlist, nid });
        src = null;
    }
    if ((w.nlist % 16) == 0) {
        const p = alloc.realloc(@ptrCast(w.list), @sizeOf(?*Widget) * (w.nlist + 16)) orelse {
            print("hda: no memory for Widgetlist\n", .{});
            return;
        };
        w.list = @ptrCast(@alignCast(p));
    }
    w.list.?[w.nlist] = src;
    w.nlist += 1;
}

fn enumconns(w: *Widget) void {
    if ((w.cap & Wconncap) == 0)
        return;

    var r = cmd(w.id, Getparm, Connlistlen);
    const n = r & 0x7f;
    const b: u5 = if ((r & 0x80) != 0) 16 else 8;
    const m: u32 = (@as(u32, 1) << b) - 1;
    const f: u32 = (32 / @as(u32, b)) - 1;
    var x: u32 = 0;
    for (0..n) |ii| {
        const i: u32 = @intCast(ii);
        if ((i & f) != 0)
            r >>= b
        else
            r = cmd(w.id, Getconnlist, i);
        const y = r & (m >> 1);
        if (i != 0 and (r & m) != y) {
            x += 1;
            while (x < y) : (x += 1)
                addconn(w, x);
        }
        addconn(w, y);
        x = y;
    }
}

fn enumwidget(w: *Widget) void {
    w.cap = cmd(w.id, Getparm, Widgetcap);
    w.type = (w.cap >> 20) & 0x7;
    if ((w.cap & Wpwrcap) != 0) {
        _ = cmd(w.id, Setpower, 0);
        arch.delay(10);
    }
    switch (w.type) {
        Wpin => {
            w.pin = cmd(w.id, Getdefault, 0);
            w.pincap = cmd(w.id, Getparm, Pincap);
            if ((w.pincap & Peapd) != 0)
                _ = cmd(w.id, Seteapd, Eapdenable);
        },
        else => {},
    }
}

fn enumfungroup(codec: *Codec, id: Id) ?*Fungroup {
    var r = cmd(id, Getparm, Fungrtype) & 0x7f;
    if (r != Graudio) {
        _ = cmd(id, Setpower, 3); // turn off
        return null;
    }

    // open eyes
    _ = cmd(id, Setpower, 0);
    arch.delay(10);

    r = cmd(id, Getparm, Subnodecnt);
    var n = r & 0xff;
    const base = (r >> 16) & 0xff;
    if (base >= Maxwidgets) {
        print("hda: enumfungroup: base %d out of range\n", .{base});
        return null;
    }
    if (base + n > Maxwidgets) {
        print("hda: enumfungroup: widgets %d - %d out of range\n", .{ base, base + n });
        n = Maxwidgets - base;
    }

    const fg = alloc.new(Fungroup) orelse {
        print("hda: enumfungroup: out of memory\n", .{});
        return null;
    };
    fg.* = .{ .codec = codec, .id = id, .type = r };

    var tail = &fg.first;
    for (0..n) |i| {
        if (codec.widgets[base + i] != null) {
            print("hda: enumfungroup: duplicate widget %d\n", .{base + i});
            continue;
        }
        const w = alloc.new(Widget) orelse {
            while (fg.first) |x| {
                fg.first = x.next;
                codec.widgets[x.id.nid] = null;
                alloc.free(x);
            }
            alloc.free(fg);
            print("hda: enumfungroup: out of memory\n", .{});
            return null;
        };
        w.* = .{ .id = newnid(id, @intCast(base + i)), .fg = fg };
        tail.* = w;
        tail = &w.next;
        codec.widgets[w.id.nid] = w;
    }

    // DIFF: a duplicate widget's slot is someone else's, or empty;
    // the C enumerates whatever is there.
    for (0..n) |i| {
        if (codec.widgets[base + i]) |w| if (w.fg == fg)
            enumwidget(w);
    }
    for (0..n) |i| {
        if (codec.widgets[base + i]) |w| if (w.fg == fg)
            enumconns(w);
    }

    return fg;
}

fn enumcodec(codec: *Codec, id: Id) i32 {
    var vid: u32 = 0;
    var rid: u32 = 0;
    if (cmderr(id, Getparm, Vendorid, &vid) < 0)
        return -1;
    if (cmderr(id, Getparm, Revid, &rid) < 0)
        return -1;

    codec.id = id;
    codec.vid = vid;
    codec.rid = rid;

    const r = cmd(id, Getparm, Subnodecnt);
    const n = r & 0xff;
    const base = (r >> 16) & 0xff;

    for (0..n) |i| {
        const fg = enumfungroup(codec, newnid(id, @intCast(base + i))) orelse continue;
        fg.next = codec.fgroup;
        codec.fgroup = fg;
    }
    if (codec.fgroup == null)
        return -1;

    print("#A%d: codec #%d, vendor %08ux, rev %08ux\n", .{ id.ctlr.no, codec.id.codec, codec.vid, codec.rid });

    return 0;
}

fn enumdev(ctlr: *Ctlr) i32 {
    var ret: i32 = -1;
    var id: Id = .{ .ctlr = ctlr, .nid = 0 };
    for (0..Maxcodecs) |i| {
        if (((@as(u32, 1) << @intCast(i)) & ctlr.codecmask) == 0)
            continue;
        const codec = alloc.new(Codec) orelse {
            print("hda: no memory for Codec\n", .{});
            break;
        };
        id.codec = @intCast(i);
        codec.* = .{ .id = id };
        ctlr.codec[i] = codec;
        if (enumcodec(codec, id) < 0) {
            ctlr.codec[i] = null;
            alloc.free(codec);
            continue;
        }
        ret += 1;
    }
    return ret;
}

fn connectpin(ctlr: *Ctlr, s: *Stream, typ: u32, pin: u32, cad: u32, route: ?[]const u8) i32 {
    if (s.atag == 0)
        return -1;
    if (cad >= Maxcodecs or pin >= Maxwidgets or ctlr.codec[cad] == null)
        return -1;
    const jack = ctlr.codec[cad].?.widgets[pin] orelse return -1;
    if (jack.type != Wpin)
        return -1;

    const conv = findpath(jack, typ, route) orelse return -1;

    if (s.conv) |sconv| if (s.jack) |sjack| {
        if (sconv.type == Waout)
            disconnectpath(sconv, sjack)
        else
            disconnectpath(sjack, sconv);
        _ = cmd(sconv.id, Setstream, 0);
        _ = cmd(sjack.id, Setpinctl, 0);
    };

    if (typ == Waout) {
        connectpath(conv, jack);
        _ = cmd(jack.id, Setpinctl, Pinctlout);
    } else {
        connectpath(jack, conv);
        _ = cmd(jack.id, Setpinctl, Pinctlin);
    }

    _ = cmd(conv.id, Setconvfmt, s.afmt);
    _ = cmd(conv.id, Setstream, (s.atag << 4) | 0);
    _ = cmd(conv.id, Setchancnt, 1);

    s.conv = conv;
    s.jack = jack;
    s.pin = pin;
    s.cad = cad;

    return 0;
}

fn scoreout(w: *Widget) i32 {
    if ((w.pincap & Pout) == 0)
        return -1;
    if (w.id.ctlr.sin.jack == w)
        return -1;

    var score: i32 = 0;
    const r = w.pin;
    if (((r >> 30) & 0x3) >= 2) // fix or fix+jack
        score |= 32;
    if (((r >> 12) & 0xf) == 4) // green
        score |= 32;
    if (((r >> 24) & 0xf) == 1) // rear
        score |= 16;
    if (((r >> 28) & 0x3) == 0) // ext
        score |= 8;
    if (((r >> 20) & 0xf) == 2) // hpout
        score |= 4;
    if (((r >> 20) & 0xf) == 0) // lineout
        score |= 4;
    return score;
}

fn scorein(w: *Widget) i32 {
    if ((w.pincap & Pin) == 0)
        return -1;
    if (w.id.ctlr.sout.jack == w)
        return -1;

    var score: i32 = 0;
    const r = w.pin;
    if (((r >> 30) & 0x3) >= 2) // fix or fix+jack
        score |= 4;
    return score;
}

fn bestpin(ctlr: *Ctlr, pcad: *u32, fscore: *const fn (*Widget) i32) i32 {
    var pin: i32 = -1;
    var best: i32 = -1;
    for (ctlr.codec, 0..) |codec, i| {
        const c = codec orelse continue;
        var fgp = c.fgroup;
        while (fgp) |fg| : (fgp = fg.next) {
            var wp = fg.first;
            while (wp) |w| : (wp = w.next) {
                if (w.type != Wpin)
                    continue;
                const score = fscore(w);
                if (score >= 0 and score >= best) {
                    best = score;
                    pin = @intCast(w.id.nid);
                    pcad.* = @intCast(i);
                }
            }
        }
    }
    return pin;
}

fn buffered(r: *Ring) u32 {
    const ri = @atomicLoad(u32, &r.ri, .monotonic);
    const wi = @atomicLoad(u32, &r.wi, .monotonic);
    if (wi >= ri)
        return wi - ri
    else
        return r.nbuf - (ri - wi);
}

fn available(r: *Ring) u32 {
    const m: i64 = @as(i64, r.nbuf - BytesPerSample) - buffered(r);
    return if (m < 0) 0 else @intCast(m);
}

fn readring(r: *Ring, p_: ?[*]u8, n_: usize) usize {
    var p = p_;
    var n = n_;
    while (n > 0) {
        var m: usize = buffered(r);
        if (m <= 0)
            break;
        if (m > n)
            m = n;
        const ri = @atomicLoad(u32, &r.ri, .monotonic);
        if (p) |pp| {
            if (ri + m > r.nbuf)
                m = r.nbuf - ri;
            @memcpy(pp[0..m], r.buf.?[ri..][0..m]);
            p = pp + m;
        }
        @atomicStore(u32, &r.ri, @intCast((ri + m) % r.nbuf), .monotonic);
        n -= m;
    }
    return n_ - n;
}

fn writering(r: *Ring, p_: ?[*]const u8, n_: usize) usize {
    var p = p_;
    var n = n_;
    while (n > 0) {
        var m: usize = available(r);
        if (m <= 0)
            break;
        if (m > n)
            m = n;
        const wi = @atomicLoad(u32, &r.wi, .monotonic);
        if (p) |pp| {
            if (wi + m > r.nbuf)
                m = r.nbuf - wi;
            @memcpy(r.buf.?[wi..][0..m], pp[0..m]);
            p = pp + m;
        }
        @atomicStore(u32, &r.wi, @intCast((wi + m) % r.nbuf), .monotonic);
        n -= m;
    }
    return n_ - n;
}

fn streamalloc(ctlr: *Ctlr, s: *Stream, num: u32) i32 {
    const r = &s.ring;
    r.nbuf = Bufsize;
    r.buf = @ptrFromInt(xalloc.xspanalloc(r.nbuf, 128, 0));
    const blds: [*]volatile Bld = @ptrFromInt(xalloc.xspanalloc(Nblocks * @sizeOf(Bld), 128, 0));
    s.blds = blds;
    for (0..Nblocks) |i| {
        const pa = pciwaddr(@intFromPtr(r.buf.?)) + i * Blocksize;
        blds[i] = .{
            .addrlo = @truncate(pa),
            .addrhi = @truncate(pa >> 32),
            .len = Blocksize,
            .flags = 0x01, // interrupt on completion
        };
    }

    s.sdnum = num;
    s.sdctl = Sdctl0 + s.sdnum * 0x20;
    s.sdintr = @as(u32, 1) << @intCast(s.sdnum);
    s.atag = s.sdnum + 1;
    s.afmt = Fmtstereo | Fmtsampw | Fmtdiv1 | Fmtmul1 | Fmtbase441;
    s.active = false;

    // perform reset
    csr8w(ctlr, s.sdctl, csr8r(ctlr, s.sdctl) & ~@as(u8, Srst | Srun | Scie | Seie | Sdie));
    csr8w(ctlr, s.sdctl, csr8r(ctlr, s.sdctl) | Srst);
    arch.microdelay(Codecdelay);
    _ = waitup8(ctlr, s.sdctl, Srst, Srst);
    csr8w(ctlr, s.sdctl, csr8r(ctlr, s.sdctl) & ~@as(u8, Srst));
    arch.microdelay(Codecdelay);
    _ = waitup8(ctlr, s.sdctl, Srst, 0);

    // set stream number
    csr32w(ctlr, s.sdctl, (s.atag << Stagbit) |
        (csr32r(ctlr, s.sdctl) & ~@as(u32, 0xF << Stagbit)));

    // set stream format
    csr16w(ctlr, Sdfmt + s.sdctl, @intCast(s.afmt));

    // program stream DMA & parms
    const pa = pciwaddr(@intFromPtr(blds));
    csr32w(ctlr, Sdbdplo + s.sdctl, @truncate(pa));
    csr32w(ctlr, Sdbdphi + s.sdctl, @truncate(pa >> 32));
    csr32w(ctlr, Sdcbl + s.sdctl, r.nbuf);
    csr16w(ctlr, Sdlvi + s.sdctl, (Nblocks - 1) & 0xff);

    // mask out ints
    csr8w(ctlr, Sdsts + s.sdctl, Scompl | Sfifoerr | Sdescerr);

    // enable global intrs for this stream
    csr32w(ctlr, Intctl, csr32r(ctlr, Intctl) | s.sdintr);
    csr8w(ctlr, s.sdctl, csr8r(ctlr, s.sdctl) | Scie | Seie | Sdie);

    return 0;
}

fn streamstart(ctlr: *Ctlr, s: *Stream) void {
    s.active = true;
    csr8w(ctlr, s.sdctl, csr8r(ctlr, s.sdctl) | Srun);
    _ = waitup8(ctlr, s.sdctl, Srun, Srun);
}

fn streamstop(ctlr: *Ctlr, s: *Stream) void {
    csr8w(ctlr, s.sdctl, csr8r(ctlr, s.sdctl) & ~@as(u8, Srun));
    _ = waitup8(ctlr, s.sdctl, Srun, 0);
    s.active = false;
}

fn streampos(ctlr: *Ctlr, s: *Stream) u32 {
    var p = csr32r(ctlr, Sdlpib + s.sdctl);
    if (p >= s.ring.nbuf)
        p = 0;
    return p;
}

fn ctlrof(adev: *Audio) *Ctlr {
    return @ptrCast(@alignCast(adev.ctlr.?));
}

fn hdactl(adev: *Audio, va: []u8, _: i64) Error!usize {
    const ctlr = ctlrof(adev);

    var lines = std.mem.splitScalar(u8, va, '\n');
    while (lines.next()) |line_| {
        // tokenize edits the line in place
        const line = va[@intFromPtr(line_.ptr) - @intFromPtr(va.ptr) ..][0..line_.len];
        var tok: [4][]u8 = undefined;
        const ntok = parse.tokenize(line, &tok);
        if (ntok <= 0)
            continue;
        if (std.ascii.eqlIgnoreCase(tok[0], "pin") and ntok >= 2) {
            var cad = ctlr.sout.cad;
            const s = netif.strtoul(tok[1], 0);
            const pin = s.v;
            const route = tok[1][s.n..];
            if (ntok > 2)
                cad = netif.strtoul(tok[2], 0).v;
            if (connectpin(ctlr, &ctlr.sout, Waout, pin, cad, route) < 0)
                return proc.errorf("connectpin failed", .{});
        } else if (std.ascii.eqlIgnoreCase(tok[0], "inpin") and ntok >= 2) {
            var cad = ctlr.sin.cad;
            const s = netif.strtoul(tok[1], 0);
            const pin = s.v;
            const route = tok[1][s.n..];
            if (ntok > 2)
                cad = netif.strtoul(tok[2], 0).v;
            if (connectpin(ctlr, &ctlr.sin, Wain, pin, cad, route) < 0)
                return proc.errorf("connectpin failed", .{});
        } else return error.Ebadctl;
    }
    return va.len;
}

fn inavail(arg: ?*anyopaque) bool {
    const r: *Ring = @ptrCast(@alignCast(arg.?));
    return buffered(r) > 0;
}

fn outavail(arg: ?*anyopaque) bool {
    const r: *Ring = @ptrCast(@alignCast(arg.?));
    return available(r) > 0;
}

fn outrate(arg: ?*anyopaque) bool {
    const ctlr: *Ctlr = @ptrCast(@alignCast(arg.?));
    const delay = ctlr.adev.?.delay * BytesPerSample;
    return (delay <= 0) or (buffered(&ctlr.sout.ring) <= delay) or !@atomicLoad(bool, &ctlr.sout.active, .monotonic);
}

fn hdabuffered(adev: *Audio) usize {
    const ctlr = ctlrof(adev);
    return buffered(&ctlr.sout.ring);
}

fn hdakick(ctlr: *Ctlr) void {
    if (@atomicLoad(bool, &ctlr.sout.active, .monotonic))
        return;
    const delay = ctlr.adev.?.delay * BytesPerSample;
    if (buffered(&ctlr.sout.ring) >= delay)
        streamstart(ctlr, &ctlr.sout);
}

fn hdaread(adev: *Audio, vp: []u8, _: i64) Error!usize {
    const ctlr = ctlrof(adev);
    const ring = &ctlr.sin.ring;
    if (ring.buf == null or ctlr.sin.conv == null)
        return 0;
    var p: usize = 0;
    while (p < vp.len) {
        const n = readring(ring, vp[p..].ptr, vp.len - p);
        if (n <= 0) {
            if (!@atomicLoad(bool, &ctlr.sin.active, .monotonic))
                streamstart(ctlr, &ctlr.sin);
            try proc.sleep(&ring.r, inavail, ring);
            continue;
        }
        p += n;
    }
    return p;
}

fn hdawrite(adev: *Audio, vp: []const u8, _: i64) Error!usize {
    const ctlr = ctlrof(adev);
    const ring = &ctlr.sout.ring;
    if (ring.buf == null or ctlr.sout.conv == null)
        return 0;
    var p: usize = 0;
    while (p < vp.len) {
        const n = writering(ring, vp[p..].ptr, vp.len - p);
        if (n <= 0) {
            hdakick(ctlr);
            try proc.sleep(&ring.r, outavail, ring);
            continue;
        }
        p += n;
    }
    hdakick(ctlr);
    while (!outrate(ctlr))
        try proc.sleep(&ring.r, outrate, ctlr);
    return p;
}

fn hdaclose(adev: *Audio, mode: u32) Error!void {
    const ctlr = ctlrof(adev);
    if (mode == lib.OREAD or mode == lib.ORDWR) {
        if (@atomicLoad(bool, &ctlr.sin.active, .monotonic))
            streamstop(ctlr, &ctlr.sin);
    }
    if (mode == lib.OWRITE or mode == lib.ORDWR) {
        const ring = &ctlr.sout.ring;
        const zero = [1]u8{0};
        while (@atomicLoad(u32, &ring.wi, .monotonic) % Blocksize != 0) {
            if (writering(ring, &zero, 1) <= 0)
                break;
        }
    }
}

const Vmaster = 0;
const Vrecord = 1;
const Vspeed = 2;
const Vdelay = 3;
const Nvol = 4;

const voltab = [Nvol]Volume{
    .{ .name = "master", .reg = 0, .range = 0x7f, .type = audioif.Stereo, .cap = 0 },
    .{ .name = "recgain", .reg = 0, .range = 0x7f, .type = audioif.Stereo, .cap = 0 },
    .{ .name = "speed", .reg = 0, .range = 0, .type = audioif.Absolute, .cap = 0 },
    .{ .name = "delay", .reg = 0, .range = 0, .type = audioif.Absolute, .cap = 0 },
};

fn findoutamp(s: *Stream) ?*Widget {
    var wp = s.conv;
    while (wp) |w| : (wp = w.path) {
        if ((w.cap & Woutampcap) != 0)
            return w;
        if (w == s.jack)
            break;
    }
    return null;
}

fn findinamp(s: *Stream) ?*Widget {
    var a: ?*Widget = null;
    var p: ?*Widget = null;
    var wp = s.jack;
    while (wp) |w| : ({
        p = w;
        wp = w.path;
    }) {
        w.link = p; // for setinamp
        if ((w.cap & Winampcap) != 0)
            a = w;
        if (w == s.conv)
            break;
    }
    return a;
}

fn hdagetvol(adev: *Audio, x: usize, a: *[2]i32) i32 {
    const ctlr = ctlrof(adev);
    switch (x) {
        Vmaster => if (findoutamp(&ctlr.sout)) |w| getoutamp(w, a),
        Vrecord => if (findinamp(&ctlr.sin)) |w| getinamp(w, a),
        Vspeed => a[0] = adev.speed,
        Vdelay => a[0] = adev.delay,
        else => {},
    }
    return 0;
}

fn hdasetvol(adev: *Audio, x: usize, a: *[2]i32) i32 {
    const ctlr = ctlrof(adev);
    switch (x) {
        Vmaster => if (findoutamp(&ctlr.sout)) |w| setoutamp(w, false, a),
        Vrecord => if (findinamp(&ctlr.sin)) |w| setinamp(w, w.link, false, a),
        Vspeed => adev.speed = a[0],
        Vdelay => {
            const max: i32 = @intCast(ctlr.sout.ring.nbuf / BytesPerSample - 1);
            if (a[0] < Blocksize / BytesPerSample) {
                adev.delay = Blocksize / BytesPerSample;
            } else if (a[0] > max) {
                adev.delay = max;
            } else {
                adev.delay = a[0];
            }
        },
        else => {},
    }
    return 0;
}

fn fillvoltab(ctlr: *Ctlr, vt: *[Nvol]Volume) void {
    vt.* = voltab;
    if (findoutamp(&ctlr.sout)) |w|
        vt[Vmaster].range = @intCast(getoutamprange(w));
    if (findinamp(&ctlr.sin)) |w|
        vt[Vrecord].range = @intCast(getinamprange(w));
}

fn hdavolread(adev: *Audio, a: []u8, _: i64) Error!usize {
    var vt: [Nvol]Volume = undefined;
    fillvoltab(ctlrof(adev), &vt);
    return devaudio.genaudiovolread(adev, a, 0, &vt, hdagetvol, 0);
}

fn hdavolwrite(adev: *Audio, a: []u8, _: i64) Error!usize {
    var vt: [Nvol]Volume = undefined;
    fillvoltab(ctlrof(adev), &vt);
    return devaudio.genaudiovolwrite(adev, a, 0, &vt, hdasetvol, 0);
}

fn hdainterrupt(_: *arch.Ureg, arg: ?*anyopaque) void {
    const adev: *Audio = @ptrCast(@alignCast(arg.?));
    const ctlr: *Ctlr = @ptrCast(@alignCast(adev.ctlr orelse return));
    if (ctlr.adev != adev)
        return;
    ilock(&ctlr.lock);
    const sts = csr32r(ctlr, Intsts);
    if ((sts & ctlr.sout.sdintr) != 0) {
        csr8w(ctlr, Sdsts + ctlr.sout.sdctl, csr8r(ctlr, Sdsts + ctlr.sout.sdctl) | Scompl);

        const r = &ctlr.sout.ring;
        @atomicStore(u32, &r.ri, streampos(ctlr, &ctlr.sout), .monotonic);
        if (ctlr.sout.active and buffered(r) < Blocksize) {
            streamstop(ctlr, &ctlr.sout);
            const pos = streampos(ctlr, &ctlr.sout);
            @atomicStore(u32, &r.ri, pos, .monotonic);
            @atomicStore(u32, &r.wi, pos, .monotonic);
        }
        _ = proc.wakeup(&r.r);
    }
    if ((sts & ctlr.sin.sdintr) != 0) {
        csr8w(ctlr, Sdsts + ctlr.sin.sdctl, csr8r(ctlr, Sdsts + ctlr.sin.sdctl) | Scompl);

        const r = &ctlr.sin.ring;
        @atomicStore(u32, &r.wi, streampos(ctlr, &ctlr.sin), .monotonic);
        if (ctlr.sin.active and available(r) < Blocksize) {
            streamstop(ctlr, &ctlr.sin);
            const pos = streampos(ctlr, &ctlr.sin);
            @atomicStore(u32, &r.ri, pos, .monotonic);
            @atomicStore(u32, &r.wi, pos, .monotonic);
        }
        _ = proc.wakeup(&r.r);
    }
    if ((sts & Cis) != 0) {
        csr8w(ctlr, Rirbsts, Rirbrover | Rirbrint);
    }
    iunlock(&ctlr.lock);
}

fn hdastatus(adev: *Audio, a: []u8, _: i64) Error!usize {
    const ctlr = ctlrof(adev);
    var f: fmt.Fmt = .{ .buf = a };

    fmt.fmtprint(&f, "bufsize %6d buffered %6ld\n", .{ @as(u32, Blocksize), buffered(&ctlr.sout.ring) });
    for (ctlr.codec) |codec_| {
        const codec = codec_ orelse continue;
        fmt.fmtprint(&f, "codec %d pin %d inpin %d\n", .{ codec.id.codec, ctlr.sout.pin, ctlr.sin.pin });
        for (codec.widgets) |w_| {
            const w = w_ orelse continue;
            switch (w.type) {
                Wpin => {
                    const r = w.pin;
                    fmt.fmtprint(&f, "%s %d %s%s %s %s %s %s %s%s%s", .{
                        widtype[w.type & 7],                       w.id.nid,
                        if ((w.pincap & Pin) != 0) "in" else "",   if ((w.pincap & Pout) != 0) "out" else "",
                        pinport[(r >> 30) & 0x3],                  pinloc2[(r >> 28) & 0x3],
                        pinloc[(r >> 24) & 0xf],                   pinfunc[(r >> 20) & 0xf],
                        pincol[(r >> 12) & 0xf],                   if ((w.pincap & Phdmi) != 0) " hdmi" else "",
                        if ((w.pincap & Peapd) != 0) " eapd" else "",
                    });
                },
                else => fmt.fmtprint(&f, "%s %d %lux", .{ widtype[w.type & 7], w.id.nid, w.cap }),
            }
            if (w.nlist > 0) {
                fmt.fmtprint(&f, " ← ", .{});
                for (0..w.nlist) |k| {
                    if (k > 0)
                        fmt.fmtprint(&f, ", ", .{});
                    if (w.list.?[k]) |x|
                        fmt.fmtprint(&f, "%s %d", .{ widtype[x.type & 7], x.id.nid });
                }
            }
            fmt.fmtprint(&f, "\n", .{});
        }
    }

    if (ctlr.sout.conv != null and ctlr.sout.jack != null) {
        fmt.fmtprint(&f, "outpath ", .{});
        var wp = ctlr.sout.conv;
        while (wp) |w| : (wp = w.path) {
            fmt.fmtprint(&f, "%s %d", .{ widtype[w.type & 7], w.id.nid });
            if (w == ctlr.sout.jack)
                break;
            fmt.fmtprint(&f, " → ", .{});
        }
        fmt.fmtprint(&f, "\n", .{});
        if (findoutamp(&ctlr.sout)) |w|
            fmt.fmtprint(&f, "outamp %s %d\n", .{ widtype[w.type & 7], w.id.nid });
    }

    if (ctlr.sin.conv != null and ctlr.sin.jack != null) {
        fmt.fmtprint(&f, "inpath ", .{});
        var wp = ctlr.sin.jack;
        while (wp) |w| : (wp = w.path) {
            fmt.fmtprint(&f, "%s %d", .{ widtype[w.type & 7], w.id.nid });
            if (w == ctlr.sin.conv)
                break;
            fmt.fmtprint(&f, " → ", .{});
        }
        fmt.fmtprint(&f, "\n", .{});
        if (findinamp(&ctlr.sin)) |w|
            fmt.fmtprint(&f, "inamp %s %d\n", .{ widtype[w.type & 7], w.id.nid });
    }

    return f.n;
}

fn hdastart(ctlr: *Ctlr) i32 {
    const cmdbufsize = [_]u32{ 2, 16, 256, 2048 };

    // reset controller
    csr32w(ctlr, Gctl, csr32r(ctlr, Gctl) & ~@as(u32, Rst));
    _ = waitup32(ctlr, Gctl, Rst, 0);
    arch.microdelay(Codecdelay);
    csr32w(ctlr, Gctl, csr32r(ctlr, Gctl) | Rst);
    if (waitup32(ctlr, Gctl, Rst, Rst) != 0 and
        waitup32(ctlr, Gctl, Rst, Rst) != 0)
    {
        print("#A%d: hda failed to reset\n", .{ctlr.no});
        return -1;
    }
    arch.microdelay(Codecdelay);

    ctlr.codecmask = csr16r(ctlr, Statests);
    if (ctlr.codecmask == 0) {
        print("#A%d: hda no codecs\n", .{ctlr.no});
        return -1;
    }

    const cap: u32 = csr16r(ctlr, Gcap);
    ctlr.bss = (cap >> 3) & 0x1F;
    ctlr.iss = (cap >> 8) & 0xF;
    ctlr.oss = (cap >> 12) & 0xF;

    csr8w(ctlr, Corbctl, 0);
    _ = waitup8(ctlr, Corbctl, Corbdma, 0);

    csr8w(ctlr, Rirbctl, 0);
    _ = waitup8(ctlr, Rirbctl, Rirbdma, 0);

    // alloc command buffers
    var size = csr8r(ctlr, Corbsz);
    var n = cmdbufsize[size & 3];
    ctlr.corb = @ptrFromInt(xalloc.xspanalloc(n * 4, 128, 0));
    for (0..n) |i| ctlr.corb[i] = 0;
    ctlr.corbsize = n;

    size = csr8r(ctlr, Rirbsz);
    n = cmdbufsize[size & 3];
    ctlr.rirb = @ptrFromInt(xalloc.xspanalloc(n * 8, 128, 0));
    for (0..n * 2) |i| ctlr.rirb[i] = 0;
    ctlr.rirbsize = n;

    // setup controller
    csr32w(ctlr, Dplbase, 0);
    csr32w(ctlr, Dpubase, 0);
    csr16w(ctlr, Statests, csr16r(ctlr, Statests));
    csr8w(ctlr, Rirbsts, csr8r(ctlr, Rirbsts));

    // setup CORB
    var pa = pciwaddr(@intFromPtr(ctlr.corb));
    csr32w(ctlr, Corblbase, @truncate(pa));
    csr32w(ctlr, Corbubase, @truncate(pa >> 32));
    csr16w(ctlr, Corbwp, 0);
    csr16w(ctlr, Corbrp, Corbptrrst);
    _ = waitup16(ctlr, Corbrp, Corbptrrst, Corbptrrst);
    csr16w(ctlr, Corbrp, 0);
    _ = waitup16(ctlr, Corbrp, Corbptrrst, 0);
    csr8w(ctlr, Corbctl, Corbdma);
    _ = waitup8(ctlr, Corbctl, Corbdma, Corbdma);

    // setup RIRB
    pa = pciwaddr(@intFromPtr(ctlr.rirb));
    csr32w(ctlr, Rirblbase, @truncate(pa));
    csr32w(ctlr, Rirbubase, @truncate(pa >> 32));
    csr16w(ctlr, Rirbwp, Rirbptrrst);

    // qemu requires interrupt handshake,
    // even tho we just poll the irb write
    // pointer for command completion.
    csr16w(ctlr, Rintcnt, 1);
    csr8w(ctlr, Rirbctl, Rirbdma | Rirbint);

    _ = waitup8(ctlr, Rirbctl, Rirbdma, Rirbdma);

    return 0;
}

/// DIFF: see the header.  Whether p is the audio function of a device
/// whose function 0 is a display controller.
fn isgpuaudio(p: *Pcidev) bool {
    if (pci.BUSFNO(p.tbdf) == 0)
        return false;
    const f0 = pci.pcimatchtbdf(p.tbdf & ~@as(i32, 7 << 8)) orelse return false;
    return f0.ccrb == 0x03;
}

fn hdamatch(prev: ?*Pcidev) ?*Pcidev {
    var pp = prev;
    while (pci.pcimatch(pp, 0, 0)) |p| {
        pp = p;
        if (isgpuaudio(p)) {
            if ((p.ccrb == 0x04 and p.ccru == 0x03) or knownhda(p))
                print("hda: %T: graphics card audio, not used\n", .{pci.tbdf(p.tbdf)});
            continue;
        }
        if (p.ccrb == 0x04 and p.ccru == 0x03)
            return p;
        if (knownhda(p))
            return p;
    }
    return null;
}

fn knownhda(p: *Pcidev) bool {
    return switch ((@as(u32, p.vid) << 16) | p.did) {
        (0x8086 << 16) | 0x2668, // Intel ICH6 (untested)
        (0x8086 << 16) | 0x27d8, // Intel ICH7
        (0x8086 << 16) | 0x269a, // Intel ESB2 (untested)
        (0x8086 << 16) | 0x284b, // Intel ICH8
        (0x8086 << 16) | 0x293f, // Intel ICH9 (untested)
        (0x8086 << 16) | 0x293e, // Intel P35 (untested)
        (0x8086 << 16) | 0x3b56, // Intel P55 (Ibex Peak)
        (0x8086 << 16) | 0x811b, // Intel SCH (Poulsbo)
        (0x8086 << 16) | 0x080a, // Intel SCH (Oaktrail)
        (0x8086 << 16) | 0x1c20, // Intel PCH
        (0x8086 << 16) | 0x1e20, // Intel (Thinkpad x230t)
        (0x8086 << 16) | 0x8c20, // Intel 8 Series/C220 Series
        (0x8086 << 16) | 0x8ca0, // Intel 9 Series
        (0x8086 << 16) | 0x9c20, // Intel 8 Series Lynx Point
        (0x8086 << 16) | 0x9ca0, // Intel Wildcat Point
        (0x8086 << 16) | 0xa170, // Intel Sunrise Point-H
        (0x8086 << 16) | 0x9d70, // Intel Sunrise Point-LP
        (0x8086 << 16) | 0x9d71, // Intel Kabylake-LP
        (0x8086 << 16) | 0x3a6e, // Intel ICH10
        (0x8086 << 16) | 0x3198, // Intel Gemini-Lake
        (0x8086 << 16) | 0x8d20, // Intel C610/X99
        (0x8086 << 16) | 0xa2f0, // Intel 200 Series PCH HD Audio
        (0x8086 << 16) | 0xa3f0, // Intel CometLake-S
        (0x8086 << 16) | 0x0f04, // Atom Z36*,Z37*
        (0x8086 << 16) | 0x9dc8, // Intel Cannon Point-LP
        (0x8086 << 16) | 0xa348, // Intel Cannon Lake
        (0x8086 << 16) | 0xa0c8, // Intel Tiger Lake

        (0x10de << 16) | 0x026c, // NVidia MCP51 (untested)
        (0x10de << 16) | 0x0371, // NVidia MCP55 (untested)
        (0x10de << 16) | 0x03e4, // NVidia MCP61 (untested)
        (0x10de << 16) | 0x03f0, // NVidia MCP61A (untested)
        (0x10de << 16) | 0x044a, // NVidia MCP65 (untested)
        (0x10de << 16) | 0x055c, // NVidia MCP67 (untested)
        (0x10de << 16) | 0x0fbb, // NVidia GM204 (untested)

        (0x1002 << 16) | 0x437b, // ATI SB450 (untested)
        (0x1002 << 16) | 0x4383, // ATI SB600
        (0x1002 << 16) | 0xaa55, // ATI HDMI (8500 series)
        (0x1002 << 16) | 0x7919, // ATI HDMI

        (0x1106 << 16) | 0x3288, // VIA (untested)
        (0x1039 << 16) | 0x7502, // SIS (untested)
        (0x10b9 << 16) | 0x5461, // ULI (untested)

        (0x1022 << 16) | 0x780d, // AMD FCH Azalia Controller
        (0x1022 << 16) | 0x1457, // AMD Family 17h (Models 00h-0fh) HD Audio Controller
        (0x1022 << 16) | 0x1487, // AMD Starship/Matisse HD Audio Controller
        (0x1022 << 16) | 0x15e3, // AMD Raven HD Audio Controller

        (0x15ad << 16) | 0x1977, // Vmware
        => true,
        else => false,
    };
}

fn hdareset1(adev: *Audio, ctlr: *Ctlr) i32 {
    const p = ctlr.pcidev.?;
    const irq: i32 = p.intl;
    const tbdf = p.tbdf;

    if (p.vid == 0x10de) {
        // magic for NVidia
        pci.pcicfgw8(p, 0x4e, (pci.pcicfgr8(p, 0x4e) & 0xf0) | 0x0f);
    }
    if (p.vid == 0x10b9) {
        // magic for ULI
        pci.pcicfgw16(p, 0x40, pci.pcicfgr16(p, 0x40) | 0x10);
        pci.pcicfgw32(p, pci.PciBAR1, 0);
    }
    if (p.vid == 0x8086) {
        // magic for Intel
        switch (p.did) {
            0x1c20, // PCH
            0x1e20,
            0x811b, // SCH
            0x080a,
            0x8c20,
            0x8ca0,
            0x9c20,
            0x9ca0,
            0xa170,
            => pci.pcicfgw16(p, 0x78, pci.pcicfgr16(p, 0x78) & ~@as(i32, 0x800)),
            else => {},
        }
    }
    if (p.vid == 0x1002) {
        // magic for ATI
        pci.pcicfgw8(p, 0x42, pci.pcicfgr8(p, 0x42) | 0x02);
    } else {
        // TCSEL
        pci.pcicfgw8(p, 0x44, pci.pcicfgr8(p, 0x44) & 0xf8);
    }

    if ((p.mem[0].bar & 1) != 0) {
        print("hda: bar0 %llux: not memory\n", .{p.mem[0].bar});
        return -1;
    }
    ctlr.size = @intCast(p.mem[0].size);
    ctlr.port = p.mem[0].bar & ~@as(u64, 0xF);
    ctlr.mem = arch.vmap(ctlr.port, ctlr.size) orelse {
        print("hda: can't map %llux\n", .{ctlr.port});
        return -1;
    };
    ctlr.no = adev.ctlrno;
    print("#A%d: hda mem %llux irq %d\n", .{ ctlr.no, ctlr.port, irq });

    if (hdastart(ctlr) < 0) {
        print("#A%d: unable to start hda\n", .{ctlr.no});
        return -1;
    }

    // iss + oss + bss
    if (streamalloc(ctlr, &ctlr.sout, ctlr.iss) < 0)
        print("#A%d: output streamalloc failed\n", .{ctlr.no});
    if (ctlr.iss > 0) {
        if (streamalloc(ctlr, &ctlr.sin, 0) < 0)
            print("#A%d: input streamalloc failed\n", .{ctlr.no});
    } else if (ctlr.bss > 0) {
        if (ctlr.oss > 0) {
            if (streamalloc(ctlr, &ctlr.sin, ctlr.oss) < 0)
                print("#A%d: input streamalloc failed\n", .{ctlr.no});
        } else if (ctlr.bss > 1) {
            if (streamalloc(ctlr, &ctlr.sin, 1) < 0)
                print("#A%d: input streamalloc failed\n", .{ctlr.no});
        }
    }
    pci.pcisetbme(p);

    if (enumdev(ctlr) < 0) {
        print("#A%d: no audio codecs found\n", .{ctlr.no});
        return -1;
    }
    muteall(ctlr);

    var cad: u32 = 0;
    var best = bestpin(ctlr, &cad, scoreout);
    if (best < 0)
        print("#A%d: no output pins found\n", .{ctlr.no})
    else if (connectpin(ctlr, &ctlr.sout, Waout, @intCast(best), cad, null) < 0)
        print("#A%d: error connecting output pin\n", .{ctlr.no});

    best = bestpin(ctlr, &cad, scorein);
    if (best < 0)
        print("#A%d: no input pins found\n", .{ctlr.no})
    else if (connectpin(ctlr, &ctlr.sin, Wain, @intCast(best), cad, null) < 0)
        print("#A%d: error connecting input pin\n", .{ctlr.no});

    adev.ctlr = ctlr;
    adev.read = hdaread;
    adev.write = hdawrite;
    adev.close = hdaclose;
    adev.buffered = hdabuffered;
    adev.volread = hdavolread;
    adev.volwrite = hdavolwrite;
    adev.status = hdastatus;
    adev.ctl = hdactl;

    arch.intrenable(irq, hdainterrupt, adev, tbdf, "hda");

    // enable interrupts
    csr32w(ctlr, Intctl, csr32r(ctlr, Intctl) | Gie | Cie);

    return 0;
}

var cards: ?*Ctlr = null;

fn hdareset(adev: *Audio) i32 {
    // make a list of all cards if not already done
    if (cards == null) {
        var pp: ?*Pcidev = null;
        while (hdamatch(pp)) |p| {
            pp = p;
            const ctlr = alloc.new(Ctlr) orelse {
                print("hda: can't allocate memory\n", .{});
                break;
            };
            ctlr.* = .{ .pcidev = p, .next = cards };
            cards = ctlr;
        }
    }

    // pick a card from the list
    var cp = cards;
    while (cp) |ctlr| : (cp = ctlr.next) {
        if (ctlr.adev == null and ctlr.pcidev != null) {
            ctlr.adev = adev;
            pci.pcienable(ctlr.pcidev);
            if (hdareset1(adev, ctlr) == 0)
                return 0;
            pci.pcidisable(ctlr.pcidev);
            ctlr.pcidev = null;
            ctlr.adev = null;
        }
    }
    return -1;
}

pub fn audiohdalink() void {
    devaudio.addaudiocard("hda", hdareset);
}
