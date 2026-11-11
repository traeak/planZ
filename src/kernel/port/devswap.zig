//! The device #¶: /dev/swap, the memory statistics file.
//! from 9/port/devswap.c
//!
//! DIFF:
//!   - swap: planZ has no swap.  Only the device and the text of
//!     /dev/swap are here.  The swap map, putswap/dupswap/swapcount,
//!     pageout, executeio, setswapchan and the encrypted swapfile are
//!     not ported; what is left of the pager (kickpager, killbig,
//!     reclaim, pager) is in page.zig, which also starts it, so this
//!     device has no init.
//!   - The directory has no "swapfile".
//!   - Reading swap reports "0/0 swap".  reclaim counts only idle image
//!     pages: there is no fscache (no mount cache) and no swapimage.
//!   - Writing a file descriptor number, which in 9front makes that
//!     file the swap file, fails with "no swap".  "start" still kicks
//!     the pager.

const std = @import("std");
const fcall = @import("fcall");
const fmt = @import("fmt");
const arch = @import("../arch.zig");
const portdat = @import("portdat.zig");
const alloc = @import("alloc.zig");
const proc = @import("proc.zig");
const page = @import("page.zig");
const segment = @import("segment.zig");
const devcons = @import("devcons.zig");
const devmod = @import("dev.zig");

const Error = proc.Error;
const Chan = portdat.Chan;
const Walkqid = portdat.Walkqid;
const Dirtab = devmod.Dirtab;
const BY2PG = arch.mem.BY2PG;
const iseve = devcons.iseve;
const readstr = devcons.readstr;

const Qdir = 0;
const Qswap = 1;

const swapdir = [_]Dirtab{
    .{ .name = ".", .qid = .{ .path = Qdir, .type = fcall.QTDIR }, .length = 0, .perm = fcall.DMDIR | 0o555 },
    .{ .name = "swap", .qid = .{ .path = Qswap }, .length = 0, .perm = 0o664 },
};

fn swapattach(spec: []const u8) Error!*Chan {
    return devmod.devattach('¶', spec);
}

fn swapwalk(c: *Chan, nc: ?*Chan, name: []const []const u8) Error!*Walkqid {
    return devmod.devwalk(c, nc, name, &swapdir, devmod.devgen);
}

fn swapstat(c: *Chan, dp: []u8) Error!usize {
    return devmod.devstat(c, dp, &swapdir, devmod.devgen);
}

fn swapopen(c: *Chan, omode: u32) Error!*Chan {
    return devmod.devopen(c, omode, &swapdir, devmod.devgen);
}

fn swapclose(_: *Chan) Error!void {}

fn swapread(c: *Chan, va: []u8, off: i64) Error!usize {
    var tmp: [256]u8 = undefined; // must be >= 18*NUMSIZE (Qswap)

    switch (c.qid.path) {
        Qdir => return devmod.devdirread(c, va, &swapdir, devmod.devgen),
        Qswap => {
            const conf = arch.conf;
            const reclaim: usize = segment.imagecached();
            const kpages: usize = conf.npage - conf.upages;
            const s = fmt.snprint(&tmp, "%llud memory\n" ++
                "%llud pagesize\n" ++
                "%lud kernel\n" ++
                "%lud/%lud user\n" ++
                "%lud/%lud swap\n" ++
                "%lud/%lud reclaim\n" ++
                "%llud/%llud/%llud kernel malloc\n" ++
                "%llud/%llud/%llud kernel draw\n" ++
                "%llud/%llud/%llud kernel secret\n", .{
                @as(u64, conf.npage) * BY2PG,
                @as(u64, BY2PG),
                kpages,
                page.palloc.user -% page.palloc.freecount -% reclaim,
                page.palloc.user,
                @as(usize, 0),
                @as(usize, 0),
                reclaim,
                page.palloc.user,
                @as(u64, alloc.mainmem.curalloc),
                @as(u64, alloc.mainmem.cursize),
                @as(u64, alloc.mainmem.maxsize),
                @as(u64, alloc.imagmem.curalloc),
                @as(u64, alloc.imagmem.cursize),
                @as(u64, alloc.imagmem.maxsize),
                @as(u64, alloc.secrmem.curalloc),
                @as(u64, alloc.secrmem.cursize),
                @as(u64, alloc.secrmem.maxsize),
            });
            return readstr(@as(u32, @truncate(@as(u64, @bitCast(off)))), va, s);
        },
        else => {},
    }
    return error.Egreg;
}

fn swapwrite(c: *Chan, va: []const u8, _: i64) Error!usize {
    switch (c.qid.path) {
        Qswap => {
            if (!iseve())
                return error.Eperm;
            if (va.len >= 256)
                return error.Egreg;
            // start a pager if not already started
            if (std.mem.startsWith(u8, va, "start"))
                page.kickpager()
            else if (va.len > 0 and va[0] >= '0' and va[0] <= '9')
                // DIFF: swap — setswapchan(fdtochan(...)) in the C.
                return proc.errorf("no swap", .{})
            else
                return error.Ebadctl;
            return va.len;
        },
        else => {},
    }
    return error.Egreg;
}

pub const swapdevtab: devmod.Dev = .{
    .dc = '¶',
    .name = "swap",

    .attach = swapattach,
    .walk = swapwalk,
    .stat = swapstat,
    .open = swapopen,
    .close = swapclose,
    .read = swapread,
    .write = swapwrite,
};
