//! System call dispatch and note delivery.
//! from 9/port/sysproc.c (dosyscall, donotify) and the table that
//! 9/port/mksystab generates from /sys/src/libc/9syscall/sys.h
//!
//! DIFF:
//!   - The table is written out here, not generated.
//!   - A handler takes *Sargs and returns Error!usize.  Failure is a Zig
//!     error, turned here into the -1 and error string the user sees.
//!   - The compatibility calls (the ones with an underscore in sys.h)
//!     only return an error saying they are gone.
//!   - Syscall tracing (Proc_tracesyscall, syscallfmt) is not ported.

const std = @import("std");
const arch = @import("../arch.zig");
const portdat = @import("portdat.zig");
const proc = @import("proc.zig");
const ql = @import("qlock.zig");
const fault = @import("fault.zig");
const devcons = @import("devcons.zig");
const p9 = @import("print.zig");

const Error = proc.Error;
const Sargs = portdat.Sargs;
const Ureg = arch.Ureg;

pub const Syscall = *const fn (*Sargs) Error!usize;

// System call numbers, from /sys/src/libc/9syscall/sys.h
pub const SYSR1 = 0;
pub const _ERRSTR = 1;
pub const BIND = 2;
pub const CHDIR = 3;
pub const CLOSE = 4;
pub const DUP = 5;
pub const ALARM = 6;
pub const EXEC = 7;
pub const EXITS = 8;
pub const _FSESSION = 9;
pub const FAUTH = 10;
pub const _FSTAT = 11;
pub const SEGBRK = 12;
pub const _MOUNT = 13;
pub const OPEN = 14;
pub const _READ = 15;
pub const OSEEK = 16;
pub const SLEEP = 17;
pub const _STAT = 18;
pub const RFORK = 19;
pub const _WRITE = 20;
pub const PIPE = 21;
pub const CREATE = 22;
pub const FD2PATH = 23;
pub const BRK_ = 24;
pub const REMOVE = 25;
pub const _WSTAT = 26;
pub const _FWSTAT = 27;
pub const NOTIFY = 28;
pub const NOTED = 29;
pub const SEGATTACH = 30;
pub const SEGDETACH = 31;
pub const SEGFREE = 32;
pub const SEGFLUSH = 33;
pub const RENDEZVOUS = 34;
pub const UNMOUNT = 35;
pub const _WAIT = 36;
pub const SEMACQUIRE = 37;
pub const SEMRELEASE = 38;
pub const SEEK = 39;
pub const FVERSION = 40;
pub const ERRSTR = 41;
pub const STAT = 42;
pub const FSTAT = 43;
pub const WSTAT = 44;
pub const FWSTAT = 45;
pub const MOUNT = 46;
pub const AWAIT = 47;
pub const PREAD = 50;
pub const PWRITE = 51;
pub const TSEMACQUIRE = 52;
pub const _NSEC = 53;

pub const nsyscall = 54;

const Entry = struct {
    /// What /proc/n/status says while the call is running.
    name: []const u8 = "",
    f: ?Syscall = null,
};

/// Filled in by `install`; a null handler is a call this kernel lacks.
var systab: [nsyscall]Entry = @splat(.{});

/// Install the handler for a call.  The handlers live in sysfile.zig
/// and sysproc.zig; the kernel's start-up code lists them.
pub fn install(n: usize, name: []const u8, f: Syscall) void {
    systab[n] = .{ .name = name, .f = f };
}

/// List the system calls this kernel has.
pub fn systabinit() void {
    const f = @import("sysfile.zig");
    install(BIND, "Bind", f.sysbind);
    install(CHDIR, "Chdir", f.syschdir);
    install(CLOSE, "Close", f.sysclose);
    install(DUP, "Dup", f.sysdup);
    install(OPEN, "Open", f.sysopen);
    install(PIPE, "Pipe", f.syspipe);
    install(CREATE, "Create", f.syscreate);
    install(FD2PATH, "Fd2path", f.sysfd2path);
    install(REMOVE, "Remove", f.sysremove);
    install(UNMOUNT, "Unmount", f.sysunmount);
    install(SEEK, "Seek", f.sysseek);
    install(STAT, "Stat", f.sysstat);
    install(FSTAT, "Fstat", f.sysfstat);
    install(WSTAT, "Wstat", f.syswstat);
    install(FWSTAT, "Fwstat", f.sysfwstat);
    install(MOUNT, "Mount", f.sysmount);
    install(PREAD, "Pread", f.syspread);
    install(PWRITE, "Pwrite", f.syspwrite);
    // The compatibility calls, which only say that they are gone.
    install(_READ, "_read", f.sys_read);
    install(_WRITE, "_write", f.sys_write);
    install(OSEEK, "Oseek", f.sysoseek);
    install(_STAT, "_stat", f.sys_stat);
    install(_FSTAT, "_fstat", f.sys_fstat);
    install(_WSTAT, "_wstat", f.sys_wstat);
    install(_FWSTAT, "_fwstat", f.sys_fwstat);
    install(_MOUNT, "_mount", f.sys_mount);
    // M5: FAUTH and FVERSION, with devmnt.

    const p = @import("sysproc.zig");
    install(SYSR1, "Running", p.sysr1);
    install(ALARM, "Alarm", p.sysalarm);
    install(EXEC, "Exec", p.sysexec);
    install(EXITS, "Exits", p.sysexits);
    install(SEGBRK, "Segbrk", p.syssegbrk);
    install(SLEEP, "Sleep", p.syssleep);
    install(RFORK, "Rfork", p.sysrfork);
    install(BRK_, "Brk", p.sysbrk_);
    install(NOTIFY, "Notify", p.sysnotify);
    install(NOTED, "Noted", p.sysnoted);
    install(SEGATTACH, "Segattach", p.syssegattach);
    install(SEGDETACH, "Segdetach", p.syssegdetach);
    install(SEGFREE, "Segfree", p.syssegfree);
    install(SEGFLUSH, "Segflush", p.syssegflush);
    install(RENDEZVOUS, "Rendez", p.sysrendezvous);
    install(SEMACQUIRE, "Semacquire", p.syssemacquire);
    install(SEMRELEASE, "Semrelease", p.syssemrelease);
    install(ERRSTR, "Errstr", p.syserrstr);
    install(AWAIT, "Await", p.sysawait);
    install(TSEMACQUIRE, "Tsemacquire", p.systsemacquire);
    install(_ERRSTR, "_errstr", p.sys_errstr);
    install(_WAIT, "_wait", p.sys_wait);
    install(_NSEC, "_nsec", p.sys_nsec);
}

/// Run system call scallnr with the arguments at user address `args`.
/// The result goes in *retp.  Returns true if the call was noted(),
/// which replaces the registers and has no result.
pub fn dosyscall(scallnr: usize, args: usize, retp: *u64) bool {
    const up = arch.up().?;

    arch.m().syscall +%= 1;
    up.insyscall = 1;
    const s = arch.spllo();

    var ret: usize = undefined;
    if (call(scallnr, args)) |r| {
        ret = r;
        if (scallnr == NOTED) {
            // special case: noted() changes the ureg, return without setting *retp
            arch.splx(s);
            up.insyscall = 0;
            up.psstate = null;
            return true;
        }
    } else |err| {
        // failure: save the error buffer for errstr
        proc.seterror(err);
        proc.swaperr();
        ret = @bitCast(@as(isize, -1));
    }

    retp.* = ret;

    arch.splx(s);
    up.insyscall = 0;
    up.psstate = null;
    return false;
}

fn call(scallnr: usize, args: usize) Error!usize {
    const up = arch.up().?;
    if (!arch.validalign(args)) return error.Ebadarg;
    const a = try fault.userslice(args, @sizeOf([portdat.MAXSYSARG]usize), false);
    up.s = .{};
    @memcpy(std.mem.asBytes(&up.s.args), a);
    up.scallnr = @intCast(scallnr);

    if (scallnr >= nsyscall or systab[scallnr].f == null) {
        _ = proc.postnote(up, true, "sys: bad sys call", portdat.NDebug);
        return error.Ebadarg;
    }
    up.psstate = systab[scallnr].name;
    return systab[scallnr].f.?(&up.s);
}

/// Deliver a pending note to the current process, which is on its way
/// back to user mode with the registers in ureg.  Returns true if ureg
/// now enters the note handler.
pub fn donotify(ureg: *Ureg) bool {
    const up = arch.up().?;

    if (up.procctl != 0)
        proc.procctl();
    if (up.nnote == 0)
        return false;

    _ = arch.spllo();
    ql.qlock(&up.debug);
    const msg = proc.popnote(ureg) orelse {
        ql.qunlock(&up.debug);
        _ = arch.splhi();
        return false;
    };
    _ = arch.splhi();
    arch.fpunotify(up);
    _ = arch.spllo();
    ql.qunlock(&up.debug);

    const nureg = (if (up.notify != 0) arch.notify(ureg, msg) else null) orelse {
        const debug = up.lastnote.?.flag == portdat.NDebug;
        if (debug)
            _ = devcons.pprint("suicide: %s\n", .{msg});
        proc.pexit(msg, !debug);
    };

    // word under Ureg is old ureg
    @as(*?*Ureg, @ptrFromInt(@intFromPtr(nureg) - @sizeOf(usize))).* = up.noteureg;
    up.noteureg = nureg;
    _ = arch.splhi();
    return true;
}
