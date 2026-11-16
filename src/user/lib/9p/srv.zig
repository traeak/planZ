//! The file service loop: what is checked for each message before the
//! server sees it, and what is done after it answers.
//! from lib9p/srv.c

const std = @import("std");
const libc = @import("libc");
const sys = libc.sys;
const p9 = @import("lib9p.zig");
const mem = @import("mem.zig");
const fcall = libc.fcall;

const Srv = p9.Srv;
const Req = p9.Req;
const Fid = p9.Fid;
const Fcall = p9.Fcall;
const File = p9.File;
const Qid = p9.Qid;
const lookupfid = p9.lookupfid;
const allocfid = p9.allocfid;
const removefid = p9.removefid;
const closefid = p9.closefid;
const closereq = p9.closereq;
const qlock = libc.qlock;
const qunlock = libc.qunlock;
const incref = p9.incref;
const decref = p9.decref;

const Ebadoffset = "bad offset";
const Ebotch = "9P protocol botch";
const Ecreatenondir = "create in non-directory";
const Edupfid = "duplicate fid";
const Eduptag = "duplicate tag";
const Eisdir = "is a directory";
const Enocreate = "create prohibited";
const Enoremove = "remove prohibited";
const Enostat = "stat prohibited";
const Enotfound = "file not found";
const Enowrite = "write prohibited";
const Enowstat = "wstat prohibited";
const Eperm = "permission denied";
const Eunknownfid = "unknown fid";
const Ebaddir = "bad directory in wstat";
const Ewalknodir = "walk in non-directory";
const Emsize = "message size too small";

fn setfcallerror(f: *Fcall, err: []const u8) void {
    f.ename = err;
    f.type = fcall.Rerror;
}

fn changemsize(srv_: *Srv, msize: u32) void {
    if (srv_.rbuf.len != 0 and srv_.wbuf.len != 0 and srv_.msize == msize)
        return;
    qlock(&srv_.rlock);
    qlock(&srv_.wlock);
    srv_.msize = msize;
    libc.allocator.free(srv_.rbuf);
    libc.allocator.free(srv_.wbuf);
    srv_.rbuf = mem.emalloc9p(msize);
    srv_.wbuf = mem.emalloc9p(msize);
    qunlock(&srv_.rlock);
    qunlock(&srv_.wlock);
}

fn getreq(s: *Srv) ?*Req {
    var f: Fcall = .{};

    qlock(&s.rlock);
    const n = libc.read9pmsg(s.infd, s.rbuf[0..s.msize]) catch 0;
    if (n == 0) {
        qunlock(&s.rlock);
        return null;
    }

    const buf = mem.emalloc9p(n);
    @memcpy(buf, s.rbuf[0..n]);
    qunlock(&s.rlock);

    if (fcall.convM2S(buf, &f) != n) {
        libc.allocator.free(buf);
        return null;
    }

    const r = p9.allocreq(s.rpool.?, f.tag) orelse {
        // duplicate tag: cons up a fake Req
        const fake = mem.create9p(Req);
        incref(&fake.ref);
        fake.tag = f.tag;
        fake.ifcall = f;
        fake.@"error" = Eduptag;
        fake.buf = buf;
        fake.responded = false;
        fake.type = 0;
        fake.srv = s;
        fake.pool = null;
        return fake;
    };

    r.srv = s;
    r.responded = false;
    r.buf = buf;
    r.ifcall = f;
    r.ofcall = .{};
    r.type = r.ifcall.type;
    return r;
}

fn filewalk(r: *Req) void {
    var f: ?*File = r.fid.?.file.?;

    incref(&f.?.ref);
    var i: usize = 0;
    while (i < r.ifcall.nwname) : (i += 1) {
        f = p9.walkfile(f.?, r.ifcall.wname[i]);
        if (f) |x|
            r.ofcall.wqid[i] = x.d.qid
        else
            break;
    }

    r.ofcall.nwqid = @intCast(i);
    if (f) |x| {
        r.newfid.?.file = x;
        r.newfid.?.qid = x.d.qid;
    }
    respond(r, null);
}

pub const Walk1 = *const fn (*Fid, []const u8, ?*anyopaque) ?[]const u8;
pub const Clone = *const fn (*Fid, *Fid, ?*anyopaque) ?[]const u8;

/// Answer a walk for a server without a file tree: clone (if there is
/// one) is told of a new fid, and walk1 steps the new fid, whose qid
/// it sets, one name at a time; each returns null or the error.
pub fn walkandclone(r: *Req, walk1: Walk1, clone: ?Clone, arg: ?*anyopaque) void {
    const fid = r.fid.?;
    const newfid = r.newfid.?;

    if (fid == newfid and r.ifcall.nwname > 1) {
        respond(r, "lib9p: unused documented feature not implemented");
        return;
    }

    if (fid != newfid) {
        newfid.qid = fid.qid;
        if (clone) |c| {
            if (c(fid, newfid, arg)) |e| {
                respond(r, e);
                return;
            }
        }
    }

    var e: ?[]const u8 = null;
    var i: usize = 0;
    while (i < r.ifcall.nwname) : (i += 1) {
        e = walk1(newfid, r.ifcall.wname[i], arg);
        if (e != null)
            break;
        r.ofcall.wqid[i] = newfid.qid;
    }

    r.ofcall.nwqid = @intCast(i);
    if (e != null and i == 0)
        respond(r, e)
    else
        respond(r, null);
}

fn sversion(srv_: *Srv, r: *Req) void {
    if (srv_.rref.ref != 1) {
        respond(r, Ebotch);
        return;
    }
    if (!std.mem.startsWith(u8, r.ifcall.version, "9P")) {
        r.ofcall.version = "unknown";
        r.ofcall.msize = 256;
        respond(r, null);
        return;
    }
    r.ofcall.version = "9P2000";
    if (r.ifcall.msize < 256) {
        respond(r, Emsize);
        return;
    }
    if (r.ifcall.msize < 1024 * 1024)
        r.ofcall.msize = r.ifcall.msize
    else
        r.ofcall.msize = 1024 * 1024;
    respond(r, null);
}

fn rversion(r: *Req, err: ?[]const u8) void {
    if (err == null)
        changemsize(r.srv, r.ofcall.msize);
}

fn sauth(srv_: *Srv, r: *Req) void {
    var e: [fcall.ERRMAX]u8 = undefined;

    r.afid = allocfid(srv_.fpool.?, r.ifcall.afid) orelse {
        respond(r, Edupfid);
        return;
    };
    if (srv_.auth) |f|
        f(r)
    else
        respond(r, libc.sprint(&e, "%s: authentication not required", .{libc.argv0}));
}

fn rauth(r: *Req, err: ?[]const u8) void {
    const afid = r.afid orelse return;
    if (err != null) {
        closefid(removefid(r.srv.fpool.?, afid.fid));
        return;
    }
    if (afid.omode == -1)
        afid.omode = sys.ORDWR;
}

fn sattach(srv_: *Srv, r: *Req) void {
    const fid = allocfid(srv_.fpool.?, r.ifcall.fid) orelse {
        respond(r, Edupfid);
        return;
    };
    r.fid = fid;
    r.afid = null;
    if (r.ifcall.afid != fcall.NOFID) {
        r.afid = lookupfid(srv_.fpool.?, r.ifcall.afid);
        if (r.afid == null) {
            respond(r, Eunknownfid);
            return;
        }
    }
    fid.uid = mem.estrdup9p(r.ifcall.uname);
    if (srv_.tree) |t| {
        fid.file = t.root;
        incref(&t.root.ref);
        r.ofcall.qid = t.root.d.qid;
        fid.qid = r.ofcall.qid;
    }
    if (srv_.attach) |f|
        f(r)
    else
        respond(r, null);
}

fn rattach(r: *Req, err: ?[]const u8) void {
    if (err != null) {
        if (r.fid) |f|
            closefid(removefid(r.srv.fpool.?, f.fid));
    }
}

fn sflush(srv_: *Srv, r: *Req) void {
    r.oldreq = p9.lookupreq(srv_.rpool.?, r.ifcall.oldtag);
    if (r.oldreq == null or r.oldreq == r)
        respond(r, null)
    else if (srv_.flush) |f|
        f(r)
    else
        respond(r, null);
}

/// False if the answer must wait until the old request is answered.
fn rflush(r: *Req, err: ?[]const u8) bool {
    std.debug.assert(err == null);
    if (r.oldreq) |o| {
        qlock(&o.lk);
        if (!o.responded) {
            o.flush = mem.erealloc9p(o.flush, o.flush.len + 1);
            o.flush[o.flush.len - 1] = r;
            qunlock(&o.lk);
            return false; // delay response until or is responded
        }
        qunlock(&o.lk);
        closereq(o);
    }
    r.oldreq = null;
    return true;
}

fn oldwalk1(fid: *Fid, name: []const u8, arg: ?*anyopaque) ?[]const u8 {
    var qid: Qid = .{};
    const srv_: *Srv = @ptrCast(@alignCast(arg.?));
    if (srv_.walk1.?(fid, name, &qid)) |e|
        return e;
    fid.qid = qid;
    return null;
}

fn oldclone(fid: *Fid, newfid: *Fid, arg: ?*anyopaque) ?[]const u8 {
    const srv_: *Srv = @ptrCast(@alignCast(arg.?));
    const c = srv_.clone orelse return null;
    return c(fid, newfid);
}

fn swalk(srv_: *Srv, r: *Req) void {
    const fid = lookupfid(srv_.fpool.?, r.ifcall.fid) orelse {
        respond(r, Eunknownfid);
        return;
    };
    r.fid = fid;
    if (fid.omode != -1) {
        respond(r, "cannot clone open fid");
        return;
    }
    if (r.ifcall.nwname != 0 and (fid.qid.type & fcall.QTDIR) == 0) {
        respond(r, Ewalknodir);
        return;
    }
    if (r.ifcall.fid != r.ifcall.newfid) {
        const nf = allocfid(srv_.fpool.?, r.ifcall.newfid) orelse {
            respond(r, Edupfid);
            return;
        };
        r.newfid = nf;
        nf.uid = mem.estrdup9p(fid.uid);
    } else {
        incref(&fid.ref);
        r.newfid = fid;
    }
    if (fid.file != null) {
        filewalk(r);
    } else if (srv_.walk1 != null)
        walkandclone(r, oldwalk1, oldclone, srv_)
    else if (srv_.walk) |f|
        f(r)
    else
        libc.sysfatal("no walk function, no file trees", .{});
}

fn rwalk(r: *Req, err: ?[]const u8) void {
    if (err != null or r.ofcall.nwqid < r.ifcall.nwname) {
        if (r.ifcall.fid != r.ifcall.newfid) {
            if (r.newfid) |nf|
                closefid(removefid(r.srv.fpool.?, nf.fid));
        }
        if (r.ofcall.nwqid == 0) {
            if (err == null and r.ifcall.nwname != 0)
                r.@"error" = Enotfound;
        } else r.@"error" = null; // No error on partial walks
    } else {
        if (r.ofcall.nwqid == 0) {
            // Just a clone
            r.newfid.?.qid = r.fid.?.qid;
        } else {
            // if file trees are in use, filewalk took care of the rest
            r.newfid.?.qid = r.ofcall.wqid[r.ofcall.nwqid - 1];
        }
    }
}

fn dirwritable(fid: *Fid) bool {
    if (fid.file) |f| {
        libc.rlock(&f.rw);
        defer libc.runlock(&f.rw);
        if (f.parent) |fp| {
            if (!p9.hasperm(fp, fid.uid, sys.AWRITE))
                return false;
        }
    }
    return true;
}

fn sopen(srv_: *Srv, r: *Req) void {
    const fid = lookupfid(srv_.fpool.?, r.ifcall.fid) orelse {
        respond(r, Eunknownfid);
        return;
    };
    r.fid = fid;
    if (fid.omode != -1) {
        respond(r, Ebotch);
        return;
    }
    if ((fid.qid.type & fcall.QTDIR) != 0 and (r.ifcall.mode & ~@as(u8, sys.ORCLOSE)) != sys.OREAD) {
        respond(r, Eisdir);
        return;
    }
    r.ofcall.qid = fid.qid;
    var p: u32 = switch (r.ifcall.mode & 3) {
        sys.OREAD => sys.AREAD,
        sys.OWRITE => sys.AWRITE,
        sys.ORDWR => sys.AREAD | sys.AWRITE,
        sys.OEXEC => sys.AEXEC,
        else => unreachable,
    };
    if (r.ifcall.mode & sys.OTRUNC != 0)
        p |= sys.AWRITE;
    if ((fid.qid.type & fcall.QTDIR) != 0 and p != sys.AREAD) {
        respond(r, Eperm);
        return;
    }
    if (fid.file) |file| {
        if (!p9.hasperm(file, fid.uid, p)) {
            respond(r, Eperm);
            return;
        }
        if ((r.ifcall.mode & sys.ORCLOSE) != 0 and !dirwritable(fid)) {
            respond(r, Eperm);
            return;
        }
        r.ofcall.qid = file.d.qid;
        if ((r.ofcall.qid.type & fcall.QTDIR) != 0) {
            fid.rdir = p9.opendirfile(file);
            if (fid.rdir == null) {
                respond(r, "opendirfile failed");
                return;
            }
        }
    }
    if (srv_.open) |f|
        f(r)
    else
        respond(r, null);
}

fn screate(srv_: *Srv, r: *Req) void {
    r.fid = lookupfid(srv_.fpool.?, r.ifcall.fid);
    const fid = r.fid orelse return respond(r, Eunknownfid);
    if (fid.omode != -1)
        respond(r, Ebotch)
    else if ((fid.qid.type & fcall.QTDIR) == 0)
        respond(r, Ecreatenondir)
    else if (fid.file != null and !p9.hasperm(fid.file.?, fid.uid, sys.AWRITE))
        respond(r, Eperm)
    else if (srv_.create) |f|
        f(r)
    else
        respond(r, Enocreate);
}

fn ropen(r: *Req, err: ?[]const u8) void {
    if (err != null)
        return;
    const iounit = r.srv.msize - fcall.IOHDRSZ;
    if (r.ofcall.iounit > iounit)
        r.ofcall.iounit = iounit;
    const fid = r.fid.?;
    if (r.ofcall.qid.type & fcall.QTDIR != 0)
        fid.diroffset = 0;
    fid.qid = r.ofcall.qid;
    fid.omode = r.ifcall.mode;
}

fn sread(srv_: *Srv, r: *Req) void {
    const fid = lookupfid(srv_.fpool.?, r.ifcall.fid) orelse {
        respond(r, Eunknownfid);
        return;
    };
    r.fid = fid;
    const o = fid.omode;
    if (o == -1) {
        respond(r, Ebotch);
        return;
    }
    switch (o & 3) {
        sys.OREAD, sys.ORDWR, sys.OEXEC => {},
        else => {
            respond(r, Ebotch);
            return;
        },
    }
    const isdir = (fid.qid.type & fcall.QTDIR) != 0;
    if (r.ifcall.offset < 0 or (isdir and r.ifcall.offset != 0 and r.ifcall.offset != fid.diroffset)) {
        respond(r, Ebadoffset);
        return;
    }
    if (r.ifcall.count > std.math.maxInt(i32)) {
        respond(r, Ebotch);
        return;
    }
    const iounit = srv_.msize - fcall.IOHDRSZ;
    if (r.ifcall.count > iounit)
        r.ifcall.count = iounit;
    r.rbuf = mem.emalloc9p(r.ifcall.count);
    if (isdir and fid.file != null) {
        r.ofcall.count = @intCast(p9.readdirfile(fid.rdir.?, r.rbuf, r.ifcall.offset));
        respond(r, null);
        return;
    }
    if (srv_.read) |f|
        f(r)
    else
        respond(r, "no srv->read");
}

fn rread(r: *Req, err: ?[]const u8) void {
    if (err == null and (r.fid.?.qid.type & fcall.QTDIR) != 0)
        r.fid.?.diroffset = r.ifcall.offset + r.ofcall.count;
}

fn swrite(srv_: *Srv, r: *Req) void {
    const fid = lookupfid(srv_.fpool.?, r.ifcall.fid) orelse {
        respond(r, Eunknownfid);
        return;
    };
    r.fid = fid;
    const o = fid.omode;
    if (o == -1) {
        respond(r, Ebotch);
        return;
    }
    switch (o & 3) {
        sys.OWRITE, sys.ORDWR => {},
        else => {
            respond(r, Ebotch);
            return;
        },
    }
    if (fid.qid.type & fcall.QTDIR != 0) {
        respond(r, Ebotch);
        return;
    }
    if (r.ifcall.offset < 0) {
        respond(r, Ebotch);
        return;
    }
    if (r.ifcall.count > std.math.maxInt(i32)) {
        respond(r, Ebotch);
        return;
    }
    const iounit = srv_.msize - fcall.IOHDRSZ;
    if (r.ifcall.count > iounit)
        r.ifcall.count = iounit;
    if (srv_.write) |f|
        f(r)
    else
        respond(r, Enowrite);
}

fn rwrite(r: *Req, err: ?[]const u8) void {
    if (err != null)
        return;
    if (r.fid.?.file) |f|
        f.d.qid.vers +%= 1;
}

fn sclunk(srv_: *Srv, r: *Req) void {
    r.fid = removefid(srv_.fpool.?, r.ifcall.fid);
    if (r.fid == null)
        respond(r, Eunknownfid)
    else
        respond(r, null);
}

fn sremove(srv_: *Srv, r: *Req) void {
    r.fid = removefid(srv_.fpool.?, r.ifcall.fid);
    const fid = r.fid orelse {
        respond(r, Eunknownfid);
        return;
    };
    if (!dirwritable(fid)) {
        respond(r, Eperm);
        return;
    }
    if (srv_.remove) |f|
        f(r)
    else
        respond(r, if (fid.file != null) null else Enoremove);
}

fn rremove(r: *Req, err: ?[]const u8, errbuf: *[fcall.ERRMAX]u8) void {
    if (err != null)
        return;
    const fid = r.fid.?;
    if (fid.file) |f| {
        // the name, before the file is given up
        var nb: [fcall.ERRMAX]u8 = undefined;
        const name = libc.sprint(&nb, "%s", .{f.d.name});
        p9.removefile(f) catch {
            r.@"error" = libc.sprint(errbuf, "remove %s: %r", .{name});
        };
        fid.file = null;
    }
}

fn sstat(srv_: *Srv, r: *Req) void {
    const fid = lookupfid(srv_.fpool.?, r.ifcall.fid) orelse {
        respond(r, Eunknownfid);
        return;
    };
    r.fid = fid;
    if (fid.file) |f| {
        // should we rlock the file?
        r.d = f.d;
        r.d.name = mem.estrdup9p(r.d.name);
        r.d.uid = mem.estrdup9p(r.d.uid);
        r.d.gid = mem.estrdup9p(r.d.gid);
        r.d.muid = mem.estrdup9p(r.d.muid);
    }
    if (srv_.stat) |f|
        f(r)
    else if (fid.file != null)
        respond(r, null)
    else
        respond(r, Enostat);
}

fn rstat(r: *Req, err: ?[]const u8) void {
    if (err != null)
        return;
    const statbuf = mem.emalloc9p(fcall.sizeD2M(&r.d));
    const n = fcall.convD2M(&r.d, statbuf);
    if (n <= fcall.BIT16SZ or n > r.srv.msize - (fcall.BIT32SZ + fcall.BIT8SZ + fcall.BIT16SZ + fcall.BIT16SZ)) {
        r.@"error" = Emsize;
        libc.allocator.free(statbuf);
        return;
    }
    r.ofcall.nstat = @intCast(n);
    r.statbuf = statbuf; // freed in closereq
    r.ofcall.stat = statbuf;
}

fn swstat(srv_: *Srv, r: *Req) void {
    const fid = lookupfid(srv_.fpool.?, r.ifcall.fid) orelse {
        respond(r, Eunknownfid);
        return;
    };
    r.fid = fid;
    const wstat = srv_.wstat orelse {
        respond(r, Enowstat);
        return;
    };
    // DIFF: the names are copied into memory of the request's (rbuf,
    // freed with it); the C leaves them in the message, where it has
    // room to put a 0 after each
    r.rbuf = mem.emalloc9p(r.ifcall.stat.len + 4);
    if (r.ifcall.stat.len < r.ifcall.nstat or
        fcall.convM2D(r.ifcall.stat[0..r.ifcall.nstat], &r.d, r.rbuf) != r.ifcall.nstat)
    {
        respond(r, Ebaddir);
        return;
    }
    const d = &r.d;
    if (d.qid.path != ~@as(u64, 0) and d.qid.path != fid.qid.path) {
        respond(r, "wstat -- attempt to change qid.path");
        return;
    }
    if (d.qid.vers != ~@as(u32, 0) and d.qid.vers != fid.qid.vers) {
        respond(r, "wstat -- attempt to change qid.vers");
        return;
    }
    if (d.mode != ~@as(u32, 0)) {
        if (d.mode & ~@as(u32, fcall.DMDIR | fcall.DMAPPEND | fcall.DMEXCL | fcall.DMTMP | 0o777) != 0) {
            respond(r, "wstat -- unknown bits in mode");
            return;
        }
        if (d.qid.type != 0xFF and d.qid.type != ((d.mode >> 24) & 0xFF)) {
            respond(r, "wstat -- qid.type/mode mismatch");
            return;
        }
        if (((d.mode >> 24) ^ fid.qid.type) & ~@as(u32, fcall.QTAPPEND | fcall.QTEXCL | fcall.QTTMP) != 0) {
            respond(r, "wstat -- attempt to change qid.type");
            return;
        }
    } else {
        if (d.qid.type != 0xFF and d.qid.type != fid.qid.type) {
            respond(r, "wstat -- attempt to change qid.type");
            return;
        }
    }
    wstat(r);
}

fn srvwork(srv_: *Srv) void {
    while (getreq(srv_)) |r| {
        incref(&srv_.rref);
        if (r.@"error") |e| {
            respond(r, e);
            continue;
        }
        qlock(&srv_.slock);
        switch (r.ifcall.type) {
            fcall.Tversion => sversion(srv_, r),
            fcall.Tauth => sauth(srv_, r),
            fcall.Tattach => sattach(srv_, r),
            fcall.Tflush => sflush(srv_, r),
            fcall.Twalk => swalk(srv_, r),
            fcall.Topen => sopen(srv_, r),
            fcall.Tcreate => screate(srv_, r),
            fcall.Tread => sread(srv_, r),
            fcall.Twrite => swrite(srv_, r),
            fcall.Tclunk => sclunk(srv_, r),
            fcall.Tremove => sremove(srv_, r),
            fcall.Tstat => sstat(srv_, r),
            fcall.Twstat => swstat(srv_, r),
            else => respond(r, "unknown message"),
        }
        if (srv_.sref.ref > 8 and srv_.spid != @as(i32, @intCast(libc.getpid()))) {
            _ = decref(&srv_.sref);
            qunlock(&srv_.slock);
            return;
        }
        qunlock(&srv_.slock);
    }

    if (srv_.end) |f| {
        if (srv_.sref.ref == 1)
            f(srv_);
    }
    if (decref(&srv_.sref) == 0)
        srvclose(srv_);
}

fn srvclose(srv_: *Srv) void {
    if (srv_.rref.ref != 0 or srv_.sref.ref != 0)
        return;

    libc.allocator.free(srv_.rbuf);
    srv_.rbuf = &.{};
    libc.allocator.free(srv_.wbuf);
    srv_.wbuf = &.{};
    srv_.msize = 0;
    if (srv_.fpool) |p|
        p9.freefidpool(p);
    srv_.fpool = null;
    if (srv_.rpool) |p|
        p9.freereqpool(p);
    srv_.rpool = null;

    if (srv_.free) |f|
        f(srv_);
}

/// For a function that will wait: it gives up its turn at the
/// requests with srvrelease (another process is started to read them
/// if this was the last), and takes it back with srvacquire before it
/// responds.
pub fn srvacquire(srv_: *Srv) void {
    incref(&srv_.sref);
    qlock(&srv_.slock);
}

pub fn srvrelease(srv_: *Srv) void {
    if (decref(&srv_.sref) == 0) {
        incref(&srv_.sref);
        srv_.forker.?(srvwork, srv_, 0);
    }
    qunlock(&srv_.slock);
}

/// Serve 9P on srv.infd and srv.outfd until the other end goes away.
pub fn srv(srv_: *Srv) void {
    srv_.spid = @intCast(libc.getpid());
    srv_.sref = .{};
    srv_.rref = .{};

    if (srv_.fpool == null)
        srv_.fpool = p9.allocfidpool(srv_.destroyfid);
    if (srv_.rpool == null)
        srv_.rpool = p9.allocreqpool(srv_.destroyreq);
    if (srv_.msize == 0)
        srv_.msize = 8192 + fcall.IOHDRSZ;

    changemsize(srv_, srv_.msize);

    srv_.fpool.?.srv = srv_;
    srv_.rpool.?.srv = srv_;

    if (srv_.start) |f|
        f(srv_);

    if (srv_.forker == null)
        srv_.forker = p9.srvforker;

    incref(&srv_.sref);
    srvwork(srv_);
}

/// Answer r: with what the server put in r.ofcall, or with the error.
pub fn respond(r: *Req, err: ?[]const u8) void {
    var errbuf: [fcall.ERRMAX]u8 = undefined;

    const srv_ = r.srv;

    std.debug.assert(!r.responded);
    r.@"error" = err;

    switch (r.ifcall.type) {
        // Flush is special.  If the handler says so, we return
        // without further processing.  Respond will be called
        // again once it is safe.
        fcall.Tflush => {
            if (!rflush(r, err))
                return;
        },
        fcall.Tversion => rversion(r, err),
        fcall.Tauth => rauth(r, err),
        fcall.Tattach => rattach(r, err),
        fcall.Twalk => rwalk(r, err),
        fcall.Topen => ropen(r, err),
        fcall.Tcreate => ropen(r, err),
        fcall.Tread => rread(r, err),
        fcall.Twrite => rwrite(r, err),
        fcall.Tclunk => {},
        fcall.Tremove => rremove(r, err, &errbuf),
        fcall.Tstat => rstat(r, err),
        fcall.Twstat => {},
        else => {},
    }

    r.ofcall.tag = r.ifcall.tag;
    r.ofcall.type = r.ifcall.type +% 1;
    if (r.ifcall.type == fcall.Tread)
        r.ofcall.data = r.rbuf;
    if (r.@"error") |e|
        setfcallerror(&r.ofcall, e);

    qlock(&srv_.wlock);
    const n = fcall.convS2M(&r.ofcall, srv_.wbuf[0..srv_.msize]);
    if (n == 0) {
        libc.fprint(2, "%s: msize = %d n = %d type %d\n", .{ libc.argv0, srv_.msize, n, r.ofcall.type });
        sys.exits("abort");
    }
    std.debug.assert(n > 2);
    if (r.pool) |pool| // not a fake
        closereq(p9.removereq(pool, r.ifcall.tag));
    const m = sys.write(srv_.outfd, srv_.wbuf[0..n]);
    if (m != n)
        libc.fprint(2, "%s: 9p write %d returned %d on fd %d: %r\n", .{ libc.argv0, n, m, srv_.outfd });
    qunlock(&srv_.wlock);

    qlock(&r.lk); // no one will add flushes now
    r.responded = true;
    qunlock(&r.lk);

    const fl = r.flush;
    r.flush = &.{};
    for (fl) |f|
        respond(f, null);
    libc.allocator.free(fl);

    if (r.pool != null)
        closereq(r)
    else {
        libc.allocator.free(r.buf);
        libc.allocator.destroy(r);
    }

    if (decref(&srv_.rref) == 0)
        srvclose(srv_);
}

/// Answer r with the process's error string.
pub fn responderror(r: *Req) void {
    var errbuf: [fcall.ERRMAX]u8 = undefined;
    respond(r, libc.rerrstr(&errbuf));
}
