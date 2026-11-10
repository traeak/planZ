//! The first process.
//! from 9/port/userinit.c
//!
//! DIFF: the initcode array is not generated into a C file; it is the
//! a.out image the build links from src/user/initcode.zig.

const std = @import("std");
const arch = @import("../arch.zig");
const portdat = @import("portdat.zig");
const proc = @import("proc.zig");
const ql = @import("qlock.zig");
const chan = @import("chan.zig");
const pgrp = @import("pgrp.zig");
const devenv = @import("devenv.zig");
const segment = @import("segment.zig");
const page = @import("page.zig");
const p9 = @import("print.zig");

const mem = arch.mem;
const panic = p9.panic;

/// The initcode array contains the binary text of the first
/// user process. Its job is to invoke the exec system call
/// for /boot/boot.
/// Initcode does not link with standard plan9 libc _main()
/// trampoline due to size constrains. Instead it is linked
/// with a small machine specific trampoline that
/// only passes arguments to startboot() (see src/user/initcode.zig).
const initcode = @embedFile("initcode");

comptime {
    if (initcode.len > mem.BY2PG) @compileError("initcode does not fit in a page");
}

/// The machine's part of starting the first process: it sets up the
/// environment and the user stack, and leaves for user mode.
pub var init0: *const fn () noreturn = undefined;

fn proc0setup() proc.Error!void {
    const up = arch.up().?;

    up.pgrp = try pgrp.newpgrp();
    up.egrp = try devenv.newegrp();
    up.fgrp = try pgrp.dupfgrp(null);
    up.rgrp = try pgrp.newrgrp();

    // These are o.k. because rootinit is null.
    // Then early kproc's will have a root and dot.
    up.slash = try chan.namec("#/", portdat.Atodir, 0, 0);
    chan.pathclose(up.slash.?.path);
    up.slash.?.path = chan.newpath("/");
    up.dot = try chan.cclone(up.slash.?);

    // Setup Text and Stack segments for initcode.
    ql.qlock(&up.seglock);
    segment.attachseg(up, portdat.SSEG, try segment.newseg(portdat.SG_STACK | portdat.SG_NOEXEC, mem.USTKTOP - mem.USTKSIZE, mem.USTKSIZE / mem.BY2PG));
    segment.attachseg(up, portdat.TSEG, try segment.newseg(portdat.SG_TEXT | portdat.SG_RONLY, mem.UTZERO, 1));
    ql.qunlock(&up.seglock);

    const p = page.newpage(mem.UTZERO, null).?;
    const k = arch.kmap(p);
    const dst: *[mem.BY2PG]u8 = @ptrFromInt(k);
    @memcpy(dst[0..initcode.len], initcode);
    @memset(dst[initcode.len..], 0);
    arch.kunmap(k);
    try segment.segpage(up.seg[portdat.TSEG].?, p);
}

/// The first kernel process starts here.
fn proc0(_: ?*anyopaque) void {
    const up = arch.up().?;

    _ = arch.spllo();

    // The kernel process that proc.kproc made shares the kernel
    // processes' name space; the first process has its own.
    if (up.pgrp) |pg| {
        up.pgrp = null;
        pgrp.closepgrp(pg);
    }
    proc0setup() catch |err| panic("proc0: %s", .{proc.errtext(err)});

    // Become a user process.
    up.kp = false;
    up.noswap = false;
    up.privatemem = false;
    proc.procpriority(up, portdat.PriNormal, false);
    arch.procsetup(up);

    arch.flushmmu();

    // init0():
    //  call chandevinit()
    //  setup environment variables
    //  prepare the stack for initcode
    //  switch to usermode to run initcode
    init0();
}

pub fn userinit() void {
    proc.kproc("*init*", proc0, null);
}
