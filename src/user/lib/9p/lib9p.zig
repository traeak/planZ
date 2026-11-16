//! lib9p: what a 9P file server is written on.  9p.h, and the
//! library's functions under their C names, as libc.zig is for libc.
//! from 9front 11952's /sys/src/lib9p, one file per C file in this
//! directory (thread.zig holds thread.c and the five thread*srv.c
//! files, which are a line each)
//!
//! A server fills in a Srv with the functions for the messages it
//! answers itself, perhaps a Tree of Files, and calls srv (on file
//! descriptors it has), postsrv (a pipe, posted in /srv) or
//! postmountsrv (and mounted).  Each function gets the Req, with the
//! message in ifcall, fills in ofcall and calls respond, with null or
//! the error.  The library checks the fids, the modes and the walks,
//! and answers what the server leaves out.
//!
//! Not ported yet: listen.c (listensrv: with dial and announce).
//!
//! DIFF (all files):
//!   - Strings are slices; an error is `?[]const u8`, null for none.
//!     The text given to respond must stay as it is until respond
//!     returns.
//!   - A File's Dir, embedded in C, is its field `d`; the locks and
//!     Refs embedded in C structures are named fields.
//!   - A read's data goes into r.rbuf, with the count in
//!     r.ofcall.count (the C's r->ofcall.data points at rbuf).
//!   - The strings a server puts in r.d for a stat are from
//!     estrdup9p, as in C; an empty one is "".
//!   - chatty9p is there but prints nothing: fcallfmt (%F) is not
//!     ported.
//!   - A forker is given a function of the Srv.  srvrelease's new
//!     process calls the work loop where it stands; the C first
//!     longjmps back to srv's frame.  Such a process ends with _exits
//!     either way, unless it is the one that called srv.
//!   - No malloc tags.

const std = @import("std");
const libc = @import("libc");
const thread = @import("thread");
const fcall = libc.fcall;

pub const Qid = fcall.Qid;
pub const Dir = fcall.Dir;
pub const Fcall = fcall.Fcall;
pub const Ref = thread.Ref;
pub const incref = thread.incref;
pub const decref = thread.decref;

const intmap_ = @import("intmap.zig");
const fid_ = @import("fid.zig");
const req_ = @import("req.zig");
const file_ = @import("file.zig");
const srv_ = @import("srv.zig");
const util_ = @import("util.zig");
const uid_ = @import("uid.zig");
const dirread_ = @import("dirread.zig");
const mem_ = @import("mem.zig");
const parse_ = @import("parse.zig");
const post_ = @import("post.zig");
const mount_ = @import("mount.zig");
const rfork_ = @import("rfork.zig");
const share_ = @import("share.zig");
const thread_ = @import("thread.zig");
const queue_ = @import("queue.zig");

// Maps from ulongs to void*s.
pub const Intmap = intmap_.Intmap;
pub const allocmap = intmap_.allocmap;
pub const freemap = intmap_.freemap;
pub const lookupkey = intmap_.lookupkey;
pub const insertkey = intmap_.insertkey;
pub const caninsertkey = intmap_.caninsertkey;
pub const deletekey = intmap_.deletekey;

// Fid and Request structures.

pub const Queueelem = struct {
    prev: ?*Queueelem = null,
    next: ?*Queueelem = null,
    f: ?*const fn (*Req) void = null,
};

pub const Reqqueue = queue_.Reqqueue;

pub const Fid = struct {
    fid: u32 = 0,
    omode: i32 = -1, // -1 = not open
    file: ?*File = null,
    uid: []u8 = &.{},
    qid: Qid = .{},
    aux: ?*anyopaque = null,

    // below is implementation-specific; don't use
    rdir: ?*Readdir = null,
    ref: Ref = .{},
    pool: *Fidpool = undefined,
    diroffset: i64 = 0,
    dirindex: i32 = 0,
};

pub const Req = struct {
    tag: u32 = 0,
    aux: ?*anyopaque = null,
    ifcall: Fcall = .{},
    ofcall: Fcall = .{},
    d: Dir = .{},
    oldreq: ?*Req = null,
    fid: ?*Fid = null,
    afid: ?*Fid = null,
    newfid: ?*Fid = null,
    srv: *Srv = undefined,

    qu: Queueelem = .{},

    // below is implementation-specific; don't use
    lk: libc.QLock = .{},
    ref: Ref = .{},
    pool: ?*Reqpool = null,
    buf: []u8 = &.{},
    type: u8 = 0,
    responded: bool = false,
    @"error": ?[]const u8 = null,
    /// What a read answers with: ofcall.count bytes of it.
    rbuf: []u8 = &.{},
    /// The stat message of an Rstat.
    statbuf: []u8 = &.{},
    flush: []*Req = &.{},
};

// Pools to maintain Fid <-> fid and Req <-> tag maps.

pub const Fidpool = struct {
    map: *Intmap = undefined,
    destroy: ?*const fn (*Fid) void = null,
    srv: *Srv = undefined,
};

pub const Reqpool = struct {
    map: *Intmap = undefined,
    destroy: ?*const fn (*Req) void = null,
    srv: *Srv = undefined,
};

pub const allocfidpool = fid_.allocfidpool;
pub const freefidpool = fid_.freefidpool;
pub const allocfid = fid_.allocfid;
pub const lookupfid = fid_.lookupfid;
pub const closefid = fid_.closefid;
pub const removefid = fid_.removefid;

pub const allocreqpool = req_.allocreqpool;
pub const freereqpool = req_.freereqpool;
pub const allocreq = req_.allocreq;
pub const lookupreq = req_.lookupreq;
pub const closereq = req_.closereq;
pub const removereq = req_.removereq;

/// Fill in d for the i'th entry of a directory, its strings from
/// estrdup9p; false when there is no such entry.
pub const Dirgen = dirread_.Dirgen;
pub const dirread9p = dirread_.dirread9p;

// File trees.

pub const Filelist = file_.Filelist;
pub const Readdir = file_.Readdir;

pub const File = struct {
    ref: Ref = .{},
    /// name, uid, gid and muid are the allocator's, and the File's.
    d: Dir = .{},
    parent: ?*File = null,
    aux: ?*anyopaque = null,

    // below is implementation-specific; don't use
    rw: libc.RWLock = .{},
    filelist: ?*Filelist = null,
    tree: *Tree = undefined,
    nchild: i32 = 0,
    allocd: bool = false,
    nxchild: i32 = 0,
    readers: Ref = .{},
};

pub const Tree = struct {
    root: *File = undefined,
    destroy: *const fn (*File) void = undefined,

    // below is implementation-specific; don't use
    genlock: libc.Lock = .{},
    qidgen: u32 = 0,
};

pub const alloctree = file_.alloctree;
pub const freetree = file_.freetree;
pub const createfile = file_.createfile;
pub const removefile = file_.removefile;
pub const closefile = file_.closefile;
pub const walkfile = file_.walkfile;
pub const opendirfile = file_.opendirfile;
pub const readdirfile = file_.readdirfile;
pub const closedirfile = file_.closedirfile;

// Kernel-style command parser
pub const Cmdbuf = parse_.Cmdbuf;
pub const Cmdtab = parse_.Cmdtab;
pub const parsecmd = parse_.parsecmd;
pub const freecmd = parse_.freecmd;
pub const respondcmderror = parse_.respondcmderror;
pub const lookupcmd = parse_.lookupcmd;

/// What starts a process (or a proc) for the server: f(s) runs in it,
/// made with the rfork flags given besides the usual ones.
pub const Forker = *const fn (f: *const fn (*Srv) void, s: *Srv, flag: u32) void;

// File service loop.
pub const Srv = struct {
    tree: ?*Tree = null,
    destroyfid: ?*const fn (*Fid) void = null,
    destroyreq: ?*const fn (*Req) void = null,
    start: ?*const fn (*Srv) void = null,
    end: ?*const fn (*Srv) void = null,
    aux: ?*anyopaque = null,

    attach: ?*const fn (*Req) void = null,
    auth: ?*const fn (*Req) void = null,
    open: ?*const fn (*Req) void = null,
    create: ?*const fn (*Req) void = null,
    read: ?*const fn (*Req) void = null,
    write: ?*const fn (*Req) void = null,
    remove: ?*const fn (*Req) void = null,
    flush: ?*const fn (*Req) void = null,
    stat: ?*const fn (*Req) void = null,
    wstat: ?*const fn (*Req) void = null,
    walk: ?*const fn (*Req) void = null,
    clone: ?*const fn (*Fid, *Fid) ?[]const u8 = null,
    walk1: ?*const fn (*Fid, []const u8, *Qid) ?[]const u8 = null,

    infd: i32 = -1,
    outfd: i32 = -1,
    keyspec: ?[]const u8 = null,

    // below is implementation-specific; don't use
    fpool: ?*Fidpool = null,
    rpool: ?*Reqpool = null,
    msize: u32 = 0,

    rbuf: []u8 = &.{},
    rlock: libc.QLock = .{},
    wbuf: []u8 = &.{},
    wlock: libc.QLock = .{},

    addr: ?[]const u8 = null,

    slock: libc.QLock = .{},
    sref: Ref = .{}, // srvwork procs
    rref: Ref = .{}, // requests in flight

    spid: i32 = 0, // pid of srv() caller
    authok: bool = false, // auth was done on this channel (for none)

    forker: ?Forker = null,
    free: ?*const fn (*Srv) void = null,
};

pub const srvforker = rfork_.srvforker;
pub const threadsrvforker = thread_.threadsrvforker;

pub const srv = srv_.srv;
pub const postsrv = post_.postsrv;
pub const postmountsrv = mount_.postmountsrv;
pub const postsharesrv = share_.postsharesrv;

pub const threadsrv = thread_.threadsrv;
pub const threadpostsrv = thread_.threadpostsrv;
pub const threadpostmountsrv = thread_.threadpostmountsrv;
pub const threadpostsharesrv = thread_.threadpostsharesrv;

pub var chatty9p: i32 = 0;
pub const respond = srv_.respond;
pub const responderror = srv_.responderror;

/// Helper.  Assumes user is same as group.
pub const hasperm = uid_.hasperm;

pub const emalloc9p = mem_.emalloc9p;
pub const erealloc9p = mem_.erealloc9p;
pub const estrdup9p = mem_.estrdup9p;
pub const create9p = mem_.create9p;

pub const OMASK = 3;

pub const readstr = util_.readstr;
pub const readbuf = util_.readbuf;
pub const walkandclone = srv_.walkandclone;

const auth_ = @import("auth.zig");
pub const auth9p = auth_.auth9p;
pub const authread = auth_.authread;
pub const authwrite = auth_.authwrite;
pub const authdestroy = auth_.authdestroy;
pub const authattach = auth_.authattach;

pub const srvacquire = srv_.srvacquire;
pub const srvrelease = srv_.srvrelease;

pub const reqqueuecreate = queue_.reqqueuecreate;
pub const reqqueuepush = queue_.reqqueuepush;
pub const reqqueueflush = queue_.reqqueueflush;
pub const reqqueuefree = queue_.reqqueuefree;
