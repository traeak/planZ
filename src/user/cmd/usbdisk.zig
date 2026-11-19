//! nusb/disk - usb mass storage file server
//!
//! supports only the scsi command interface, not ata.
//! from /sys/src/cmd/nusb/disk/disk.c and ums.h (scsireq.c and the
//! error texts are in usbdisk/)
//!
//! usage: disk [-dD] devid
//!
//! Fixed from C, read and not shown:
//!   - A status wrapper with a residue below 0 or over the count asked
//!     for gave a count past the data, which went on into the answer
//!     to the read.  Such a residue is taken as the C takes one of 0:
//!     what was not transferred.
//!   - A block size that is not a power of two failed an assert in
//!     setup, and the server was gone.  It is an error to the reader.
//!   - A device with no configuration made findendpoints read through
//!     a nil pointer.
//!   - A write of nothing to ctl read the byte before the message.
//!
//! Kept from C, shown by the test where it can be:
//!   - The qid of a stat has the partition's number alone, and a
//!     directory entry's has the lun's number where a walk's has that
//!     plus one.
//!   - A lun's directory stats under the name "/".
//!   - A read or write at the end of a partition, or of nothing, is
//!     an error (with whatever the error string holds), not a count of
//!     0.
//!   - iounit is set for raw, data and the first partition made, not
//!     for those after it.
//!
//! DIFF:
//!   - A Umsc's ScsiReq and QLock are the fields req and lk.
//!   - The command and status wrappers are made and read as bytes; the
//!     C writes and reads the structures.
//!   - -D is taken and prints nothing (lib9p's chatty9p).

const std = @import("std");
const libc = @import("libc");
const p9 = @import("9p");
const usb = @import("usb");
const scsi = @import("usbdisk/scsireq.zig");
const sys = libc.sys;
const fcall = libc.fcall;

const Dev = usb.Dev;
const Ep = usb.Ep;
const Iface = usb.Iface;
const Req = p9.Req;
const Fid = p9.Fid;
const Dir = p9.Dir;
const Qid = p9.Qid;
const ScsiReq = scsi.ScsiReq;
const ScsiPtr = scsi.ScsiPtr;
const Maxiosize = scsi.Maxiosize;
const respond = p9.respond;
const responderror = p9.responderror;
const dprint = usb.dprint;
const usbcmd = usb.usbcmd;
const devctl = usb.devctl;

// mass storage transport protocols and subclasses,
// from usb mass storage class specification overview rev 1.2
// (ums.h)

const Protocbi = 0; // control/bulk/interrupt; mainly floppies
const Protocb = 1; //   "  with no interrupt; mainly floppies
const Protobulk = 0x50; // bulk only
const Protouas = 0x62; // USB-attached SCSI

const Subrbc = 1; // reduced blk cmds
const Subatapi = 2; // cd/dvd using sff-8020i or mmc-2 cmd blks
const Subqic = 3; // QIC-157 tapes
const Subufi = 4; // floppy
const Sub8070 = 5; // removable media, atapi-like
const Subscsi = 6; // scsi transparent cmd set
const Subisd200 = 7; // ISD200 ATA
const Subdev = 0xff; // use device's value

const Umsreset = 0xFF;
const Getmaxlun = 0xFE;

const Maxlun = 32;

const CMreset = 1;

const Pcmd = 0;
const Pdata = 1;
const Pstatus = 2;

const CbwLen = 31;
const CbwDataIn = 0x80;
const CbwDataOut = 0x00;
const CswLen = 13;
const CswOk = 0;
const CswFailed = 1;
const CswPhaseErr = 2;

const Maxparts = 16;

// corresponds to a lun.
// these are ~600+Maxiosize bytes each; ScsiReq is not tiny.

const Part = struct {
    id: usize = 0,
    inuse: bool = false,
    vers: u32 = 0,
    mode: u32 = 0,
    name: []u8 = &.{},
    offset: i64 = 0, // in lbsize units
    length: i64 = 0, // in lbsize units
};

pub const Umsc = struct {
    req: ScsiReq = .{},
    namebuf: [40]u8 = undefined,
    name: []const u8 = "",
    blocks: u64 = 0,
    capacity: i64 = 0,

    // from setup
    bufp: []u8 = &.{},
    off: i32 = 0, // offset within a block
    nb: i32 = 0, // byte count

    lk: libc.QLock = .{},

    // partitions
    part: [Maxparts]Part = @splat(.{}),

    rawcmd: [16]u8 = @splat(0),
    phase: u8 = 0,
    /// null for a lun that is no disk: its ctl says "inquiry <nil>",
    /// as the C's does
    inq: ?[]u8 = null,
    ums: *Ums = undefined,
    buf: [Maxiosize]u8 = undefined,
};

const Ums = struct {
    epin: ?*Dev = null,
    epout: ?*Dev = null,
    lun: []Umsc = &.{},
    maxlun: u8 = 0,
    seq: u32 = 0,
    wrongresidues: bool = false,
};

// USB transparent SCSI devices
//
// Cbw, the command block wrapper: signature "USBC" 0, tag 4, datalen
// 8, flags 12, lun 13, len 14, command 15 (16 bytes).
// Csw, the command status wrapper: signature "USBS" 0, tag 4,
// dataresidue 8, status 12.

const Qdir = 0;
const Qctl = 1;
const Qraw = 2;
const Qdata = 3;
const Qpart = 4;
const Qmax = Maxparts;

var dev: *Dev = undefined;
var ums: *Ums = undefined;

// Partition management (adapted from disk/partfs)

fn lookpart(lun: *Umsc, name: []const u8) ?*Part {
    for (&lun.part) |*p| {
        if (p.inuse and std.mem.eql(u8, p.name, name))
            return p;
    }
    return null;
}

fn freepart(lun: *Umsc) ?*Part {
    for (&lun.part) |*p| {
        if (!p.inuse)
            return p;
    }
    return null;
}

fn addpart(lun: *Umsc, name: []const u8, start: i64, end: i64, mode: u32) libc.Error!void {
    if (start < 0 or start > end or @as(u64, @bitCast(end)) > lun.blocks) {
        libc.werrstr("bad partition boundaries", .{});
        return error.Plan9;
    }
    if (lookpart(lun, name)) |p| {
        // adding identical partition is no-op
        if (p.offset == start and p.length == end - start and p.mode == mode)
            return;
        libc.werrstr("partition name already in use", .{});
        return error.Plan9;
    }
    const p = freepart(lun) orelse {
        libc.werrstr("no free partition slots", .{});
        return error.Plan9;
    };
    p.inuse = true;
    libc.allocator.free(p.name);
    p.id = (@intFromPtr(p) - @intFromPtr(&lun.part)) / @sizeOf(Part);
    p.name = usb.estrdup(name);
    p.offset = start;
    p.length = end - start;
    p.mode = mode;
}

fn delpart(lun: *Umsc, s: []const u8) libc.Error!void {
    const p = lookpart(lun, s);
    if (p == null or p.?.id <= Qdata) {
        libc.werrstr("partition not found", .{});
        return error.Plan9;
    }
    p.?.inuse = false;
    libc.allocator.free(p.?.name);
    p.?.name = &.{};
    p.?.vers += 1;
}

fn fixlength(lun: *Umsc, blocks_: u64) void {
    const blocks: i64 = @bitCast(blocks_);
    lun.part[Qdata].length = blocks;
    for (lun.part[Qdata + 1 ..]) |*p| {
        if (p.inuse and p.offset + p.length > blocks) {
            if (p.offset > blocks) {
                p.offset = blocks;
                p.length = 0;
            } else p.length = blocks - p.offset;
        }
    }
}

fn makeparts(lun: *Umsc) void {
    addpart(lun, "/", 0, 0, fcall.DMDIR | 0o555) catch {};
    addpart(lun, "ctl", 0, 0, 0o664) catch {};
    addpart(lun, "raw", 0, 0, 0o640) catch {};
    addpart(lun, "data", 0, @bitCast(lun.blocks), 0o640) catch {};
}

// ctl parsing & formatting (adapted from partfs)

fn lunno(lun: *Umsc) usize {
    return (@intFromPtr(lun) - @intFromPtr(ums.lun.ptr)) / @sizeOf(Umsc);
}

fn ctlstring(lun: *Umsc) []u8 {
    var out: std.ArrayList(u8) = .empty;
    var buf: [256]u8 = undefined;
    const put = struct {
        fn f(o: *std.ArrayList(u8), s: []const u8) void {
            o.appendSlice(libc.allocator, s) catch libc.sysfatal("malloc: %r", .{});
        }
    }.f;

    if (lun.req.flags & scsi.Finqok != 0)
        put(&out, libc.sprint(&buf, "inquiry %s\n", .{lun.inq}));
    put(&out, libc.sprint(&buf, "dev %s\n", .{dev.dir}));
    put(&out, libc.sprint(&buf, "lun %d\n", .{lunno(lun)}));
    if (lun.blocks > 0)
        put(&out, libc.sprint(&buf, "geometry %ud %d\n", .{ lun.blocks, lun.req.lbsize }));
    for (lun.part[Qdata + 1 ..]) |*p| {
        if (p.inuse)
            put(&out, libc.sprint(&buf, "part %s %d %d\n", .{ p.name, p.offset, p.offset + p.length }));
    }
    return out.toOwnedSlice(libc.allocator) catch libc.sysfatal("malloc: %r", .{});
}

fn ctlparse(lun: *Umsc, msg: []u8) libc.Error!void {
    var argv: [16][]u8 = undefined;

    const argc = libc.tokenize(msg, &argv);

    if (argc < 1) {
        libc.werrstr("empty control message", .{});
        return error.Plan9;
    }

    if (std.mem.eql(u8, argv[0], "part")) {
        if (argc != 4) {
            libc.werrstr("part takes 3 args", .{});
            return error.Plan9;
        }
        const start = libc.strtol(argv[2], 0).v;
        const end = libc.strtol(argv[3], 0).v;
        return addpart(lun, argv[1], start, end, 0o640);
    } else if (std.mem.eql(u8, argv[0], "delpart")) {
        if (argc != 2) {
            libc.werrstr("delpart takes 1 arg", .{});
            return error.Plan9;
        }
        return delpart(lun, argv[1]);
    }
    libc.werrstr("unknown ctl", .{});
    return error.Plan9;
}

pub var diskdebug: i32 = 0;

fn getmaxlun() u8 {
    var max = [1]u8{0};

    const r = usb.Rd2h | usb.Rclass | usb.Riface;
    if (usbcmd(dev, r, Getmaxlun, 0, 0, &max)) |_| {
        max[0] &= 0o17; // 15 is the max. allowed
        dprint("%s: %s: maxlun %d\n", .{ libc.argv0, dev.dir, max[0] });
    } else |_| {
        dprint("%s: %s: getmaxlun failed: %r\n", .{ libc.argv0, dev.dir });
    }
    // 0e8d:1887 does not respond to followup commands without a delay
    libc.sleep(1) catch {};
    return max[0];
}

fn umsreset() bool {
    const r = usb.Rh2d | usb.Rclass | usb.Riface;
    _ = usbcmd(dev, r, Umsreset, 0, 0, null) catch {
        libc.fprint(2, "%s: reset: %r\n", .{libc.argv0});
        return false;
    };
    libc.sleep(100) catch {};
    return true;
}

fn umsrecover() void {
    if (!umsreset()) {
        // kill the 9p procs
        libc.postnote(libc.PNGROUP, libc.getpid(), "shutdown") catch {};
        libc.sysfatal("umsrecover: %r", .{});
    }
    usb.unstall(dev, ums.epin.?, usb.Ein) catch
        dprint("%s: unstall epin: %r\n", .{libc.argv0});
    // do we need this when epin == epout?
    usb.unstall(dev, ums.epout.?, usb.Eout) catch
        dprint("%s: unstall epout: %r\n", .{libc.argv0});
}

fn ispow2(ul: u64) bool {
    return (ul & (ul -% 1)) == 0;
}

/// return smallest power of 2 >= n
fn log2(n: u32) u5 {
    var i: u5 = 0;
    while ((@as(u32, 1) << i) < n)
        i += 1;
    return i;
}

fn umsready(lun: *Umsc) bool {
    const rp = &lun.req;
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        if (scsi.SRready(rp) != -1)
            break;

        if (rp.status != scsi.Status_SD)
            continue;

        // logical unit is in process of becoming ready
        // or initializing command required
        if (rp.sense[12] == 0x04) {
            if (rp.sense[13] == 0x02 or rp.sense[13] == 0x01)
                break;
        }

        // medium not present
        if (rp.sense[12] == 0x3A)
            return false;
    }

    // start unit
    if ((rp.inquiry[0] & 0x1F) == 0) {
        _ = scsi.SRstart(rp, 1);
        libc.sleep(250) catch {};
    }

    return true;
}

fn umscapacity(lun: *Umsc) bool {
    var data: [32]u8 = @splat(0);
    const rp = &lun.req;

    lun.blocks = 0;
    lun.capacity = 0;
    rp.lbsize = 0;

    if (!umsready(lun))
        return false;

    if (scsi.SRrcapacity(rp, &data) < 0)
        return false;

    lun.blocks = scsi.GETBELONG(&data);
    rp.lbsize = scsi.GETBELONG(data[4..]);
    if (lun.blocks == 0xFFFFFFFF) {
        if (scsi.SRrcapacity16(rp, &data) < 0) {
            rp.lbsize = 0;
            lun.blocks = 0;
            return false;
        } else {
            rp.lbsize = scsi.GETBELONG(data[8..]);
            lun.blocks = @as(u64, scsi.GETBELONG(&data)) << 32 |
                scsi.GETBELONG(data[4..]);
        }
    }
    lun.blocks +%= 1; // SRcapacity returns LBA of last block
    lun.capacity = @bitCast(lun.blocks *% rp.lbsize);
    fixlength(lun, lun.blocks);
    if (diskdebug != 0)
        libc.fprint(2, "%s: logical block size %ud, # blocks %ud\n", .{ libc.argv0, rp.lbsize, lun.blocks });
    return true;
}

fn umsinit() bool {
    var inqbuf: [64]u8 = undefined;

    _ = umsreset();
    ums.maxlun = getmaxlun();
    ums.lun = libc.allocator.alloc(Umsc, @as(usize, ums.maxlun) + 1) catch libc.sysfatal("malloc: %r", .{});
    var some: usize = 0;
    for (ums.lun, 0..) |*lun, i| {
        lun.* = .{};
        @memset(&lun.buf, 0);
        lun.ums = ums;
        lun.req.umsc = lun;
        lun.req.lun = @intCast(i);
        lun.req.flags = scsi.Fopen | scsi.Fusb | scsi.Frw10;
        if (scsi.SRinquiry(&lun.req) < 0 and scsi.SRinquiry(&lun.req) < 0) {
            dprint("%s: lun %d inquiry failed\n", .{ libc.argv0, i });
            continue;
        }
        switch (lun.req.inquiry[0]) {
            scsi.Devdir,
            scsi.Devworm, // a little different than the others
            scsi.Devcd,
            scsi.Devmo,
            => {},
            else => {
                libc.fprint(2, "%s: lun %d is not a disk (type %#02x)\n", .{ libc.argv0, i, lun.req.inquiry[0] });
                continue;
            },
        }

        // we ignore the device type reported by inquiry.
        // Some devices return a wrong value but would still work.
        some += 1;
        const inq = lun.req.inquiry[8..];
        lun.inq = usb.estrdup(libc.sprint(&inqbuf, "%.48s", .{inq[0 .. std.mem.indexOfScalar(u8, inq, 0) orelse inq.len]}));
        _ = umscapacity(lun);
    }
    if (some == 0) {
        dprint("%s: all luns failed\n", .{libc.argv0});
        return false;
    }
    return true;
}

/// called by SR*() commands provided by scuzz's scsireq
pub fn umsrequest(umsc: *Umsc, cmd: *ScsiPtr, data: *ScsiPtr, status: *i32) i32 {
    var cbw: [CbwLen]u8 = @splat(0);
    var csw: [CswLen]u8 = undefined;
    const u = umsc.ums;
    const epin = u.epin.?;
    const epout = u.epout.?;

    @memcpy(cbw[0..4], "USBC");
    u.seq +%= 1;
    const tag = u.seq;
    usb.PUT4(cbw[4..], tag);
    usb.PUT4(cbw[8..], @bitCast(data.count));
    cbw[12] = if (data.write) CbwDataOut else CbwDataIn;
    cbw[13] = umsc.req.lun;
    if (cmd.count < 1 or cmd.count > 16)
        libc.fprint(2, "%s: umsrequest: bad cmd count: %d\n", .{ libc.argv0, cmd.count });

    cbw[14] = @truncate(@as(u32, @bitCast(cmd.count)));
    std.debug.assert(cmd.count >= 0 and cmd.count <= 16);
    const ncmd: usize = @intCast(cmd.count);
    @memcpy(cbw[15..][0..ncmd], cmd.p[0..ncmd]);

    libc.werrstr("", .{}); // we use %r later even for n == 0
    if (diskdebug != 0) {
        libc.fprint(2, "%s: cmd: tag %#ux: ", .{ libc.argv0, tag });
        for (cbw[15..][0..cbw[14]]) |c|
            libc.fprint(2, " %2.2x", .{c});
        libc.fprint(2, " datalen: %d\n", .{data.count});
    }

    fail: {
        // issue tunnelled scsi command
        if (sys.write(epout.dfd, &cbw) != CbwLen) {
            libc.fprint(2, "%s: cmd: %r\n", .{libc.argv0});
            break :fail;
        }

        // transfer the data
        var nio: i32 = data.count;
        if (nio != 0) {
            const buf = data.p[0..@intCast(nio)];
            var n: isize = undefined;
            if (data.write)
                n = sys.write(epout.dfd, buf)
            else {
                n = sys.read(epin.dfd, buf);
                if (n >= 0 and n < nio) // didn't fill data->p?
                    @memset(buf[@intCast(n)..], 0);
            }
            if (diskdebug != 0) {
                if (n < 0)
                    libc.fprint(2, "%s: data: %r\n", .{libc.argv0})
                else
                    libc.fprint(2, "%s: data: %d bytes (nio: %d)\n", .{ libc.argv0, n, nio });
            }
            nio = @intCast(n);
            if (n <= 0) {
                nio = 0;
                if (!data.write)
                    usb.unstall(dev, epin, usb.Ein) catch {};
            }
        }

        var residue: i32 = undefined;
        while (true) {
            // read the transfer's status
            var n = sys.read(epin.dfd, &csw);
            if (n <= 0) {
                // n == 0 means "stalled"
                usb.unstall(dev, epin, usb.Ein) catch {};
                n = sys.read(epin.dfd, &csw);
            }

            if (n != CswLen or !std.mem.eql(u8, csw[0..4], "USBS")) {
                dprint("%s: read n=%d: status: %r\n", .{ libc.argv0, n });
                break :fail;
            }
            const ctag = usb.GET4(csw[4..]);
            if (ctag != tag) {
                dprint("%s: status tag mismatch: %ux != %ux\n", .{ libc.argv0, ctag, tag });
                continue;
            }
            break;
        }
        if (csw[12] >= CswPhaseErr) {
            dprint("%s: phase error\n", .{libc.argv0});
            break :fail;
        }
        residue = @bitCast(usb.GET4(csw[8..]));
        // Fixed from C: a residue that cannot be; see the top of the file
        if (residue <= 0 or residue > data.count or u.wrongresidues)
            residue = data.count - nio;
        if (diskdebug != 0) {
            libc.fprint(2, "%s: status: %2.2ux residue: %d\n", .{ libc.argv0, csw[12], residue });
            if (cbw[15] == scsi.ScmdRsense) {
                libc.fprint(2, "sense data:", .{});
                for (data.p[0..@intCast(data.count - residue)]) |c|
                    libc.fprint(2, " %2.2x", .{c});
                libc.fprint(2, "\n", .{});
            }
        }
        switch (csw[12]) {
            CswOk => status.* = scsi.STok,
            CswFailed => status.* = scsi.STcheck,
            else => {
                dprint("%s: phase error\n", .{libc.argv0});
                break :fail;
            },
        }
        return data.count - residue;
    }
    status.* = scsi.STharderr;
    return -1;
}

fn dattach(req: *Req) void {
    req.fid.?.qid = .{ .path = 0, .vers = 0, .type = fcall.QTDIR };
    req.ofcall.qid = req.fid.?.qid;
    respond(req, null);
}

/// The lun of a qid's path, which is not the root's.
fn qidlun(path: u64) *Umsc {
    return &ums.lun[@intCast((path >> 16) - 1)];
}

fn dwalk(fid: *Fid, name: []const u8, qid: *Qid) ?[]const u8 {
    if ((fid.qid.type & fcall.QTDIR) == 0)
        return "walk in non-directory";
    if (std.mem.eql(u8, name, "..")) {
        fid.qid = .{ .path = 0, .vers = 0, .type = fcall.QTDIR };
        qid.* = fid.qid;
        return null;
    }
    if (fid.qid.path == 0) {
        for (ums.lun, 0..) |*lun, i| {
            if (std.mem.eql(u8, lun.name, name)) {
                fid.qid.path = (i + 1) << 16;
                fid.qid.vers = 0;
                fid.qid.type = fcall.QTDIR;
                qid.* = fid.qid;
                return null;
            }
        }
        return "file does not exist";
    }
    const lun = qidlun(fid.qid.path);
    const p = lookpart(lun, name) orelse
        return "file does not exist";
    fid.qid.path |= p.id;
    fid.qid.vers = p.vers;
    fid.qid.type = @truncate(p.mode >> 24);
    qid.* = fid.qid;
    return null;
}

fn dostat(lun: *Umsc, path: usize, d: *Dir) void {
    const p = &lun.part[path];
    d.qid.path = path;
    d.qid.vers = p.vers;
    d.qid.type = @truncate(p.mode >> 24);
    d.mode = p.mode;
    d.length = p.length *% lun.req.lbsize;
    d.name = p9.estrdup9p(p.name);
    d.uid = p9.estrdup9p(libc.getuser());
    d.gid = p9.estrdup9p(d.uid);
    d.muid = p9.estrdup9p(d.uid);
}

fn dirgen(n_: i32, d: *Dir, aux: ?*anyopaque) bool {
    const lun: *Umsc = @ptrCast(@alignCast(aux.?));
    var n = n_;
    var i: usize = Qctl;
    while (i < Qmax) : (i += 1) {
        if (!lun.part[i].inuse)
            continue;
        if (n == 0)
            break;
        n -= 1;
    }
    if (i == Qmax)
        return false;
    d.* = .{};
    dostat(lun, i, d);
    d.qid.path |= lunno(lun) << 16;
    return true;
}

fn rootgen(n: i32, d: *Dir, _: ?*anyopaque) bool {
    if (n > ums.maxlun)
        return false;
    const lun = &ums.lun[@intCast(n)];
    d.* = .{};
    d.qid.path = @as(u64, @intCast(n + 1)) << 16;
    d.qid.type = fcall.QTDIR;
    d.mode = 0o555 | fcall.DMDIR;
    d.name = p9.estrdup9p(lun.name);
    d.uid = p9.estrdup9p(libc.getuser());
    d.gid = p9.estrdup9p(d.uid);
    d.muid = p9.estrdup9p(d.uid);
    return true;
}

fn dstat(req: *Req) void {
    const d = &req.d;
    const qid = req.fid.?.qid;
    d.qid = qid;
    if (qid.path == 0) {
        d.name = p9.estrdup9p("");
        d.mode = 0o555 | fcall.DMDIR;
        d.uid = p9.estrdup9p(libc.getuser());
        d.gid = p9.estrdup9p(d.uid);
        d.muid = p9.estrdup9p(d.uid);
    } else {
        dostat(qidlun(qid.path), @intCast(qid.path & 0xFFFF), d);
    }
    respond(req, null);
}

fn dopen(req: *Req) void {
    if (req.ofcall.qid.path == 0) {
        respond(req, null);
        return;
    }
    const path = req.ofcall.qid.path & 0xFFFF;
    const lun = qidlun(req.ofcall.qid.path);
    switch (path) {
        Qraw, Qdata, Qpart => {
            if (path == Qraw) {
                p9.srvrelease(req.srv);
                libc.qlock(&lun.lk);
                lun.phase = Pcmd;
                libc.qunlock(&lun.lk);
                p9.srvacquire(req.srv);
                // wet floor
            }
            req.ofcall.iounit = Maxiosize;
        },
        else => {},
    }
    respond(req, null);
}

/// check i/o parameters and compute values needed later.
/// we shift & mask manually to avoid run-time calls to _divv and _modv,
/// since we don't need general division nor its cost.
///
/// The count, 0 when there is nothing to transfer, or -1.  data is
/// the request's own buffer, for count bytes.
fn setup(lun: *Umsc, p: *Part, data: []u8, count: i32, offset: i64) i32 {
    const rp = &lun.req;
    if (count < 0 or rp.lbsize <= 0 and !umscapacity(lun) or
        rp.lbsize == 0)
        return -1;
    const lbsize: i64 = rp.lbsize;
    if (!ispow2(rp.lbsize) or lbsize > Maxiosize) {
        libc.werrstr("bad block size %ud", .{rp.lbsize});
        return -1;
    }
    const lbshift = log2(rp.lbsize);
    const lbmask = lbsize - 1;

    // an offset no disk has (the C's sums wrap there, and come to
    // the same: nothing to transfer)
    if (offset < 0 or offset > (1 << 62)) {
        lun.nb = 0;
        return 0;
    }
    var bno: i64 = offset >> lbshift; // offset / lbsize
    var nb: i64 = ((offset + count + lbsize - 1) >> lbshift) - bno;

    if (bno + nb > p.length) // past end of partition?
        nb = p.length - bno;
    if (nb * lbsize > Maxiosize)
        nb = @divTrunc(Maxiosize, lbsize);
    lun.nb = @intCast(@max(nb, 0));
    if (bno >= p.length or nb <= 0)
        return 0;

    bno += p.offset; // start of partition
    rp.offset = @bitCast(bno);
    lun.off = @intCast(offset & lbmask); // offset % lbsize
    if (lun.off == 0 and (count & lbmask) == 0)
        lun.bufp = data
    else
        // not transferring full, aligned blocks; need intermediary
        lun.bufp = &lun.buf;
    return count;
}

/// Upon SRread/SRwrite errors we assume the medium may have changed,
/// and ask again for the capacity of the media.
/// BUG: How to proceed to avoid confussing dossrv??
fn dread(req: *Req) void {
    var buf: [64]u8 = undefined;

    const q = req.fid.?.qid;
    if (q.path == 0) {
        p9.dirread9p(req, rootgen, null);
        respond(req, null);
        return;
    }
    const path: usize = @intCast(q.path & 0xFFFF);
    const lun = qidlun(q.path);
    var count: i32 = @intCast(req.ifcall.count);
    const data = req.rbuf[0..req.ifcall.count];
    const offset = req.ifcall.offset;

    switch (path) {
        Qdir => {
            p9.dirread9p(req, dirgen, lun);
            respond(req, null);
            return;
        },
        Qctl => {
            const s = ctlstring(lun);
            p9.readstr(req, s);
            libc.allocator.free(s);
            respond(req, null);
            return;
        },
        else => {},
    }

    const srv = req.srv;
    p9.srvrelease(srv);
    libc.qlock(&lun.lk);
    switch (path) {
        Qraw => switch (lun.phase) {
            Pcmd => respond(req, "phase error"),
            Pdata => {
                lun.req.data.p = data;
                lun.req.data.count = count;
                lun.req.data.write = false;
                count = umsrequest(lun, &lun.req.cmd, &lun.req.data, &lun.req.status);
                lun.phase = Pstatus;
                if (count < 0) {
                    lun.req.lbsize = 0; // medium may have changed
                    responderror(req);
                    umsrecover();
                } else {
                    req.ofcall.count = @intCast(count);
                    respond(req, null);
                }
            },
            else => { // Pstatus
                const s = libc.sprint(buf[0 .. buf.len - 1], "%11.0ud ", .{lun.req.status});
                const n: i32 = @intCast(s.len);
                if (n < count)
                    count = n;
                lun.phase = Pcmd;
                req.ofcall.count = @intCast(count);
                @memcpy(data[0..@intCast(count)], s[0..@intCast(count)]);
                respond(req, null);
            },
        },
        else => blk: { // Qdata and the partitions
            const p = &lun.part[path];
            if (!p.inuse) {
                respond(req, "permission denied");
                break :blk;
            }
            count = setup(lun, p, data, count, offset);
            if (count <= 0) {
                responderror(req);
                break :blk;
            }
            const n = scsi.SRread(&lun.req, lun.bufp, lun.nb * @as(i32, @intCast(lun.req.lbsize)));
            if (n < 0) {
                lun.req.lbsize = 0; // medium may have changed
                responderror(req);
                break :blk;
            } else if (lun.bufp.ptr == data.ptr)
                count = n
            else {
                // if n == lun->nb*lun->lbsize (as expected),
                // just copy count bytes.
                if (lun.off + count > n)
                    count = n - lun.off; // short read
                if (count > 0)
                    @memcpy(data[0..@intCast(count)], lun.bufp[@intCast(lun.off)..][0..@intCast(count)]);
            }
            // DIFF: a short read that ends before the offset within
            // the block is a count of 0 (the C answers with the
            // negative count)
            req.ofcall.count = @intCast(@max(count, 0));
            respond(req, null);
        },
    }

    libc.qunlock(&lun.lk);
    p9.srvacquire(srv);
}

fn dwrite(req: *Req) void {
    const qid = req.fid.?.qid;
    const lun = qidlun(qid.path);
    const path: usize = @intCast(qid.path & 0xFFFF);
    var count: i32 = @intCast(req.ifcall.count);
    // the message's data, which the request owns: ctl's is cut into
    // words where it lies, and raw's goes to the device from there
    const data: []u8 = @constCast(req.ifcall.data[0..req.ifcall.count]);
    const offset = req.ifcall.offset;

    const srv = req.srv;
    p9.srvrelease(srv);
    libc.qlock(&lun.lk);

    switch (path) {
        Qctl => {
            const s = usb.estrdup(data);
            var n = s.len;
            if (n > 0 and s[n - 1] == '\n')
                n -= 1;
            if (ctlparse(lun, s[0..n])) |_| {
                req.ofcall.count = @intCast(count);
                respond(req, null);
            } else |_| responderror(req);
            libc.allocator.free(s);
        },
        Qraw => switch (lun.phase) {
            Pcmd => blk: {
                if (count != 6 and count != 10 and count != 12 and count != 16) {
                    respond(req, "bad command length");
                    break :blk;
                }
                @memcpy(lun.rawcmd[0..data.len], data);
                lun.req.cmd.p = &lun.rawcmd;
                lun.req.cmd.count = count;
                lun.req.cmd.write = true;
                lun.phase = Pdata;
                req.ofcall.count = @intCast(count);
                respond(req, null);
            },
            Pdata => {
                lun.req.data.p = data;
                lun.req.data.count = count;
                lun.req.data.write = true;
                count = umsrequest(lun, &lun.req.cmd, &lun.req.data, &lun.req.status);
                lun.phase = Pstatus;
                if (count < 0) {
                    lun.req.lbsize = 0; // medium may have changed
                    responderror(req);
                    umsrecover();
                } else {
                    req.ofcall.count = @intCast(count);
                    respond(req, null);
                }
            },
            else => { // Pstatus
                lun.phase = Pcmd;
                respond(req, "phase error");
            },
        },
        else => blk: { // Qdata and the partitions
            const p = &lun.part[path];
            if (!p.inuse) {
                respond(req, "permission denied");
                break :blk;
            }
            var len = count;
            const ocount = count;
            count = setup(lun, p, data, count, offset);
            if (count <= 0) {
                responderror(req);
                break :blk;
            }
            const bno = lun.req.offset;
            const nbytes = lun.nb * @as(i32, @intCast(lun.req.lbsize));
            if (lun.bufp.ptr == &lun.buf) {
                count = scsi.SRread(&lun.req, lun.bufp, nbytes);
                if (count < 0) {
                    lun.req.lbsize = 0; // medium may have changed
                    responderror(req);
                    break :blk;
                }
                // if count == lun->nb*lun->lbsize, as expected, just
                // copy len (the original count) bytes of user data.
                if (lun.off + len > count)
                    len = count - lun.off; // short read
                if (len > 0)
                    @memcpy(lun.bufp[@intCast(lun.off)..][0..@intCast(len)], data[0..@intCast(len)]);
            }

            lun.req.offset = bno;
            count = scsi.SRwrite(&lun.req, lun.bufp, nbytes);
            if (count < 0) {
                lun.req.lbsize = 0; // medium may have changed
                responderror(req);
                break :blk;
            } else {
                if (lun.off + len > count)
                    count -= lun.off; // short write
                // never report more bytes written than requested
                if (count < 0)
                    count = 0
                else if (count > ocount)
                    count = ocount;
            }
            req.ofcall.count = @intCast(count);
            respond(req, null);
        },
    }

    libc.qunlock(&lun.lk);
    p9.srvacquire(srv);
}

fn findendpoints(u: *Ums, proto: u32) libc.Error!void {
    var ein: ?*Ep = null;
    var eout: ?*Ep = null;
    var found: ?*Iface = null;

    const ud = dev.usb.?;
    search: {
        const conf = ud.conf[0] orelse break :search;
        for (conf.iface) |first| {
            var ip = first;
            while (ip) |ifc| : (ip = ifc.next) {
                if (usb.Class(ifc.csp) != usb.Clstorage)
                    continue;
                if (usb.Proto(ifc.csp) != proto)
                    continue;
                ein = null;
                eout = null;
                for (ifc.ep) |slot| {
                    const ep = slot orelse break;
                    if (ep.type != usb.Ebulk)
                        continue;
                    if (ep.dir == usb.Eboth or ep.dir == usb.Ein) {
                        if (ein == null)
                            ein = ep;
                    }
                    if (ep.dir == usb.Eboth or ep.dir == usb.Eout) {
                        if (eout == null)
                            eout = ep;
                    }
                    if (ein != null and eout != null) {
                        dprint("%s: ifc %d csp %ux ep ids: in %d out %d\n", .{ libc.argv0, ifc.id, ifc.csp, ein.?.id, eout.?.id });
                        found = ifc;
                        break :search;
                    }
                }
            }
        }
    }
    const ifc = found orelse {
        libc.werrstr("no endpoints found", .{});
        return error.Plan9;
    };
    if (ifc.alt != 0)
        try usb.setalt(dev, ifc);
    u.epin = usb.openep(dev, ein.?) orelse return error.Plan9;
    if (ein == eout) {
        usb.incref(&u.epin.?.ref);
        u.epout = u.epin;
    } else u.epout = usb.openep(dev, eout.?);
    if (u.epout == null) {
        usb.closedev(u.epin);
        return error.Plan9;
    }
    const epin = u.epin.?;
    const epout = u.epout.?;

    _ = devctl(epin, "timeout 5000", .{}) catch {};
    _ = devctl(epout, "timeout 5000", .{}) catch {};
    if (usb.usbdebug > 1 or diskdebug > 2) {
        _ = devctl(epin, "debug 1", .{}) catch {};
        _ = devctl(epout, "debug 1", .{}) catch {};
        _ = devctl(dev, "debug 1", .{}) catch {};
    }

    if (epin == epout)
        _ = usb.opendevdata(epin, sys.ORDWR) catch {}
    else {
        _ = usb.opendevdata(epin, sys.OREAD) catch {};
        _ = usb.opendevdata(epout, sys.OWRITE) catch {};
    }
    if (epin.dfd < 0 or epout.dfd < 0) {
        usb.closedev(epin);
        usb.closedev(epout);
        return error.Plan9;
    }
    dprint("%s: ep in %s out %s\n", .{ libc.argv0, epin.dir, epout.dir });
}

fn usage() noreturn {
    libc.fprint(2, "usage: %s [-d] devid\n", .{libc.argv0});
    libc.exits("usage");
}

/// some devices like usb modems appear as mass storage
/// for windows driver installation. switch mode here
/// and exit if we detect one so the real driver can
/// attach it.
fn notreallyums(d: *Dev) void {
    const RealtekMagic = [_]u8{
        0x55, 0x53,
        0x42, 0x43,
        0x08, 0x60,
        0xd9, 0xa9,
        0xc0, 0x00,
        0x00, 0x00,
        0x80, 0x00,
        0x06, 0xe0,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00,
    };
    const ud = d.usb.?;

    // Realtek RTL8153
    if (ud.vid == 0x0bda and ud.did == 0x8151) {
        _ = sys.write(ums.epout.?.dfd, &RealtekMagic);
        libc.exits("mode switch");
    }

    // HUAWEI E220
    if (ud.vid == 0x12d1 and ud.did == 0x1003) {
        _ = usbcmd(d, usb.Rh2d | usb.Rstd | usb.Rdev, usb.Rsetfeature, usb.Fdevremotewakeup, 0x02, null) catch {};
        libc.exits("mode switch");
    }
}

var diskfs: p9.Srv = .{
    .attach = dattach,
    .walk1 = dwalk,
    .open = dopen,
    .read = dread,
    .write = dwrite,
    .stat = dstat,
};

pub fn main(argv: []const []const u8) void {
    var buf: [20]u8 = undefined;

    var args = libc.Args.init(argv);
    while (args.next()) |c| switch (c) {
        'D' => p9.chatty9p += 1,
        'd' => {
            scsi.scsidebug(diskdebug);
            diskdebug += 1;
            usb.usbdebug += 1;
        },
        else => usage(),
    };
    const rest = args.rest();
    if (rest.len != 1)
        usage();
    dev = usb.getdev(rest[0]) orelse libc.sysfatal("getdev: %r", .{});
    ums = usb.create(Ums);
    dev.aux = ums;
    ums.maxlun = 0xFF;
    findendpoints(ums, Protobulk) catch
        findendpoints(ums, Protouas) catch
        libc.sysfatal("findendpoints: %r", .{});

    notreallyums(dev);

    // SanDISK 512M gets residues wrong.
    if (dev.usb.?.vid == 0x0781 and dev.usb.?.did == 0x5150)
        ums.wrongresidues = true;

    if (!umsinit())
        libc.sysfatal("umsinit: %r", .{});

    for (ums.lun, 0..) |*lun, i| {
        if (ums.maxlun > 0)
            lun.name = libc.sprint(lun.namebuf[0 .. lun.namebuf.len - 1], "sdU%s.%d", .{ dev.hname, i })
        else
            lun.name = libc.sprint(lun.namebuf[0 .. lun.namebuf.len - 1], "sdU%s", .{dev.hname});
        makeparts(lun);
    }
    p9.postsharesrv(&diskfs, null, "usb", libc.sprint(buf[0 .. buf.len - 1], "%d.disk", .{dev.id}));
    libc.exits(null);
}
