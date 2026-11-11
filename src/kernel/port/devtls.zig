//! devtls - record layer for transport layer security 1.2 (#a).
//! The handshake is done by user programs (libsec's tlshand), which
//! give this device a connection (`fd`), the protocol version and the
//! keys (`secret`), and then read and write `hand` and `data`.
//! from 9/port/devtls.c
//!
//! DIFF:
//!   - Cryptography is std.crypto instead of libsec.  A Secret holds its
//!     cipher state in a tagged union (`enckey`) inside the Secret, which
//!     is itself secalloc'ed, where the C allocates the state separately.
//!   - Not ported: the `rc4_128` and `3des_ede_cbc` ciphers, the `md5`
//!     MAC, and the SSL 3.0 MACs (sslmac_md5, sslmac_sha1, sslmac_x).
//!     They are broken algorithms that no current server negotiates.
//!     They are not in the tables, so `encalgs` and `hashalgs` do not
//!     list them and a `secret` naming them fails as any unknown
//!     algorithm does.  With no SSL 3.0 MAC, `sha1` under version 0x300
//!     fails with "sha1 cannot be used with SSL", as sha256 does in the
//!     C; the rest of the SSL 3.0 handling (sslPackAAD, sslunpad, the
//!     alert numbers) is kept.
//!   - A Secret's `mac` computes the MAC of two pieces (the header data
//!     and the body) in one call; the C calls it twice with a
//!     DigestState carried between.  packMac hides the difference.
//!   - AES is built here (setupAESstate, aes_encrypt, aes_decrypt) from
//!     std.crypto.core.aes.Block, the single-round interface, and AES-GCM
//!     (setupAESGCMstate, aesgcm_encrypt, aesgcm_decrypt) from that and
//!     std's Ghash, following std's aes_gcm.zig.  std's own AES contexts
//!     and its AesGcm cannot be used in the kernel: without AES
//!     instructions (kernel code has no SSE registers) they are a
//!     bitsliced implementation whose contexts are 3-4K each and are
//!     passed by value, which gave stack frames of 8-12K on 8K kernel
//!     stacks.  The round functions keep std's protection against
//!     cache-timing side channels (they read every cache line of a table).
//!   - The ChaCha20-Poly1305 state keeps the key bytes; std's functions
//!     take the key for each record.
//!   - ccpoly64_aead (the draft construction with a 64-bit nonce) is
//!     composed here from std's ChaCha20 and Poly1305 exactly as
//!     libsec's ccpoly.c does; std has no AEAD for it.
//!   - Errors are Zig error returns.  tlsrecread's two waserror regions
//!     are the functions tlsrecreadhdr and tlsrecreadbody, and the
//!     switch in tlswrite's ctl case is tlsctl, so that their clean-up
//!     can be written once around the call.
//!   - rcvError and rcvAlert return the error for the caller to return.
//!   - Dev.bread cannot return nil: the connection's bread gives an
//!     empty block when it has hung up, which ensure() treats as the C
//!     treats an empty list.
//!   - tlsopen checks the open mode before it does anything else, so a
//!     bad mode cannot leave a reference or a new conversation behind
//!     (as devpipe).
//!   - Fixed relative to the C: tlsrecwrite sets the length of a record
//!     cut from a block longer than MaxRecLen when there is no cipher
//!     (the C leaves the new block empty), and frees the record when
//!     `changecipher` finds no new cipher (the C leaks it); a block
//!     handed to qbwrite for the handshake queue is not freed again if
//!     qbwrite fails; tlshangup frees the whole list of unprocessed
//!     blocks, not only the first.
//!   - The %H format (fmtinstall in tlsinit) is not needed: nothing
//!     prints with it.
//!   - tlswstat allocates the buffer for the Dir's strings before it
//!     takes tdlock, not under it.
//!   - The debugging prints call pprint out of line, so that its buffer
//!     is not part of every stack frame here.
//!   - dec64 (libc) and tsmemcmp (libsec) are private here; MACs and
//!     tags are compared with std.crypto.timing_safe.

const std = @import("std");
const fcall = @import("fcall");
const fmt = @import("fmt");
const arch = @import("../arch.zig");
const portdat = @import("portdat.zig");
const lib = @import("lib.zig");
const taslock = @import("taslock.zig");
const ql = @import("qlock.zig");
const alloc = @import("alloc.zig");
const ab = @import("allocb.zig");
const qio = @import("qio.zig");
const proc = @import("proc.zig");
const chan = @import("chan.zig");
const devmod = @import("dev.zig");
const devcons = @import("devcons.zig");
const parse = @import("parse.zig");
const netif = @import("netif.zig");
const random = @import("random.zig");
const sysfile = @import("sysfile.zig");
const p9 = @import("print.zig");

const crypto = std.crypto;
const aes = crypto.core.aes;
const Poly1305 = crypto.onetimeauth.Poly1305;
const ChaCha20Poly1305 = crypto.aead.chacha_poly.ChaCha20Poly1305;
const ChaCha20With64BitNonce = crypto.stream.chacha.ChaCha20With64BitNonce;
const Ghash = crypto.onetimeauth.Ghash;
const HmacSha1 = crypto.auth.hmac.HmacSha1;
const HmacSha256 = crypto.auth.hmac.sha2.HmacSha256;

const panic = p9.panic;
const readstr = devcons.readstr;
const lock = taslock.lock;
const unlock = taslock.unlock;
const qlock = ql.qlock;
const qunlock = ql.qunlock;
const devdir = devmod.devdir;
const allocb = ab.allocb;
const freeb = ab.freeb;
const BLEN = ab.BLEN;
const errorf = proc.errorf;

/// devcons.pprint, kept out of line: its buffer is 512 bytes of stack
/// that only a connection being debugged should pay for.
fn pprint(comptime format: []const u8, args: anytype) usize {
    return @call(.never_inline, devcons.pprint, .{ format, args });
}

pub const Error = proc.Error;
const Chan = portdat.Chan;
const Walkqid = portdat.Walkqid;
const Qid = portdat.Qid;
const Dir = portdat.Dir;
const Lock = portdat.Lock;
const QLock = portdat.QLock;
const Queue = qio.Queue;
const Block = ab.Block;
const Dirtab = devmod.Dirtab;
const Cmdbuf = parse.Cmdbuf;
const QTDIR = fcall.QTDIR;
const QTFILE = fcall.QTFILE;
const DEVDOTDOT = portdat.DEVDOTDOT;
const COPEN = portdat.COPEN;
const ERRMAX = portdat.ERRMAX;

const SHA1dlen = 20;
const SHA2_256dlen = 32;
const Poly1305dlen = 16;
const AESbsize = 16;
const ChachaIVlen = 12;

const Statlen = 1024; // max. length of status or stats message
// buffer limits
const MaxRecLen = 1 << 14; // max payload length of a record layer message
const MaxCipherRecLen = MaxRecLen + 2048;
const RecHdrLen = 5;
const MaxMacLen = SHA2_256dlen;

// protocol versions we can accept
const SSL3Version = 0x0300;
const TLS10Version = 0x0301;
const TLS11Version = 0x0302;
const TLS12Version = 0x0303;
const MinProtoVersion = 0x0300; // limits on version we accept
const MaxProtoVersion = 0x03ff;

// connection states
const SHandshake: u32 = 1 << 0; // doing handshake
const SOpen: u32 = 1 << 1; // application data can be sent
const SRClose: u32 = 1 << 2; // remote side has closed down
const SLClose: u32 = 1 << 3; // sent a close notify alert
const SAlert: u32 = 1 << 5; // sending or sent a fatal alert
const SError: u32 = 1 << 6; // some sort of error has occured
const SClosed: u32 = 1 << 7; // it is all over

// record types
const RChangeCipherSpec = 20;
const RAlert = 21;
const RHandshake = 22;
const RApplication = 23;

const SSL2ClientHello = 1;
const HSSL2ClientHello = 9; // local convention;  see tlshand.c

// alerts
const ECloseNotify = 0;
const EUnexpectedMessage = 10;
const EBadRecordMac = 20;
const EDecryptionFailed = 21;
const ERecordOverflow = 22;
const EDecompressionFailure = 30;
const EHandshakeFailure = 40;
const ENoCertificate = 41;
const EBadCertificate = 42;
const EUnsupportedCertificate = 43;
const ECertificateRevoked = 44;
const ECertificateExpired = 45;
const ECertificateUnknown = 46;
const EIllegalParameter = 47;
const EUnknownCa = 48;
const EAccessDenied = 49;
const EDecodeError = 50;
const EDecryptError = 51;
const EExportRestriction = 60;
const EProtocolVersion = 70;
const EInsufficientSecurity = 71;
const EInternalError = 80;
const EUserCanceled = 90;
const ENoRenegotiation = 100;
const EUnrecognizedName = 112;

const EMAX = 256;

/// The MAC of aad followed by body, keyed with key, into digest (see DIFF).
const Macfn = *const fn (aad: []const u8, body: []const u8, key: []const u8, digest: []u8) void;

const AESmaxrounds = 14;

/// libsec's AESstate, as far as CBC needs it.  The round keys are kept
/// as bytes: an aes.Block wants 16-byte alignment, which malloc does
/// not promise.
const AESstate = struct {
    rounds: usize = 0,
    ekey: [AESmaxrounds + 1][AESbsize]u8 = undefined, // encryption key
    dkey: [AESmaxrounds + 1][AESbsize]u8 = undefined, // decryption key
    ivec: [AESbsize]u8 = @splat(0),
};

/// libsec's Chachastate, as far as ccpoly needs it: the iv is set for
/// each record.
const Chachastate = struct {
    key: [32]u8,
    iv: [ChachaIVlen]u8 = @splat(0),
    ivwords: u8, // 2: 64-bit nonce (draft), 3: 96-bit nonce (IETF)
};

/// libsec's AESGCMstate: the key, the hash key H (the encryption of a
/// zero block) and the iv of the record being worked on.
const AESGCMstate = struct {
    a: AESstate = .{},
    h: [16]u8 = @splat(0),
    iv: [12]u8 = @splat(0),
};

const Enckey = union(enum) {
    none,
    aes: AESstate,
    chacha: Chachastate,
    aesgcm: AESGCMstate,
};

const Secret = struct {
    encalg: []const u8 = "", // name of encryption alg
    hashalg: []const u8 = "", // name of hash alg

    aead_enc: ?*const fn (sec: *Secret, aad: []const u8, reciv: [*]u8, data: [*]u8, len: i32) i32 = null,
    aead_dec: ?*const fn (sec: *Secret, aad: []const u8, reciv: [*]u8, data: [*]u8, len: i32) i32 = null,

    enc: ?*const fn (sec: *Secret, buf: [*]u8, n: i32) i32 = null,
    dec: ?*const fn (sec: *Secret, buf: [*]u8, n: i32) i32 = null,
    unpad: ?*const fn (buf: [*]u8, n: i32, block: i32) i32 = null,
    mac: ?Macfn = null,

    block: i32 = 0, // encryption block len, 0 if none
    maclen: i32 = 0, // # bytes of record mac / authentication tag
    recivlen: i32 = 0, // # bytes of record iv for AEAD ciphers
    enckey: Enckey = .none,
    mackey: [MaxMacLen]u8 = @splat(0),
};

const OneWay = struct {
    io: QLock = .{}, // locks io access
    seclock: QLock = .{}, // locks secret paramaters
    seq: u64 = 0,
    sec: ?*Secret = null, // cipher in use
    new: ?*Secret = null, // cipher waiting for enable
};

const TlsRec = struct {
    c: ?*Chan = null, // io channel
    ref: i32 = 0, // serialized by tdlock for atomic destroy
    version: i32 = 0, // version of the protocol we are speaking
    verset: bool = false, // version has been set
    opened: bool = false, // opened command every issued?
    err: [ERRMAX]u8 = @splat(0), // error message to return to handshake requests
    handin: i64 = 0, // bytes communicated by the record layer
    handout: i64 = 0,
    datain: i64 = 0,
    dataout: i64 = 0,

    statelk: Lock = .{},
    state: u32 = 0,
    debug: bool = false,

    // function to genrate authenticated data blob for different
    // protocol versions
    packAAD: ?*const fn (seq: u64, hdr: *const [RecHdrLen]u8, aad: *[8 + RecHdrLen]u8) usize = null,

    // input side -- protected by in.io
    in: OneWay = .{},
    processed: ?*Block = null, // next bunch of application data
    unprocessed: ?*Block = null, // data read from c but not parsed into records

    // handshake queue
    hqlock: Lock = .{}, // protects hqref, alloc & free of handq, hprocessed
    hqref: i32 = 0,
    handq: ?*Queue = null, // queue of handshake messages
    hprocessed: ?*Block = null, // remainder of last block read from handq
    hqread: QLock = .{}, // protects reads for hprocessed, handq

    // output side
    out: OneWay = .{},

    // protections
    user: []u8 = portdat.nostr,
    perm: u32 = 0,
};

const TlsErrs = struct {
    err: i32,
    sslerr: i32,
    tlserr: i32,
    fatal: bool,
    msg: []const u8,
};

const tlserrs = [_]TlsErrs{
    .{ .err = ECloseNotify, .sslerr = ECloseNotify, .tlserr = ECloseNotify, .fatal = false, .msg = "close notify" },
    .{ .err = EUnexpectedMessage, .sslerr = EUnexpectedMessage, .tlserr = EUnexpectedMessage, .fatal = true, .msg = "unexpected message" },
    .{ .err = EBadRecordMac, .sslerr = EBadRecordMac, .tlserr = EBadRecordMac, .fatal = true, .msg = "bad record mac" },
    .{ .err = EDecryptionFailed, .sslerr = EIllegalParameter, .tlserr = EDecryptionFailed, .fatal = true, .msg = "decryption failed" },
    .{ .err = ERecordOverflow, .sslerr = EIllegalParameter, .tlserr = ERecordOverflow, .fatal = true, .msg = "record too long" },
    .{ .err = EDecompressionFailure, .sslerr = EDecompressionFailure, .tlserr = EDecompressionFailure, .fatal = true, .msg = "decompression failed" },
    .{ .err = EHandshakeFailure, .sslerr = EHandshakeFailure, .tlserr = EHandshakeFailure, .fatal = true, .msg = "could not negotiate acceptable security parameters" },
    .{ .err = ENoCertificate, .sslerr = ENoCertificate, .tlserr = ECertificateUnknown, .fatal = true, .msg = "no appropriate certificate available" },
    .{ .err = EBadCertificate, .sslerr = EBadCertificate, .tlserr = EBadCertificate, .fatal = true, .msg = "corrupted or invalid certificate" },
    .{ .err = EUnsupportedCertificate, .sslerr = EUnsupportedCertificate, .tlserr = EUnsupportedCertificate, .fatal = true, .msg = "unsupported certificate type" },
    .{ .err = ECertificateRevoked, .sslerr = ECertificateRevoked, .tlserr = ECertificateRevoked, .fatal = true, .msg = "revoked certificate" },
    .{ .err = ECertificateExpired, .sslerr = ECertificateExpired, .tlserr = ECertificateExpired, .fatal = true, .msg = "expired certificate" },
    .{ .err = ECertificateUnknown, .sslerr = ECertificateUnknown, .tlserr = ECertificateUnknown, .fatal = true, .msg = "unacceptable certificate" },
    .{ .err = EIllegalParameter, .sslerr = EIllegalParameter, .tlserr = EIllegalParameter, .fatal = true, .msg = "illegal parameter" },
    .{ .err = EUnknownCa, .sslerr = EHandshakeFailure, .tlserr = EUnknownCa, .fatal = true, .msg = "unknown certificate authority" },
    .{ .err = EAccessDenied, .sslerr = EHandshakeFailure, .tlserr = EAccessDenied, .fatal = true, .msg = "access denied" },
    .{ .err = EDecodeError, .sslerr = EIllegalParameter, .tlserr = EDecodeError, .fatal = true, .msg = "error decoding message" },
    .{ .err = EDecryptError, .sslerr = EIllegalParameter, .tlserr = EDecryptError, .fatal = true, .msg = "error decrypting message" },
    .{ .err = EExportRestriction, .sslerr = EHandshakeFailure, .tlserr = EExportRestriction, .fatal = true, .msg = "export restriction violated" },
    .{ .err = EProtocolVersion, .sslerr = EIllegalParameter, .tlserr = EProtocolVersion, .fatal = true, .msg = "protocol version not supported" },
    .{ .err = EInsufficientSecurity, .sslerr = EHandshakeFailure, .tlserr = EInsufficientSecurity, .fatal = true, .msg = "stronger security routines required" },
    .{ .err = EInternalError, .sslerr = EHandshakeFailure, .tlserr = EInternalError, .fatal = true, .msg = "internal error" },
    .{ .err = EUserCanceled, .sslerr = ECloseNotify, .tlserr = EUserCanceled, .fatal = false, .msg = "handshake canceled by user" },
    .{ .err = ENoRenegotiation, .sslerr = EUnexpectedMessage, .tlserr = ENoRenegotiation, .fatal = false, .msg = "no renegotiation" },
};

// max. open tls connections
const MaxTlsDevs = 1024;

var tdlock: Lock = .{};
var tdhiwat: usize = 0;
var maxtlsdevs: usize = 128;
var tlsdevs: []?*TlsRec = &.{};
var trnames: []?[]u8 = &.{};
var encalgs: []const u8 = "";
var hashalgs: []const u8 = "";

const Qtopdir = 1; // top level directory
const Qprotodir = 2;
const Qclonus = 3;
const Qencalgs = 4;
const Qhashalgs = 5;
const Qconvdir = 6; // directory for a conversation
const Qdata = 7;
const Qctl = 8;
const Qhand = 9;
const Qstatus = 10;
const Qstats = 11;

fn TYPE(x: Qid) u32 {
    return @intCast(x.path & 0xf);
}

fn CONV(x: Qid) usize {
    return @intCast((x.path >> 5) & (MaxTlsDevs - 1));
}

fn QID(c: usize, y: u32) u64 {
    return (@as(u64, c) << 5) | y;
}

const tlsnames = blk: {
    var t: [Qstats + 1][]const u8 = @splat("");
    t[Qclonus] = "clone";
    t[Qencalgs] = "encalgs";
    t[Qhashalgs] = "hashalgs";
    t[Qdata] = "data";
    t[Qctl] = "ctl";
    t[Qhand] = "hand";
    t[Qstatus] = "status";
    t[Qstats] = "stats";
    break :blk t;
};

const convdir = [_]u32{ Qctl, Qdata, Qhand, Qstatus, Qstats };

fn tlsgen(c: *Chan, _: ?[]const u8, _: []const Dirtab, s_: i32, dp: *Dir) i32 {
    var s = s_;
    var q: Qid = .{ .path = 0, .vers = 0, .type = QTFILE };

    const t = TYPE(c.qid);
    switch (t) {
        Qtopdir => {
            if (s == DEVDOTDOT) {
                q.path = QID(0, Qtopdir);
                q.type = QTDIR;
                devdir(c, q, "#a", 0, proc.eve, 0o555, dp);
                return 1;
            }
            if (s > 0)
                return -1;
            q.path = QID(0, Qprotodir);
            q.type = QTDIR;
            devdir(c, q, "tls", 0, proc.eve, 0o555, dp);
            return 1;
        },
        Qprotodir => {
            if (s == DEVDOTDOT) {
                q.path = QID(0, Qtopdir);
                q.type = QTDIR;
                devdir(c, q, ".", 0, proc.eve, 0o555, dp);
                return 1;
            }
            if (s < 3) {
                switch (s) {
                    0 => q.path = QID(0, Qclonus),
                    1 => q.path = QID(0, Qencalgs),
                    2 => q.path = QID(0, Qhashalgs),
                    else => return -1,
                }
                var perm: u32 = 0o444;
                if (TYPE(q) == Qclonus)
                    perm = 0o555;
                devdir(c, q, tlsnames[TYPE(q)], 0, proc.eve, perm, dp);
                return 1;
            }
            s -= 3;
            const i: usize = @intCast(s);
            if (i >= tdhiwat)
                return -1;
            q.path = QID(i, Qconvdir);
            q.type = QTDIR;
            lock(&tdlock);
            const nm: []const u8 = if (tlsdevs[i]) |tr| tr.user else proc.eve;
            const name = trnames[i] orelse blk: {
                const buf = alloc.smalloc(16);
                const n = fmt.snprint(buf[0..16], "%d", .{s});
                trnames[i] = n;
                break :blk n;
            };
            devdir(c, q, name, 0, nm, 0o555, dp);
            unlock(&tdlock);
            return 1;
        },
        Qconvdir => {
            if (s == DEVDOTDOT) {
                q.path = QID(0, Qprotodir);
                q.type = QTDIR;
                devdir(c, q, "tls", 0, proc.eve, 0o555, dp);
                return 1;
            }
            if (s < 0 or s >= convdir.len)
                return -1;
            lock(&tdlock);
            var nm: []const u8 = proc.eve;
            var perm: u32 = 0;
            if (tlsdevs[CONV(c.qid)]) |tr| {
                nm = tr.user;
                perm = tr.perm;
            }
            const ct = convdir[@intCast(s)];
            if (ct == Qstatus or ct == Qstats)
                perm &= 0o444;
            q.path = QID(CONV(c.qid), ct);
            devdir(c, q, tlsnames[ct], 0, nm, perm, dp);
            unlock(&tdlock);
            return 1;
        },
        Qclonus, Qencalgs, Qhashalgs => {
            var perm: u32 = 0o444;
            if (t == Qclonus)
                perm = 0o555;
            devdir(c, c.qid, tlsnames[t], 0, proc.eve, perm, dp);
            return 1;
        },
        else => {
            lock(&tdlock);
            var nm: []const u8 = proc.eve;
            var perm: u32 = 0;
            if (tlsdevs[CONV(c.qid)]) |tr| {
                nm = tr.user;
                perm = tr.perm;
            }
            if (t == Qstatus or t == Qstats)
                perm &= 0o444;
            devdir(c, c.qid, if (t < tlsnames.len) tlsnames[t] else "", 0, nm, perm, dp);
            unlock(&tdlock);
            return 1;
        },
    }
}

fn tlsattach(spec: []const u8) Error!*Chan {
    const c = devmod.devattach('a', spec);
    c.qid.path = QID(0, Qtopdir);
    c.qid.type = QTDIR;
    c.qid.vers = 0;
    return c;
}

fn tlswalk(c: *Chan, nc: ?*Chan, name: []const []const u8) Error!*Walkqid {
    return devmod.devwalk(c, nc, name, &.{}, tlsgen);
}

fn tlsstat(c: *Chan, db: []u8) Error!usize {
    return devmod.devstat(c, db, &.{}, tlsgen);
}

fn tlsopen(c: *Chan, omode: u32) Error!*Chan {
    // DIFF: checked first, see the header.
    const mode = try devmod.openmode(omode);

    const t = TYPE(c.qid);
    switch (t) {
        Qtopdir, Qprotodir, Qconvdir => {
            if (omode != lib.OREAD)
                return error.Eperm;
        },
        Qclonus => {
            _ = try newtls(c) orelse
                return error.Enodev;
        },
        Qctl, Qdata, Qhand, Qstatus, Qstats => {
            if ((t == Qstatus or t == Qstats) and omode != lib.OREAD)
                return error.Eperm;
            lock(&tdlock);
            errdefer unlock(&tdlock);
            const tr = tlsdevs[CONV(c.qid)] orelse
                return errorf("must open connection using clone", .{});
            try devmod.devpermcheck(tr.user, tr.perm, omode);
            if (t == Qhand) {
                lock(&tr.hqlock);
                errdefer unlock(&tr.hqlock);
                if (tr.handq != null)
                    return error.Einuse;
                tr.handq = qio.qopen(2 * MaxCipherRecLen, 0, null, null);
                if (tr.handq == null)
                    return errorf("cannot allocate handshake queue", .{});
                tr.hqref = 1;
                unlock(&tr.hqlock);
            }
            tr.ref += 1;
            unlock(&tdlock);
        },
        Qencalgs, Qhashalgs => {
            if (omode != lib.OREAD)
                return error.Eperm;
        },
        else => panic("tlsopen", .{}),
    }
    c.mode = @intCast(mode);
    c.flag |= COPEN;
    c.offset = 0;
    switch (t) {
        Qdata => c.iounit = qio.qiomaxatomic,
        Qhand => c.iounit = MaxRecLen,
        else => c.iounit = 0,
    }
    return c;
}

fn tlswstat(c: *Chan, dp: []const u8) Error!usize {
    // the strings of the Dir point into this
    const strs = alloc.snewslice(u8, dp.len);
    defer alloc.free(strs.ptr);

    lock(&tdlock);
    defer unlock(&tdlock);
    const tr = tlsdevs[CONV(c.qid)] orelse
        return error.Ebadusefd;
    if (!std.mem.eql(u8, tr.user, arch.up().?.user))
        return error.Eperm;

    var d: Dir = .{};
    const rv = fcall.convM2D(dp, &d, strs);
    if (rv == 0)
        return error.Eshortstat;
    if (d.uid.len != 0)
        proc.kstrdup(&tr.user, d.uid);
    if (d.mode != ~@as(u32, 0))
        tr.perm = d.mode;

    return rv;
}

fn dechandq(tr: *TlsRec) void {
    lock(&tr.hqlock);
    tr.hqref -= 1;
    if (tr.hqref == 0) {
        if (tr.handq != null) {
            qio.qfree(tr.handq);
            tr.handq = null;
        }
        if (tr.hprocessed != null) {
            freeb(tr.hprocessed);
            tr.hprocessed = null;
        }
    }
    unlock(&tr.hqlock);
}

fn tlsclose(c: *Chan) Error!void {
    const t = TYPE(c.qid);
    switch (t) {
        Qctl, Qdata, Qhand, Qstatus, Qstats => {
            if (c.flag & COPEN == 0)
                return;

            const tr = tlsdevs[CONV(c.qid)] orelse
                return;

            if (t == Qhand)
                dechandq(tr);

            lock(&tdlock);
            tr.ref -= 1;
            if (tr.ref > 0) {
                unlock(&tdlock);
                return;
            }
            tlsdevs[CONV(c.qid)] = null;
            unlock(&tdlock);

            if (tr.c != null) {
                // errors are ignored: the connection is going away
                if (checkstate(tr, false, SOpen | SHandshake | SRClose)) |_| {
                    sendAlert(tr, ECloseNotify) catch {};
                } else |_| {}
            }
            tlshangup(tr);
            if (tr.c) |ch|
                chan.cclose(ch);
            freeSec(tr.in.sec);
            freeSec(tr.in.new);
            freeSec(tr.out.sec);
            freeSec(tr.out.new);
            if (tr.user.ptr != portdat.nostr.ptr)
                alloc.free(tr.user.ptr);
            alloc.free(tr);
        },
        else => {},
    }
}

/// make sure we have at least 'n' bytes in list 'l'
fn ensure(s: *TlsRec, l_: *?*Block, n: usize) Error!void {
    var l = l_;
    var sofar: usize = 0;
    var bp = l.*;
    while (bp) |b| : (bp = b.next) {
        sofar += BLEN(b);
        if (sofar >= n)
            return;
        l = &b.next;
    }

    const c = s.c.?;
    while (sofar < n) {
        const bl = try devmod.devtab[c.type].bread(c, MaxCipherRecLen + RecHdrLen, 0);
        l.* = bl;
        var i: usize = 0;
        bp = bl;
        while (bp) |b| : (bp = b.next) {
            i += BLEN(b);
            l = &b.next;
        }
        if (i == 0)
            return error.Ehungup;
        sofar += i;
    }
    if (s.debug) _ = pprint("ensure read %d\n", .{sofar});
}

/// copy 'n' bytes from 'l' into 'p' and free
/// the bytes in 'l'
fn consume(l: *?*Block, p_: [*]u8, n_: usize) void {
    var p = p_;
    var n = n_;
    while (l.*) |b| {
        if (n == 0)
            break;
        var i = BLEN(b);
        if (i > n)
            i = n;
        @memcpy(p[0..i], b.rp[0..i]);
        b.rp += i;
        p += i;
        n -= i;
        if (@intFromPtr(b.wp) < @intFromPtr(b.rp))
            panic("consume", .{});
        if (BLEN(b) != 0)
            break;
        l.* = b.next;
        freeb(b);
    }
}

/// give back n bytes
fn regurgitate(s: *TlsRec, p: []const u8) void {
    const n = p.len;
    if (n == 0)
        return;
    if (s.unprocessed) |b| {
        if (@intFromPtr(b.rp) - @intFromPtr(b.base) >= n) {
            b.rp -= n;
            @memcpy(b.rp[0..n], p);
            return;
        }
    }
    const b = allocb(n);
    @memcpy(b.wp[0..n], p);
    b.wp += n;
    b.next = s.unprocessed;
    s.unprocessed = b;
}

/// remove at most n bytes from the queue
fn qgrab(l: *?*Block, n: usize) *Block {
    const b = l.*.?;
    if (BLEN(b) == n) {
        l.* = b.next;
        b.next = null;
        return b;
    }

    var i: usize = 0;
    var bp: ?*Block = b;
    while (bp) |x| : (bp = x.next) {
        if (i >= n)
            break;
        i += BLEN(x);
    }
    if (i > n)
        i = n;

    const bb = allocb(i);
    consume(l, bb.wp, i);
    bb.wp += i;
    return bb;
}

fn tlsclosed(tr: *TlsRec, new: u32) Error!void {
    lock(&tr.statelk);
    if (tr.state == SOpen or tr.state == SHandshake)
        tr.state = new
    else if ((new | tr.state) == (SRClose | SLClose))
        tr.state = SClosed;
    unlock(&tr.statelk);
    try alertHand(tr, "close notify");
}

/// Whether e is "interrupted", however it was raised.
fn isintr(e: Error) bool {
    return e == error.Eintr or std.mem.eql(u8, proc.errtext(e), "interrupted");
}

const RecHdr = struct { len: i32, type: i32, ver: i32 };

/// The first part of tlsrecread: the header, and enough input for the
/// record it announces.  *nconsumed is how much of header was taken
/// from tr.unprocessed and would have to go back after an interrupt.
fn tlsrecreadhdr(tr: *TlsRec, header: *[RecHdrLen]u8, nconsumed: *usize) Error!RecHdr {
    var len: i32 = undefined;
    var typ: i32 = undefined;
    var ver: i32 = undefined;

    try ensure(tr, &tr.unprocessed, RecHdrLen);
    consume(&tr.unprocessed, header, RecHdrLen);
    if (tr.debug) _ = pprint("consumed %d header\n", .{@as(i32, RecHdrLen)});
    nconsumed.* = RecHdrLen;

    if (tr.handin == 0 and header[0] & 0x80 != 0) {
        // Cope with an SSL3 ClientHello expressed in SSL2 record format.
        // This is sent by some clients that we must interoperate
        // with, such as Java's JSSE and Microsoft's Internet Explorer.
        len = (get16(header[0..2]) & ~@as(i32, 0x8000)) - 3;
        typ = header[2];
        ver = get16(header[3..5]);
        if (typ != SSL2ClientHello or len < 22)
            return rcvError(tr, EProtocolVersion, "invalid initial SSL2-like message", .{});
    } else { // normal SSL3 record format
        typ = header[0];
        ver = get16(header[1..3]);
        len = get16(header[3..5]);
    }
    if (ver != tr.version and (tr.verset or ver < MinProtoVersion or ver > MaxProtoVersion))
        return rcvError(tr, EProtocolVersion, "devtls expected ver=%x%s, saw (len=%d) type=%x ver=%x '%.12s'", .{
            tr.version,                      @as([]const u8, if (tr.verset) "/set" else ""), len, typ, ver,
            std.mem.sliceTo(header[0..], 0),
        });
    if (len > MaxCipherRecLen or len <= 0)
        return rcvError(tr, ERecordOverflow, "bad record message length %d", .{len});
    try ensure(tr, &tr.unprocessed, @intCast(len));
    nconsumed.* = 0;
    return .{ .len = len, .type = typ, .ver = ver };
}

/// The second part of tlsrecread: take the record out of
/// tr.unprocessed, decrypt and check it, and pass it on.  *bp is the
/// record's block for as long as this function owns it; the caller
/// frees what is left there.
fn tlsrecreadbody(tr: *TlsRec, header: *[RecHdrLen]u8, h: RecHdr, bp: *?*Block) Error!void {
    var aad: [8 + RecHdrLen]u8 = undefined;
    var hmac: [MaxMacLen]u8 = @splat(0);
    var len = h.len;
    const typ = h.type;
    const ver = h.ver;

    var b = qgrab(&tr.unprocessed, @intCast(len));
    bp.* = b;
    if (tr.debug) _ = pprint("consumed unprocessed %d\n", .{len});

    const in = &tr.in;
    var p = b.rp;
    {
        qlock(&in.seclock);
        defer qunlock(&in.seclock);
        if (in.sec) |sec| {
            // to avoid Canvel-Hiltgen-Vaudenay-Vuagnoux attack, all errors here
            // should look alike, including timing of the response.
            var unpad_len: i32 = undefined;
            if (sec.aead_dec != null)
                unpad_len = len
            else {
                unpad_len = sec.dec.?(sec, p, len);
                if (tr.debug) _ = pprint("decrypted %d\n", .{unpad_len});
                if (tr.debug) pdump(unpad_len, p, "decrypted:");
            }

            var ivlen = sec.recivlen;
            if (tr.version >= TLS11Version) {
                if (ivlen == 0)
                    ivlen = sec.block;
            }
            len -= ivlen;
            if (len < 0)
                return rcvError(tr, EDecodeError, "runt record message", .{});
            unpad_len -= ivlen;
            p += @as(usize, @intCast(ivlen));

            if (unpad_len >= sec.maclen)
                len = unpad_len - sec.maclen;

            // update length
            put16(header[3..5], len);
            const aadlen = tr.packAAD.?(in.seq, header, &aad);
            in.seq +%= 1;
            if (sec.aead_dec) |aead_dec| {
                len = aead_dec(sec, aad[0..aadlen], p - @as(usize, @intCast(ivlen)), p, unpad_len);
                if (len < 0)
                    return rcvError(tr, EBadRecordMac, "record mac mismatch", .{});
            } else {
                const ulen: usize = @intCast(len);
                packMac(sec, aad[0..aadlen], p[0..ulen], &hmac);
                if (unpad_len < sec.maclen)
                    return rcvError(tr, EBadRecordMac, "short record mac", .{});
                if (tsmemcmp(&hmac, p + ulen, @intCast(sec.maclen)) != 0)
                    return rcvError(tr, EBadRecordMac, "record mac mismatch", .{});
            }
            b.rp = p;
            b.wp = p + @as(usize, @intCast(len));
        }
    }
    if (len < 0)
        return rcvError(tr, EDecodeError, "runt record message", .{});

    switch (typ) {
        RChangeCipherSpec => {
            if (len != 1 or p[0] != 1)
                return rcvError(tr, EDecodeError, "invalid change cipher spec", .{});
            qlock(&in.seclock);
            if (in.new == null) {
                qunlock(&in.seclock);
                return rcvError(tr, EUnexpectedMessage, "unexpected change cipher spec", .{});
            }
            freeSec(in.sec);
            in.sec = in.new;
            in.new = null;
            in.seq = 0;
            qunlock(&in.seclock);
        },
        RAlert => {
            if (len != 2)
                return rcvError(tr, EDecodeError, "invalid alert", .{});
            if (p[0] == 2)
                return rcvAlert(tr, p[1]);
            if (p[0] != 1)
                return rcvError(tr, EIllegalParameter, "invalid alert fatal code", .{});

            // propagate non-fatal alerts to handshaker
            switch (p[1]) {
                ECloseNotify => {
                    try tlsclosed(tr, SRClose);
                    if (tr.opened)
                        return errorf("tls hungup", .{});
                    return errorf("close notify", .{});
                },
                ENoRenegotiation => try alertHand(tr, "no renegotiation"),
                EUserCanceled => try alertHand(tr, "handshake canceled by user"),
                EUnrecognizedName => {
                    // happens in response to SNI, can be ignored.
                },
                else => return rcvError(tr, EIllegalParameter, "invalid alert code", .{}),
            }
        },
        RHandshake => {
            // don't worry about dropping the block
            // qbwrite always queues even if flow controlled and interrupted.
            //
            // if there isn't any handshaker, ignore the request,
            // but notify the other side we are doing so.
            lock(&tr.hqlock);
            if (tr.handq) |handq| {
                tr.hqref += 1;
                unlock(&tr.hqlock);
                defer dechandq(tr);
                b = qio.padblock(b, 1);
                b.rp[0] = RHandshake;
                bp.* = null;
                _ = try qio.qbwrite(handq, b);
            } else {
                unlock(&tr.hqlock);
                if (tr.verset and tr.version != SSL3Version)
                    sendAlert(tr, ENoRenegotiation) catch {};
            }
        },
        SSL2ClientHello => {
            lock(&tr.hqlock);
            if (tr.handq) |handq| {
                tr.hqref += 1;
                unlock(&tr.hqlock);
                defer dechandq(tr);
                // Pass the SSL2 format data, so that the handshake code can compute
                // the correct checksums.  HSSL2ClientHello = HandshakeType 9 is
                // unused in RFC2246.
                b = qio.padblock(b, 8);
                b.rp[0] = RHandshake;
                b.rp[1] = HSSL2ClientHello;
                put24(b.rp[2..5], len + 3);
                b.rp[5] = SSL2ClientHello;
                put16(b.rp[6..8], ver);
                bp.* = null;
                _ = try qio.qbwrite(handq, b);
            } else {
                unlock(&tr.hqlock);
                if (tr.verset and tr.version != SSL3Version)
                    sendAlert(tr, ENoRenegotiation) catch {};
            }
        },
        RApplication => {
            if (!tr.opened)
                return rcvError(tr, EUnexpectedMessage, "application message received before handshake completed", .{});
            if (BLEN(b) > 0) {
                tr.processed = b;
                bp.* = null;
            }
        },
        else => return rcvError(tr, EIllegalParameter, "invalid record message %#x", .{typ}),
    }
}

/// read and process one tls record layer message
/// must be called with tr.in.io held
/// We can't let Eintrs lose data, since doing so will get
/// us out of sync with the sender and break the reliablity
/// of the channel.  Eintr only happens during the reads in
/// consume.  Therefore we put back any bytes consumed before
/// the last call to ensure.
fn tlsrecread(tr: *TlsRec) Error!void {
    var header: [RecHdrLen]u8 = undefined;
    var nconsumed: usize = 0;

    const h = tlsrecreadhdr(tr, &header, &nconsumed) catch |e| {
        if (isintr(e))
            regurgitate(tr, header[0..nconsumed])
        else
            try tlsError(tr, "channel error");
        return e;
    };

    // If an Eintr happens after this, we'll get out of sync.
    // Make sure nothing we call can sleep.
    // Errors are ok, as they kill the connection.
    // Luckily, allocb won't sleep, it'll just error out.
    var b: ?*Block = null;
    tlsrecreadbody(tr, &header, h, &b) catch |e| {
        if (b != null)
            freeb(b);
        try tlsError(tr, "channel error");
        return e;
    };
    if (b != null)
        freeb(b);
}

/// got a fatal alert message
fn rcvAlert(tr: *TlsRec, err: i32) Error {
    var s: []const u8 = "unknown error";
    for (&tlserrs) |*te| {
        if (te.err == err) {
            s = te.msg;
            break;
        }
    }
    if (tr.debug) _ = pprint("rcvAlert: %s\n", .{s});

    tlsError(tr, s) catch |e| return e;
    if (!tr.opened)
        return errorf("%s", .{s});
    return errorf("tls error", .{});
}

/// found an error while decoding the input stream
fn rcvError(tr: *TlsRec, err: i32, comptime format: []const u8, args: anytype) Error {
    var buf: [ERRMAX]u8 = undefined;
    const msg = fmt.snprint(buf[0 .. ERRMAX - 1], format, args);
    if (tr.debug) _ = pprint("rcvError: %s\n", .{msg});

    sendAlert(tr, err) catch |e| return e;

    if (!tr.opened)
        return errorf("%s", .{msg});
    return errorf("tls error", .{});
}

/// make sure the next hand operation returns with a 'msg' error
fn alertHand(tr: *TlsRec, msg: []const u8) Error!void {
    lock(&tr.hqlock);
    const handq = tr.handq orelse {
        unlock(&tr.hqlock);
        return;
    };
    tr.hqref += 1;
    unlock(&tr.hqlock);
    defer dechandq(tr);

    const n = msg.len;
    const b = allocb(n + 2);
    b.wp[0] = RAlert;
    b.wp += 1;
    @memcpy(b.wp[0..n], msg);
    b.wp[n] = 0;
    b.wp += n + 1;

    _ = try qio.qbwrite(handq, b);
}

fn checkstate(tr: *TlsRec, ishand: bool, ok: u32) Error!void {
    lock(&tr.statelk);
    const state = tr.state;
    unlock(&tr.statelk);
    if (state & ok != 0)
        return;
    switch (state) {
        SHandshake, SOpen => {},
        SError, SAlert => {
            if (ishand)
                return errorf("%s", .{std.mem.sliceTo(&tr.err, 0)});
            return errorf("tls error", .{});
        },
        SRClose, SLClose, SClosed => return errorf("tls hungup", .{}),
        else => {},
    }
    return errorf("tls improperly configured", .{});
}

fn tlsbread(c: *Chan, n: usize, offset: u64) Error!*Block {
    const ty = TYPE(c.qid);
    switch (ty) {
        Qhand, Qdata => {},
        else => return devmod.devbread(c, n, offset),
    }

    const tr = tlsdevs[CONV(c.qid)] orelse
        panic("tlsbread", .{});

    var b: *Block = undefined;
    if (ty == Qdata) {
        {
            qlock(&tr.in.io);
            defer qunlock(&tr.in.io);
            try checkstate(tr, false, SOpen);
            while (tr.processed == null)
                try tlsrecread(tr);

            // return at most what was asked for
            b = qgrab(&tr.processed, n);
            if (tr.debug) _ = pprint("consumed processed %d\n", .{BLEN(b)});
            if (tr.debug) pdump(@intCast(BLEN(b)), b.rp, "consumed:");
        }
        tr.datain += @intCast(BLEN(b));
    } else {
        {
            qlock(&tr.in.io);
            defer qunlock(&tr.in.io);
            try checkstate(tr, true, SOpen | SHandshake | SLClose);

            // it's ok to look at state without the lock
            // since it only protects reading records,
            // and we have that tr.in.io held.
            while (!tr.opened and tr.hprocessed == null and !qio.qcanread(tr.handq.?))
                try tlsrecread(tr);
        }

        {
            qlock(&tr.hqread);
            defer qunlock(&tr.hqread);
            if (tr.hprocessed == null) {
                const hb = try qio.qbread(tr.handq.?, MaxRecLen + 1) orelse
                    return error.Ehungup;
                const rtype = hb.rp[0];
                hb.rp += 1;
                if (rtype == RAlert) {
                    const e = errorf("%s", .{std.mem.sliceTo(hb.rp[0..BLEN(hb)], 0)});
                    freeb(hb);
                    return e;
                }
                tr.hprocessed = hb;
            }
            b = qgrab(&tr.hprocessed, n);
        }
        tr.handin += @intCast(BLEN(b));
    }

    return b;
}

fn tlsread(c: *Chan, a: []u8, off: i64) Error!usize {
    const offset: usize = @as(u32, @truncate(@as(u64, @bitCast(off))));

    if (c.qid.type & QTDIR != 0)
        return devmod.devdirread(c, a, &.{}, tlsgen);

    const ty = TYPE(c.qid);
    var b: *Block = undefined;
    switch (ty) {
        Qstatus => {
            const tr = tlsdevs[CONV(c.qid)].?;
            const buf = alloc.smalloc(Statlen)[0..Statlen];
            defer alloc.free(buf.ptr);
            qlock(&tr.in.seclock);
            qlock(&tr.out.seclock);
            var s: usize = 0;
            s += fmt.snprint(buf[s..], "State: %s\n", .{tlsstate(tr.state)}).len;
            s += fmt.snprint(buf[s..], "Version: %#x\n", .{tr.version}).len;
            if (tr.in.sec) |sec|
                s += fmt.snprint(buf[s..], "EncIn: %s\nHashIn: %s\n", .{ sec.encalg, sec.hashalg }).len;
            if (tr.in.new) |sec|
                s += fmt.snprint(buf[s..], "NewEncIn: %s\nNewHashIn: %s\n", .{ sec.encalg, sec.hashalg }).len;
            if (tr.out.sec) |sec|
                s += fmt.snprint(buf[s..], "EncOut: %s\nHashOut: %s\n", .{ sec.encalg, sec.hashalg }).len;
            if (tr.out.new) |sec|
                s += fmt.snprint(buf[s..], "NewEncOut: %s\nNewHashOut: %s\n", .{ sec.encalg, sec.hashalg }).len;
            if (tr.c != null)
                s += fmt.snprint(buf[s..], "Chan: %s\n", .{chan.chanpath(tr.c)}).len;
            qunlock(&tr.in.seclock);
            qunlock(&tr.out.seclock);
            return readstr(offset, a, buf[0..s]);
        },
        Qstats => {
            const tr = tlsdevs[CONV(c.qid)].?;
            const buf = alloc.smalloc(Statlen)[0..Statlen];
            defer alloc.free(buf.ptr);
            var s: usize = 0;
            s += fmt.snprint(buf[s..], "DataIn: %lld\n", .{tr.datain}).len;
            s += fmt.snprint(buf[s..], "DataOut: %lld\n", .{tr.dataout}).len;
            s += fmt.snprint(buf[s..], "HandIn: %lld\n", .{tr.handin}).len;
            s += fmt.snprint(buf[s..], "HandOut: %lld\n", .{tr.handout}).len;
            return readstr(offset, a, buf[0..s]);
        },
        Qctl => {
            const buf = alloc.smalloc(Statlen)[0..Statlen];
            defer alloc.free(buf.ptr);
            const s = fmt.snprint(buf, "%llud", .{@as(u64, CONV(c.qid))});
            return readstr(offset, a, s);
        },
        Qdata, Qhand => b = try tlsbread(c, a.len, offset),
        Qencalgs => return readstr(offset, a, encalgs),
        Qhashalgs => return readstr(offset, a, hashalgs),
        else => return error.Ebadusefd,
    }

    defer qio.freeblist(b);

    var n: usize = 0;
    var nb: ?*Block = b;
    while (nb) |x| : (nb = x.next) {
        const i = BLEN(x);
        @memcpy(a[n..][0..i], x.rp[0..i]);
        n += i;
    }

    return n;
}

/// write a block in tls records
fn tlsrecwrite(tr: *TlsRec, typ: u8, b: *Block) Error!void {
    var aad: [8 + RecHdrLen]u8 = undefined;

    const out = &tr.out;
    var bb: ?*Block = b;
    qlock(&out.io);
    defer qunlock(&out.io);
    errdefer if (bb != null) freeb(bb);
    if (tr.debug) _ = pprint("send %d\n", .{BLEN(b)});
    if (tr.debug) pdump(@intCast(BLEN(b)), b.rp, "sent:");

    if (typ == RApplication)
        try checkstate(tr, false, SOpen);

    var ok: u32 = SHandshake | SOpen | SRClose;
    if (typ == RAlert)
        ok |= SAlert;
    while (bb != null) {
        try checkstate(tr, typ != RApplication, ok);

        // get at most one maximal record's input,
        // with padding on the front for header and
        // back for mac and maximal block padding.
        var nb: *Block = undefined;
        {
            qlock(&out.seclock);
            defer qunlock(&out.seclock);
            var maclen: usize = 0;
            var pad: usize = 0;
            var ivlen: usize = 0;
            const sec = out.sec;
            if (sec) |s| {
                maclen = @intCast(s.maclen);
                pad = maclen + @as(usize, @intCast(s.block));
                ivlen = @intCast(s.recivlen);
                if (tr.version >= TLS11Version) {
                    if (ivlen == 0)
                        ivlen = @intCast(s.block);
                }
            }
            var n = BLEN(bb.?);
            if (n > MaxRecLen) {
                n = MaxRecLen;
                nb = allocb(RecHdrLen + ivlen + n + pad);
                @memcpy((nb.wp + RecHdrLen + ivlen)[0..n], bb.?.rp[0..n]);
                bb.?.rp += n;
            } else {
                // carefully reuse bb so it will get freed if we're out of memory
                bb = qio.padblock(bb.?, @intCast(RecHdrLen + ivlen));
                if (pad != 0)
                    nb = qio.padblock(bb.?, -@as(i32, @intCast(pad)))
                else
                    nb = bb.?;
                bb = null;
            }
            errdefer freeb(nb); // DIFF: the C leaks nb

            const p = nb.rp;
            p[0] = typ;
            put16(p[1..3], tr.version);
            put16(p[3..5], @intCast(n));
            // DIFF: the C leaves this to the cipher, see the header.
            nb.wp = p + RecHdrLen + ivlen + n;

            if (sec) |s| {
                const aadlen = tr.packAAD.?(out.seq, p[0..RecHdrLen], &aad);
                out.seq +%= 1;
                if (s.aead_enc) |aead_enc|
                    n = @as(usize, @intCast(aead_enc(s, aad[0..aadlen], p + RecHdrLen, p + RecHdrLen + ivlen, @intCast(n)))) + ivlen
                else {
                    if (ivlen > 0)
                        random.genrandom((p + RecHdrLen)[0..ivlen]);
                    packMac(s, aad[0..aadlen], (p + RecHdrLen + ivlen)[0..n], (p + RecHdrLen + ivlen + n)[0..maclen]);
                    n = @intCast(s.enc.?(s, p + RecHdrLen, @intCast(ivlen + n + maclen)));
                }
                nb.wp = p + RecHdrLen + n;

                // update length
                put16(p[3..5], @intCast(n));
            }
            if (typ == RChangeCipherSpec) {
                if (out.new == null)
                    return errorf("change cipher without a new cipher", .{});
                freeSec(out.sec);
                out.sec = out.new;
                out.new = null;
                out.seq = 0;
            }
        }

        // if bwrite error's, we assume the block is queued.
        // if not, we're out of sync with the receiver and will not recover.
        const c = tr.c.?;
        _ = devmod.devtab[c.type].bwrite(c, nb, 0) catch |e| {
            if (!isintr(e))
                try tlsError(tr, "channel error")
            else if (bb != null)
                continue;
            return e;
        };
    }
}

fn tlsbwrite(c: *Chan, b: *Block, offset: u64) Error!usize {
    const n = BLEN(b);

    const tr = tlsdevs[CONV(c.qid)] orelse
        panic("tlsbwrite", .{});

    const ty = TYPE(c.qid);
    switch (ty) {
        Qhand => {
            try tlsrecwrite(tr, RHandshake, b);
            tr.handout += @intCast(n);
        },
        Qdata => {
            try tlsrecwrite(tr, RApplication, b);
            tr.dataout += @intCast(n);
        },
        else => return devmod.devbwrite(c, b, offset),
    }

    return n;
}

const Hashalg = struct {
    name: []const u8,
    maclen: i32,
    initkey: *const fn (ha: *const Hashalg, version: i32, s: *Secret, p: []const u8) Error!void,
};

// DIFF: initmd5key is not ported (see the header).

fn initclearmac(_: *const Hashalg, _: i32, s: *Secret, _: []const u8) Error!void {
    s.mac = nomac;
}

fn initsha1key(ha: *const Hashalg, version: i32, s: *Secret, p: []const u8) Error!void {
    // DIFF: the C uses sslmac_sha1 here, which is not ported.
    if (version == SSL3Version)
        return errorf("sha1 cannot be used with SSL", .{});
    s.maclen = ha.maclen;
    s.mac = hmac_sha1;
    const n: usize = @intCast(ha.maclen);
    @memcpy(s.mackey[0..n], p[0..n]);
}

fn initsha2_256key(ha: *const Hashalg, version: i32, s: *Secret, p: []const u8) Error!void {
    if (version == SSL3Version)
        return errorf("sha256 cannot be used with SSL", .{});
    s.maclen = ha.maclen;
    s.mac = hmac_sha2_256;
    const n: usize = @intCast(ha.maclen);
    @memcpy(s.mackey[0..n], p[0..n]);
}

const hashtab = [_]Hashalg{
    .{ .name = "clear", .maclen = 0, .initkey = initclearmac },
    // DIFF: no md5
    .{ .name = "sha1", .maclen = SHA1dlen, .initkey = initsha1key },
    .{ .name = "sha256", .maclen = SHA2_256dlen, .initkey = initsha2_256key },
};

fn parsehashalg(p: []const u8) Error!*const Hashalg {
    for (&hashtab) |*ha| {
        if (std.mem.eql(u8, p, ha.name))
            return ha;
    }
    return errorf("unsupported hash algorithm", .{});
}

const Encalg = struct {
    name: []const u8,
    keylen: usize,
    ivlen: usize,
    initkey: *const fn (ea: *const Encalg, s: *Secret, p: []const u8, iv: []const u8) void,
};

// DIFF: initRC4key and initDES3key are not ported (see the header).

fn initAESkey(ea: *const Encalg, s: *Secret, p: []const u8, iv: []const u8) void {
    s.enc = aesenc;
    s.dec = aesdec;
    s.block = 16;
    s.enckey = .{ .aes = .{} };
    setupAESstate(&s.enckey.aes, p[0..ea.keylen], iv[0..AESbsize]);
}

fn initccpolykey(ea: *const Encalg, s: *Secret, p: []const u8, iv: []const u8) void {
    s.aead_enc = ccpoly_aead_enc;
    s.aead_dec = ccpoly_aead_dec;
    s.maclen = Poly1305dlen;
    if (ea.ivlen == 0) {
        // older draft version, iv is 64-bit sequence number
        s.enckey = .{ .chacha = .{ .key = p[0..32].*, .ivwords = 2 } };
    } else {
        // IETF standard, 96-bit iv xored with sequence number
        @memcpy(s.mackey[0..ea.ivlen], iv[0..ea.ivlen]);
        s.enckey = .{ .chacha = .{ .key = p[0..32].*, .ivwords = 3 } };
    }
}

fn initaesgcmkey(ea: *const Encalg, s: *Secret, p: []const u8, iv: []const u8) void {
    s.aead_enc = aesgcm_aead_enc;
    s.aead_dec = aesgcm_aead_dec;
    s.maclen = 16;
    s.recivlen = 8;
    @memcpy(s.mackey[0..ea.ivlen], iv[0..ea.ivlen]);
    random.genrandom(s.mackey[ea.ivlen..][0..8]);
    s.enckey = .{ .aesgcm = .{} };
    setupAESGCMstate(&s.enckey.aesgcm, p[0..ea.keylen]);
}

fn initclearenc(_: *const Encalg, s: *Secret, _: []const u8, _: []const u8) void {
    s.enc = noenc;
    s.dec = noenc;
}

const encrypttab = [_]Encalg{
    .{ .name = "clear", .keylen = 0, .ivlen = 0, .initkey = initclearenc },
    // DIFF: no rc4_128, no 3des_ede_cbc
    .{ .name = "aes_128_cbc", .keylen = 128 / 8, .ivlen = 16, .initkey = initAESkey },
    .{ .name = "aes_256_cbc", .keylen = 256 / 8, .ivlen = 16, .initkey = initAESkey },
    .{ .name = "ccpoly64_aead", .keylen = 256 / 8, .ivlen = 0, .initkey = initccpolykey },
    .{ .name = "ccpoly96_aead", .keylen = 256 / 8, .ivlen = 96 / 8, .initkey = initccpolykey },
    .{ .name = "aes_128_gcm_aead", .keylen = 128 / 8, .ivlen = 4, .initkey = initaesgcmkey },
    .{ .name = "aes_256_gcm_aead", .keylen = 256 / 8, .ivlen = 4, .initkey = initaesgcmkey },
};

fn parseencalg(p: []const u8) Error!*const Encalg {
    for (&encrypttab) |*ea| {
        if (std.mem.eql(u8, p, ea.name))
            return ea;
    }
    return errorf("unsupported encryption algorithm", .{});
}

/// What is left to do for a control message once the locks are
/// released and the message freed.
const Ctl = union(enum) {
    done,
    changecipher,
    alert: i32,
};

/// The control messages; the body of the C tlswrite's Qctl case, called
/// with both seclocks held.
fn tlsctl(tr: *TlsRec, cb: *Cmdbuf) Error!Ctl {
    const f = cb.f;
    if (std.mem.eql(u8, f[0], "fd")) {
        if (cb.nf != 3)
            return errorf("usage: fd open-fd version", .{});
        if (tr.c != null)
            return error.Einuse;
        const m = strtol(f[2]);
        if (m < MinProtoVersion or m > MaxProtoVersion)
            return errorf("unsupported version", .{});
        tr.c = try buftochan(f[1]);
        tr.version = m;
        tlsSetState(tr, SHandshake, SClosed);
    } else if (std.mem.eql(u8, f[0], "version")) {
        if (cb.nf != 2)
            return errorf("usage: version vers", .{});
        if (tr.c == null)
            return errorf("must set fd before version", .{});
        if (tr.verset)
            return errorf("version already set", .{});
        const m = strtol(f[1]);
        if (m < MinProtoVersion or m > MaxProtoVersion)
            return errorf("unsupported version", .{});
        if (m == SSL3Version)
            tr.packAAD = sslPackAAD
        else
            tr.packAAD = tlsPackAAD;
        tr.verset = true;
        tr.version = m;
    } else if (std.mem.eql(u8, f[0], "secret")) {
        if (cb.nf != 5)
            return errorf("usage: secret hashalg encalg isclient secretdata", .{});
        if (tr.c == null or !tr.verset)
            return errorf("must set fd and version before secrets", .{});

        if (tr.in.new != null) {
            freeSec(tr.in.new);
            tr.in.new = null;
        }
        if (tr.out.new != null) {
            freeSec(tr.out.new);
            tr.out.new = null;
        }

        const ha = try parsehashalg(f[1]);
        const ea = try parseencalg(f[2]);

        const p = f[4];
        var m: i32 = @intCast((p.len * 3) / 2 + 1);
        const x = alloc.secalloc(@intCast(m))[0..@intCast(m)];
        defer alloc.secfree(x.ptr);
        const tos = newSec();
        const toc = newSec();
        errdefer {
            freeSec(tos);
            freeSec(toc);
        }

        m = dec64(x, p);
        @memset(p, 0);
        const maclen: usize = @intCast(ha.maclen);
        if (m < 0 or @as(usize, @intCast(m)) < 2 * maclen + 2 * ea.keylen + 2 * ea.ivlen)
            return errorf("not enough secret data provided", .{});

        try ha.initkey(ha, tr.version, tos, x[0..]);
        try ha.initkey(ha, tr.version, toc, x[maclen..]);
        ea.initkey(ea, tos, x[2 * maclen ..], x[2 * maclen + 2 * ea.keylen ..]);
        ea.initkey(ea, toc, x[2 * maclen + ea.keylen ..], x[2 * maclen + 2 * ea.keylen + ea.ivlen ..]);

        if (tos.aead_enc == null or tos.aead_dec == null or toc.aead_enc == null or toc.aead_dec == null)
            if (tos.mac == null or tos.enc == null or tos.dec == null or toc.mac == null or toc.enc == null or toc.dec == null)
                return errorf("missing algorithm implementations", .{});

        if (strtol(f[3]) == 0) {
            tr.in.new = tos;
            tr.out.new = toc;
        } else {
            tr.in.new = toc;
            tr.out.new = tos;
        }
        if (tr.version == SSL3Version) {
            toc.unpad = sslunpad;
            tos.unpad = sslunpad;
        } else {
            toc.unpad = tlsunpad;
            tos.unpad = tlsunpad;
        }
        toc.encalg = ea.name;
        toc.hashalg = ha.name;
        tos.encalg = ea.name;
        tos.hashalg = ha.name;
    } else if (std.mem.eql(u8, f[0], "changecipher")) {
        if (cb.nf != 1)
            return errorf("usage: changecipher", .{});
        if (tr.out.new == null)
            return errorf("cannot change cipher spec without setting secret", .{});
        return .changecipher;
    } else if (std.mem.eql(u8, f[0], "opened")) {
        if (cb.nf != 1)
            return errorf("usage: opened", .{});
        if (tr.in.sec == null or tr.out.sec == null)
            return errorf("cipher must be configured before enabling data messages", .{});
        lock(&tr.statelk);
        if (tr.state != SHandshake and tr.state != SOpen) {
            unlock(&tr.statelk);
            return errorf("cannot enable data messages", .{});
        }
        tr.state = SOpen;
        unlock(&tr.statelk);
        tr.opened = true;
    } else if (std.mem.eql(u8, f[0], "alert")) {
        if (cb.nf != 2)
            return errorf("usage: alert n", .{});
        const m = strtol(f[1]);
        if (tr.c == null)
            return errorf("must set fd before sending alerts", .{});
        return .{ .alert = m };
    } else if (std.mem.eql(u8, f[0], "hangup")) {
        if (tr.c == null)
            return errorf("must set fd before sending alerts", .{});
        return .{ .alert = ECloseNotify };
    } else if (std.mem.eql(u8, f[0], "debug")) {
        if (cb.nf == 2) {
            tr.debug = std.mem.eql(u8, f[1], "on");
        } else tr.debug = true;
    } else return error.Ebadarg;

    return .done;
}

fn tlswrite(c: *Chan, a: []const u8, off: i64) Error!usize {
    var offset: u64 = @as(u32, @truncate(@as(u64, @bitCast(off))));
    const n = a.len;

    const tr = tlsdevs[CONV(c.qid)] orelse
        panic("tlswrite", .{});

    const ty = TYPE(c.qid);
    switch (ty) {
        Qdata, Qhand => {
            var p: usize = 0;
            while (true) {
                var m = n - p;
                if (m > c.iounit)
                    m = c.iounit;

                const b = allocb(m);
                @memcpy(b.wp[0..m], a[p..][0..m]);
                b.wp += m;

                _ = try tlsbwrite(c, b, offset);
                offset += m;

                p += m;
                if (p >= n)
                    break;
            }
            return n;
        },
        Qctl => {},
        else => return error.Ebadusefd,
    }

    const todo = blk: {
        const cb = try parse.parsecmd(a);
        defer alloc.free(cb);
        if (cb.nf < 1)
            return errorf("short control request", .{});

        // mutex with operations using what we're about to change
        qlock(&tr.in.seclock);
        qlock(&tr.out.seclock);
        defer {
            qunlock(&tr.in.seclock);
            qunlock(&tr.out.seclock);
        }
        break :blk try tlsctl(tr, cb);
    };

    switch (todo) {
        .done => {},
        .changecipher => {
            // the real work is done as the message is written
            // so the stream is encrypted in sync.
            const b = allocb(1);
            b.wp[0] = 1;
            b.wp += 1;
            try tlsrecwrite(tr, RChangeCipherSpec, b);
        },
        .alert => |m| {
            try sendAlert(tr, m);

            if (m == ECloseNotify)
                try tlsclosed(tr, SLClose);
        },
    }

    return n;
}

fn tlsinit() void {
    tlsdevs = alloc.snewslice(?*TlsRec, maxtlsdevs);
    @memset(tlsdevs, null);
    trnames = alloc.snewslice(?[]u8, maxtlsdevs);
    @memset(trnames, null);

    var n: usize = 1;
    for (&encrypttab) |*e|
        n += e.name.len + 1;
    var cp = alloc.smalloc(n);
    var i: usize = 0;
    for (&encrypttab, 0..) |*e, j| {
        if (j != 0) {
            cp[i] = ' ';
            i += 1;
        }
        @memcpy(cp[i..][0..e.name.len], e.name);
        i += e.name.len;
    }
    encalgs = cp[0..i];

    n = 1;
    for (&hashtab) |*h|
        n += h.name.len + 1;
    cp = alloc.smalloc(n);
    i = 0;
    for (&hashtab, 0..) |*h, j| {
        if (j != 0) {
            cp[i] = ' ';
            i += 1;
        }
        @memcpy(cp[i..][0..h.name.len], h.name);
        i += h.name.len;
    }
    hashalgs = cp[0..i];
}

pub const tlsdevtab: devmod.Dev = .{
    .dc = 'a',
    .name = "tls",

    .init = tlsinit,
    .attach = tlsattach,
    .walk = tlswalk,
    .stat = tlsstat,
    .open = tlsopen,
    .close = tlsclose,
    .read = tlsread,
    .bread = tlsbread,
    .write = tlswrite,
    .bwrite = tlsbwrite,
    .wstat = tlswstat,
};

/// libc's strtol(p, nil, 0).
fn strtol(p: []const u8) i32 {
    return @bitCast(netif.strtoul(p, 0).v);
}

/// get channel associated with an fd
fn buftochan(p: []const u8) Error!*Chan {
    const fd = strtol(p);
    if (fd < 0)
        return error.Ebadarg;
    return sysfile.fdtochan(fd, lib.ORDWR, true, true); // error check and inc ref
}

fn sendAlert(tr: *TlsRec, err_: i32) Error!void {
    var err = err_;

    if (tr.debug) _ = pprint("sendAlert %d\n", .{err});
    var fatal = true;
    var msg: []const u8 = "tls unknown alert";
    for (&tlserrs) |*te| {
        if (te.err == err) {
            msg = te.msg;
            if (tr.version == SSL3Version)
                err = te.sslerr
            else
                err = te.tlserr;
            fatal = te.fatal;
            break;
        }
    }

    {
        const b = allocb(2);
        b.wp[0] = @as(u8, @intFromBool(fatal)) + 1;
        b.wp[1] = @truncate(@as(u32, @bitCast(err)));
        b.wp += 2;
        if (fatal)
            tlsSetState(tr, SAlert, SOpen | SHandshake | SRClose);
        // an error here is dropped, as in the C
        tlsrecwrite(tr, RAlert, b) catch {};
    }
    if (fatal)
        try tlsError(tr, msg);
}

fn tlsError(tr: *TlsRec, msg: []const u8) Error!void {
    if (tr.debug) _ = pprint("tlsError %s\n", .{msg});
    lock(&tr.statelk);
    const s = tr.state;
    tr.state = SError;
    if (s != SError) {
        const n = @min(msg.len, ERRMAX - 1);
        @memcpy(tr.err[0..n], msg[0..n]);
        @memset(tr.err[n..], 0);
    }
    unlock(&tr.statelk);
    if (s != SError)
        try alertHand(tr, msg);
}

fn tlsSetState(tr: *TlsRec, new: u32, old: u32) void {
    lock(&tr.statelk);
    if (tr.state & old != 0)
        tr.state = new;
    unlock(&tr.statelk);
}

/// hand up a digest connection
fn tlshangup(tr: *TlsRec) void {
    qlock(&tr.in.io);
    while (tr.processed) |b| {
        tr.processed = b.next;
        freeb(b);
    }
    if (tr.unprocessed != null) {
        qio.freeblist(tr.unprocessed); // DIFF: the C frees the first block only
        tr.unprocessed = null;
    }
    qunlock(&tr.in.io);

    tlsSetState(tr, SClosed, ~@as(u32, 0));
}

fn newtls(ch: *Chan) Error!?*TlsRec {
    lock(&tdlock);
    defer unlock(&tdlock);
    var i: usize = 0;
    while (i < maxtlsdevs) : (i += 1) {
        if (tlsdevs[i] == null)
            break;
    }
    if (i >= maxtlsdevs) {
        if (maxtlsdevs >= MaxTlsDevs)
            return null;
        var newmax = 2 * maxtlsdevs;
        if (newmax > MaxTlsDevs)
            newmax = MaxTlsDevs;
        const np = alloc.snewslice(?*TlsRec, newmax);
        @memcpy(np[0..maxtlsdevs], tlsdevs);
        @memset(np[maxtlsdevs..], null);
        tlsdevs = np;
        i = maxtlsdevs;

        const nmp = alloc.snewslice(?[]u8, newmax);
        @memcpy(nmp[0..maxtlsdevs], trnames);
        @memset(nmp[maxtlsdevs..], null);
        trnames = nmp;

        maxtlsdevs = newmax;
    }
    const tr = try mktlsrec();
    tlsdevs[i] = tr;
    if (i >= tdhiwat)
        tdhiwat += 1;
    var t = TYPE(ch.qid);
    if (t == Qclonus)
        t = Qctl;
    ch.qid.path = QID(i, t);
    ch.qid.vers = 0;
    return tr;
}

fn mktlsrec() Error!*TlsRec {
    const tr = alloc.new(TlsRec) orelse
        return error.Enomem;
    tr.* = .{};
    tr.state = SClosed;
    tr.ref = 1;
    proc.kstrdup(&tr.user, arch.up().?.user);
    tr.perm = 0o660;
    return tr;
}

fn tlsstate(s: u32) []const u8 {
    return switch (s) {
        SHandshake => "Handshaking",
        SOpen => "Established",
        SRClose => "RemoteClosed",
        SLClose => "LocalClosed",
        SAlert => "Alerting",
        SError => "Errored",
        SClosed => "Closed",
        else => "Unknown",
    };
}

/// A zeroed Secret from the memory for secrets (the C's
/// secalloc(sizeof(Secret))).
fn newSec() *Secret {
    // malloc's memory is aligned for a pointer, no more
    comptime std.debug.assert(@alignOf(Secret) <= @alignOf(usize));
    const s: *Secret = @ptrCast(@alignCast(alloc.secalloc(@sizeOf(Secret))));
    s.* = .{};
    return s;
}

fn freeSec(s: ?*Secret) void {
    alloc.secfree(s orelse return);
}

fn noenc(_: *Secret, _: [*]u8, n: i32) i32 {
    return n;
}

// DIFF: rc4enc is not ported (see the header).

fn tlsunpad(buf: [*]u8, n_: i32, block: i32) i32 {
    var n = n_;
    const pad: i32 = buf[@intCast(n - 1)];
    const nn = n - 1 - pad;
    if (nn <= 0 or @rem(n, block) != 0)
        return -1;
    while (true) {
        n -= 1;
        if (n <= nn)
            break;
        if (pad != buf[@intCast(n - 1)])
            return -1;
    }
    return nn;
}

fn sslunpad(buf: [*]u8, n: i32, block: i32) i32 {
    const pad: i32 = buf[@intCast(n - 1)];
    const nn = n - 1 - pad;
    if (nn <= 0 or @rem(n, block) != 0)
        return -1;
    return nn;
}

fn blockpad(buf: [*]u8, n_: i32, block: i32) i32 {
    var n = n_;
    var nn = n + block;
    nn -= @rem(nn, block);
    const pad = nn - (n + 1);
    while (n < nn) : (n += 1)
        buf[@intCast(n)] = @intCast(pad);
    return nn;
}

// DIFF: des3enc and des3dec are not ported (see the header).

/// SubWord of the key expansion, FIPS-197 5.2: the S-box applied to
/// each byte of w.  The last round of the cipher is SubBytes, ShiftRows
/// and AddRoundKey, and ShiftRows does nothing to a state whose four
/// columns are equal.
fn aessubword(w: [4]u8) [4]u8 {
    const zero: [AESbsize]u8 = @splat(0);
    const st: [AESbsize]u8 = w ++ w ++ w ++ w;
    return aes.Block.fromBytes(&st).encryptLast(aes.Block.fromBytes(&zero)).toBytes()[0..4].*;
}

/// libsec's setupAESstate: the key schedules (FIPS-197 5.2, and 5.3.5
/// for the decryption key) and the first iv.  key is 16 or 32 bytes.
fn setupAESstate(s: *AESstate, key: []const u8, ivec: ?*const [AESbsize]u8) void {
    const nk = key.len / 4;
    const rounds = nk + 6;
    var w: [4 * (AESmaxrounds + 1)][4]u8 = undefined;
    defer crypto.secureZero(u8, std.mem.asBytes(&w));

    for (0..nk) |i|
        w[i] = key[4 * i ..][0..4].*;
    var rcon: u8 = 1;
    for (nk..4 * (rounds + 1)) |i| {
        var t = w[i - 1];
        if (i % nk == 0) {
            t = aessubword(.{ t[1], t[2], t[3], t[0] });
            t[0] ^= rcon;
            rcon = (rcon << 1) ^ (if (rcon & 0x80 != 0) @as(u8, 0x1b) else 0);
        } else if (nk > 6 and i % nk == 4)
            t = aessubword(t);
        for (&w[i], w[i - nk], t) |*x, a, b|
            x.* = a ^ b;
    }

    s.rounds = rounds;
    for (0..rounds + 1) |r|
        s.ekey[r] = std.mem.asBytes(w[4 * r ..][0..4]).*;
    // the key of the equivalent inverse cipher
    s.dkey[0] = s.ekey[rounds];
    for (1..rounds) |r|
        s.dkey[r] = aes.Block.fromBytes(&s.ekey[rounds - r]).invMixColumns().toBytes();
    s.dkey[rounds] = s.ekey[0];
    if (ivec) |iv|
        s.ivec = iv.*
    else
        s.ivec = @splat(0);
}

/// libsec's aes_encrypt: one block.  ct and pt may be the same.
fn aes_encrypt(s: *const AESstate, pt: *const [AESbsize]u8, ct: *[AESbsize]u8) void {
    const B = aes.Block;
    var t = B.fromBytes(pt).xorBlocks(B.fromBytes(&s.ekey[0]));
    for (1..s.rounds) |r|
        t = t.encrypt(B.fromBytes(&s.ekey[r]));
    ct.* = t.encryptLast(B.fromBytes(&s.ekey[s.rounds])).toBytes();
}

/// libsec's aes_decrypt: one block.  pt and ct may be the same.
fn aes_decrypt(s: *const AESstate, ct: *const [AESbsize]u8, pt: *[AESbsize]u8) void {
    const B = aes.Block;
    var t = B.fromBytes(ct).xorBlocks(B.fromBytes(&s.dkey[0]));
    for (1..s.rounds) |r|
        t = t.decrypt(B.fromBytes(&s.dkey[r]));
    pt.* = t.decryptLast(B.fromBytes(&s.dkey[s.rounds])).toBytes();
}

/// libsec's aesCBCencrypt.
fn aesCBCencrypt(p_: []u8, s: *AESstate) void {
    var p = p_;
    while (p.len >= AESbsize) : (p = p[AESbsize..]) {
        for (&s.ivec, p[0..AESbsize]) |*ip, x|
            ip.* ^= x;
        aes_encrypt(s, &s.ivec, &s.ivec);
        @memcpy(p[0..AESbsize], &s.ivec);
    }

    if (p.len > 0) {
        aes_encrypt(s, &s.ivec, &s.ivec);
        for (p, s.ivec[0..p.len]) |*x, ip|
            x.* ^= ip;
    }
}

/// libsec's aesCBCdecrypt.
fn aesCBCdecrypt(p_: []u8, s: *AESstate) void {
    var p = p_;
    var t: [AESbsize]u8 = undefined;
    while (p.len >= AESbsize) : (p = p[AESbsize..]) {
        const blk = p[0..AESbsize];
        t = blk.*;
        aes_decrypt(s, blk, blk);
        for (blk, &s.ivec) |*x, ip|
            x.* ^= ip;
        s.ivec = t;
    }

    if (p.len > 0) {
        aes_encrypt(s, &s.ivec, &s.ivec);
        for (p, s.ivec[0..p.len]) |*x, ip|
            x.* ^= ip;
    }
}

fn aesenc(sec: *Secret, buf: [*]u8, n_: i32) i32 {
    const n = blockpad(buf, n_, 16);
    aesCBCencrypt(buf[0..@intCast(n)], &sec.enckey.aes);
    return n;
}

fn aesdec(sec: *Secret, buf: [*]u8, n: i32) i32 {
    aesCBCdecrypt(buf[0..@intCast(n)], &sec.enckey.aes);
    return sec.unpad.?(buf, n, 16);
}

fn ccpoly_aead_setiv(sec: *Secret, seq: *const [8]u8) void {
    const cs = &sec.enckey.chacha;
    if (cs.ivwords == 2) {
        cs.iv[0..8].* = seq.*;
        return;
    }

    var iv: [ChachaIVlen]u8 = sec.mackey[0..ChachaIVlen].*;
    for (0..8) |i|
        iv[i + (ChachaIVlen - 8)] ^= seq[i];

    cs.iv = iv;

    crypto.secureZero(u8, &iv);
}

/// libsec's ccpolylen: a length as Poly1305 input.
fn ccpolylen(n: usize, ds: *Poly1305) void {
    var info: [8]u8 = undefined;
    std.mem.writeInt(u64, &info, @as(u32, @truncate(n)), .little);
    ds.update(&info);
}

/// The tag of libsec's ccpoly_encrypt and ccpoly_decrypt in the draft
/// construction (64-bit nonce): Poly1305, keyed with the first 32
/// bytes of ChaCha20 block 0, over the unpadded aad, its length, the
/// unpadded ciphertext and its length.
fn ccpoly64tag(cs: *const Chachastate, aad: []const u8, dat: []const u8, tag: *[Poly1305dlen]u8) void {
    var otk: [32]u8 = @splat(0);
    ChaCha20With64BitNonce.stream(&otk, 0, cs.key, cs.iv[0..8].*);
    var ds = Poly1305.init(&otk);
    crypto.secureZero(u8, &otk);
    ds.update(aad);
    ccpolylen(aad.len, &ds);
    ds.update(dat);
    ccpolylen(dat.len, &ds);
    ds.final(tag);
}

/// libsec's ccpoly_encrypt.
fn ccpoly_encrypt(dat: []u8, aad: []const u8, tag: *[Poly1305dlen]u8, cs: *const Chachastate) void {
    if (cs.ivwords == 2) {
        ChaCha20With64BitNonce.xor(dat, dat, 1, cs.key, cs.iv[0..8].*);
        ccpoly64tag(cs, aad, dat, tag);
    } else ChaCha20Poly1305.encrypt(dat, tag, dat, aad, cs.iv, cs.key);
}

/// libsec's ccpoly_decrypt; false if the tag does not match.
fn ccpoly_decrypt(dat: []u8, aad: []const u8, tag: *const [Poly1305dlen]u8, cs: *const Chachastate) bool {
    if (cs.ivwords == 2) {
        var tmp: [Poly1305dlen]u8 = undefined;
        ccpoly64tag(cs, aad, dat, &tmp);
        if (!crypto.timing_safe.eql([Poly1305dlen]u8, tag.*, tmp))
            return false;
        ChaCha20With64BitNonce.xor(dat, dat, 1, cs.key, cs.iv[0..8].*);
        return true;
    }
    ChaCha20Poly1305.decrypt(dat, dat, tag.*, aad, cs.iv, cs.key) catch return false;
    return true;
}

fn ccpoly_aead_enc(sec: *Secret, aad: []const u8, _: [*]u8, data: [*]u8, len_: i32) i32 {
    const len: usize = @intCast(len_);
    ccpoly_aead_setiv(sec, aad[0..8]);
    ccpoly_encrypt(data[0..len], aad, (data + len)[0..Poly1305dlen], &sec.enckey.chacha);
    return len_ + sec.maclen;
}

fn ccpoly_aead_dec(sec: *Secret, aad: []const u8, _: [*]u8, data: [*]u8, len_: i32) i32 {
    if (len_ - sec.maclen < 0)
        return -1;
    const len: usize = @intCast(len_ - sec.maclen);
    ccpoly_aead_setiv(sec, aad[0..8]);
    if (!ccpoly_decrypt(data[0..len], aad, (data + len)[0..Poly1305dlen], &sec.enckey.chacha))
        return -1;
    return @intCast(len);
}

/// libsec's setupAESGCMstate, without an iv.
fn setupAESGCMstate(s: *AESGCMstate, key: []const u8) void {
    const zero: [AESbsize]u8 = @splat(0);
    setupAESstate(&s.a, key, null);
    aes_encrypt(&s.a, &zero, &s.h);
}

/// Counter mode from the counter block j on: dat ^= E(j), E(j+1), ...
/// where the last four bytes of j count (NIST SP 800-38D, GCTR).
fn aesgcm_ctr(s: *const AESGCMstate, j: *[AESbsize]u8, dat_: []u8) void {
    var dat = dat_;
    var ks: [AESbsize]u8 = undefined;
    var cnt = std.mem.readInt(u32, j[12..16], .big);
    while (dat.len > 0) {
        aes_encrypt(&s.a, j, &ks);
        cnt +%= 1;
        std.mem.writeInt(u32, j[12..16], cnt, .big);
        const n = @min(dat.len, AESbsize);
        for (dat[0..n], ks[0..n]) |*d, k|
            d.* ^= k;
        dat = dat[n..];
    }
    crypto.secureZero(u8, &ks);
}

/// The GCM tag of aad and the ciphertext dat, as std's aes_gcm.zig
/// computes it: GHASH over both, each padded to a block, and their
/// lengths in bits, encrypted with counter block j (count 1).
fn aesgcm_tag(s: *const AESGCMstate, j: *const [AESbsize]u8, aad: []const u8, dat: []const u8, tag: *[16]u8) void {
    var t: [AESbsize]u8 = undefined;
    aes_encrypt(&s.a, j, &t);

    const block_count = (aad.len + 15) / 16 + (dat.len + 15) / 16 + 1;
    var mac = Ghash.initForBlockCount(&s.h, block_count);
    mac.update(aad);
    mac.pad();
    mac.update(dat);
    mac.pad();

    var final_block: [16]u8 = undefined;
    std.mem.writeInt(u64, final_block[0..8], @as(u64, aad.len) * 8, .big);
    std.mem.writeInt(u64, final_block[8..16], @as(u64, dat.len) * 8, .big);
    mac.update(&final_block);
    mac.final(tag);
    for (tag, t) |*x, y|
        x.* ^= y;
}

/// libsec's aesgcm_encrypt, with the iv aesgcm_setiv left in s.
fn aesgcm_encrypt(dat: []u8, aad: []const u8, tag: *[16]u8, s: *const AESGCMstate) void {
    var j: [AESbsize]u8 = s.iv ++ [4]u8{ 0, 0, 0, 2 };
    aesgcm_ctr(s, &j, dat);
    j = s.iv ++ [4]u8{ 0, 0, 0, 1 };
    aesgcm_tag(s, &j, aad, dat, tag);
}

/// libsec's aesgcm_decrypt; false if the tag does not match.
fn aesgcm_decrypt(dat: []u8, aad: []const u8, tag: *const [16]u8, s: *const AESGCMstate) bool {
    var tmp: [16]u8 = undefined;
    var j: [AESbsize]u8 = s.iv ++ [4]u8{ 0, 0, 0, 1 };
    aesgcm_tag(s, &j, aad, dat, &tmp);
    if (!crypto.timing_safe.eql([16]u8, tag.*, tmp))
        return false;
    j = s.iv ++ [4]u8{ 0, 0, 0, 2 };
    aesgcm_ctr(s, &j, dat);
    return true;
}

fn aesgcm_aead_enc(sec: *Secret, aad: []const u8, reciv: [*]u8, data: [*]u8, len_: i32) i32 {
    const len: usize = @intCast(len_);
    const s = &sec.enckey.aesgcm;
    var iv: [12]u8 = sec.mackey[0 .. 4 + 8].*;

    for (0..8) |i| iv[4 + i] ^= aad[i];
    @memcpy(reciv[0..8], iv[4..]);
    s.iv = iv;
    crypto.secureZero(u8, &iv);
    aesgcm_encrypt(data[0..len], aad, (data + len)[0..16], s);
    return len_ + sec.maclen;
}

fn aesgcm_aead_dec(sec: *Secret, aad: []const u8, reciv: [*]u8, data: [*]u8, len_: i32) i32 {
    const s = &sec.enckey.aesgcm;
    var iv: [12]u8 = undefined;

    if (len_ - sec.maclen < 0)
        return -1;
    const len: usize = @intCast(len_ - sec.maclen);
    @memcpy(iv[0..4], sec.mackey[0..4]);
    @memcpy(iv[4..], reciv[0..8]);
    s.iv = iv;
    crypto.secureZero(u8, &iv);
    if (!aesgcm_decrypt(data[0..len], aad, (data + len)[0..16], s))
        return -1;
    return @intCast(len);
}

fn nomac(_: []const u8, _: []const u8, _: []const u8, _: []u8) void {}

/// libsec's hmac_sha1, over two pieces (see DIFF).
fn hmac_sha1(aad: []const u8, body: []const u8, key: []const u8, digest: []u8) void {
    var s = HmacSha1.init(key);
    s.update(aad);
    s.update(body);
    s.final(digest[0..SHA1dlen]);
}

/// libsec's hmac_sha2_256, over two pieces (see DIFF).
fn hmac_sha2_256(aad: []const u8, body: []const u8, key: []const u8, digest: []u8) void {
    var s = HmacSha256.init(key);
    s.update(aad);
    s.update(body);
    s.final(digest[0..SHA2_256dlen]);
}

// DIFF: sslmac_x, sslmac_sha1 and sslmac_md5 (mac calculations for
// ssl 3.0 only; tls 1.0 uses the standard hmac) are not ported.

fn sslPackAAD(seq: u64, hdr: *const [RecHdrLen]u8, aad: *[8 + RecHdrLen]u8) usize {
    put64(aad[0..8], seq);
    aad[8] = hdr[0];
    aad[9] = hdr[3];
    aad[10] = hdr[4];
    return 11;
}

fn tlsPackAAD(seq: u64, hdr: *const [RecHdrLen]u8, aad: *[8 + RecHdrLen]u8) usize {
    put64(aad[0..8], seq);
    aad[8] = hdr[0];
    aad[9] = hdr[1];
    aad[10] = hdr[2];
    aad[11] = hdr[3];
    aad[12] = hdr[4];
    return 13;
}

/// mac must have room for sec.maclen bytes.
fn packMac(sec: *Secret, aad: []const u8, body: []const u8, mac: []u8) void {
    sec.mac.?(aad, body, sec.mackey[0..@intCast(sec.maclen)], mac);
}

/// libsec's tsmemcmp, as far as it is used here: 0 if the n bytes at a
/// and b are equal, in time that does not depend on where they differ.
fn tsmemcmp(a: *const [MaxMacLen]u8, b: [*]const u8, n: usize) i32 {
    var x: [MaxMacLen]u8 = @splat(0);
    var y: [MaxMacLen]u8 = @splat(0);
    @memcpy(x[0..n], a[0..n]);
    @memcpy(y[0..n], b[0..n]);
    return if (crypto.timing_safe.eql([MaxMacLen]u8, x, y)) 0 else 1;
}

fn put32(p: *[4]u8, x: u32) void {
    p[0] = @truncate(x >> 24);
    p[1] = @truncate(x >> 16);
    p[2] = @truncate(x >> 8);
    p[3] = @truncate(x);
}

fn put64(p: *[8]u8, x: u64) void {
    put32(p[0..4], @truncate(x >> 32));
    put32(p[4..8], @truncate(x));
}

fn put24(p: *[3]u8, x_: i32) void {
    const x: u32 = @bitCast(x_);
    p[0] = @truncate(x >> 16);
    p[1] = @truncate(x >> 8);
    p[2] = @truncate(x);
}

fn put16(p: *[2]u8, x_: i32) void {
    const x: u32 = @bitCast(x_);
    p[0] = @truncate(x >> 8);
    p[1] = @truncate(x);
}

fn get16(p: *const [2]u8) i32 {
    return (@as(i32, p[0]) << 8) | p[1];
}

const charmap = "0123456789abcdef";

noinline fn pdump(len_: i32, a: [*]const u8, tag: []const u8) void {
    var buf: [65 + 32]u8 = undefined;
    var len = len_;
    var p = a;

    @memcpy(buf[0..tag.len], tag);
    while (len > 0) {
        var q = tag.len;
        var i: usize = 0;
        while (len > 0 and i < 32) : (i += 1) {
            if (p[0] >= ' ' and p[0] < 0x7f) {
                buf[q] = ' ';
                buf[q + 1] = p[0];
            } else {
                buf[q] = charmap[p[0] >> 4];
                buf[q + 1] = charmap[p[0] & 0xf];
            }
            q += 2;
            len -= 1;
            p += 1;
        }

        if (len > 0)
            _ = pprint("%s...\n", .{buf[0..q]})
        else
            _ = pprint("%s\n", .{buf[0..q]});
    }
}

// from libc/port/u64.c

fn between(x: i32, min: i32, max: i32) i32 {
    return ((min - 1 - x) & (x - max - 1)) >> 8;
}

fn dec64chr(c: i32) i32 {
    var o = between(c, 'A', 'Z') & (1 + (c - 'A'));
    o |= between(c, 'a', 'z') & (1 + 26 + (c - 'a'));
    o |= between(c, '0', '9') & (1 + 52 + (c - '0'));
    o |= between(c, '+', '+') & (1 + 62);
    o |= between(c, '/', '/') & (1 + 63);
    return o - 1;
}

/// Decode base 64 text into out; the number of bytes, or -1 if out is
/// too small.  Characters outside the alphabet are skipped.
fn dec64(out: []u8, in: []const u8) i32 {
    var b24: u32 = 0;
    var i: u32 = 0;
    var o: usize = 0;

    for (in) |ch| {
        const c = dec64chr(ch);
        if (c < 0)
            continue;
        const v: u32 = @intCast(c);
        switch (i) {
            0 => b24 = v << 18,
            1 => b24 |= v << 12,
            2 => b24 |= v << 6,
            else => {
                if (o + 3 > out.len)
                    return -1;

                b24 |= v;
                out[o] = @truncate(b24 >> 16);
                out[o + 1] = @truncate(b24 >> 8);
                out[o + 2] = @truncate(b24);
                o += 3;
                i = 0;
                continue;
            },
        }
        i += 1;
    }
    switch (i) {
        2 => {
            if (o + 1 > out.len)
                return -1;
            out[o] = @truncate(b24 >> 16);
            o += 1;
        },
        3 => {
            if (o + 2 > out.len)
                return -1;
            out[o] = @truncate(b24 >> 16);
            out[o + 1] = @truncate(b24 >> 8);
            o += 2;
        },
        else => {},
    }
    return @intCast(o);
}

// Host tests of the record protection.  Run them both for the host
// processor and with -mcpu=baseline: only the latter uses std's
// software AES rounds, which is what the kernel gets.  They must not
// refer to hashtab, encrypttab or anything else that leads to the
// rest of the kernel (errorf, genrandom), so they make their Secrets
// by hand.

const testccpoly64: Encalg = .{ .name = "ccpoly64_aead", .keylen = 256 / 8, .ivlen = 0, .initkey = initccpolykey };
const testccpoly96: Encalg = .{ .name = "ccpoly96_aead", .keylen = 256 / 8, .ivlen = 96 / 8, .initkey = initccpolykey };
const testaes128cbc: Encalg = .{ .name = "aes_128_cbc", .keylen = 128 / 8, .ivlen = 16, .initkey = initAESkey };
const testaes256cbc: Encalg = .{ .name = "aes_256_cbc", .keylen = 256 / 8, .ivlen = 16, .initkey = initAESkey };

/// What a Hashalg's initkey does for TLS.
fn testinitmac(s: *Secret, maclen: usize, p: []const u8) void {
    s.maclen = @intCast(maclen);
    s.mac = if (maclen == SHA1dlen) hmac_sha1 else hmac_sha2_256;
    @memcpy(s.mackey[0..maclen], p[0..maclen]);
}

const testing = std.testing;

fn hex(comptime s: []const u8) [s.len / 2]u8 {
    var out: [s.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, s) catch unreachable;
    return out;
}

test "aes: FIPS-197 appendix C" {
    var s: AESstate = .{};
    var out: [16]u8 = undefined;
    const pt = hex("00112233445566778899aabbccddeeff");

    setupAESstate(&s, &hex("000102030405060708090a0b0c0d0e0f"), null);
    try testing.expectEqual(@as(usize, 10), s.rounds);
    aes_encrypt(&s, &pt, &out);
    try testing.expectEqualSlices(u8, &hex("69c4e0d86a7b0430d8cdb78070b4c55a"), &out);
    aes_decrypt(&s, &out, &out);
    try testing.expectEqualSlices(u8, &pt, &out);

    setupAESstate(&s, &hex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"), null);
    try testing.expectEqual(@as(usize, 14), s.rounds);
    aes_encrypt(&s, &pt, &out);
    try testing.expectEqualSlices(u8, &hex("8ea2b7ca516745bfeafc49904b496089"), &out);
    aes_decrypt(&s, &out, &out);
    try testing.expectEqualSlices(u8, &pt, &out);
}

test "aes cbc: NIST SP 800-38A F.2" {
    const iv = hex("000102030405060708090a0b0c0d0e0f");
    const pt = hex("6bc1bee22e409f96e93d7e117393172a" ++ "ae2d8a571e03ac9c9eb76fac45af8e51" ++
        "30c81c46a35ce411e5fbc1191a0a52ef" ++ "f69f2445df4f9b17ad2b417be66c3710");
    const cases = [_]struct { key: []const u8, ct: [64]u8 }{
        .{
            .key = &hex("2b7e151628aed2a6abf7158809cf4f3c"),
            .ct = hex("7649abac8119b246cee98e9b12e9197d" ++ "5086cb9b507219ee95db113a917678b2" ++
                "73bed6b8e3c1743b7116e69e22229516" ++ "3ff1caa1681fac09120eca307586e1a7"),
        },
        .{
            .key = &hex("603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4"),
            .ct = hex("f58c4c04d6e5f1ba779eabfb5f7bfbd6" ++ "9cfc4e967edb808d679f777bc6702c7d" ++
                "39f23369a9d9bacfa530e26304231461" ++ "b2eb05e2c39be9fcda6c19078c6a9d1b"),
        },
    };
    for (cases) |c| {
        var s: AESstate = .{};
        var buf = pt;
        setupAESstate(&s, c.key, &iv);
        // in two calls: the chaining value carries over, as it does
        // from record to record in TLS 1.0
        aesCBCencrypt(buf[0..32], &s);
        aesCBCencrypt(buf[32..], &s);
        try testing.expectEqualSlices(u8, &c.ct, &buf);
        setupAESstate(&s, c.key, &iv);
        aesCBCdecrypt(buf[0..16], &s);
        aesCBCdecrypt(buf[16..], &s);
        try testing.expectEqualSlices(u8, &pt, &buf);
    }
}

test "aes gcm: against std's AEAD" {
    const Aes128Gcm = crypto.aead.aes_gcm.Aes128Gcm;
    const Aes256Gcm = crypto.aead.aes_gcm.Aes256Gcm;
    const key = hex("feffe9928665731c6d6a8f9467308308feffe9928665731c6d6a8f9467308308");
    const iv = hex("cafebabefacedbaddecaf888");
    const aad = hex("0000000000000001170303");
    var prng = std.Random.DefaultPrng.init(9);
    var msg: [MaxRecLen]u8 = undefined;
    prng.random().bytes(&msg);

    for ([_]usize{ 16, 32 }) |keylen| {
        var s: AESGCMstate = .{};
        setupAESGCMstate(&s, key[0..keylen]);
        s.iv = iv;
        for ([_]usize{ 0, 1, 15, 16, 17, 31, 32, 33, 255, 1000, MaxRecLen }) |n| {
            for ([_]usize{ 0, 11, aad.len }) |naad| {
                var want: [MaxRecLen]u8 = undefined;
                var wanttag: [16]u8 = undefined;
                if (keylen == 16)
                    Aes128Gcm.encrypt(want[0..n], &wanttag, msg[0..n], aad[0..naad], iv, key[0..16].*)
                else
                    Aes256Gcm.encrypt(want[0..n], &wanttag, msg[0..n], aad[0..naad], iv, key);

                var buf: [MaxRecLen]u8 = undefined;
                var tag: [16]u8 = undefined;
                @memcpy(buf[0..n], msg[0..n]);
                aesgcm_encrypt(buf[0..n], aad[0..naad], &tag, &s);
                try testing.expectEqualSlices(u8, want[0..n], buf[0..n]);
                try testing.expectEqualSlices(u8, &wanttag, &tag);

                try testing.expect(aesgcm_decrypt(buf[0..n], aad[0..naad], &tag, &s));
                try testing.expectEqualSlices(u8, msg[0..n], buf[0..n]);

                tag[5] ^= 1;
                try testing.expect(!aesgcm_decrypt(buf[0..n], aad[0..naad], &tag, &s));
            }
        }
    }
}

test "aes gcm: NIST test case 4" {
    // from "The Galois/Counter Mode of Operation (GCM)", McGrew and Viega
    var s: AESGCMstate = .{};
    setupAESGCMstate(&s, &hex("feffe9928665731c6d6a8f9467308308"));
    s.iv = hex("cafebabefacedbaddecaf888");
    const aad = hex("feedfacedeadbeeffeedfacedeadbeefabaddad2");
    var buf = hex("d9313225f88406e5a55909c5aff5269a" ++ "86a7a9531534f7da2e4c303d8a318a72" ++
        "1c3c0c95956809532fcf0e2449a6b525" ++
        "b16aedf5aa0de657ba637b39");
    var tag: [16]u8 = undefined;
    aesgcm_encrypt(&buf, &aad, &tag, &s);
    try testing.expectEqualSlices(u8, &hex("42831ec2217774244b7221b784d0d49c" ++ "e3aa212f2c02a4e035c17e2329aca12e" ++
        "21d514b25466931c7d8f6a5aac84aa05" ++ "1ba30b396a0aac973d58e091"), &buf);
    try testing.expectEqualSlices(u8, &hex("5bc94fbc3221a5db94fae95ae7121a47"), &tag);
}

/// A Secret for an AES-GCM connection, as initaesgcmkey makes it but
/// with the explicit nonce's start given.
fn testgcmsec(sec: *Secret, key: []const u8, salt: [4]u8, start: [8]u8) void {
    sec.* = .{};
    sec.aead_enc = aesgcm_aead_enc;
    sec.aead_dec = aesgcm_aead_dec;
    sec.maclen = 16;
    sec.recivlen = 8;
    sec.mackey[0..4].* = salt;
    sec.mackey[4..12].* = start;
    sec.enckey = .{ .aesgcm = .{} };
    setupAESGCMstate(&sec.enckey.aesgcm, key);
}

test "tls 1.2 aes gcm record" {
    // The record as RFC 5288 defines it, made with std's AEAD: the
    // nonce is the 4-byte salt from the key block and 8 explicit bytes
    // sent in front of the ciphertext.
    const Aes128Gcm = crypto.aead.aes_gcm.Aes128Gcm;
    const key = hex("000102030405060708090a0b0c0d0e0f");
    const salt = [4]u8{ 0xa0, 0xa1, 0xa2, 0xa3 };
    const msg = "GET /file HTTP/1.1\r\n\r\n";
    const seq: u64 = 3;

    var hdr = [RecHdrLen]u8{ RApplication, 3, 3, 0, msg.len };
    var aad: [8 + RecHdrLen]u8 = undefined;
    try testing.expectEqual(@as(usize, 13), tlsPackAAD(seq, &hdr, &aad));
    try testing.expectEqualSlices(u8, &hex("0000000000000003" ++ "1703030016"), &aad);

    // what the peer sends
    const explicit = hex("1122334455667788");
    var rec: [8 + msg.len + 16]u8 = undefined;
    rec[0..8].* = explicit;
    Aes128Gcm.encrypt(rec[8..][0..msg.len], rec[8 + msg.len ..][0..16], msg, &aad, salt ++ explicit, key);

    // read it as tlsrecread does
    var rsec: Secret = undefined;
    testgcmsec(&rsec, &key, salt, @splat(0));
    var in = rec;
    const n = rsec.aead_dec.?(&rsec, &aad, &in, in[8..].ptr, @intCast(in.len - 8));
    try testing.expectEqual(@as(i32, msg.len), n);
    try testing.expectEqualSlices(u8, msg, in[8..][0..msg.len]);

    // a damaged record
    in = rec;
    in[10] ^= 0x80;
    try testing.expectEqual(@as(i32, -1), rsec.aead_dec.?(&rsec, &aad, &in, in[8..].ptr, @intCast(in.len - 8)));
    // too short to hold a tag
    try testing.expectEqual(@as(i32, -1), rsec.aead_dec.?(&rsec, &aad, &in, in[8..].ptr, 15));

    // write it as tlsrecwrite does: the explicit part is the secret's
    // random start xored with the sequence number
    var wsec: Secret = undefined;
    testgcmsec(&wsec, &key, salt, explicit);
    var out: [8 + msg.len + 16]u8 = undefined;
    @memcpy(out[8..][0..msg.len], msg);
    const m = wsec.aead_enc.?(&wsec, &aad, &out, out[8..].ptr, msg.len);
    try testing.expectEqual(@as(i32, msg.len + 16), m);
    try testing.expectEqualSlices(u8, &hex("112233445566778b"), out[0..8]);
    var plain: [msg.len]u8 = undefined;
    try Aes128Gcm.decrypt(&plain, out[8..][0..msg.len], out[8 + msg.len ..][0..16].*, &aad, salt ++ out[0..8].*, key);
    try testing.expectEqualSlices(u8, msg, &plain);
}

test "ccpoly96: RFC 8439 section 2.8.2" {
    const msg = "Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.";
    const aad = hex("50515253c0c1c2c3c4c5c6c7");
    var cs: Chachastate = .{
        .key = hex("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f"),
        .iv = hex("070000004041424344454647"),
        .ivwords = 3,
    };
    var buf: [msg.len]u8 = msg.*;
    var tag: [16]u8 = undefined;
    ccpoly_encrypt(&buf, &aad, &tag, &cs);
    try testing.expectEqualSlices(u8, &hex("d31a8d34648e60db7b86afbc53ef7ec2" ++ "a4aded51296e08fea9e2b5a736ee62d6" ++
        "3dbea45e8ca9671282fafb69da92728b" ++ "1a71de0a9e060b2905d6a5b67ecd3b36" ++
        "92ddbd7f2d778b8c9803aee328091b58" ++ "fab324e4fad675945585808b4831d7bc" ++
        "3ff4def08e4b7a9de576d26586cec64b" ++ "6116"), &buf);
    try testing.expectEqualSlices(u8, &hex("1ae10b594f09e26a7e902ecbd0600691"), &tag);
    try testing.expect(ccpoly_decrypt(&buf, &aad, &tag, &cs));
    try testing.expectEqualSlices(u8, msg, &buf);
    tag[0] ^= 1;
    try testing.expect(!ccpoly_decrypt(&buf, &aad, &tag, &cs));
}

test "ccpoly64: draft-agl-tls-chacha20poly1305-04 section 7" {
    const pt = hex("86d09974840bded2a5ca");
    const aad = hex("87e229d4500845a079c0");
    var cs: Chachastate = .{
        .key = hex("4290bcb154173531f314af57f3be3b5006da371ece272afa1b5dbdd1100a1007"),
        .ivwords = 2,
    };
    cs.iv[0..8].* = hex("cd7cf67be39c794a");
    var buf = pt;
    var tag: [16]u8 = undefined;
    ccpoly_encrypt(&buf, &aad, &tag, &cs);
    try testing.expectEqualSlices(u8, &hex("e3e446f7ede9a19b62a4"), &buf);
    try testing.expectEqualSlices(u8, &hex("677dabf4e3d24b876bb284753896e1d6"), &tag);
    try testing.expect(ccpoly_decrypt(&buf, &aad, &tag, &cs));
    try testing.expectEqualSlices(u8, &pt, &buf);
    tag[15] ^= 1;
    try testing.expect(!ccpoly_decrypt(&buf, &aad, &tag, &cs));
}

test "ccpoly records: the nonce from the sequence number" {
    const key = hex("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f");
    const iv = hex("070000004041424344454647");
    const msg = "hello, world";
    var hdr = [RecHdrLen]u8{ RApplication, 3, 3, 0, msg.len };
    var aad: [8 + RecHdrLen]u8 = undefined;
    _ = tlsPackAAD(0x0102030405060708, &hdr, &aad);

    // RFC 7905: the 96-bit iv with the sequence number xored into its end
    var sec: Secret = .{};
    initccpolykey(&testccpoly96, &sec, &key, &iv);
    var buf: [msg.len + 16]u8 = undefined;
    @memcpy(buf[0..msg.len], msg);
    try testing.expectEqual(@as(i32, msg.len + 16), sec.aead_enc.?(&sec, &aad, &buf, &buf, msg.len));
    var plain: [msg.len]u8 = undefined;
    try ChaCha20Poly1305.decrypt(&plain, buf[0..msg.len], buf[msg.len..].*, &aad, hex("07000000414341474143414f"), key);
    try testing.expectEqualSlices(u8, msg, &plain);
    try testing.expectEqual(@as(i32, msg.len), sec.aead_dec.?(&sec, &aad, &buf, &buf, buf.len));
    try testing.expectEqualSlices(u8, msg, buf[0..msg.len]);

    // the draft: the sequence number is the nonce
    sec = .{};
    initccpolykey(&testccpoly64, &sec, &key, &.{});
    @memcpy(buf[0..msg.len], msg);
    _ = sec.aead_enc.?(&sec, &aad, &buf, &buf, msg.len);
    try testing.expectEqualSlices(u8, &hex("0102030405060708"), sec.enckey.chacha.iv[0..8]);
    try testing.expectEqual(@as(i32, msg.len), sec.aead_dec.?(&sec, &aad, &buf, &buf, buf.len));
    try testing.expectEqualSlices(u8, msg, buf[0..msg.len]);
    buf[0] ^= 1;
    _ = sec.aead_enc.?(&sec, &aad, &buf, &buf, msg.len);
    buf[3] ^= 1;
    try testing.expectEqual(@as(i32, -1), sec.aead_dec.?(&sec, &aad, &buf, &buf, buf.len));
}

test "hmac: RFC 2202 and RFC 4231 test case 2, in two pieces" {
    var d: [MaxMacLen]u8 = undefined;
    hmac_sha1("what do ya want ", "for nothing?", "Jefe", &d);
    try testing.expectEqualSlices(u8, &hex("effcdf6ae5eb2fa2d27416d5f184df9c259a7c79"), d[0..20]);
    hmac_sha2_256("what do ya want ", "for nothing?", "Jefe", &d);
    try testing.expectEqualSlices(u8, &hex("5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"), &d);
}

test "padding" {
    var buf: [48]u8 = undefined;
    @memset(&buf, 0xee);
    try testing.expectEqual(@as(i32, 16), blockpad(&buf, 13, 16));
    try testing.expectEqualSlices(u8, &.{ 2, 2, 2, 0xee }, buf[13..17]);
    try testing.expectEqual(@as(i32, 13), tlsunpad(&buf, 16, 16));
    try testing.expectEqual(@as(i32, 13), sslunpad(&buf, 16, 16));
    // a whole block of padding when the data fills its blocks
    try testing.expectEqual(@as(i32, 32), blockpad(&buf, 16, 16));
    try testing.expectEqual(@as(u8, 15), buf[31]);
    try testing.expectEqual(@as(i32, 16), tlsunpad(&buf, 32, 16));
    // a padding byte that differs: wrong for TLS, unchecked in SSL 3.0
    buf[20] ^= 1;
    try testing.expectEqual(@as(i32, -1), tlsunpad(&buf, 32, 16));
    try testing.expectEqual(@as(i32, 16), sslunpad(&buf, 32, 16));
    buf[20] ^= 1;
    // not a whole number of blocks
    try testing.expectEqual(@as(i32, -1), tlsunpad(&buf, 31, 16));
    // padding longer than the record
    buf[15] = 15;
    try testing.expectEqual(@as(i32, -1), tlsunpad(&buf, 16, 16));
    buf[15] = 200;
    try testing.expectEqual(@as(i32, -1), tlsunpad(&buf, 16, 16));
}

/// One CBC record written as tlsrecwrite writes it and read as
/// tlsrecreadbody reads it; `damage` changes the record in between.
/// The length of the data read, or the alert tlsrecreadbody would send.
fn testcbcrecord(version: i32, maclen: usize, ea: *const Encalg, msg: []const u8, damage: ?*const fn (rec: []u8) void) !i32 {
    var x: [2 * 32 + 2 * 32 + 2 * 16]u8 = undefined;
    for (&x, 0..) |*b, i| b.* = @truncate(i * 7 + 1);
    var wsec: Secret = .{};
    var rsec: Secret = .{};
    testinitmac(&wsec, maclen, x[0..]);
    testinitmac(&rsec, maclen, x[0..]);
    ea.initkey(ea, &wsec, x[2 * maclen ..], x[2 * maclen + 2 * ea.keylen ..]);
    ea.initkey(ea, &rsec, x[2 * maclen ..], x[2 * maclen + 2 * ea.keylen ..]);
    wsec.unpad = tlsunpad;
    rsec.unpad = tlsunpad;

    var aad: [8 + RecHdrLen]u8 = undefined;
    var rec: [RecHdrLen + 16 + 256 + 32 + 16]u8 = undefined;
    var total: usize = 0;
    // two records, so that the chaining of TLS 1.0 is exercised
    var len: i32 = undefined;
    for (0..2) |seq| {
        // write
        const ivlen: usize = if (version >= TLS11Version) @intCast(wsec.block) else 0;
        var n = msg.len;
        const p: [*]u8 = &rec;
        p[0] = RApplication;
        put16(p[1..3], version);
        put16(p[3..5], @intCast(n));
        @memcpy((p + RecHdrLen + ivlen)[0..n], msg);
        var aadlen = tlsPackAAD(seq, p[0..RecHdrLen], &aad);
        @memset((p + RecHdrLen)[0..ivlen], 0x5a);
        packMac(&wsec, aad[0..aadlen], (p + RecHdrLen + ivlen)[0..n], (p + RecHdrLen + ivlen + n)[0..maclen]);
        n = @intCast(wsec.enc.?(&wsec, p + RecHdrLen, @intCast(ivlen + n + maclen)));
        put16(p[3..5], @intCast(n));
        total = RecHdrLen + n;
        try testing.expect(n % 16 == 0);
        try testing.expect(msg.len < 8 or std.mem.find(u8, rec[0..total], msg) == null);

        if (seq == 1) {
            if (damage) |f| f(rec[RecHdrLen..total]);
        }

        // read
        var header: [RecHdrLen]u8 = rec[0..RecHdrLen].*;
        len = get16(header[3..5]);
        var q: [*]u8 = p + RecHdrLen;
        var unpad_len = rsec.dec.?(&rsec, q, len);
        var rivlen = rsec.recivlen;
        if (version >= TLS11Version) {
            if (rivlen == 0)
                rivlen = rsec.block;
        }
        len -= rivlen;
        if (len < 0)
            return -EDecodeError;
        unpad_len -= rivlen;
        q += @as(usize, @intCast(rivlen));
        if (unpad_len >= rsec.maclen)
            len = unpad_len - rsec.maclen;
        put16(header[3..5], len);
        aadlen = tlsPackAAD(seq, &header, &aad);
        var hmac: [MaxMacLen]u8 = @splat(0);
        const ulen: usize = @intCast(len);
        packMac(&rsec, aad[0..aadlen], q[0..ulen], &hmac);
        if (unpad_len < rsec.maclen)
            return -EBadRecordMac;
        if (tsmemcmp(&hmac, q + ulen, @intCast(rsec.maclen)) != 0)
            return -EBadRecordMac;
        try testing.expectEqualSlices(u8, msg, q[0..ulen]);
    }
    return len;
}

fn damagepad(rec: []u8) void {
    // the last block's plaintext ends in the padding: changing the
    // block before it changes the padding bytes
    rec[rec.len - 17] ^= 0x01;
}

fn damagedata(rec: []u8) void {
    rec[rec.len - 40] ^= 0x10;
}

fn damagecut(rec: []u8) void {
    // (the record keeps its length; its last block is garbage)
    @memset(rec[rec.len - 16 ..], 0);
}

test "cbc with hmac records" {
    const msg = "The quick brown fox jumps over the lazy dog, twice over if it must";
    for ([_]i32{ TLS10Version, TLS11Version, TLS12Version }) |version| {
        for ([_]usize{ SHA1dlen, SHA2_256dlen }) |maclen| {
            for ([_]*const Encalg{ &testaes128cbc, &testaes256cbc }) |ea| {
                for ([_]usize{ 0, 1, 11, 12, 13, 16, msg.len }) |n| {
                    try testing.expectEqual(@as(i32, @intCast(n)), try testcbcrecord(version, maclen, ea, msg[0..n], null));
                    try testing.expectEqual(@as(i32, -EBadRecordMac), try testcbcrecord(version, maclen, ea, msg[0..n], damagepad));
                    try testing.expectEqual(@as(i32, -EBadRecordMac), try testcbcrecord(version, maclen, ea, msg[0..n], damagecut));
                }
                try testing.expectEqual(@as(i32, -EBadRecordMac), try testcbcrecord(version, maclen, ea, msg, damagedata));
            }
        }
    }
}

test "dec64" {
    var out: [16]u8 = undefined;
    try testing.expectEqual(@as(i32, 5), dec64(&out, "aGVsbG8="));
    try testing.expectEqualSlices(u8, "hello", out[0..5]);
    try testing.expectEqual(@as(i32, 6), dec64(&out, "aGVsbG8h"));
    try testing.expectEqualSlices(u8, "hello!", out[0..6]);
    try testing.expectEqual(@as(i32, 4), dec64(&out, "/+8AAQ"));
    try testing.expectEqualSlices(u8, &.{ 0xff, 0xef, 0x00, 0x01 }, out[0..4]);
    // characters outside the alphabet are skipped
    try testing.expectEqual(@as(i32, 5), dec64(&out, "aGVs\nbG8=\n"));
    try testing.expectEqual(@as(i32, -1), dec64(out[0..4], "aGVsbG8h"));
    try testing.expectEqual(@as(i32, 0), dec64(&out, ""));
}

test "put and get" {
    var b: [8]u8 = undefined;
    put64(&b, 0x0102030405060708);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8 }, &b);
    put24(b[0..3], 0x0a0b0c);
    try testing.expectEqualSlices(u8, &.{ 0x0a, 0x0b, 0x0c }, b[0..3]);
    put16(b[0..2], 0x0303);
    try testing.expectEqual(@as(i32, 0x0303), get16(b[0..2]));
    var hdr = [RecHdrLen]u8{ 22, 3, 0, 1, 2 };
    var aad: [8 + RecHdrLen]u8 = undefined;
    try testing.expectEqual(@as(usize, 11), sslPackAAD(1, &hdr, &aad));
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0, 0, 1, 22, 1, 2 }, aad[0..11]);
}
