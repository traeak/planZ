//! System calls for planZ's own user programs: the Plan 9 amd64 calling
//! convention, with the call number in RBP and the arguments on the
//! stack above a slot for the return address.
//! Numbers from /sys/src/libc/9syscall/sys.h; prototypes from libc.h,
//! argument layouts as the kernel's handlers read them (port/sysfile.zig,
//! sysproc.zig, auth.zig).
//!
//! These are the raw calls: each returns what the kernel returns, -1
//! (or ~0 for an address) on error, with the message in the process's
//! error string.  libc.zig has checked versions that return Zig errors.

pub const SYSR1 = 0;
pub const BIND = 2;
pub const CHDIR = 3;
pub const CLOSE = 4;
pub const DUP = 5;
pub const ALARM = 6;
pub const EXEC = 7;
pub const EXITS = 8;
pub const FAUTH = 10;
pub const SEGBRK = 12;
pub const OPEN = 14;
pub const SLEEP = 17;
pub const RFORK = 19;
pub const PIPE = 21;
pub const CREATE = 22;
pub const FD2PATH = 23;
pub const BRK_ = 24;
pub const REMOVE = 25;
pub const NOTIFY = 28;
pub const NOTED = 29;
pub const SEGATTACH = 30;
pub const SEGDETACH = 31;
pub const SEGFREE = 32;
pub const SEGFLUSH = 33;
pub const RENDEZVOUS = 34;
pub const UNMOUNT = 35;
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

pub const OREAD = 0;
pub const OWRITE = 1;
pub const ORDWR = 2;
pub const OEXEC = 3;
pub const OTRUNC = 16;
pub const OCEXEC = 32;
pub const ORCLOSE = 64;
pub const OEXCL = 0x1000;

pub const AEXIST = 0;
pub const AEXEC = 1;
pub const AWRITE = 2;
pub const AREAD = 4;

pub const MREPL = 0;
pub const MBEFORE = 1;
pub const MAFTER = 2;
pub const MCREATE = 4;
pub const MCACHE = 16;

pub const RFNAMEG = 1 << 0;
pub const RFENVG = 1 << 1;
pub const RFFDG = 1 << 2;
pub const RFNOTEG = 1 << 3;
pub const RFPROC = 1 << 4;
pub const RFMEM = 1 << 5;
pub const RFNOWAIT = 1 << 6;
pub const RFCNAMEG = 1 << 10;
pub const RFCENVG = 1 << 11;
pub const RFCFDG = 1 << 12;
pub const RFREND = 1 << 13;
pub const RFNOMNT = 1 << 14;

pub const NCONT = 0;
pub const NDFLT = 1;

pub const ERRMAX = 128;

comptime {
    asm (
        \\ .text
        \\ .globl p9syscall
        \\p9syscall:                    /* p9syscall(number, &args[5]) */
        \\ pushq %rbp
        \\ pushq %rbx
        \\ pushq %r12
        \\ pushq %r13
        \\ pushq 32(%rsi)
        \\ pushq 24(%rsi)
        \\ pushq 16(%rsi)
        \\ pushq 8(%rsi)
        \\ pushq 0(%rsi)
        \\ pushq $0                    /* where the caller's pc would be */
        \\ movq %rdi, %rbp
        \\ syscall
        \\ addq $48, %rsp
        \\ popq %r13
        \\ popq %r12
        \\ popq %rbx
        \\ popq %rbp
        \\ ret
    );
}

extern fn p9syscall(n: usize, args: *const [5]usize) callconv(.c) isize;

fn call(n: usize, args: [5]usize) isize {
    return p9syscall(n, &args);
}

fn z(s: [*:0]const u8) usize {
    return @intFromPtr(s);
}

fn oz(s: ?[*:0]const u8) usize {
    return @intFromPtr(s);
}

fn i(v: anytype) usize {
    return @bitCast(@as(isize, v));
}

pub fn bind(name: [*:0]const u8, old: [*:0]const u8, flag: u32) isize {
    return call(BIND, .{ z(name), z(old), flag, 0, 0 });
}

pub fn mount(fd: isize, afd: isize, old: [*:0]const u8, flag: u32, aname: ?[*:0]const u8) isize {
    return call(MOUNT, .{ i(fd), i(afd), z(old), flag, oz(aname) });
}

pub fn unmount(name: ?[*:0]const u8, old: [*:0]const u8) isize {
    return call(UNMOUNT, .{ oz(name), z(old), 0, 0, 0 });
}

pub fn fversion(fd: isize, msize: i32, vers: []u8) isize {
    return call(FVERSION, .{ i(fd), i(@as(isize, msize)), @intFromPtr(vers.ptr), vers.len, 0 });
}

pub fn fauth(fd: isize, aname: [*:0]const u8) isize {
    return call(FAUTH, .{ i(fd), z(aname), 0, 0, 0 });
}

pub fn open(name: [*:0]const u8, mode: u32) isize {
    return call(OPEN, .{ z(name), mode, 0, 0, 0 });
}

pub fn create(name: [*:0]const u8, mode: u32, perm: u32) isize {
    return call(CREATE, .{ z(name), mode, perm, 0, 0 });
}

pub fn close(fd: isize) isize {
    return call(CLOSE, .{ i(fd), 0, 0, 0, 0 });
}

pub fn remove(name: [*:0]const u8) isize {
    return call(REMOVE, .{ z(name), 0, 0, 0, 0 });
}

pub fn pread(fd: isize, buf: []u8, off: i64) isize {
    return call(PREAD, .{ i(fd), @intFromPtr(buf.ptr), buf.len, @bitCast(off), 0 });
}

pub fn pwrite(fd: isize, buf: []const u8, off: i64) isize {
    return call(PWRITE, .{ i(fd), @intFromPtr(buf.ptr), buf.len, @bitCast(off), 0 });
}

pub fn read(fd: isize, buf: []u8) isize {
    return pread(fd, buf, -1);
}

pub fn write(fd: isize, buf: []const u8) isize {
    return pwrite(fd, buf, -1);
}

/// The kernel returns the new offset through the first argument.
pub fn seek(fd: isize, n: i64, typ: u32) i64 {
    var v: i64 = -1;
    if (call(SEEK, .{ @intFromPtr(&v), i(fd), @bitCast(n), typ, 0 }) < 0)
        return -1;
    return v;
}

pub fn stat(name: [*:0]const u8, buf: []u8) isize {
    return call(STAT, .{ z(name), @intFromPtr(buf.ptr), buf.len, 0, 0 });
}

pub fn fstat(fd: isize, buf: []u8) isize {
    return call(FSTAT, .{ i(fd), @intFromPtr(buf.ptr), buf.len, 0, 0 });
}

pub fn wstat(name: [*:0]const u8, buf: []const u8) isize {
    return call(WSTAT, .{ z(name), @intFromPtr(buf.ptr), buf.len, 0, 0 });
}

pub fn fwstat(fd: isize, buf: []const u8) isize {
    return call(FWSTAT, .{ i(fd), @intFromPtr(buf.ptr), buf.len, 0, 0 });
}

pub fn exec(name: [*:0]const u8, argv: [*]const ?[*:0]const u8) isize {
    return call(EXEC, .{ z(name), @intFromPtr(argv), 0, 0, 0 });
}

pub fn exits(msg: ?[*:0]const u8) noreturn {
    _ = call(EXITS, .{ oz(msg), 0, 0, 0, 0 });
    while (true) {}
}

pub fn rfork(flags: u32) isize {
    return call(RFORK, .{ flags, 0, 0, 0, 0 });
}

pub fn await(buf: []u8) isize {
    return call(AWAIT, .{ @intFromPtr(buf.ptr), buf.len, 0, 0, 0 });
}

pub fn pipe(fd: *[2]i32) isize {
    return call(PIPE, .{ @intFromPtr(fd), 0, 0, 0, 0 });
}

pub fn sleep(ms: u32) isize {
    return call(SLEEP, .{ ms, 0, 0, 0, 0 });
}

pub fn alarm(ms: u32) isize {
    return call(ALARM, .{ ms, 0, 0, 0, 0 });
}

pub fn brk_(addr: usize) isize {
    return call(BRK_, .{ addr, 0, 0, 0, 0 });
}

/// The raw call, as boot.zig uses it; libc.brk rounds as the C does.
pub const brk = brk_;

pub fn segattach(attr: u32, class: [*:0]const u8, va: usize, len: u32) usize {
    return @bitCast(call(SEGATTACH, .{ attr, z(class), va, len, 0 }));
}

pub fn segbrk(saddr: usize, addr: usize) usize {
    return @bitCast(call(SEGBRK, .{ saddr, addr, 0, 0, 0 }));
}

pub fn segdetach(addr: usize) isize {
    return call(SEGDETACH, .{ addr, 0, 0, 0, 0 });
}

pub fn segfree(va: usize, len: u32) isize {
    return call(SEGFREE, .{ va, len, 0, 0, 0 });
}

pub fn segflush(va: usize, len: u32) isize {
    return call(SEGFLUSH, .{ va, len, 0, 0, 0 });
}

pub fn errstr(buf: []u8) isize {
    return call(ERRSTR, .{ @intFromPtr(buf.ptr), buf.len, 0, 0, 0 });
}

pub fn notify(f: ?*const fn (ureg: *anyopaque, msg: [*:0]const u8) callconv(.c) void) isize {
    return call(NOTIFY, .{ @intFromPtr(f), 0, 0, 0, 0 });
}

pub fn noted(v: u32) isize {
    return call(NOTED, .{ v, 0, 0, 0, 0 });
}

/// Returns the value the other process gave, which may be any number.
pub fn rendezvous(tag: usize, val: usize) usize {
    return @bitCast(call(RENDEZVOUS, .{ tag, val, 0, 0, 0 }));
}

pub fn semacquire(addr: *i32, block: bool) isize {
    return call(SEMACQUIRE, .{ @intFromPtr(addr), @intFromBool(block), 0, 0, 0 });
}

pub fn tsemacquire(addr: *i32, ms: u32) isize {
    return call(TSEMACQUIRE, .{ @intFromPtr(addr), ms, 0, 0, 0 });
}

pub fn semrelease(addr: *i32, count: i32) isize {
    return call(SEMRELEASE, .{ @intFromPtr(addr), i(@as(isize, count)), 0, 0, 0 });
}

/// The time in nanoseconds since the epoch; the kernel returns it in
/// the register on 64-bit machines.
pub fn nsec() i64 {
    return call(_NSEC, .{ 0, 0, 0, 0, 0 });
}

pub fn fd2path(fd: isize, buf: []u8) isize {
    return call(FD2PATH, .{ i(fd), @intFromPtr(buf.ptr), buf.len, 0, 0 });
}

pub fn dup(old: isize, new: isize) isize {
    return call(DUP, .{ i(old), i(new), 0, 0, 0 });
}

pub fn chdir(name: [*:0]const u8) isize {
    return call(CHDIR, .{ z(name), 0, 0, 0, 0 });
}
