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
//!
//! Strings are plain slices here too.  Every call that takes a string
//! uses planZ's own call numbers (64 on, kernel port/syscall.zig), which
//! take a string as two argument words, address then length, so a slice
//! goes to the kernel as it is: no copy, no 0 after it.  The kernel
//! refuses a name with a 0 byte in it ("bad character in file name") as
//! it refuses any control character, and one of 2^16 bytes or more.
//! exec's arguments go as an array of Str pairs.  9front's own calls
//! that take 0-ended strings are not used.
//!
//! Strings coming from the kernel (argv, a note's message) are read
//! through `span`, which looks for the 0 the kernel put after them, and
//! strings it wrote into our buffers (errstr, fd2path) through `upto0`.

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

// planZ's calls that take (address, length) strings
pub const OPENN = 64;
pub const CREATEN = 65;
pub const REMOVEN = 66;
pub const CHDIRN = 67;
pub const STATN = 68;
pub const WSTATN = 69;
pub const BINDN = 70;
pub const MOUNTN = 71;
pub const UNMOUNTN = 72;
pub const SEGATTACHN = 73;
pub const EXITSN = 74;
pub const EXECN = 75;
pub const FAUTHN = 76;

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
        \\p9syscall:                    /* p9syscall(number, &args[7]) */
        \\ pushq %rbp
        \\ pushq %rbx
        \\ pushq %r12
        \\ pushq %r13
        \\ pushq 48(%rsi)
        \\ pushq 40(%rsi)
        \\ pushq 32(%rsi)
        \\ pushq 24(%rsi)
        \\ pushq 16(%rsi)
        \\ pushq 8(%rsi)
        \\ pushq 0(%rsi)
        \\ pushq $0                    /* where the caller's pc would be */
        \\ movq %rdi, %rbp
        \\ syscall
        \\ addq $64, %rsp
        \\ popq %r13
        \\ popq %r12
        \\ popq %rbx
        \\ popq %rbp
        \\ ret
    );
}

/// The most words a call takes: mount's seven.
const maxarg = 7;

extern fn p9syscall(n: usize, args: *const [maxarg]usize) callconv(.c) isize;

/// args is a tuple of up to maxarg words.
fn call(n: usize, args: anytype) isize {
    var a: [maxarg]usize = @splat(0);
    inline for (args, 0..) |v, k| a[k] = v;
    return p9syscall(n, &a);
}

/// A string as two words, for the calls that take a slice.
fn sp(s: []const u8) usize {
    return @intFromPtr(s.ptr);
}

fn i(v: anytype) usize {
    return @bitCast(@as(isize, v));
}

fn seterr(msg: []const u8) void {
    var buf: [ERRMAX]u8 = undefined;
    const n = @min(msg.len, ERRMAX - 1);
    @memcpy(buf[0..n], msg[0..n]);
    buf[n] = 0;
    _ = call(ERRSTR, .{ @intFromPtr(&buf), buf.len });
}

/// The bytes of buf before its first 0, or all of buf if it has none:
/// what errstr or fd2path wrote into it.
pub fn upto0(buf: []const u8) []const u8 {
    for (buf, 0..) |c, k| {
        if (c == 0) return buf[0..k];
    }
    return buf;
}

/// The string the kernel left at p, with no length known (argv, a
/// note's message): the bytes up to its 0.
pub fn span(p: [*]const u8) []const u8 {
    var n: usize = 0;
    while (p[n] != 0) n += 1;
    return p[0..n];
}

pub fn bind(name: []const u8, old: []const u8, flag: u32) isize {
    return call(BINDN, .{ sp(name), name.len, sp(old), old.len, flag });
}

/// A null aname is the empty one, as the kernel takes a nil spec.
pub fn mount(fd: isize, afd: isize, old: []const u8, flag: u32, aname: ?[]const u8) isize {
    const an = aname orelse "";
    return call(MOUNTN, .{ i(fd), i(afd), sp(old), old.len, flag, sp(an), an.len });
}

/// A null name unmounts everything from old.
pub fn unmount(name: ?[]const u8, old: []const u8) isize {
    const nm = name orelse "";
    return call(UNMOUNTN, .{ sp(nm), nm.len, sp(old), old.len });
}

pub fn fversion(fd: isize, msize: i32, vers: []u8) isize {
    return call(FVERSION, .{ i(fd), i(@as(isize, msize)), @intFromPtr(vers.ptr), vers.len });
}

pub fn fauth(fd: isize, aname: []const u8) isize {
    return call(FAUTHN, .{ i(fd), sp(aname), aname.len });
}

pub fn open(name: []const u8, mode: u32) isize {
    return call(OPENN, .{ sp(name), name.len, mode });
}

pub fn create(name: []const u8, mode: u32, perm: u32) isize {
    return call(CREATEN, .{ sp(name), name.len, mode, perm });
}

pub fn close(fd: isize) isize {
    return call(CLOSE, .{ i(fd) });
}

pub fn remove(name: []const u8) isize {
    return call(REMOVEN, .{ sp(name), name.len });
}

pub fn pread(fd: isize, buf: []u8, off: i64) isize {
    return call(PREAD, .{ i(fd), @intFromPtr(buf.ptr), buf.len, @as(u64, @bitCast(off)) });
}

pub fn pwrite(fd: isize, buf: []const u8, off: i64) isize {
    return call(PWRITE, .{ i(fd), @intFromPtr(buf.ptr), buf.len, @as(u64, @bitCast(off)) });
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
    if (call(SEEK, .{ @intFromPtr(&v), i(fd), @as(u64, @bitCast(n)), typ }) < 0)
        return -1;
    return v;
}

pub fn stat(name: []const u8, buf: []u8) isize {
    return call(STATN, .{ sp(name), name.len, @intFromPtr(buf.ptr), buf.len });
}

pub fn fstat(fd: isize, buf: []u8) isize {
    return call(FSTAT, .{ i(fd), @intFromPtr(buf.ptr), buf.len });
}

pub fn wstat(name: []const u8, buf: []const u8) isize {
    return call(WSTATN, .{ sp(name), name.len, @intFromPtr(buf.ptr), buf.len });
}

pub fn fwstat(fd: isize, buf: []const u8) isize {
    return call(FWSTAT, .{ i(fd), @intFromPtr(buf.ptr), buf.len });
}

/// One of exec's arguments as the kernel reads it: 16 bytes, address
/// then length (the layout of a Zig slice is not guaranteed, so this is
/// spelled out).
pub const Str = extern struct {
    ptr: u64,
    len: u64,

    pub fn of(s: []const u8) Str {
        return .{ .ptr = @intFromPtr(s.ptr), .len = s.len };
    }

    pub fn slice(s: Str) []const u8 {
        return @as([*]const u8, @ptrFromInt(s.ptr))[0..s.len];
    }
};

/// Replace the program with name, giving it args (args[0] first),
/// which the kernel copies.  An argument may not have a 0 byte in it.
/// Returns only on failure.
pub fn execstr(name: []const u8, args: []const Str) isize {
    return call(EXECN, .{ sp(name), name.len, @intFromPtr(args.ptr), args.len });
}

/// As execstr, from slices: the pairs are made in strs, which must have
/// room for args.len of them.
pub fn exec(name: []const u8, strs: []Str, args: []const []const u8) isize {
    if (strs.len < args.len) {
        seterr("too many arguments");
        return -1;
    }
    for (args, strs[0..args.len]) |a, *s| s.* = .of(a);
    return execstr(name, strs[0..args.len]);
}

/// Exit with msg as the status; null or empty for success.  The kernel
/// keeps at most ERRMAX-1 bytes of it, up to a 0 byte if it has one.
pub fn exits(msg: ?[]const u8) noreturn {
    if (msg) |m|
        _ = call(EXITSN, .{ sp(m), m.len })
    else
        _ = call(EXITSN, .{ 0 });
    while (true) {}
}

pub fn rfork(flags: u32) isize {
    return call(RFORK, .{ flags });
}

pub fn await(buf: []u8) isize {
    return call(AWAIT, .{ @intFromPtr(buf.ptr), buf.len });
}

pub fn pipe(fd: *[2]i32) isize {
    return call(PIPE, .{ @intFromPtr(fd) });
}

pub fn sleep(ms: u32) isize {
    return call(SLEEP, .{ ms });
}

pub fn alarm(ms: u32) isize {
    return call(ALARM, .{ ms });
}

pub fn brk_(addr: usize) isize {
    return call(BRK_, .{ addr });
}

/// The raw call, as boot.zig uses it; libc.brk rounds as the C does.
pub const brk = brk_;

pub fn segattach(attr: u32, class: []const u8, va: usize, len: u32) usize {
    return @bitCast(call(SEGATTACHN, .{ attr, sp(class), class.len, va, len }));
}

pub fn segbrk(saddr: usize, addr: usize) usize {
    return @bitCast(call(SEGBRK, .{ saddr, addr }));
}

pub fn segdetach(addr: usize) isize {
    return call(SEGDETACH, .{ addr });
}

pub fn segfree(va: usize, len: u32) isize {
    return call(SEGFREE, .{ va, len });
}

pub fn segflush(va: usize, len: u32) isize {
    return call(SEGFLUSH, .{ va, len });
}

/// Swap buf with the process's error string; the kernel puts a 0 after
/// what it writes.
pub fn errstr(buf: []u8) isize {
    return call(ERRSTR, .{ @intFromPtr(buf.ptr), buf.len });
}

/// A note handler as the kernel calls it: the Ureg and the address of
/// the message, which span reads.  It must end with noted.
pub const Notehandler = *const fn (ureg: *anyopaque, msg: [*]const u8) callconv(.c) void;

/// Set the note handler.  The kernel enters it the Plan 9 way, with
/// its arguments on the stack, so f must be a trampoline (see proc.zig).
pub fn notify(f: ?*const anyopaque) isize {
    return call(NOTIFY, .{ @intFromPtr(f) });
}

pub fn noted(v: u32) isize {
    return call(NOTED, .{ v });
}

/// Returns the value the other process gave, which may be any number.
pub fn rendezvous(tag: usize, val: usize) usize {
    return @bitCast(call(RENDEZVOUS, .{ tag, val }));
}

pub fn semacquire(addr: *i32, block: bool) isize {
    return call(SEMACQUIRE, .{ @intFromPtr(addr), @intFromBool(block) });
}

pub fn tsemacquire(addr: *i32, ms: u32) isize {
    return call(TSEMACQUIRE, .{ @intFromPtr(addr), ms });
}

pub fn semrelease(addr: *i32, count: i32) isize {
    return call(SEMRELEASE, .{ @intFromPtr(addr), i(@as(isize, count)) });
}

/// The time in nanoseconds since the epoch; the kernel returns it in
/// the register on 64-bit machines.
pub fn nsec() i64 {
    return call(_NSEC, .{});
}

/// The path of fd's file in buf, with a 0 after it.
pub fn fd2path(fd: isize, buf: []u8) isize {
    return call(FD2PATH, .{ i(fd), @intFromPtr(buf.ptr), buf.len });
}

pub fn dup(old: isize, new: isize) isize {
    return call(DUP, .{ i(old), i(new) });
}

pub fn chdir(name: []const u8) isize {
    return call(CHDIRN, .{ sp(name), name.len });
}
