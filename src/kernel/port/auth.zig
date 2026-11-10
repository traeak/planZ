//! The two system calls that set up a 9P connection: fversion and fauth.
//! from 9/port/auth.c
//!
//! DIFF:
//!   - Only sysfversion and sysfauth are here.  The rest of auth.c (eve,
//!     hostdomain, iseve, sys_fsession, userwrite, hostownerwrite,
//!     hostdomainwrite) is not ported yet; eve is in proc.zig and
//!     devcons.zig and devenv.zig have private copies of iseve.
//!   - A handler takes *Sargs and returns Error!usize; each waserror is
//!     a defer or errdefer.
//!   - sysfversion passes the user's buffer to mntversion as a slice;
//!     the buffer is both the version asked for and where the answer
//!     goes.

const std = @import("std");
const portdat = @import("portdat.zig");
const lib = @import("lib.zig");
const alloc = @import("alloc.zig");
const proc = @import("proc.zig");
const chan = @import("chan.zig");
const fault = @import("fault.zig");
const sysfile = @import("sysfile.zig");
const devmnt = @import("devmnt.zig");

const cclose = chan.cclose;

pub const Error = proc.Error;
const Sargs = portdat.Sargs;

pub fn sysfversion(a: *Sargs) Error!usize {
    const fd = a.next(i32);
    const msize = a.next(i32);
    const uvers = a.next(usize);
    const arglen = a.next(i32);
    // a negative length becomes a huge one and is refused, as in C
    const vers = try fault.userslice(uvers, @bitCast(@as(isize, arglen)), true);
    // check there's a NUL in the version string
    if (arglen <= 0 or std.mem.findScalar(u8, vers, 0) == null)
        return error.Ebadarg;
    const c = try sysfile.fdtochan(fd, lib.ORDWR, false, true);
    defer cclose(c);
    return devmnt.mntversion(c, vers, msize, vers.len);
}

pub fn sysfauth(a: *Sargs) Error!usize {
    const fd = a.next(i32);
    const uaname = a.next(usize);
    const aname = try chan.validnamedup(try fault.userstr(uaname), true);
    const ac = blk: {
        defer alloc.free(aname.ptr);
        const c = try sysfile.fdtochan(fd, lib.ORDWR, false, true);
        defer cclose(c);

        break :blk try devmnt.mntauth(c, aname);
        // at this point ac is responsible for keeping c alive
    };
    errdefer cclose(ac);

    // always mark it close on exec
    const nfd = sysfile.newfd(ac, lib.OCEXEC);
    if (nfd < 0)
        return error.Enofd;

    return @intCast(nfd);
}
