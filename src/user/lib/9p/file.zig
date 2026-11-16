//! File trees.
//! from lib9p/file.c
//!
//! To avoid deadlock, the following rules must be followed.
//! Always lock child then parent, never parent then child.
//! If holding the free file lock, do not lock any Files.
//!
//! DIFF:
//!   - createfile and removefile return errors, with the C's text in
//!     the error string.
//!   - readdirfile takes the buffer as a slice.

const std = @import("std");
const libc = @import("libc");
const p9 = @import("lib9p.zig");
const mem = @import("mem.zig");
const fcall = libc.fcall;

const File = p9.File;
const Tree = p9.Tree;
const Error = libc.Error;

pub const Filelist = struct {
    f: ?*File = null,
    link: ?*Filelist = null,
};

pub const Readdir = struct {
    dir: *File = undefined,
    fl: ?*Filelist = null,
};

var filelk: libc.QLock = .{};
var freefilelist: ?*File = null;

fn allocfile() *File {
    const N = 16;

    libc.qlock(&filelk);
    if (freefilelist == null) {
        const f = libc.allocator.alloc(File, N) catch
            libc.sysfatal("out of memory allocating %d", .{N * @sizeOf(File)});
        for (f) |*x|
            x.* = .{};
        for (0..N - 1) |i|
            f[i].aux = &f[i + 1];
        f[N - 1].aux = null;
        f[0].allocd = true;
        freefilelist = &f[0];
    }

    const f = freefilelist.?;
    freefilelist = @ptrCast(@alignCast(f.aux));
    libc.qunlock(&filelk);

    const a = f.allocd;
    f.* = .{};
    f.allocd = a;
    return f;
}

fn freefile(f: *File) void {
    var fl = f.filelist;
    while (fl) |x| {
        fl = x.link;
        std.debug.assert(x.f == null);
        libc.allocator.destroy(x);
    }

    libc.allocator.free(f.d.name);
    libc.allocator.free(f.d.uid);
    libc.allocator.free(f.d.gid);
    libc.allocator.free(f.d.muid);
    f.d = .{};
    libc.qlock(&filelk);
    std.debug.assert(f.ref.ref == 0);
    f.aux = freefilelist;
    freefilelist = f;
    libc.qunlock(&filelk);
}

fn cleanfilelist(f: *File) void {
    // can't delete filelist structures while there
    // are open readers of this directory, because
    // they might have references to the structures.
    // instead, just leave the empty refs in the list
    // until there is no activity and then clean up.
    if (f.readers.ref != 0)
        return;
    if (f.nxchild == 0)
        return;

    // no dir readers, file is locked, and
    // there are empty entries in the file list.
    // clean them out.
    var l: *?*Filelist = &f.filelist;
    while (l.*) |fl| {
        if (fl.f == null) {
            l.* = fl.link;
            libc.allocator.destroy(fl);
        } else l = &fl.link;
    }
    f.nxchild = 0;
}

pub fn closefile(f: *File) void {
    if (p9.decref(&f.ref) == 0) {
        f.tree.destroy(f);
        freefile(f);
    }
}

fn nop(_: *File) void {}

/// Take f out of its directory.  The caller's reference to f is given
/// up, whether it works or not.
pub fn removefile(f: *File) Error!void {
    const fp = f.parent orelse {
        libc.werrstr("no parent", .{});
        closefile(f);
        return error.Plan9;
    };

    if (fp == f) {
        libc.werrstr("cannot remove root", .{});
        closefile(f);
        return error.Plan9;
    }

    libc.wlock(&f.rw);
    libc.wlock(&fp.rw);
    if (f.nchild != 0) {
        libc.werrstr("has children", .{});
        libc.wunlock(&fp.rw);
        libc.wunlock(&f.rw);
        closefile(f);
        return error.Plan9;
    }

    if (f.parent != fp) {
        libc.werrstr("parent changed underfoot", .{});
        libc.wunlock(&fp.rw);
        libc.wunlock(&f.rw);
        closefile(f);
        return error.Plan9;
    }

    var fl = fp.filelist;
    while (fl) |x| : (fl = x.link) {
        if (x.f == f)
            break;
    }
    std.debug.assert(fl != null and fl.?.f == f);

    fl.?.f = null;
    fp.nchild -= 1;
    fp.nxchild += 1;
    f.parent = null;
    libc.wunlock(&f.rw);

    cleanfilelist(fp);
    libc.wunlock(&fp.rw);

    closefile(fp); // reference from child
    closefile(f); // reference from tree
    closefile(f);
}

/// A new file in the directory fp, owned by uid (the directory's
/// owner for null).  It is returned with a reference for the caller.
pub fn createfile(fp: *File, name: []const u8, uid: ?[]const u8, perm: u32, aux: ?*anyopaque) Error!*File {
    if ((fp.d.qid.type & fcall.QTDIR) == 0) {
        libc.werrstr("create in non-directory", .{});
        return error.Plan9;
    }

    libc.wlock(&fp.rw);
    if (fp.parent == null) {
        libc.wunlock(&fp.rw);
        libc.werrstr("create in deleted directory", .{});
        return error.Plan9;
    }

    // We might encounter blank spots along the
    // way due to deleted files that have not yet
    // been flushed from the file list.  Don't reuse
    // those - some apps (e.g., omero) depend on
    // the file order reflecting creation order.
    // Always create at the end of the list.
    var l: *?*Filelist = &fp.filelist;
    while (l.*) |x| : (l = &x.link) {
        if (x.f) |xf| {
            if (std.mem.eql(u8, xf.d.name, name)) {
                libc.wunlock(&fp.rw);
                libc.werrstr("file already exists", .{});
                return error.Plan9;
            }
        }
    }

    const fl = mem.create9p(Filelist);
    l.* = fl;

    const f = allocfile();
    f.d.name = mem.estrdup9p(name);
    f.d.uid = mem.estrdup9p(uid orelse fp.d.uid);
    f.d.gid = mem.estrdup9p(fp.d.gid);
    f.d.muid = mem.estrdup9p(uid orelse "unknown");
    f.aux = aux;
    f.d.mode = perm;

    const t = fp.tree;
    libc.lock(&t.genlock);
    f.d.qid.path = t.qidgen;
    t.qidgen +%= 1;
    libc.unlock(&t.genlock);
    if (perm & fcall.DMDIR != 0)
        f.d.qid.type |= fcall.QTDIR;
    if (perm & fcall.DMAPPEND != 0)
        f.d.qid.type |= fcall.QTAPPEND;
    if (perm & fcall.DMEXCL != 0)
        f.d.qid.type |= fcall.QTEXCL;

    f.d.mtime = @truncate(@as(u64, @bitCast(libc.time())));
    f.d.atime = f.d.mtime;
    f.d.length = 0;
    f.parent = fp;
    p9.incref(&fp.ref);
    f.tree = fp.tree;

    p9.incref(&f.ref); // being returned
    p9.incref(&f.ref); // for the tree
    fl.f = f;
    fp.nchild += 1;
    libc.wunlock(&fp.rw);

    return f;
}

fn walkfile1(dir: *File, elem: []const u8) ?*File {
    libc.rlock(&dir.rw);
    if (std.mem.eql(u8, elem, "..")) {
        const fp = dir.parent;
        if (fp) |x|
            p9.incref(&x.ref);
        libc.runlock(&dir.rw);
        closefile(dir);
        return fp;
    }

    var fp: ?*File = null;
    var fl = dir.filelist;
    while (fl) |x| : (fl = x.link) {
        if (x.f) |xf| {
            if (std.mem.eql(u8, xf.d.name, elem)) {
                fp = xf;
                p9.incref(&xf.ref);
                break;
            }
        }
    }

    libc.runlock(&dir.rw);
    closefile(dir);
    return fp;
}

/// The file at path from f, with a reference; f's reference is given
/// up.
pub fn walkfile(f_: *File, path: []const u8) ?*File {
    if (std.mem.indexOfScalar(u8, path, '/') == null)
        return walkfile1(f_, path); // avoid malloc

    var f = f_;
    var s = path;
    while (s.len != 0) {
        var elem = s;
        if (std.mem.indexOfScalar(u8, s, '/')) |i| {
            elem = s[0..i];
            s = s[i + 1 ..];
        } else s = s[s.len..];
        f = walkfile1(f, elem) orelse return null;
    }
    return f;
}

pub fn alloctree(uid_: ?[]const u8, gid_: ?[]const u8, mode: u32, destroy: ?*const fn (*File) void) *Tree {
    const t = mem.create9p(Tree);
    const f = allocfile();
    f.d.name = mem.estrdup9p("/");
    const uid = mem.estrdup9p(uid_ orelse libc.getuser());
    const gid = mem.estrdup9p(gid_ orelse uid);
    const muid = mem.estrdup9p(uid);

    f.d.qid = .{ .path = 0, .vers = 0, .type = fcall.QTDIR };
    f.d.length = 0;
    f.d.mtime = @truncate(@as(u64, @bitCast(libc.time())));
    f.d.atime = f.d.mtime;
    f.d.mode = fcall.DMDIR | mode;
    f.tree = t;
    f.parent = f;
    f.d.uid = uid;
    f.d.gid = gid;
    f.d.muid = muid;

    p9.incref(&f.ref);
    t.root = f;

    // t.qidgen starts at 1 because root Qid.path is 0
    t.qidgen = 1;
    t.destroy = destroy orelse nop;

    return t;
}

fn _freefiles(f: *File) void {
    var fl = f.filelist;
    f.filelist = null;
    while (fl) |x| {
        fl = x.link;
        // DIFF: an entry of a removed file has no file; the C
        // passes its nil on
        if (x.f) |xf| {
            x.f = null;
            _freefiles(xf);
        }
        libc.allocator.destroy(x);
    }

    f.tree.destroy(f);
    f.ref.ref = 0;
    freefile(f);
}

pub fn freetree(t: *Tree) void {
    _freefiles(t.root);
    libc.allocator.destroy(t);
}

pub fn opendirfile(dir: *File) ?*Readdir {
    libc.rlock(&dir.rw);
    if ((dir.d.mode & fcall.DMDIR) == 0) {
        libc.runlock(&dir.rw);
        return null;
    }
    const r = mem.create9p(Readdir);

    // This reference won't go away while we're
    // using it because file list entries are not freed
    // until the directory is removed and all refs to
    // it (our fid is one!) have gone away.
    r.fl = dir.filelist;
    r.dir = dir;
    p9.incref(&dir.readers);
    libc.runlock(&dir.rw);
    return r;
}

/// Entries of the directory into buf, from the start for an offset
/// of 0 and from where the last read ended otherwise; returns the
/// bytes written.
pub fn readdirfile(r: *Readdir, buf: []u8, o: i64) usize {
    var fl = if (o == 0) r.dir.filelist else r.fl;
    var m: usize = 0;
    while (fl) |x| {
        if (m + 2 > buf.len)
            break;
        var n: usize = 0;
        if (x.f) |xf| {
            n = fcall.convD2M(&xf.d, buf[m..]);
            if (n <= fcall.BIT16SZ)
                break;
        }
        fl = x.link;
        m += n;
    }
    r.fl = fl;
    return m;
}

pub fn closedirfile(r: *Readdir) void {
    if (p9.decref(&r.dir.readers) == 0) {
        libc.wlock(&r.dir.rw);
        cleanfilelist(r.dir);
        libc.wunlock(&r.dir.rw);
    }
    libc.allocator.destroy(r);
}
