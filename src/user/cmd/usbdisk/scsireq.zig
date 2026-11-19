//! SCSI requests, as nusb/disk has them from scuzz: the commands a
//! disk is asked, each sent through umsrequest.
//! from nusb/disk/scsireq.c and scsireq.h
//!
//! DIFF:
//!   - Only what nusb/disk uses is here.  Left out: the requests on a
//!     file (request, SRopenraw, SRopen, SRclose, and dirdevopen,
//!     seqdevopen and wormdevopen under them), so SRrequest is always
//!     umsrequest and Fusb says nothing; and the commands the disk
//!     server does not send (SRrewind, SRformat, SRrblimits, SRseek,
//!     SRfilemark, SRspace, the mode selects and senses, and the CD
//!     and changer commands the header names).
//!   - A ScsiPtr's p is a slice with room for count bytes at least.
//!   - The functions return the C's long: the count, or -1 with the
//!     error string set.
//!   - A ScsiReq is a field of the Umsc (req), which the C puts at
//!     its start without a name.
//!
//! Kept from C: SRwrite, on a check condition with nothing but "end
//! of medium" in the third byte of the sense data, takes the count
//! left from -1 and so returns more than was to be written; the
//! server then says all of it was.  That is tape's code, and no disk
//! here gives that sense data.

const std = @import("std");
const libc = @import("libc");
const disk = @import("../usbdisk.zig");
const scsierrmsg = @import("scsierrs.zig").scsierrmsg;

const Umsc = disk.Umsc;

// fundamental constants/defaults
pub const MaxDirData = 255; // max. direct data returned
pub const Maxiosize = libc.IOUNIT; // max. I/O transfer size

pub const ScsiPtr = struct {
    p: []u8 = &.{},
    count: i32 = 0,
    write: bool = false,
};

pub const ScsiReq = struct {
    flags: u32 = 0,
    unit: ?[]const u8 = null, // unit directory
    lun: u8 = 0,
    lbsize: u32 = 0,
    offset: u64 = 0, // in blocks of lbsize bytes
    fd: i32 = -1,
    umsc: ?*Umsc = null, // lun
    cmd: ScsiPtr = .{},
    data: ScsiPtr = .{},
    status: i32 = 0, // returned status
    sense: [MaxDirData]u8 = @splat(0), // returned sense data
    inquiry: [MaxDirData]u8 = @splat(0), // returned inquiry data
    readblock: i32 = 0, // flag: read a block since open
};

// software flags
pub const Fopen = 0x0001; // open
pub const Fseqdev = 0x0002; // sequential-access device
pub const Fwritten = 0x0004; // device written
pub const Fronly = 0x0008; // device is read-only
pub const Fwormdev = 0x0010; // write-once read-multiple device
pub const Fprintdev = 0x0020; // printer
pub const Fbfixed = 0x0040; // fixed block size
pub const Fchanger = 0x0080; // medium-changer device
pub const Finqok = 0x0100; // inquiry data is OK
pub const Fmode6 = 0x0200; // use 6-byte modeselect
pub const Frw10 = 0x0400; // use 10-byte read/write
pub const Fusb = 0x0800; // USB transparent scsi

pub const STnomem = -4; // buffer allocation failed
pub const STharderr = -3; // controller error of some kind
pub const STtimeout = -2; // bus timeout
pub const STok = 0; // good
pub const STcheck = 0x02; // check condition
pub const STcondmet = 0x04; // condition met/good
pub const STbusy = 0x08; // busy
pub const STintok = 0x10; // intermediate/good
pub const STintcondmet = 0x14; // intermediate/condition met/good
pub const STresconf = 0x18; // reservation conflict
pub const STterminated = 0x22; // command terminated
pub const STqfull = 0x28; // queue full

// status
pub const Status_SD = 0x80; // sense-data available
pub const Status_SW = 0x83; // internal software error
pub const Status_BADARG = 0x84; // bad argument to request
pub const Status_RO = 0x85; // device is read-only

// SCSI command codes (those with a name in scmdnames, or sent)
pub const ScmdTur = 0x00; // test unit ready
pub const ScmdRewind = 0x01; // rezero/rewind
pub const ScmdRsense = 0x03; // request sense
pub const ScmdFormat = 0x04; // format unit
pub const ScmdRblimits = 0x05; // read block limits
pub const ScmdRead = 0x08; // read
pub const ScmdWrite = 0x0A; // write
pub const ScmdSeek = 0x0B; // seek
pub const ScmdFmark = 0x10; // write filemarks
pub const ScmdSpace = 0x11; // space forward/backward
pub const ScmdInq = 0x12; // inquiry
pub const ScmdMselect6 = 0x15; // mode select
pub const ScmdMselect10 = 0x55; // mode select
pub const ScmdMsense6 = 0x1A; // mode sense
pub const ScmdMsense10 = 0x5A; // mode sense
pub const ScmdStart = 0x1B; // start/stop unit
pub const ScmdRcapacity = 0x25; // read capacity
pub const ScmdRcapacity16 = 0x9e; // long read capacity
pub const ScmdRead16 = 0x88; // long read
pub const ScmdWrite16 = 0x8A; // long write
pub const ScmdSeek16 = 0x9E; // long seek
pub const ScmdExtread = 0x28; // extended read
pub const ScmdExtwrite = 0x2A; // extended write
pub const ScmdExtseek = 0x2B; // extended seek

pub const ScmdSynccache = 0x35; // flush cache
pub const ScmdRTOC = 0x43; // read TOC data
pub const ScmdRdiscinfo = 0x51; // read disc information
pub const ScmdRtrackinfo = 0x52; // read track information
pub const ScmdReserve = 0x53; // reserve track
pub const ScmdBlank = 0xA1; // blank *-RW media

pub const ScmdCDpause = 0x4B; // pause/resume
pub const ScmdCDstop = 0x4E; // stop play/scan
pub const ScmdCDplay = 0xA5; // play audio
pub const ScmdCDload = 0xA6; // load/unload
pub const ScmdCDscan = 0xBA; // fast forward/reverse
pub const ScmdCDstatus = 0xBD; // mechanism status
pub const Scmdgetconf = 0x46; // get configuration

// sense data byte 0
pub const Sd0valid = 0x80; // valid sense data present

// sense data byte 2
// incorrect-length indicator, difference in bytes 3—6
pub const Sd2ili = 0x20;
pub const Sd2eom = 0x40; // end of medium (tape)
pub const Sd2filemark = 0x80; // at a filemark (tape)

// command byte 1
pub const Cmd1fixed = 1; // use fixed-length blocks
pub const Cmd1sili = 2; // don't set Sd2ili

// limit of block #s in 24-bit ccbs
pub const Max24off = (1 << 21) - 1; // 2²¹ - 1

// mode pages
pub const Allmodepages = 0x3F;

// scsi device types, from the scsi standards
pub const Devdir = 0; // usually disk
pub const Devseq = 1; // usually tape
pub const Devprint = 2;
pub const Dev3 = 3;
pub const Devworm = 4; // also direct, but special
pub const Devcd = 5; // also direct
pub const Dev6 = 6;
pub const Devmo = 7; // also direct
pub const Devjuke = 8;

pub fn GETBELONG(p: []const u8) u32 {
    return @as(u32, p[0]) << 24 | @as(u32, p[1]) << 16 | @as(u32, p[2]) << 8 | p[3];
}

pub fn PUTBELONG(p: []u8, ul: u32) void {
    p[0] = @truncate(ul >> 24);
    p[1] = @truncate(ul >> 16);
    p[2] = @truncate(ul >> 8);
    p[3] = @truncate(ul);
}

pub fn GETBE24(p: []const u8) u32 {
    return @as(u32, p[0]) << 16 | @as(u32, p[1]) << 8 | p[2];
}

pub fn PUTBE24(p: []u8, ul: u32) void {
    p[0] = @truncate(ul >> 16);
    p[1] = @truncate(ul >> 8);
    p[2] = @truncate(ul);
}

const Debug = 0;

/// exabyte tape drives, at least old ones like the 8200 and 8505,
/// are dumb: you have to read the exact block size on the tape,
/// they don't take 10-byte SCSI commands, and various other fine points.
/// (Nothing sets either here, as nothing does in nusb/disk.)
pub var exabyte: bool = false;
pub var force6bytecmds: bool = false;

var debug: i32 = Debug;

fn scmdname(c: u8) ?[]const u8 {
    return switch (c) {
        ScmdTur => "Tur",
        ScmdRewind => "Rewind",
        ScmdRsense => "Rsense",
        ScmdFormat => "Format",
        ScmdRblimits => "Rblimits",
        ScmdRead => "Read",
        ScmdWrite => "Write",
        ScmdSeek => "Seek",
        ScmdFmark => "Fmark",
        ScmdSpace => "Space",
        ScmdInq => "Inq",
        ScmdMselect6 => "Mselect6",
        ScmdMselect10 => "Mselect10",
        ScmdMsense6 => "Msense6",
        ScmdMsense10 => "Msense10",
        ScmdStart => "Start",
        ScmdRcapacity => "Rcapacity",
        ScmdRcapacity16 => "Rcap16",
        ScmdExtread => "Extread",
        ScmdExtwrite => "Extwrite",
        ScmdExtseek => "Extseek",

        ScmdSynccache => "Synccache",
        ScmdRTOC => "RTOC",
        ScmdRdiscinfo => "Rdiscinfo",
        ScmdRtrackinfo => "Rtrackinfo",
        ScmdReserve => "Reserve",
        ScmdBlank => "Blank",

        ScmdCDpause => "CDpause",
        ScmdCDstop => "CDstop",
        ScmdCDplay => "CDplay",
        ScmdCDload => "CDload",
        ScmdCDscan => "CDscan",
        ScmdCDstatus => "CDstatus",
        Scmdgetconf => "getconf",
        else => null,
    };
}

pub fn SRready(rp: *ScsiReq) i32 {
    var cmd: [6]u8 = @splat(0);

    rp.cmd.p = &cmd;
    rp.cmd.count = cmd.len;
    rp.data.p = &cmd;
    rp.data.count = 0;
    rp.data.write = true;
    return SRrequest(rp);
}

pub fn SRreqsense(rp: *ScsiReq) i32 {
    var cmd: [6]u8 = @splat(0);
    var req: ScsiReq = .{};

    if (rp.status == Status_SD) {
        rp.status = STok;
        return 0;
    }
    cmd[0] = ScmdRsense;
    cmd[4] = req.sense.len;
    if (rp.flags & Fusb != 0)
        req.flags |= Fusb;
    req.lun = rp.lun;
    req.unit = rp.unit;
    req.fd = rp.fd;
    req.umsc = rp.umsc;
    req.cmd.p = &cmd;
    req.cmd.count = cmd.len;
    req.data.p = &rp.sense;
    req.data.count = rp.sense.len;
    req.data.write = false;
    const status = SRrequest(&req);
    rp.status = req.status;
    if (status != -1)
        rp.sense[0] |= Sd0valid;
    return status;
}

fn dirdevrw(rp: *ScsiReq, cmd: *[16]u8, nbytes: i32) i32 {
    const n: u32 = @as(u32, @bitCast(nbytes)) / rp.lbsize;
    if (rp.offset <= Max24off and n <= 256 and (rp.flags & Frw10) == 0) {
        PUTBE24(cmd[1..], @truncate(rp.offset));
        cmd[4] = @truncate(n);
        cmd[5] = 0;
        return 6;
    }
    if (rp.offset > 0xFFFFFFFF) {
        cmd[0] |= ScmdRead16;
        cmd[1] = 0;
        cmd[2] = @truncate(rp.offset >> 56);
        cmd[3] = @truncate(rp.offset >> 48);
        cmd[4] = @truncate(rp.offset >> 40);
        cmd[5] = @truncate(rp.offset >> 32);
        cmd[6] = @truncate(rp.offset >> 24);
        cmd[7] = @truncate(rp.offset >> 16);
        cmd[8] = @truncate(rp.offset >> 8);
        cmd[9] = @truncate(rp.offset);
        cmd[10] = @truncate(n >> 24);
        cmd[11] = @truncate(n >> 16);
        cmd[12] = @truncate(n >> 8);
        cmd[13] = @truncate(n);
        cmd[14] = 0;
        cmd[15] = 0;
        return 16;
    }
    cmd[0] |= ScmdExtread;
    cmd[1] = 0;
    PUTBELONG(cmd[2..], @truncate(rp.offset));
    cmd[6] = 0;
    cmd[7] = @truncate(n >> 8);
    cmd[8] = @truncate(n);
    cmd[9] = 0;
    return 10;
}

fn seqdevrw(rp: *ScsiReq, cmd: *[16]u8, nbytes: i32) i32 {
    // don't set Cmd1sili; we want the ILI bit instead of a fatal error
    cmd[1] = if (rp.flags & Fbfixed != 0) Cmd1fixed else 0;
    const n: u32 = @as(u32, @bitCast(nbytes)) / rp.lbsize;
    PUTBE24(cmd[2..], n);
    cmd[5] = 0;
    return 6;
}

fn badsize(rp: *ScsiReq, nbytes: i32) bool {
    if (rp.lbsize == 0 or nbytes < 0 or (@as(u32, @bitCast(nbytes)) % rp.lbsize) != 0 or nbytes > Maxiosize) {
        if (disk.diskdebug != 0) {
            if (rp.lbsize != 0 and @as(u32, @bitCast(nbytes)) % rp.lbsize != 0)
                libc.fprint(2, "%s: i/o size %d %% %d != 0\n", .{ libc.argv0, nbytes, rp.lbsize })
            else
                libc.fprint(2, "%s: i/o size %d > %d\n", .{ libc.argv0, nbytes, @as(i32, Maxiosize) });
        }
        rp.status = Status_BADARG;
        return true;
    }
    return false;
}

/// buf has room for nbytes.
pub fn SRread(rp: *ScsiReq, buf: []u8, nbytes: i32) i32 {
    var cmd: [16]u8 = undefined;

    // DIFF: a count below 0 is a bad argument too (the C takes its
    // remainder), and the message for a block size of 0 is the other
    // one, where the C divides by it
    if (badsize(rp, nbytes))
        return -1;

    // set up scsi read cmd
    cmd[0] = ScmdRead;
    if (rp.flags & Fseqdev != 0)
        rp.cmd.count = seqdevrw(rp, &cmd, nbytes)
    else
        rp.cmd.count = dirdevrw(rp, &cmd, nbytes);
    rp.cmd.p = &cmd;
    rp.data.p = buf;
    rp.data.count = nbytes;
    rp.data.write = false;

    // issue it
    var n = SRrequest(rp);
    if (n != -1) { // it worked?
        rp.offset += @as(u32, @bitCast(n)) / rp.lbsize;
        return n;
    }

    // request failed; maybe we just read a short record?
    if (exabyte) {
        libc.fprint(2, "read error\n", .{});
        rp.status = STcheck;
        return n;
    }
    if (rp.status != Status_SD or (rp.sense[0] & Sd0valid) == 0)
        return -1;
    // compute # of bytes not read
    n = @bitCast(GETBELONG(rp.sense[3..]) *% rp.lbsize);
    if (rp.flags & Fseqdev == 0)
        return -1;

    // device is a tape or something similar
    if (rp.sense[2] == Sd2filemark or rp.sense[2] == 0x08 or
        rp.sense[2] & Sd2ili != 0 and n > 0)
        rp.data.count = nbytes -% n
    else
        return -1;
    n = rp.data.count;
    if (rp.readblock == 0 or debug != 0)
        libc.fprint(2, "SRread: tape data count %d%s\n", .{ n, if (rp.sense[2] & Sd2ili != 0) " with ILI" else "" });
    rp.readblock += 1;
    rp.status = STok;
    rp.offset += @as(u32, @bitCast(n)) / rp.lbsize;
    return n;
}

/// buf has nbytes to write.
pub fn SRwrite(rp: *ScsiReq, buf: []u8, nbytes: i32) i32 {
    var cmd: [16]u8 = undefined;

    if (badsize(rp, nbytes))
        return -1;

    // set up scsi write cmd
    cmd[0] = ScmdWrite;
    if (rp.flags & Fseqdev != 0)
        rp.cmd.count = seqdevrw(rp, &cmd, nbytes)
    else
        rp.cmd.count = dirdevrw(rp, &cmd, nbytes);
    rp.cmd.p = &cmd;
    rp.data.p = buf;
    rp.data.count = nbytes;
    rp.data.write = true;

    // issue it
    var n = SRrequest(rp);
    if (n == -1) {
        if (exabyte) {
            libc.fprint(2, "write error\n", .{});
            rp.status = STcheck;
            return n;
        }
        if (rp.status != Status_SD or rp.sense[2] != Sd2eom)
            return -1;
        if (rp.sense[0] & Sd0valid != 0) {
            // Kept from C: see the top of the file
            n -%= @bitCast(GETBELONG(rp.sense[3..]) *% rp.lbsize);
            rp.data.count = nbytes -% n;
        } else rp.data.count = nbytes;
        n = rp.data.count;
    }
    rp.offset += @as(u32, @bitCast(n)) / rp.lbsize;
    return n;
}

pub fn SRinquiry(rp: *ScsiReq) i32 {
    var cmd: [6]u8 = @splat(0);

    cmd[0] = ScmdInq;
    cmd[4] = 36;
    rp.cmd.p = &cmd;
    rp.cmd.count = cmd.len;
    @memset(&rp.inquiry, 0);
    rp.data.p = &rp.inquiry;
    rp.data.count = 36;
    rp.data.write = false;
    if (SRrequest(rp) >= 0) {
        rp.flags |= Finqok;
        return 0;
    }
    rp.flags &= ~@as(u32, Finqok);
    return -1;
}

pub fn SRstart(rp: *ScsiReq, code: u8) i32 {
    var cmd: [6]u8 = @splat(0);

    cmd[0] = ScmdStart;
    cmd[4] = code;
    rp.cmd.p = &cmd;
    rp.cmd.count = cmd.len;
    rp.data.p = &cmd;
    rp.data.count = 0;
    rp.data.write = true;
    return SRrequest(rp);
}

/// data has room for 8 bytes.
pub fn SRrcapacity(rp: *ScsiReq, data: []u8) i32 {
    var cmd: [10]u8 = @splat(0);

    cmd[0] = ScmdRcapacity;
    rp.cmd.p = &cmd;
    rp.cmd.count = cmd.len;
    rp.data.p = data;
    rp.data.count = 8;
    rp.data.write = false;
    return SRrequest(rp);
}

/// data has room for 32 bytes.
pub fn SRrcapacity16(rp: *ScsiReq, data: []u8) i32 {
    var cmd: [16]u8 = @splat(0);

    const i: u32 = 32;
    cmd[0] = ScmdRcapacity16;
    cmd[1] = 0x10;
    cmd[10] = @truncate(i >> 24);
    cmd[11] = @truncate(i >> 16);
    cmd[12] = @truncate(i >> 8);
    cmd[13] = @truncate(i);

    rp.cmd.p = &cmd;
    rp.cmd.count = cmd.len;
    rp.data.p = data;
    rp.data.count = @intCast(i);
    rp.data.write = false;
    return SRrequest(rp);
}

pub fn scsidebug(d: i32) void {
    debug = d;
    if (debug != 0)
        libc.fprint(2, "scsidebug on\n", .{});
}

fn seprintcmd(f: *libc.fmt.Fmt, cmd: []const u8, count: i32, args: bool) void {
    if (count < 6) {
        f.print("<short cmd>", .{});
        return;
    }
    const c = cmd[0];
    if (scmdname(c)) |s|
        f.print("%s", .{s})
    else
        f.print("cmd:%#02uX", .{c});
    if (args) switch (c) {
        ScmdRsense, ScmdInq, ScmdMselect6, ScmdMsense6 => f.print(" sz %d", .{cmd[4]}),
        ScmdSpace => f.print(" code %d", .{cmd[1]}),
        ScmdStart => f.print(" code %d", .{cmd[4]}),
        else => {},
    };
}

fn seprintdata(f: *libc.fmt.Fmt, p: []const u8, count: i32) void {
    if (count <= 0)
        return;
    var i: usize = 0;
    while (i < 20 and i < count and i < p.len) : (i += 1)
        f.print(" %02x", .{p[i]});
}

fn SRdumpReq(rp: *ScsiReq) void {
    var buf: [128]u8 = undefined;
    var f: libc.fmt.Fmt = .{ .buf = buf[0 .. buf.len - 1] };

    f.print("lun %d ", .{rp.lun});
    seprintcmd(&f, rp.cmd.p, rp.cmd.count, true);
    f.print(" [%d]", .{rp.data.count});
    if (rp.cmd.write)
        seprintdata(&f, rp.data.p, rp.data.count);
    libc.fprint(2, "scsi⇒ %s\n", .{buf[0..f.n]});
}

fn SRdumpRep(rp: *ScsiReq) void {
    var buf: [128]u8 = undefined;
    var f: libc.fmt.Fmt = .{ .buf = buf[0 .. buf.len - 1] };

    f.print("lun %d ", .{rp.lun});
    seprintcmd(&f, rp.cmd.p, rp.cmd.count, false);
    switch (rp.status) {
        STok => {
            f.print(" good [%d] ", .{rp.data.count});
            if (!rp.cmd.write)
                seprintdata(&f, rp.data.p, rp.data.count);
        },
        STnomem => f.print(" buffer allocation failed", .{}),
        STharderr => f.print(" controller error", .{}),
        STtimeout => f.print(" bus timeout", .{}),
        STcheck => f.print(" check condition", .{}),
        STcondmet => f.print(" condition met/good", .{}),
        STbusy => f.print(" busy", .{}),
        STintok => f.print(" intermediate/good", .{}),
        STintcondmet => f.print(" intermediate/condition met/good", .{}),
        STresconf => f.print(" reservation conflict", .{}),
        STterminated => f.print(" command terminated", .{}),
        STqfull => f.print(" queue full", .{}),
        else => f.print(" sts=%#x", .{rp.status}),
    }
    libc.fprint(2, "scsi← %s\n", .{buf[0..f.n]});
}

fn scsierr(rp: *ScsiReq) []const u8 {
    switch (rp.status) {
        0 => return "",
        Status_SD => {
            const ec = (@as(u32, rp.sense[12]) << 8) | rp.sense[13];
            return scsierrmsg(ec);
        },
        Status_SW => return "software error",
        Status_BADARG => return "bad argument",
        Status_RO => return "device is read only",
        else => return "unknown",
    }
}

fn SRdumpErr(rp: *ScsiReq) void {
    var buf: [128]u8 = undefined;
    var f: libc.fmt.Fmt = .{ .buf = buf[0 .. buf.len - 1] };

    seprintcmd(&f, rp.cmd.p, rp.cmd.count, false);
    libc.print("\t%s status: %s\n", .{ buf[0..f.n], scsierr(rp) });
}

pub fn SRrequest(rp: *ScsiReq) i32 {
    var status: i32 = undefined;
    var n: i32 = undefined;

    while (true) {
        if (debug != 0)
            SRdumpReq(rp);
        n = disk.umsrequest(rp.umsc.?, &rp.cmd, &rp.data, &status);
        rp.status = status;
        if (status == STok)
            rp.data.count = n;
        if (debug != 0)
            SRdumpRep(rp);
        switch (status) {
            STok => break,
            STcheck => {
                if (rp.cmd.p[0] != ScmdRsense and SRreqsense(rp) != -1)
                    rp.status = Status_SD;
                if (debug != 0 or exabyte)
                    SRdumpErr(rp);
                libc.werrstr("%s", .{scsierr(rp)});
                return -1;
            },
            STbusy => {
                libc.sleep(1000) catch {}; // TODO: try a shorter sleep?
                continue;
            },
            else => {
                if (debug != 0 or exabyte)
                    SRdumpErr(rp);
                libc.werrstr("%s", .{scsierr(rp)});
                return -1;
            },
        }
    }
    return n;
}
