//! 9P2000 message marshalling: Fcall and Dir to and from wire bytes.
//! from libc/9sys/conv*.c (convM2S.c, convS2M.c, convD2M.c, convM2D.c)
//! and fcall.h, with Qid, Dir and the QT*/DM* bits from libc.h.
//!
//! The wire format is ABI: every integer is little-endian, fields are in
//! the order and of the size the C writes them.  This file imports only
//! std and allocates nothing, so it serves the kernel and host tests.
//!
//! Return convention: as in C, convM2S, convS2M, sizeS2M, convD2M,
//! sizeD2M and convM2D return a byte count as `usize`, and 0 means
//! failure (convD2M also keeps its special BIT16SZ return, see there).
//! statcheck returns 0 for a good buffer and -1 for a bad one.  No error
//! unions: callers map failure to their own errors.
//!
//! Fcall is one flat struct holding every member of the C union side by
//! side, so code reads as in C: `f.type`, `f.fid`, `f.count`, `f.data`,
//! `f.wname[i]`, `f.qid`, `f.ename`.
//!
//! DIFF: every deliberate difference from the C.
//!  - Buffers are slices; the C (pointer, length) pairs became one
//!    argument.  Positions are indices into the slice, not pointers.
//!  - Strings are `[]const u8` without a terminating NUL.  A nil string
//!    in C is an empty slice here; both go on the wire as a zero count.
//!  - convM2S does not modify the message.  The C gstring moves each
//!    string down one byte, over its count, to make room for a NUL; here
//!    the decoded strings are slices of the message where it lies, so the
//!    buffer is `[]const u8` and can be decoded more than once.
//!  - Fcall is flat, not a union: members of different message types do
//!    not overlap.  convM2S sets only the members of the decoded type and
//!    leaves the rest as they were (in C they would be clobbered through
//!    the union).  Every member has a default so an Fcall can be written
//!    as a literal.
//!  - `f.data` and `f.stat` are slices and `f.count` and `f.nstat` are
//!    kept beside them as in C.  convM2S sets both so that
//!    `f.data.len == f.count` and `f.stat.len == f.nstat`.  convS2M sends
//!    `f.count` bytes of `f.data` (`f.nstat` of `f.stat`) and fails if the
//!    slice is shorter than the count, where the C would read past it.
//!  - sizeS2M returns 0 for a Twalk with nwname > MAXWELEM.  The C would
//!    index beyond wname[] there and leaves the check to convS2M.
//!  - convS2M fails if a string is longer than 65535 bytes or the message
//!    is longer than a 32-bit size can say.  The C truncates the count
//!    and emits a corrupt message.
//!  - convD2M returns 0 if the stat would not fit the 16-bit size field
//!    (longer than STATMAX+BIT16SZ bytes); the C truncates the size.
//!  - convM2D takes the string area as an optional slice and returns 0 if
//!    it is too small.  The C trusts the caller.  It still writes a NUL
//!    after each string, so the area is sized exactly as in C.
//!  - Message types are plain `u8` constants, not an enum, because the
//!    type byte comes off the wire and may be anything.
//!  - The GBIT*/PBIT* macros take (buffer, index) and are built on
//!    std.mem.readInt/writeInt.

const std = @import("std");

pub const VERSION9P = "9P2000";

pub const MAXWELEM = 16;

pub const STATMAX = 65535; // max length of machine-independent stat structure
pub const ERRMAX = 128; // max length of error string

// bits in Qid.type
pub const QTDIR = 0x80; // type bit for directories
pub const QTAPPEND = 0x40; // type bit for append only files
pub const QTEXCL = 0x20; // type bit for exclusive use files
pub const QTMOUNT = 0x10; // type bit for mounted channel
pub const QTAUTH = 0x08; // type bit for authentication file
pub const QTTMP = 0x04; // type bit for not-backed-up file
pub const QTFILE = 0x00; // plain file

// bits in Dir.mode
pub const DMDIR = 0x80000000; // mode bit for directories
pub const DMAPPEND = 0x40000000; // mode bit for append only files
pub const DMEXCL = 0x20000000; // mode bit for exclusive use files
pub const DMMOUNT = 0x10000000; // mode bit for mounted channel
pub const DMAUTH = 0x08000000; // mode bit for authentication file
pub const DMTMP = 0x04000000; // mode bit for non-backed-up files
pub const DMREAD = 0x4; // mode bit for read permission
pub const DMWRITE = 0x2; // mode bit for write permission
pub const DMEXEC = 0x1; // mode bit for execute permission

pub const Qid = struct {
    path: u64 = 0,
    vers: u32 = 0,
    type: u8 = 0,
};

pub const Dir = struct {
    // system-modified data
    type: u16 = 0, // server type
    dev: u32 = 0, // server subtype
    // file data
    qid: Qid = .{}, // unique id from server
    mode: u32 = 0, // permissions
    atime: u32 = 0, // last read time
    mtime: u32 = 0, // last write time
    length: i64 = 0, // file length
    name: []const u8 = "", // last element of path
    uid: []const u8 = "", // owner name
    gid: []const u8 = "", // group name
    muid: []const u8 = "", // last modifier name
};

/// The C Fcall with its anonymous union flattened: all members exist at
/// once and only those of the message type are meaningful.
pub const Fcall = struct {
    type: u8 = 0,
    fid: u32 = 0,
    tag: u16 = 0,

    msize: u32 = 0, // Tversion, Rversion
    version: []const u8 = "", // Tversion, Rversion

    oldtag: u16 = 0, // Tflush

    ename: []const u8 = "", // Rerror

    qid: Qid = .{}, // Rattach, Ropen, Rcreate
    iounit: u32 = 0, // Ropen, Rcreate

    aqid: Qid = .{}, // Rauth

    afid: u32 = 0, // Tauth, Tattach
    uname: []const u8 = "", // Tauth, Tattach
    aname: []const u8 = "", // Tauth, Tattach

    perm: u32 = 0, // Tcreate
    name: []const u8 = "", // Tcreate
    mode: u8 = 0, // Tcreate, Topen

    newfid: u32 = 0, // Twalk
    nwname: u16 = 0, // Twalk
    wname: [MAXWELEM][]const u8 = @splat(""), // Twalk

    nwqid: u16 = 0, // Rwalk
    wqid: [MAXWELEM]Qid = @splat(.{}), // Rwalk

    offset: i64 = 0, // Tread, Twrite
    count: u32 = 0, // Tread, Twrite, Rread
    data: []const u8 = "", // Twrite, Rread

    nstat: u16 = 0, // Twstat, Rstat
    stat: []const u8 = "", // Twstat, Rstat
};

pub inline fn GBIT8(b: []const u8, p: usize) u8 {
    return b[p];
}
pub inline fn GBIT16(b: []const u8, p: usize) u16 {
    return std.mem.readInt(u16, b[p..][0..BIT16SZ], .little);
}
pub inline fn GBIT32(b: []const u8, p: usize) u32 {
    return std.mem.readInt(u32, b[p..][0..BIT32SZ], .little);
}
pub inline fn GBIT64(b: []const u8, p: usize) u64 {
    return std.mem.readInt(u64, b[p..][0..BIT64SZ], .little);
}

pub inline fn PBIT8(b: []u8, p: usize, v: u8) void {
    b[p] = v;
}
pub inline fn PBIT16(b: []u8, p: usize, v: u16) void {
    std.mem.writeInt(u16, b[p..][0..BIT16SZ], v, .little);
}
pub inline fn PBIT32(b: []u8, p: usize, v: u32) void {
    std.mem.writeInt(u32, b[p..][0..BIT32SZ], v, .little);
}
pub inline fn PBIT64(b: []u8, p: usize, v: u64) void {
    std.mem.writeInt(u64, b[p..][0..BIT64SZ], v, .little);
}

pub const BIT8SZ = 1;
pub const BIT16SZ = 2;
pub const BIT32SZ = 4;
pub const BIT64SZ = 8;
pub const QIDSZ = BIT8SZ + BIT32SZ + BIT64SZ;

// STATFIXLEN includes leading 16-bit count
// The count, however, excludes itself; total size is BIT16SZ+count
pub const STATFIXLEN = BIT16SZ + QIDSZ + 5 * BIT16SZ + 4 * BIT32SZ + 1 * BIT64SZ; // amount of fixed length data in a stat buffer

pub const NOTAG: u16 = 0xffff; // Dummy tag
pub const NOFID: u32 = 0xffffffff; // Dummy fid
pub const IOHDRSZ = 24; // ample room for Twrite/Rread header (iounit)

pub const Tversion: u8 = 100;
pub const Rversion: u8 = 101;
pub const Tauth: u8 = 102;
pub const Rauth: u8 = 103;
pub const Tattach: u8 = 104;
pub const Rattach: u8 = 105;
pub const Terror: u8 = 106; // illegal
pub const Rerror: u8 = 107;
pub const Tflush: u8 = 108;
pub const Rflush: u8 = 109;
pub const Twalk: u8 = 110;
pub const Rwalk: u8 = 111;
pub const Topen: u8 = 112;
pub const Ropen: u8 = 113;
pub const Tcreate: u8 = 114;
pub const Rcreate: u8 = 115;
pub const Tread: u8 = 116;
pub const Rread: u8 = 117;
pub const Twrite: u8 = 118;
pub const Rwrite: u8 = 119;
pub const Tclunk: u8 = 120;
pub const Rclunk: u8 = 121;
pub const Tremove: u8 = 122;
pub const Rremove: u8 = 123;
pub const Tstat: u8 = 124;
pub const Rstat: u8 = 125;
pub const Twstat: u8 = 126;
pub const Rwstat: u8 = 127;
pub const Tmax: u8 = 128;

//
// convM2S.c
//

// DIFF: the string is not moved down on top of its count to make room
// for '\0'; s becomes a slice of the message where the string lies.
fn gstring(ap: []const u8, p0: usize, s: *[]const u8) ?usize {
    var p = p0;
    const ep = ap.len;

    if (p + BIT16SZ > ep)
        return null;
    const n: usize = GBIT16(ap, p);
    p += BIT16SZ;
    if (p + n > ep)
        return null;
    s.* = ap[p..][0..n];
    p += n;
    return p;
}

fn gqid(ap: []const u8, p0: usize, q: *Qid) ?usize {
    var p = p0;
    const ep = ap.len;

    if (p + QIDSZ > ep)
        return null;
    q.type = GBIT8(ap, p);
    p += BIT8SZ;
    q.vers = GBIT32(ap, p);
    p += BIT32SZ;
    q.path = GBIT64(ap, p);
    p += BIT64SZ;
    return p;
}

/// Decode the 9P message at the start of `ap` into `f`.  Returns the
/// message size, or 0 on failure.  `ap` may be longer than the message.
///
/// The strings (version, ename, uname, aname, name, wname[i]) and the
/// data and stat slices of `f` alias `ap`: they are valid only as long
/// as the message buffer is, and nothing is copied.
///
/// no syntactic checks.
/// three causes for error:
///  1. message size field is incorrect
///  2. input buffer too short for its own data (counts too long, etc.)
///  3. too many names or qids
/// gqid() and gstring() return null if they would reach beyond buffer.
/// main switch statement checks range and also can fall through
/// to test at end of routine.
pub fn convM2S(ap: []const u8, f: *Fcall) usize {
    var p: usize = 0;
    const ep = ap.len;

    if (p + BIT32SZ + BIT8SZ + BIT16SZ > ep)
        return 0;
    const size: usize = GBIT32(ap, p);
    p += BIT32SZ;

    if (size < BIT32SZ + BIT8SZ + BIT16SZ)
        return 0;

    f.type = GBIT8(ap, p);
    p += BIT8SZ;
    f.tag = GBIT16(ap, p);
    p += BIT16SZ;

    switch (f.type) {
        else => return 0,

        Tversion => {
            if (p + BIT32SZ > ep)
                return 0;
            f.msize = GBIT32(ap, p);
            p += BIT32SZ;
            p = gstring(ap, p, &f.version) orelse return 0;
        },

        Tflush => {
            if (p + BIT16SZ > ep)
                return 0;
            f.oldtag = GBIT16(ap, p);
            p += BIT16SZ;
        },

        Tauth => {
            if (p + BIT32SZ > ep)
                return 0;
            f.afid = GBIT32(ap, p);
            p += BIT32SZ;
            p = gstring(ap, p, &f.uname) orelse return 0;
            p = gstring(ap, p, &f.aname) orelse return 0;
        },

        Tattach => {
            if (p + BIT32SZ > ep)
                return 0;
            f.fid = GBIT32(ap, p);
            p += BIT32SZ;
            if (p + BIT32SZ > ep)
                return 0;
            f.afid = GBIT32(ap, p);
            p += BIT32SZ;
            p = gstring(ap, p, &f.uname) orelse return 0;
            p = gstring(ap, p, &f.aname) orelse return 0;
        },

        Twalk => {
            if (p + BIT32SZ + BIT32SZ + BIT16SZ > ep)
                return 0;
            f.fid = GBIT32(ap, p);
            p += BIT32SZ;
            f.newfid = GBIT32(ap, p);
            p += BIT32SZ;
            f.nwname = GBIT16(ap, p);
            p += BIT16SZ;
            if (f.nwname > MAXWELEM)
                return 0;
            for (0..f.nwname) |i|
                p = gstring(ap, p, &f.wname[i]) orelse return 0;
        },

        Topen => {
            if (p + BIT32SZ + BIT8SZ > ep)
                return 0;
            f.fid = GBIT32(ap, p);
            p += BIT32SZ;
            f.mode = GBIT8(ap, p);
            p += BIT8SZ;
        },

        Tcreate => {
            if (p + BIT32SZ > ep)
                return 0;
            f.fid = GBIT32(ap, p);
            p += BIT32SZ;
            p = gstring(ap, p, &f.name) orelse return 0;
            if (p + BIT32SZ + BIT8SZ > ep)
                return 0;
            f.perm = GBIT32(ap, p);
            p += BIT32SZ;
            f.mode = GBIT8(ap, p);
            p += BIT8SZ;
        },

        Tread => {
            if (p + BIT32SZ + BIT64SZ + BIT32SZ > ep)
                return 0;
            f.fid = GBIT32(ap, p);
            p += BIT32SZ;
            f.offset = @bitCast(GBIT64(ap, p));
            p += BIT64SZ;
            f.count = GBIT32(ap, p);
            p += BIT32SZ;
        },

        Twrite => {
            if (p + BIT32SZ + BIT64SZ + BIT32SZ > ep)
                return 0;
            f.fid = GBIT32(ap, p);
            p += BIT32SZ;
            f.offset = @bitCast(GBIT64(ap, p));
            p += BIT64SZ;
            f.count = GBIT32(ap, p);
            p += BIT32SZ;
            if (p + f.count > ep)
                return 0;
            f.data = ap[p..][0..f.count];
            p += f.count;
        },

        Tclunk, Tremove => {
            if (p + BIT32SZ > ep)
                return 0;
            f.fid = GBIT32(ap, p);
            p += BIT32SZ;
        },

        Tstat => {
            if (p + BIT32SZ > ep)
                return 0;
            f.fid = GBIT32(ap, p);
            p += BIT32SZ;
        },

        Twstat => {
            if (p + BIT32SZ + BIT16SZ > ep)
                return 0;
            f.fid = GBIT32(ap, p);
            p += BIT32SZ;
            f.nstat = GBIT16(ap, p);
            p += BIT16SZ;
            if (p + f.nstat > ep)
                return 0;
            f.stat = ap[p..][0..f.nstat];
            p += f.nstat;
        },

        //

        Rversion => {
            if (p + BIT32SZ > ep)
                return 0;
            f.msize = GBIT32(ap, p);
            p += BIT32SZ;
            p = gstring(ap, p, &f.version) orelse return 0;
        },

        Rerror => {
            p = gstring(ap, p, &f.ename) orelse return 0;
        },

        Rflush => {},

        Rauth => {
            p = gqid(ap, p, &f.aqid) orelse return 0;
        },

        Rattach => {
            p = gqid(ap, p, &f.qid) orelse return 0;
        },

        Rwalk => {
            if (p + BIT16SZ > ep)
                return 0;
            f.nwqid = GBIT16(ap, p);
            p += BIT16SZ;
            if (f.nwqid > MAXWELEM)
                return 0;
            for (0..f.nwqid) |i|
                p = gqid(ap, p, &f.wqid[i]) orelse return 0;
        },

        Ropen, Rcreate => {
            p = gqid(ap, p, &f.qid) orelse return 0;
            if (p + BIT32SZ > ep)
                return 0;
            f.iounit = GBIT32(ap, p);
            p += BIT32SZ;
        },

        Rread => {
            if (p + BIT32SZ > ep)
                return 0;
            f.count = GBIT32(ap, p);
            p += BIT32SZ;
            if (p + f.count > ep)
                return 0;
            f.data = ap[p..][0..f.count];
            p += f.count;
        },

        Rwrite => {
            if (p + BIT32SZ > ep)
                return 0;
            f.count = GBIT32(ap, p);
            p += BIT32SZ;
        },

        Rclunk, Rremove => {},

        Rstat => {
            if (p + BIT16SZ > ep)
                return 0;
            f.nstat = GBIT16(ap, p);
            p += BIT16SZ;
            if (p + f.nstat > ep)
                return 0;
            f.stat = ap[p..][0..f.nstat];
            p += f.nstat;
        },

        Rwstat => {},
    }

    if (p > ep)
        return 0;
    if (size == p)
        return size;
    return 0;
}

//
// convS2M.c
//

// DIFF: returns null if the string is too long for its 16-bit count.
fn pstring(ap: []u8, p0: usize, s: []const u8) ?usize {
    var p = p0;

    const n = s.len;
    if (n > 0xffff)
        return null;
    // We are moving the string before the length,
    // so you can S2M a struct into an existing message
    @memmove(ap[p + BIT16SZ ..][0..n], s);
    PBIT16(ap, p, @intCast(n));
    p += n + BIT16SZ;
    return p;
}

fn pqid(ap: []u8, p0: usize, q: *const Qid) usize {
    var p = p0;

    PBIT8(ap, p, q.type);
    p += BIT8SZ;
    PBIT32(ap, p, q.vers);
    p += BIT32SZ;
    PBIT64(ap, p, q.path);
    p += BIT64SZ;
    return p;
}

fn stringsz(s: []const u8) usize {
    return BIT16SZ + s.len;
}

/// Number of bytes convS2M needs for `f`, or 0 if `f` cannot be sent
/// (unknown type, or a Twalk with more than MAXWELEM names).
pub fn sizeS2M(f: *const Fcall) usize {
    var n: usize = 0;
    n += BIT32SZ; // size
    n += BIT8SZ; // type
    n += BIT16SZ; // tag

    switch (f.type) {
        else => return 0,

        Tversion => {
            n += BIT32SZ;
            n += stringsz(f.version);
        },

        Tflush => {
            n += BIT16SZ;
        },

        Tauth => {
            n += BIT32SZ;
            n += stringsz(f.uname);
            n += stringsz(f.aname);
        },

        Tattach => {
            n += BIT32SZ;
            n += BIT32SZ;
            n += stringsz(f.uname);
            n += stringsz(f.aname);
        },

        Twalk => {
            n += BIT32SZ;
            n += BIT32SZ;
            n += BIT16SZ;
            // DIFF: the C reads beyond wname[] here
            if (f.nwname > MAXWELEM)
                return 0;
            for (0..f.nwname) |i|
                n += stringsz(f.wname[i]);
        },

        Topen => {
            n += BIT32SZ;
            n += BIT8SZ;
        },

        Tcreate => {
            n += BIT32SZ;
            n += stringsz(f.name);
            n += BIT32SZ;
            n += BIT8SZ;
        },

        Tread => {
            n += BIT32SZ;
            n += BIT64SZ;
            n += BIT32SZ;
        },

        Twrite => {
            n += BIT32SZ;
            n += BIT64SZ;
            n += BIT32SZ;
            n += f.count;
        },

        Tclunk, Tremove => {
            n += BIT32SZ;
        },

        Tstat => {
            n += BIT32SZ;
        },

        Twstat => {
            n += BIT32SZ;
            n += BIT16SZ;
            n += f.nstat;
        },

        //

        Rversion => {
            n += BIT32SZ;
            n += stringsz(f.version);
        },

        Rerror => {
            n += stringsz(f.ename);
        },

        Rflush => {},

        Rauth => {
            n += QIDSZ;
        },

        Rattach => {
            n += QIDSZ;
        },

        Rwalk => {
            n += BIT16SZ;
            n += @as(usize, f.nwqid) * QIDSZ;
        },

        Ropen, Rcreate => {
            n += QIDSZ;
            n += BIT32SZ;
        },

        Rread => {
            n += BIT32SZ;
            n += f.count;
        },

        Rwrite => {
            n += BIT32SZ;
        },

        Rclunk => {},

        Rremove => {},

        Rstat => {
            n += BIT16SZ;
            n += f.nstat;
        },

        Rwstat => {},
    }
    return n;
}

/// Encode `f` at the start of `ap`.  Returns the message size, or 0 on
/// failure (unknown type, `ap` too small, too many names or qids, a
/// string over 65535 bytes, data or stat shorter than its count).
/// On failure part of `ap` may have been written.
///
/// The strings and data of `f` may lie inside `ap` (an Fcall decoded
/// from `ap` can be encoded back into it): copies are overlap-safe.
pub fn convS2M(f: *const Fcall, ap: []u8) usize {
    const size = sizeS2M(f);
    if (size == 0)
        return 0;
    if (size > ap.len)
        return 0;
    // DIFF: the C lets the size field wrap
    if (size > 0xffffffff)
        return 0;

    var p: usize = 0;

    PBIT32(ap, p, @intCast(size));
    p += BIT32SZ;
    PBIT8(ap, p, f.type);
    p += BIT8SZ;
    PBIT16(ap, p, f.tag);
    p += BIT16SZ;

    switch (f.type) {
        else => return 0,

        Tversion => {
            PBIT32(ap, p, f.msize);
            p += BIT32SZ;
            p = pstring(ap, p, f.version) orelse return 0;
        },

        Tflush => {
            PBIT16(ap, p, f.oldtag);
            p += BIT16SZ;
        },

        Tauth => {
            PBIT32(ap, p, f.afid);
            p += BIT32SZ;
            p = pstring(ap, p, f.uname) orelse return 0;
            p = pstring(ap, p, f.aname) orelse return 0;
        },

        Tattach => {
            PBIT32(ap, p, f.fid);
            p += BIT32SZ;
            PBIT32(ap, p, f.afid);
            p += BIT32SZ;
            p = pstring(ap, p, f.uname) orelse return 0;
            p = pstring(ap, p, f.aname) orelse return 0;
        },

        Twalk => {
            PBIT32(ap, p, f.fid);
            p += BIT32SZ;
            PBIT32(ap, p, f.newfid);
            p += BIT32SZ;
            PBIT16(ap, p, f.nwname);
            p += BIT16SZ;
            if (f.nwname > MAXWELEM)
                return 0;
            for (0..f.nwname) |i|
                p = pstring(ap, p, f.wname[i]) orelse return 0;
        },

        Topen => {
            PBIT32(ap, p, f.fid);
            p += BIT32SZ;
            PBIT8(ap, p, f.mode);
            p += BIT8SZ;
        },

        Tcreate => {
            PBIT32(ap, p, f.fid);
            p += BIT32SZ;
            p = pstring(ap, p, f.name) orelse return 0;
            PBIT32(ap, p, f.perm);
            p += BIT32SZ;
            PBIT8(ap, p, f.mode);
            p += BIT8SZ;
        },

        Tread => {
            PBIT32(ap, p, f.fid);
            p += BIT32SZ;
            PBIT64(ap, p, @bitCast(f.offset));
            p += BIT64SZ;
            PBIT32(ap, p, f.count);
            p += BIT32SZ;
        },

        Twrite => {
            PBIT32(ap, p, f.fid);
            p += BIT32SZ;
            PBIT64(ap, p, @bitCast(f.offset));
            p += BIT64SZ;
            PBIT32(ap, p, f.count);
            p += BIT32SZ;
            if (f.data.len < f.count)
                return 0;
            @memmove(ap[p..][0..f.count], f.data[0..f.count]);
            p += f.count;
        },

        Tclunk, Tremove => {
            PBIT32(ap, p, f.fid);
            p += BIT32SZ;
        },

        Tstat => {
            PBIT32(ap, p, f.fid);
            p += BIT32SZ;
        },

        Twstat => {
            PBIT32(ap, p, f.fid);
            p += BIT32SZ;
            PBIT16(ap, p, f.nstat);
            p += BIT16SZ;
            if (f.stat.len < f.nstat)
                return 0;
            @memmove(ap[p..][0..f.nstat], f.stat[0..f.nstat]);
            p += f.nstat;
        },

        //

        Rversion => {
            PBIT32(ap, p, f.msize);
            p += BIT32SZ;
            p = pstring(ap, p, f.version) orelse return 0;
        },

        Rerror => {
            p = pstring(ap, p, f.ename) orelse return 0;
        },

        Rflush => {},

        Rauth => {
            p = pqid(ap, p, &f.aqid);
        },

        Rattach => {
            p = pqid(ap, p, &f.qid);
        },

        Rwalk => {
            PBIT16(ap, p, f.nwqid);
            p += BIT16SZ;
            if (f.nwqid > MAXWELEM)
                return 0;
            for (0..f.nwqid) |i|
                p = pqid(ap, p, &f.wqid[i]);
        },

        Ropen, Rcreate => {
            p = pqid(ap, p, &f.qid);
            PBIT32(ap, p, f.iounit);
            p += BIT32SZ;
        },

        Rread => {
            PBIT32(ap, p, f.count);
            p += BIT32SZ;
            if (f.data.len < f.count)
                return 0;
            @memmove(ap[p..][0..f.count], f.data[0..f.count]);
            p += f.count;
        },

        Rwrite => {
            PBIT32(ap, p, f.count);
            p += BIT32SZ;
        },

        Rclunk => {},

        Rremove => {},

        Rstat => {
            PBIT16(ap, p, f.nstat);
            p += BIT16SZ;
            if (f.stat.len < f.nstat)
                return 0;
            @memmove(ap[p..][0..f.nstat], f.stat[0..f.nstat]);
            p += f.nstat;
        },

        Rwstat => {},
    }
    if (size != p)
        return 0;
    return size;
}

//
// convD2M.c
//

/// Number of bytes convD2M needs for `d`, leading count included.
pub fn sizeD2M(d: *const Dir) usize {
    const sv = [4][]const u8{ d.name, d.uid, d.gid, d.muid };

    var ns: usize = 0;
    for (sv) |s|
        ns += s.len;

    return STATFIXLEN + ns;
}

/// Encode `d` at the start of `buf`.  Returns the number of bytes
/// written.  Returns 0 if `buf` cannot even hold the 16-bit size, and
/// BIT16SZ if `buf` is too small for the whole stat: then only the size
/// field has been written, so the caller can learn how much is needed.
pub fn convD2M(d: *const Dir, buf: []u8) usize {
    const nbuf = buf.len;

    if (nbuf < BIT16SZ)
        return 0;

    var p: usize = 0;
    const ebuf = nbuf;

    const sv = [4][]const u8{ d.name, d.uid, d.gid, d.muid };
    var nsv: [4]usize = undefined;

    var ns: usize = 0;
    for (sv, 0..) |s, i| {
        nsv[i] = s.len;
        ns += nsv[i];
    }

    const ss = STATFIXLEN + ns;

    // DIFF: the C truncates a size that does not fit in 16 bits
    if (ss - BIT16SZ > STATMAX)
        return 0;

    // set size before erroring, so user can know how much is needed
    // note that length excludes count field itself
    PBIT16(buf, p, @intCast(ss - BIT16SZ));
    p += BIT16SZ;

    if (ss > nbuf)
        return BIT16SZ;

    PBIT16(buf, p, d.type);
    p += BIT16SZ;
    PBIT32(buf, p, d.dev);
    p += BIT32SZ;
    PBIT8(buf, p, d.qid.type);
    p += BIT8SZ;
    PBIT32(buf, p, d.qid.vers);
    p += BIT32SZ;
    PBIT64(buf, p, d.qid.path);
    p += BIT64SZ;
    PBIT32(buf, p, d.mode);
    p += BIT32SZ;
    PBIT32(buf, p, d.atime);
    p += BIT32SZ;
    PBIT32(buf, p, d.mtime);
    p += BIT32SZ;
    PBIT64(buf, p, @bitCast(d.length));
    p += BIT64SZ;

    for (0..4) |i| {
        ns = nsv[i];
        if (p + ns + BIT16SZ > ebuf)
            return 0;
        PBIT16(buf, p, @intCast(ns));
        p += BIT16SZ;
        if (ns != 0)
            @memmove(buf[p..][0..ns], sv[i]);
        p += ns;
    }

    if (ss != p)
        return 0;

    return p;
}

//
// convM2D.c
//

/// Check that `buf` is exactly one well-formed stat: its size field
/// agrees with buf.len and its four strings end exactly at the end.
/// Returns 0 if so, -1 if not, as in C.
pub fn statcheck(buf: []const u8) i32 {
    const nbuf = buf.len;
    const ebuf = nbuf;

    if (nbuf < STATFIXLEN or nbuf != BIT16SZ + @as(usize, GBIT16(buf, 0)))
        return -1;

    var p: usize = STATFIXLEN - 4 * BIT16SZ;

    for (0..4) |_| {
        if (p + BIT16SZ > ebuf)
            return -1;
        p += BIT16SZ + @as(usize, GBIT16(buf, p));
    }

    if (p != ebuf)
        return -1;

    return 0;
}

const nullstring = "";

/// Decode the stat at the start of `buf` into `d`.  Returns the number
/// of bytes consumed, or 0 on failure.  The size field is ignored, as in
/// C: run statcheck first on data that is not trusted.
///
/// If `strs` is given, the four strings are copied into it one after the
/// other, each followed by a NUL, and d.name, d.uid, d.gid and d.muid
/// become slices of `strs` (without the NUL): they alias `strs`, not
/// `buf`, and stay valid as long as `strs` does.  `strs` needs the
/// total length of the strings plus 4 bytes; buf.len - STATFIXLEN + 4
/// is always enough.  If it is too small 0 is returned.
///
/// If `strs` is null the strings are skipped and the four names are set
/// to the empty string.
pub fn convM2D(buf: []const u8, d: *Dir, strs: ?[]u8) usize {
    const nbuf = buf.len;
    var sv: [4][]const u8 = undefined;

    if (nbuf < STATFIXLEN)
        return 0;

    var p: usize = 0;
    const ebuf = nbuf;
    var sp: usize = 0; // DIFF: index into strs where the C advances strs

    p += BIT16SZ; // ignore size
    d.type = GBIT16(buf, p);
    p += BIT16SZ;
    d.dev = GBIT32(buf, p);
    p += BIT32SZ;
    d.qid.type = GBIT8(buf, p);
    p += BIT8SZ;
    d.qid.vers = GBIT32(buf, p);
    p += BIT32SZ;
    d.qid.path = GBIT64(buf, p);
    p += BIT64SZ;
    d.mode = GBIT32(buf, p);
    p += BIT32SZ;
    d.atime = GBIT32(buf, p);
    p += BIT32SZ;
    d.mtime = GBIT32(buf, p);
    p += BIT32SZ;
    d.length = @bitCast(GBIT64(buf, p));
    p += BIT64SZ;

    for (0..4) |i| {
        if (p + BIT16SZ > ebuf)
            return 0;
        const ns: usize = GBIT16(buf, p);
        p += BIT16SZ;
        if (p + ns > ebuf)
            return 0;
        if (strs) |s| {
            // DIFF: the C does not know how big strs is
            if (ns + 1 > s.len - sp)
                return 0;
            sv[i] = s[sp..][0..ns];
            @memmove(s[sp..][0..ns], buf[p..][0..ns]);
            sp += ns;
            s[sp] = 0;
            sp += 1;
        }
        p += ns;
    }

    if (strs != null) {
        d.name = sv[0];
        d.uid = sv[1];
        d.gid = sv[2];
        d.muid = sv[3];
    } else {
        d.name = nullstring;
        d.uid = nullstring;
        d.gid = nullstring;
        d.muid = nullstring;
    }

    return p;
}

//
// tests
//

const testing = std.testing;

fn expectEqualQid(a: Qid, b: Qid) !void {
    try testing.expectEqual(a.path, b.path);
    try testing.expectEqual(a.vers, b.vers);
    try testing.expectEqual(a.type, b.type);
}

/// Compare every member.  Both sides start from the defaults, so the
/// members a message type does not carry must still be at their defaults.
fn expectEqualFcall(a: *const Fcall, b: *const Fcall) !void {
    try testing.expectEqual(a.type, b.type);
    try testing.expectEqual(a.fid, b.fid);
    try testing.expectEqual(a.tag, b.tag);
    try testing.expectEqual(a.msize, b.msize);
    try testing.expectEqualStrings(a.version, b.version);
    try testing.expectEqual(a.oldtag, b.oldtag);
    try testing.expectEqualStrings(a.ename, b.ename);
    try expectEqualQid(a.qid, b.qid);
    try testing.expectEqual(a.iounit, b.iounit);
    try expectEqualQid(a.aqid, b.aqid);
    try testing.expectEqual(a.afid, b.afid);
    try testing.expectEqualStrings(a.uname, b.uname);
    try testing.expectEqualStrings(a.aname, b.aname);
    try testing.expectEqual(a.perm, b.perm);
    try testing.expectEqualStrings(a.name, b.name);
    try testing.expectEqual(a.mode, b.mode);
    try testing.expectEqual(a.newfid, b.newfid);
    try testing.expectEqual(a.nwname, b.nwname);
    for (0..MAXWELEM) |i|
        try testing.expectEqualStrings(a.wname[i], b.wname[i]);
    try testing.expectEqual(a.nwqid, b.nwqid);
    for (0..MAXWELEM) |i|
        try expectEqualQid(a.wqid[i], b.wqid[i]);
    try testing.expectEqual(a.offset, b.offset);
    try testing.expectEqual(a.count, b.count);
    try testing.expectEqualSlices(u8, a.data, b.data);
    try testing.expectEqual(a.nstat, b.nstat);
    try testing.expectEqualSlices(u8, a.stat, b.stat);
}

const test_dir: Dir = .{
    .type = 'M',
    .dev = 1,
    .qid = .{ .path = 0x0102030405060708, .vers = 2, .type = QTDIR },
    .mode = DMDIR | 0o755,
    .atime = 0x11223344,
    .mtime = 0x55667788,
    .length = 0,
    .name = "a",
    .uid = "b",
    .gid = "c",
    .muid = "",
};

// test_dir on the wire, computed by hand
const test_stat = [_]u8{
    0x32, 0x00, // size, excluding itself: 50
    0x4d, 0x00, // type
    0x01, 0x00, 0x00, 0x00, // dev
    0x80, // qid.type
    0x02, 0x00, 0x00, 0x00, // qid.vers
    0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01, // qid.path
    0xed, 0x01, 0x00, 0x80, // mode
    0x44, 0x33, 0x22, 0x11, // atime
    0x88, 0x77, 0x66, 0x55, // mtime
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // length
    0x01, 0x00, 'a', // name
    0x01, 0x00, 'b', // uid
    0x01, 0x00, 'c', // gid
    0x00, 0x00, // muid
};

/// One of every T and R message, with every member it carries set to
/// something that is not the default.
fn testMessages() [27]Fcall {
    const q1: Qid = .{ .path = 0xfedcba9876543210, .vers = 0xdeadbeef, .type = QTDIR };
    const q2: Qid = .{ .path = 7, .vers = 9, .type = QTAPPEND | QTTMP };
    var twalk: Fcall = .{ .type = Twalk, .tag = 7, .fid = 1, .newfid = 2, .nwname = MAXWELEM };
    var rwalk: Fcall = .{ .type = Rwalk, .tag = 7, .nwqid = MAXWELEM };
    const names = [MAXWELEM][]const u8{
        "usr",  "glenda", "lib", "profile", "",  "a", "bb", "ccc",
        "dddd", "e",      "f",   "g",       "h", "i", "j",  "last",
    };
    for (0..MAXWELEM) |i| {
        twalk.wname[i] = names[i];
        rwalk.wqid[i] = .{ .path = 0x100000000 + i, .vers = @intCast(i * 3), .type = @intCast(i) };
    }
    return .{
        .{ .type = Tversion, .tag = NOTAG, .msize = 8192 + IOHDRSZ, .version = VERSION9P },
        .{ .type = Rversion, .tag = NOTAG, .msize = 8192, .version = "9P2000" },
        .{ .type = Tauth, .tag = 1, .afid = 0x01020304, .uname = "glenda", .aname = "main/active" },
        .{ .type = Rauth, .tag = 1, .aqid = q2 },
        .{ .type = Tattach, .tag = 2, .fid = 0x0a0b0c0d, .afid = NOFID, .uname = "glenda", .aname = "" },
        .{ .type = Rattach, .tag = 2, .qid = q1 },
        .{ .type = Rerror, .tag = 3, .ename = "file does not exist" },
        .{ .type = Tflush, .tag = 4, .oldtag = 0xbeef },
        .{ .type = Rflush, .tag = 4 },
        twalk,
        rwalk,
        .{ .type = Topen, .tag = 8, .fid = 5, .mode = 0x12 },
        .{ .type = Ropen, .tag = 8, .qid = q1, .iounit = 8192 },
        .{ .type = Tcreate, .tag = 9, .fid = 6, .name = "newfile", .perm = DMDIR | 0o775, .mode = 1 },
        .{ .type = Rcreate, .tag = 9, .qid = q2, .iounit = 0x10203040 },
        .{ .type = Tread, .tag = 10, .fid = 7, .offset = 0x0102030405060708, .count = 4096 },
        .{ .type = Rread, .tag = 10, .count = 5, .data = "hello" },
        .{ .type = Twrite, .tag = 11, .fid = 8, .offset = -1, .count = 6, .data = "world\n" },
        .{ .type = Rwrite, .tag = 11, .count = 6 },
        .{ .type = Tclunk, .tag = 12, .fid = 9 },
        .{ .type = Rclunk, .tag = 12 },
        .{ .type = Tremove, .tag = 13, .fid = 10 },
        .{ .type = Rremove, .tag = 13 },
        .{ .type = Tstat, .tag = 14, .fid = 11 },
        .{ .type = Rstat, .tag = 14, .nstat = test_stat.len, .stat = &test_stat },
        .{ .type = Twstat, .tag = 15, .fid = 12, .nstat = test_stat.len, .stat = &test_stat },
        .{ .type = Rwstat, .tag = 15 },
    };
}

test "constants" {
    try testing.expectEqual(13, QIDSZ);
    try testing.expectEqual(49, STATFIXLEN);
    try testing.expectEqual(128, Tmax);
    try testing.expectEqual(0xffff, NOTAG);
    try testing.expectEqual(0xffffffff, NOFID);
}

test "every message type round trips" {
    const msgs = testMessages();

    // every type from Tversion to Rwstat is there, except Terror
    var seen: [Tmax]bool = @splat(false);
    for (&msgs) |*f|
        seen[f.type] = true;
    for (Tversion..Tmax) |t|
        try testing.expectEqual(t != Terror, seen[t]);

    var buf: [1024]u8 = undefined;
    for (&msgs) |*f| {
        @memset(&buf, 0xaa);
        const n = convS2M(f, &buf);
        try testing.expect(n != 0);
        try testing.expectEqual(sizeS2M(f), n);
        try testing.expectEqual(n, GBIT32(&buf, 0));
        try testing.expectEqual(f.type, buf[4]);
        // nothing written past the message
        for (buf[n..]) |c|
            try testing.expectEqual(0xaa, c);

        // exact buffer
        var g: Fcall = .{};
        try testing.expectEqual(n, convM2S(buf[0..n], &g));
        try expectEqualFcall(f, &g);

        // a buffer longer than the message is fine, as in C
        var h: Fcall = .{};
        try testing.expectEqual(n, convM2S(&buf, &h));
        try expectEqualFcall(f, &h);

        // convM2S left the message alone and its slices alias it:
        // encoding the decoded Fcall back in place gives the same bytes
        var copy: [1024]u8 = undefined;
        @memcpy(copy[0..n], buf[0..n]);
        try testing.expectEqual(n, convS2M(&g, buf[0..n]));
        try testing.expectEqualSlices(u8, copy[0..n], buf[0..n]);
    }
}

test "decoded slices alias the message" {
    var buf: [64]u8 = undefined;
    const f: Fcall = .{ .type = Rread, .tag = 1, .count = 3, .data = "abc" };
    const n = convS2M(&f, &buf);
    var g: Fcall = .{};
    try testing.expectEqual(n, convM2S(buf[0..n], &g));
    try testing.expectEqual(@intFromPtr(&buf[11]), @intFromPtr(g.data.ptr));
    try testing.expectEqual(3, g.data.len);
}

fn expectWire(f: *const Fcall, wire: []const u8) !void {
    var buf: [256]u8 = undefined;
    const n = convS2M(f, &buf);
    try testing.expectEqualSlices(u8, wire, buf[0..n]);
    var g: Fcall = .{};
    try testing.expectEqual(wire.len, convM2S(wire, &g));
    try expectEqualFcall(f, &g);
}

test "wire bytes: Tversion" {
    try expectWire(&.{ .type = Tversion, .tag = NOTAG, .msize = 8192, .version = "9P2000" }, &[_]u8{
        0x13, 0x00, 0x00, 0x00, // size 19
        100, // Tversion
        0xff, 0xff, // tag
        0x00, 0x20, 0x00, 0x00, // msize
        0x06, 0x00, '9', 'P', '2', '0', '0', '0', // version
    });
}

test "wire bytes: Twalk" {
    var f: Fcall = .{ .type = Twalk, .tag = 1, .fid = 2, .newfid = 3, .nwname = 2 };
    f.wname[0] = "usr";
    f.wname[1] = "glenda";
    try expectWire(&f, &[_]u8{
        0x1e, 0x00, 0x00, 0x00, // size 30
        110, // Twalk
        0x01, 0x00, // tag
        0x02, 0x00, 0x00, 0x00, // fid
        0x03, 0x00, 0x00, 0x00, // newfid
        0x02, 0x00, // nwname
        0x03, 0x00, 'u', 's', 'r', // wname[0]
        0x06, 0x00, 'g', 'l', 'e', 'n', 'd', 'a', // wname[1]
    });
}

test "wire bytes: Rerror" {
    try expectWire(&.{ .type = Rerror, .tag = 5, .ename = "no" }, &[_]u8{
        0x0b, 0x00, 0x00, 0x00, // size 11
        107, // Rerror
        0x05, 0x00, // tag
        0x02, 0x00, 'n', 'o', // ename
    });
}

test "wire bytes: Rread" {
    try expectWire(&.{ .type = Rread, .tag = 0x1234, .count = 3, .data = "abc" }, &[_]u8{
        0x0e, 0x00, 0x00, 0x00, // size 14
        117, // Rread
        0x34, 0x12, // tag
        0x03, 0x00, 0x00, 0x00, // count
        'a', 'b', 'c', // data
    });
}

test "wire bytes: Rstat" {
    const head = [_]u8{
        0x3d, 0x00, 0x00, 0x00, // size 61
        125, // Rstat
        0x01, 0x00, // tag
        0x34, 0x00, // nstat 52
    };
    try expectWire(&.{ .type = Rstat, .tag = 1, .nstat = test_stat.len, .stat = &test_stat }, &(head ++ test_stat));
}

test "Dir round trip" {
    var buf: [128]u8 = undefined;
    @memset(&buf, 0xaa);

    try testing.expectEqual(test_stat.len, sizeD2M(&test_dir));
    const n = convD2M(&test_dir, &buf);
    try testing.expectEqual(test_stat.len, n);
    try testing.expectEqualSlices(u8, &test_stat, buf[0..n]);
    for (buf[n..]) |c|
        try testing.expectEqual(0xaa, c);
    try testing.expectEqual(0, statcheck(buf[0..n]));

    var strs: [test_stat.len - STATFIXLEN + 4]u8 = undefined;
    var d: Dir = .{};
    try testing.expectEqual(n, convM2D(buf[0..n], &d, &strs));
    try testing.expectEqual(test_dir.type, d.type);
    try testing.expectEqual(test_dir.dev, d.dev);
    try expectEqualQid(test_dir.qid, d.qid);
    try testing.expectEqual(test_dir.mode, d.mode);
    try testing.expectEqual(test_dir.atime, d.atime);
    try testing.expectEqual(test_dir.mtime, d.mtime);
    try testing.expectEqual(test_dir.length, d.length);
    try testing.expectEqualStrings("a", d.name);
    try testing.expectEqualStrings("b", d.uid);
    try testing.expectEqualStrings("c", d.gid);
    try testing.expectEqualStrings("", d.muid);
    // the strings are NUL-terminated copies in strs, not in buf
    try testing.expectEqualSlices(u8, "a\x00b\x00c\x00\x00", &strs);
    try testing.expectEqual(@intFromPtr(&strs[0]), @intFromPtr(d.name.ptr));
    try testing.expectEqual(@intFromPtr(&strs[2]), @intFromPtr(d.uid.ptr));

    // string area one byte too small
    var d2: Dir = .{};
    try testing.expectEqual(0, convM2D(buf[0..n], &d2, strs[0 .. strs.len - 1]));

    // without a string area the names are empty
    var d3: Dir = .{ .name = "x", .uid = "x", .gid = "x", .muid = "x" };
    try testing.expectEqual(n, convM2D(buf[0..n], &d3, null));
    try testing.expectEqual(test_dir.mtime, d3.mtime);
    try testing.expectEqualStrings("", d3.name);
    try testing.expectEqualStrings("", d3.uid);
    try testing.expectEqualStrings("", d3.gid);
    try testing.expectEqualStrings("", d3.muid);

    // trailing bytes after the stat are not consumed
    try testing.expectEqual(n, convM2D(&buf, &d3, null));

    // negative length and longer names survive
    const big: Dir = .{ .length = -2, .name = "a long file name", .uid = "glenda", .gid = "sys", .muid = "bootes" };
    const m = convD2M(&big, &buf);
    try testing.expectEqual(sizeD2M(&big), m);
    try testing.expectEqual(0, statcheck(buf[0..m]));
    var strs2: [64]u8 = undefined;
    var d4: Dir = .{};
    try testing.expectEqual(m, convM2D(buf[0..m], &d4, &strs2));
    try testing.expectEqual(-2, d4.length);
    try testing.expectEqualStrings(big.name, d4.name);
    try testing.expectEqualStrings(big.uid, d4.uid);
    try testing.expectEqualStrings(big.gid, d4.gid);
    try testing.expectEqualStrings(big.muid, d4.muid);
}

test "convD2M into a small buffer" {
    var buf: [test_stat.len]u8 = undefined;

    try testing.expectEqual(0, convD2M(&test_dir, buf[0..0]));
    try testing.expectEqual(0, convD2M(&test_dir, buf[0..1]));
    // from 2 bytes up to one short: only the size is written
    for (BIT16SZ..test_stat.len) |n| {
        @memset(&buf, 0xaa);
        try testing.expectEqual(BIT16SZ, convD2M(&test_dir, buf[0..n]));
        try testing.expectEqual(test_stat.len - BIT16SZ, GBIT16(&buf, 0));
        for (buf[BIT16SZ..]) |c|
            try testing.expectEqual(0xaa, c);
    }
    try testing.expectEqual(test_stat.len, convD2M(&test_dir, &buf));
}

test "convD2M with a stat too long for its size field" {
    const long: [40000]u8 = @splat('x');
    var buf: [2 * 40000 + STATFIXLEN]u8 = undefined;
    const d: Dir = .{ .name = &long, .uid = &long };
    try testing.expectEqual(0, convD2M(&d, &buf));
    // the largest that fits
    const d2: Dir = .{ .name = &long, .uid = long[0 .. STATMAX + BIT16SZ - STATFIXLEN - 40000] };
    try testing.expectEqual(STATMAX + BIT16SZ, convD2M(&d2, &buf));
    try testing.expectEqual(0, statcheck(buf[0 .. STATMAX + BIT16SZ]));
}

test "statcheck and convM2D reject truncated and corrupted stats" {
    var buf: [test_stat.len + 8]u8 = undefined;
    var strs: [64]u8 = undefined;
    var d: Dir = .{};

    // truncated at every length
    for (0..test_stat.len) |n| {
        try testing.expectEqual(-1, statcheck(test_stat[0..n]));
        try testing.expectEqual(0, convM2D(test_stat[0..n], &d, &strs));
        try testing.expectEqual(0, convM2D(test_stat[0..n], &d, null));
    }
    // too long for its size field
    @memset(&buf, 0);
    @memcpy(buf[0..test_stat.len], &test_stat);
    try testing.expectEqual(-1, statcheck(buf[0 .. test_stat.len + 1]));

    // wrong size field
    for ([_]u16{ 0, 49, 51, 0xffff }) |sz| {
        @memcpy(buf[0..test_stat.len], &test_stat);
        PBIT16(&buf, 0, sz);
        try testing.expectEqual(-1, statcheck(buf[0..test_stat.len]));
    }

    // each string count in turn too long, too short, enormous
    const counts = [_]usize{ STATFIXLEN - 8, STATFIXLEN - 8 + 3, STATFIXLEN - 8 + 6, STATFIXLEN - 8 + 9 };
    for (counts) |off| {
        for ([_]u16{ 0, 2, 3, 0x7fff, 0xffff }) |c| {
            @memcpy(buf[0..test_stat.len], &test_stat);
            if (GBIT16(&buf, off) == c)
                continue;
            PBIT16(&buf, off, c);
            try testing.expectEqual(-1, statcheck(buf[0..test_stat.len]));
            // convM2D must not run off the end whatever it returns
            _ = convM2D(buf[0..test_stat.len], &d, &strs);
            _ = convM2D(buf[0..test_stat.len], &d, null);
        }
    }

    // every byte smashed: no panic, and statcheck passing means convM2D
    // consumes exactly the buffer
    for (0..test_stat.len) |i| {
        for ([_]u8{ 0x00, 0x01, 0x7f, 0xff }) |c| {
            @memcpy(buf[0..test_stat.len], &test_stat);
            buf[i] = c;
            const ok = statcheck(buf[0..test_stat.len]) == 0;
            const n = convM2D(buf[0..test_stat.len], &d, &strs);
            if (ok)
                try testing.expectEqual(test_stat.len, n);
        }
    }
}

test "truncated messages fail at every prefix length" {
    const msgs = testMessages();
    var buf: [1024]u8 = undefined;
    for (&msgs) |*f| {
        const n = convS2M(f, &buf);
        try testing.expect(n != 0);
        // the slice is cut to the prefix, so reaching past it would trip
        // the bounds check and fail the test
        for (0..n) |len| {
            var g: Fcall = .{};
            try testing.expectEqual(0, convM2S(buf[0..len], &g));
        }
    }
}

test "size field that disagrees with the message" {
    const msgs = testMessages();
    var buf: [1024]u8 = undefined;
    for (&msgs) |*f| {
        @memset(&buf, 0);
        const n = convS2M(f, &buf);
        var g: Fcall = .{};
        for ([_]u32{ 0, 6, @intCast(n - 1), @intCast(n + 1), 0xffffffff }) |sz| {
            PBIT32(&buf, 0, sz);
            // with the exact buffer and with room to spare
            try testing.expectEqual(0, convM2S(buf[0..n], &g));
            try testing.expectEqual(0, convM2S(&buf, &g));
        }
    }
}

test "corrupted messages do not reach outside the buffer" {
    const msgs = testMessages();
    var buf: [1024]u8 = undefined;
    var m: [1024]u8 = undefined;
    for (&msgs) |*f| {
        const n = convS2M(f, &buf);
        for (0..n) |i| {
            for ([_]u8{ 0x00, 0x01, 0x11, 0x7f, 0x80, 0xff }) |c| {
                @memcpy(m[0..n], buf[0..n]);
                m[i] = c;
                var g: Fcall = .{};
                const r = convM2S(m[0..n], &g);
                try testing.expect(r == 0 or r == n);
            }
        }
    }
}

test "unknown and illegal message types" {
    var buf = [_]u8{ 7, 0, 0, 0, 0, 1, 0 };
    var f: Fcall = .{};
    for (0..256) |t| {
        buf[4] = @intCast(t);
        const want: usize = switch (t) {
            Rflush, Rclunk, Rremove, Rwstat => 7,
            else => 0,
        };
        try testing.expectEqual(want, convM2S(&buf, &f));

        const g: Fcall = .{ .type = @intCast(t) };
        var out: [64]u8 = undefined;
        const known = t >= Tversion and t < Tmax and t != Terror;
        try testing.expectEqual(known, sizeS2M(&g) != 0);
        try testing.expectEqual(known, convS2M(&g, &out) != 0);
    }
}

test "too many names or qids" {
    var buf: [256]u8 = undefined;

    // Twalk with 17 names, built by hand
    var p: usize = 0;
    const n = BIT32SZ + BIT8SZ + BIT16SZ + BIT32SZ + BIT32SZ + BIT16SZ + (MAXWELEM + 1) * (BIT16SZ + 1);
    PBIT32(&buf, p, n);
    p += BIT32SZ;
    PBIT8(&buf, p, Twalk);
    p += BIT8SZ;
    PBIT16(&buf, p, 1);
    p += BIT16SZ;
    PBIT32(&buf, p, 2);
    p += BIT32SZ;
    PBIT32(&buf, p, 3);
    p += BIT32SZ;
    PBIT16(&buf, p, MAXWELEM + 1);
    p += BIT16SZ;
    for (0..MAXWELEM + 1) |_| {
        PBIT16(&buf, p, 1);
        p += BIT16SZ;
        buf[p] = 'x';
        p += 1;
    }
    try testing.expectEqual(n, p);
    var f: Fcall = .{};
    try testing.expectEqual(0, convM2S(buf[0..n], &f));
    // with 16 it is accepted
    PBIT16(&buf, 15, MAXWELEM);
    PBIT32(&buf, 0, n - 3);
    try testing.expectEqual(n - 3, convM2S(buf[0 .. n - 3], &f));
    try testing.expectEqual(MAXWELEM, f.nwname);
    try testing.expectEqualStrings("x", f.wname[MAXWELEM - 1]);

    // Rwalk with 17 qids
    var big: [BIT32SZ + BIT8SZ + BIT16SZ + BIT16SZ + (MAXWELEM + 1) * QIDSZ]u8 = @splat(0);
    PBIT32(&big, 0, big.len);
    PBIT8(&big, 4, Rwalk);
    PBIT16(&big, 7, MAXWELEM + 1);
    try testing.expectEqual(0, convM2S(&big, &f));
    PBIT16(&big, 7, MAXWELEM);
    PBIT32(&big, 0, big.len - QIDSZ);
    try testing.expectEqual(big.len - QIDSZ, convM2S(&big, &f));

    // and the other way
    var out: [1024]u8 = undefined;
    const tw: Fcall = .{ .type = Twalk, .nwname = MAXWELEM + 1 };
    try testing.expectEqual(0, sizeS2M(&tw));
    try testing.expectEqual(0, convS2M(&tw, &out));
    const rw: Fcall = .{ .type = Rwalk, .nwqid = MAXWELEM + 1 };
    try testing.expectEqual(0, convS2M(&rw, &out));
}

test "convS2M into a buffer that is too small" {
    const msgs = testMessages();
    var buf: [1024]u8 = undefined;
    for (&msgs) |*f| {
        const n = sizeS2M(f);
        for (0..n) |len| {
            @memset(&buf, 0xaa);
            try testing.expectEqual(0, convS2M(f, buf[0..len]));
            // refused before anything is written
            for (buf) |c|
                try testing.expectEqual(0xaa, c);
        }
        try testing.expectEqual(n, convS2M(f, buf[0..n]));
    }
}

test "convS2M refuses what it cannot encode" {
    var buf: [70000]u8 = undefined;
    const long: [65536]u8 = @splat('x');

    // data and stat shorter than their counts
    try testing.expectEqual(0, convS2M(&.{ .type = Rread, .count = 4, .data = "abc" }, &buf));
    try testing.expectEqual(0, convS2M(&.{ .type = Twrite, .count = 4, .data = "abc" }, &buf));
    try testing.expectEqual(0, convS2M(&.{ .type = Rstat, .nstat = 4, .stat = "abc" }, &buf));
    try testing.expectEqual(0, convS2M(&.{ .type = Twstat, .nstat = 4, .stat = "abc" }, &buf));
    // longer is fine: count says how much is sent
    try testing.expectEqual(7 + 4 + 2, convS2M(&.{ .type = Rread, .count = 2, .data = "abc" }, &buf));
    try testing.expectEqualSlices(u8, "ab", buf[11..13]);

    // strings: 65535 is the limit
    try testing.expectEqual(0, convS2M(&.{ .type = Rerror, .ename = &long }, &buf));
    try testing.expectEqual(7 + 2 + 65535, convS2M(&.{ .type = Rerror, .ename = long[0..65535] }, &buf));
    var f: Fcall = .{};
    try testing.expectEqual(7 + 2 + 65535, convM2S(buf[0 .. 7 + 2 + 65535], &f));
    try testing.expectEqual(65535, f.ename.len);
}
