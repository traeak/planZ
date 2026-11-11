//! sata fises and sas frames
//! copyright © 2009-2010 erik quanstrom
//! from libfis/fis.c and include/fis.h
//!
//! DIFF:
//!   - A fis is a slice (`c: []u8`) of at least Fissize bytes.  For
//!     atapirwfis it must reach 0x40 + 16 bytes, since the C writes the
//!     packet at c + 0x40 (the caller hands it the start of an ahci
//!     command table).
//!   - Identify data is a `[]const u16` of the 256 words; id16/id32/id64
//!     and the internal gbit16/32/64 take it with a word index, where
//!     the C takes `id + i`.  The words are read little-endian as in C.
//!   - rwfis takes the direction as a bool (false read, true write), as
//!     SDread and SDwrite are in devsd.zig.
//!   - pflag takes the rest of the buffer as a slice and returns how
//!     much it wrote, the convention of SDifc.rctl.
//!   - idmove takes the destination as a slice of at least n+1 bytes.
//!     When it strips leading blanks the C's memmove reads up to n bytes
//!     past the blanks, which can be beyond the n+1 bytes it owns; here
//!     the string and its terminator are moved and the rest is zeroed,
//!     which leaves the same bytes in the destination.
//!   - Two sign extensions of the C are not reproduced: fisrw's
//!     `c[Flba24] << 24` and idwwn's `gbit16(id + 110) << 16` are int
//!     expressions or'd into a uvlong, so a set top bit fills the upper
//!     32 bits with ones.  Here they are unsigned.
//!   - fisrw returns the sector count beside the lba instead of through
//!     an int pointer.

const std = @import("std");
const fmt = @import("fmt");

// ata errors
pub const Emed = 1 << 0; // media error
pub const Enm = 1 << 1; // no media
pub const Eabrt = 1 << 2; // abort
pub const Emcr = 1 << 3; // media change request
pub const Eidnf = 1 << 4; // no user-accessible address
pub const Emc = 1 << 5; // media change
pub const Eunc = 1 << 6; // data error
pub const Ewp = 1 << 6; // write protect
pub const Eicrc = 1 << 7; // interface crc error

pub const Efatal = Eidnf | Eicrc; // must sw reset

// ata status
pub const ASerr = 1 << 0; // error
pub const ASdrq = 1 << 3; // request
pub const ASdf = 1 << 5; // fault
pub const ASdrdy = 1 << 6; // ready
pub const ASbsy = 1 << 7; // busy

pub const ASobs = 1 << 1 | 1 << 2 | 1 << 4;

// fis types
pub const H2dev = 0x27;
pub const D2host = 0x34;

// fis flags bits
pub const Fiscmd = 0x80;

// ata bits
pub const Ataobs = 0xa0;
pub const Atalba = 0x40;

/// nominal fis size (fits any fis)
pub const Fissize = 0x20;

// sata device-to-host (0x27) fis layout
pub const Ftype = 0;
pub const Fflags = 1;
pub const Fcmd = 2;
pub const Ffeat = 3;
pub const Flba0 = 4;
pub const Flba8 = 5;
pub const Flba16 = 6;
pub const Fdev = 7;
pub const Flba24 = 8;
pub const Flba32 = 9;
pub const Flba40 = 10;
pub const Ffeat8 = 11;
pub const Fsc = 12;
pub const Fsc8 = 13;
pub const Ficc = 14; // isochronous cmd completion
pub const Fcontrol = 15;

// sata host-to-device fis (0x34) differences
pub const Fioport = 1;
pub const Fstatus = 2;
pub const Frerror = 3;

// ata protcol type
pub const Pnd = 0 << 0; // data direction
pub const Pin = 1 << 0;
pub const Pout = 2 << 0;
pub const Pdatam = 3 << 0;

pub const Ppio = 1 << 2; // ata protocol
pub const Pdma = 2 << 2;
pub const Pdmq = 3 << 2;
pub const Preset = 4 << 2;
pub const Pdiag = 5 << 2;
pub const Ppkt = 6 << 2;
pub const Pprotom = 7 << 2;

pub const P48 = 0 << 5; // command "size"
pub const P28 = 1 << 5;
pub const Pcmdszm = 1 << 5;

pub const Pssn = 0 << 6; // sector size
pub const P512 = 1 << 6;
pub const Pssm = 1 << 6;

pub const Sfis = struct {
    feat: u16 = 0,
    udma: u8 = 0,
    speeds: u8 = 0,
    sig: u32 = 0,
    lsectsz: u32 = 0,
    physshift: u32 = 0, // log2(log/phys)
    physalign: u32 = 0, // location of lba0 within phys0
    c: u32 = 0, // disgusting, no?
    h: u32 = 0,
    s: u32 = 0,
};

pub const Dlba = 1 << 0; // required for sata
pub const Dllba = 1 << 1;
pub const Dsmart = 1 << 2;
pub const Dpower = 1 << 3;
pub const Dnop = 1 << 4;
pub const Datapi = 1 << 5;
pub const Datapi16 = 1 << 6;
pub const Data8 = 1 << 7;
pub const Dsct = 1 << 8;
pub const Dnflag = 9;

pub const Pspinup = 1 << 0;
pub const Pidready = 1 << 1;

// scsi
pub const Cfis = struct {
    phyid: u8 = 0,
    encid: [8]u8 = @splat(0),
    tsasaddr: [8]u8 = @splat(0),
    ssasaddr: [8]u8 = @splat(0),
    ict: [2]u8 = @splat(0),
};

const flagname = [9][]const u8{
    "lba",
    "llba",
    "smart",
    "power",
    "nop",
    "atapi",
    "atapi16",
    "ata8",
    "sct",
};

// ata8 standard (llba) cmd layout
//
// feature      16 bits
// count        16 bits
// lba          48 bits
// device       8 bits
// command      8 bits
//
// response:
//
// status       8 bits
// error        8 bits
// reason       8 bits
// count        8 bits
// sstatus      8 bits
// sactive      8 bits

// sata fis layout for fistype 0x27: host-to-device:
//
// 0    fistype
// 1    fis flags
// 2    ata command
// 3    features
// 4    sector          lba low 7:0
// 5    cyl low         lba mid 15:8
// 6    cyl hi          lba hi  23:16
// 7    device / head
// 8    sec exp         lba     31:24
// 9    cy low e        lba     39:32
// 10   cy hi e         lba     48:40
// 11   features (exp)
// 12   sector count
// 13   sector count (exp)
// 14   r
// 15   control

pub fn setfissig(x: *Sfis, sig: u32) void {
    x.sig = sig;
}

pub fn skelfis(c: []u8) void {
    @memset(c[0..Fissize], 0);
    c[Ftype] = H2dev;
    c[Fflags] = Fiscmd;
    c[Fdev] = Ataobs;
}

pub fn nopfis(_: *const Sfis, c: []u8, srst: bool) u8 {
    skelfis(c);
    if (srst) {
        c[Fflags] &= ~@as(u8, Fiscmd);
        c[Fcontrol] = 1 << 2;
        return Preset | P28;
    }
    return Pnd | P28;
}

/// Returns null (the C's -1) for a device that takes no transfer mode.
pub fn txmodefis(f: *const Sfis, c: []u8, d_: u8) ?u8 {
    var d = d_;

    // hack
    if ((f.sig >> 16) == 0xeb14)
        return null;
    var m: u8 = 0x40;
    if (d == 0xff) {
        d = 0;
        m = 0;
    }
    skelfis(c);
    c[Fcmd] = 0xef;
    c[Ffeat] = 3; // set transfer mode
    c[Fsc] = m | d; // sector count
    return Pnd | P28;
}

pub fn featfis(_: *const Sfis, c: []u8, f: u8) u8 {
    skelfis(c);
    c[Fcmd] = 0xef;
    c[Ffeat] = f;
    return Pnd | P28;
}

pub fn identifyfis(f: *const Sfis, c: []u8) u8 {
    const tab = [_]u8{ 0xec, 0xa1 };

    skelfis(c);
    c[Fcmd] = tab[@intFromBool(f.sig >> 16 == 0xeb14)];
    return Pin | Ppio | P28 | P512;
}

pub fn flushcachefis(f: *const Sfis, c: []u8) u8 {
    const tab = [2]u8{ 0xe7, 0xea };
    const ptab = [2]u8{ Pnd | P28, Pnd | P48 };

    const llba = @intFromBool((f.feat & Dllba) != 0);
    skelfis(c);
    c[Fcmd] = tab[llba];
    return ptab[llba];
}

fn gbit16(id: []const u16, i: usize) u16 {
    return std.mem.littleToNative(u16, id[i]);
}

fn gbit32(id: []const u16, i: usize) u32 {
    return @as(u32, gbit16(id, i + 1)) << 16 | gbit16(id, i);
}

fn gbit64(id: []const u16, i: usize) u64 {
    return @as(u64, gbit32(id, i + 2)) << 32 | gbit32(id, i);
}

pub fn id16(id: []const u16, i: usize) u16 {
    return gbit16(id, i);
}

pub fn id32(id: []const u16, i: usize) u32 {
    return gbit32(id, i);
}

pub fn id64(id: []const u16, i: usize) u64 {
    return gbit64(id, i);
}

/// acs-2 §7.18.7.4
const puistab = [_]u16{
    0x37c8, Pspinup,
    0x738c, Pspinup | Pidready,
    0x8c73, 0,
    0xc837, Pidready,
};

pub fn idpuis(id: []const u16) u32 {
    const u = gbit16(id, 2);
    var i: usize = 0;
    while (i < puistab.len) : (i += 2) {
        if (u == puistab[i])
            return puistab[i + 1];
    }
    return Pidready; // annoying cdroms
}

fn onesc(id: []const u16, i: usize) u16 {
    var u = gbit16(id, i);
    if (u == 0xffff)
        u = 0;
    return u;
}

const Idmasp = 1 << 8;
const Ilbasp = 1 << 9;
const Illba = 1 << 10;

/// Fills in f from the identify data and returns the number of
/// sectors.
pub fn idfeat(f: *Sfis, id: []const u16) i64 {
    var s: i64 = undefined;

    f.feat = 0;
    if (f.sig >> 16 == 0xeb14)
        f.feat |= Datapi;
    var i: u32 = gbit16(id, 49);
    if ((i & Ilbasp) == 0) {
        if ((gbit16(id, 53) & 1) == 0) {
            f.c = gbit16(id, 1);
            f.h = gbit16(id, 3);
            f.s = gbit16(id, 6);
        } else {
            f.c = gbit16(id, 54);
            f.h = gbit16(id, 55);
            f.s = gbit16(id, 56);
        }
        s = f.c *% f.h *% f.s;
    } else {
        f.c = 0;
        f.h = 0;
        f.s = 0;
        f.feat |= Dlba;
        const j = gbit16(id, 83) | gbit16(id, 86);
        if (j & Illba != 0) {
            f.feat |= Dllba;
            s = @bitCast(gbit64(id, 100));
        } else {
            s = gbit32(id, 60);
        }
    }
    f.udma = 0xff;
    if (i & Idmasp != 0 and gbit16(id, 53) & 4 != 0) {
        i = gbit16(id, 88) & 0x7f;
        while (i != 0) : (i >>= 1)
            f.udma +%= 1;
    }

    if (f.feat & Datapi != 0) {
        i = gbit16(id, 0);
        if (i & 1 != 0)
            f.feat |= Datapi16;
    }

    i = gbit16(id, 83);
    if ((i >> 14) == 1) {
        if (i & (1 << 3) != 0)
            f.feat |= Dpower;
        i = gbit16(id, 82);
        if (i & 1 != 0)
            f.feat |= Dsmart;
        if (i & (1 << 14) != 0)
            f.feat |= Dnop;
    }
    i = onesc(id, 80);
    if (i & 1 << 8 != 0) {
        f.feat |= Data8;
        i = onesc(id, 222); // sata?
        var j = onesc(id, 76);
        if (i != 0 and i >> 12 == 1 and j != 0) {
            j >>= 1;
            f.speeds = @truncate(j & 7);
            // not acceptable for comreset to
            // wipe out device configuration.
            // reject drive.
            //      i = gbit16(id + 78) & gbit16(id + 79);
            //      if((i & 1<<6) == 0)
            //              return -1;
        }
    }
    if (gbit16(id, 206) & 1 != 0)
        f.feat |= Dsct;
    _ = idss(f, id);
    return s;
}

/// Fills in the sector sizes of f and returns the logical one.
pub fn idss(f: *Sfis, id: []const u16) u32 {
    if (f.sig >> 16 == 0xeb14)
        return 0;
    f.lsectsz = 512;
    f.physshift = 0;
    f.physalign = 0;
    const i: u32 = gbit16(id, 106);
    if (i >> 14 != 1)
        return f.lsectsz;
    if (i & (1 << 12) != 0) {
        const sw = gbit32(id, 117);
        if (sw >= 256)
            f.lsectsz = sw *% 2;
    }
    if (i & 1 << 13 != 0) {
        f.physshift = i & 7;
        const pa = gbit16(id, 209);
        if (pa & 0x4000 != 0)
            f.physalign = pa & 0x3fff;
    }
    return f.lsectsz;
}

pub fn idwwn(_: *const Sfis, id: []const u16) u64 {
    var u: u64 = 0;
    if (id[108] >> 12 == 5) {
        u |= @as(u64, gbit16(id, 108)) << 48;
        u |= @as(u64, gbit16(id, 109)) << 32;
        u |= @as(u64, gbit16(id, 110)) << 16; // DIFF: not sign-extended
        u |= @as(u64, gbit16(id, 111)) << 0;
    }
    return u;
}

/// Copy the n bytes (n even) of an identify string at u into p,
/// swapping each pair, and strip the blanks at both ends.  p gets a
/// NUL-terminated string and must hold n+1 bytes.
pub fn idmove(p: []u8, u: []const u16, n: usize) void {
    const s = std.mem.sliceAsBytes(u);
    var i: usize = 0;
    while (i < n) : (i += 2) {
        p[i] = s[i + 1];
        p[i + 1] = s[i + 0];
    }
    p[n] = 0;
    var e: usize = n;
    while (e > 0) {
        e -= 1;
        if (p[e] != ' ')
            break;
        p[e] = 0;
    }
    var b: usize = 0;
    while (p[b] == ' ')
        b += 1;
    // DIFF: see the top of the file
    if (b > 0) {
        const len = e + 1 - b;
        std.mem.copyForwards(u8, p[0..len], p[b .. e + 1]);
        @memset(p[len .. n + 1], 0);
    }
}

/// Writes the names of f's features and a newline at the start of buf
/// and returns the number of bytes.
pub fn pflag(buf: []u8, f: *const Sfis) usize {
    var s: fmt.Fmt = .{ .buf = buf };
    const u = f.feat;
    var i: u4 = 0;
    while (i < Dnflag) : (i += 1) {
        if (u & (@as(u16, 1) << i) != 0)
            fmt.fmtprint(&s, "%s ", .{flagname[i]});
    }
    fmt.fmtprint(&s, "\n", .{});
    return s.n;
}

/// c is the start of the command table: the packet goes at c + 0x40.
pub fn atapirwfis(f: *const Sfis, c: []u8, cdb: []const u8, ndata: u32) u8 {
    const fill: usize = if (f.feat & Datapi16 != 0) 16 else 12;
    var len = cdb.len;
    if (len > fill)
        len = fill;
    @memcpy(c[0x40..][0..len], cdb[0..len]);
    @memset(c[0x40 + len .. 0x40 + fill], 0);

    c[Ftype] = H2dev;
    c[Fflags] = Fiscmd;
    c[Fcmd] = Ataobs;
    if (ndata != 0)
        c[Ffeat] = 1 // dma
    else
        c[Ffeat] = 0; // features (exp);
    c[Flba0] = 0;
    c[Flba8] = @truncate(ndata);
    c[Flba16] = @truncate(ndata >> 8);
    c[Fdev] = Ataobs;
    @memset(c[8..Fissize], 0);
    return P28 | Ppkt;
}

pub fn rwfis(f: *const Sfis, c: []u8, rw: bool, nsect: u32, lba: u64) u8 {
    const tab = [2][2][2]u8{
        .{ .{ 0x20, 0x24 }, .{ 0x30, 0x34 } },
        .{ .{ 0xc8, 0x25 }, .{ 0xca, 0x35 } },
    };
    const ptab = [2][2][2]u8{
        .{ .{ Pin | Ppio | P28, Pin | Ppio | P48 }, .{ Pout | Ppio | P28, Pout | Ppio | P48 } },
        .{ .{ Pin | Pdma | P28, Pin | Pdma | P48 }, .{ Pout | Pdma | P28, Pout | Pdma | P48 } },
    };

    const udma = @intFromBool(f.udma != 0xff);
    const llba = @intFromBool((f.feat & Dllba) != 0);
    const acmd = tab[udma][@intFromBool(rw)][llba];

    c[Ftype] = 0x27;
    c[Fflags] = 0x80;
    c[Fcmd] = acmd;
    c[Ffeat] = 0;

    c[Flba0] = @truncate(lba);
    c[Flba8] = @truncate(lba >> 8);
    c[Flba16] = @truncate(lba >> 16);
    c[Fdev] = Ataobs | Atalba;
    if (llba == 0)
        c[Fdev] |= @as(u8, @truncate(lba >> 24)) & 0xf;

    c[Flba24] = @truncate(lba >> 24);
    c[Flba32] = @truncate(lba >> 32);
    c[Flba40] = @truncate(lba >> 40);
    c[Ffeat8] = 0;

    c[Fsc] = @truncate(nsect);
    c[Fsc8] = @truncate(nsect >> 8);
    c[Ficc] = 0;
    c[Fcontrol] = 0;

    @memset(c[16..Fissize], 0);
    return ptab[udma][@intFromBool(rw)][llba];
}

/// The lba and sector count of the read or write fis c.
pub fn fisrw(_: *const Sfis, c: []const u8) struct { lba: u64, n: u32 } {
    var lba: u64 = c[Flba0];
    lba |= @as(u64, c[Flba8]) << 8;
    lba |= @as(u64, c[Flba16]) << 16;
    lba |= @as(u64, c[Flba24]) << 24; // DIFF: not sign-extended
    lba |= @as(u64, c[Flba32] | @as(u32, c[Flba40]) << 8) << 32;

    var n: u32 = c[Fsc];
    n |= @as(u32, c[Fsc8]) << 8;

    return .{ .lba = lba, .n = n };
}

pub fn sigtofis(f: *const Sfis, c: []u8) void {
    const u = f.sig;
    @memset(c[0..Fissize], 0);
    c[Ftype] = 0x34;
    c[Fflags] = 0x00;
    c[Fcmd] = 0x50;
    c[Ffeat] = 0x01;
    c[Flba0] = @truncate(u >> 8);
    c[Flba8] = @truncate(u >> 16);
    c[Flba16] = @truncate(u >> 24);
    c[Fdev] = Ataobs;
    c[Fsc] = @truncate(u);
}

pub fn fistosig(u: []const u8) u32 {
    return u[Fsc] | @as(u32, u[Flba0]) << 8 | @as(u32, u[Flba8]) << 16 | @as(u32, u[Flba16]) << 24;
}

// sas smp
pub fn smpskelframe(f: *const Cfis, c: []u8, m: u8) void {
    @memset(c[0..Fissize], 0);
    c[Ftype] = 0x40;
    c[Fflags] = m;
    if (f.phyid != 0)
        c[Flba32] = f.phyid;
}

pub fn sashash(u: u64) u32 {
    var r: u32 = 0;
    const poly: u32 = 0x01db2777;
    const msb: u32 = 0x01000000;
    var m: u64 = 1 << 63;
    while (m > 0) : (m >>= 1) {
        var l: u32 = 0;
        if (m & u != 0)
            l = msb;
        r <<= 1;
        r ^= l;
        if (r & msb != 0)
            r ^= poly;
    }
    return r & 0xffffff;
}

/// Hashes the 8 bytes at s into the 3 at t and returns t.
pub fn sasbhash(t: []u8, s: []const u8) []u8 {
    var r: u32 = 0;
    const poly: u32 = 0x01db2777;
    const msb: u32 = 0x01000000;
    for (s[0..8]) |b| {
        var j: u8 = 0x80;
        while (j != 0) : (j >>= 1) {
            var l: u32 = 0;
            if (b & j != 0)
                l = msb;
            r <<= 1;
            r ^= l;
            if (r & msb != 0)
                r ^= poly;
        }
    }
    t[0] = @truncate(r >> 16);
    t[1] = @truncate(r >> 8);
    t[2] = @truncate(r);
    return t;
}
