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
//! Strings are plain slices here too.  The kernel takes a string as the
//! address of bytes ending in a 0, so each call copies its strings into
//! a plain buffer on the stack (Name), puts the 0 after them and passes
//! the address.  A string with a 0 byte in it is refused ("bad character
//! in file name"), and so is one of Name.max bytes or more ("file name
//! too long"): this layer cannot allocate, because initcode uses it.
//! Strings coming from the kernel (argv, a note's message) are read
//! through `span`, which looks for the 0 the kernel put after them.

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

fn i(v: anytype) usize {
    return @bitCast(@as(isize, v));
}

fn seterr(msg: []const u8) void {
    var buf: [ERRMAX]u8 = undefined;
    const n = @min(msg.len, ERRMAX - 1);
    @memcpy(buf[0..n], msg[0..n]);
    buf[n] = 0;
    _ = call(ERRSTR, .{ @intFromPtr(&buf), buf.len, 0, 0, 0 });
}

/// A string copied for the kernel, with the 0 it wants after it.
pub const Name = struct {
    pub const max = 1024;

    buf: [max]u8 = undefined,

    /// The address to pass, or null (with the error string set) if s
    /// does not fit or has a 0 byte in it.
    pub fn of(n: *Name, s: []const u8) ?usize {
        if (s.len >= max) {
            seterr("file name too long");
            return null;
        }
        for (s) |c| {
            if (c == 0) {
                seterr("bad character in file name");
                return null;
            }
        }
        @memcpy(n.buf[0..s.len], s);
        n.buf[s.len] = 0;
        return @intFromPtr(&n.buf);
    }

    /// As `of`, for an optional string: null becomes address 0.
    pub fn ofopt(n: *Name, s: ?[]const u8) ?usize {
        const x = s orelse return 0;
        return n.of(x);
    }
};

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
    var n1: Name = .{};
    var n2: Name = .{};
    return call(BIND, .{ n1.of(name) orelse return -1, n2.of(old) orelse return -1, flag, 0, 0 });
}

pub fn mount(fd: isize, afd: isize, old: []const u8, flag: u32, aname: ?[]const u8) isize {
    var n1: Name = .{};
    var n2: Name = .{};
    const an = n2.ofopt(aname) orelse return -1;
    return call(MOUNT, .{ i(fd), i(afd), n1.of(old) orelse return -1, flag, an });
}

pub fn unmount(name: ?[]const u8, old: []const u8) isize {
    var n1: Name = .{};
    var n2: Name = .{};
    const nm = n1.ofopt(name) orelse return -1;
    return call(UNMOUNT, .{ nm, n2.of(old) orelse return -1, 0, 0, 0 });
}

pub fn fversion(fd: isize, msize: i32, vers: []u8) isize {
    return call(FVERSION, .{ i(fd), i(@as(isize, msize)), @intFromPtr(vers.ptr), vers.len, 0 });
}

pub fn fauth(fd: isize, aname: []const u8) isize {
    var n: Name = .{};
    return call(FAUTH, .{ i(fd), n.of(aname) orelse return -1, 0, 0, 0 });
}

pub fn open(name: []const u8, mode: u32) isize {
    var n: Name = .{};
    return call(OPEN, .{ n.of(name) orelse return -1, mode, 0, 0, 0 });
}

pub fn create(name: []const u8, mode: u32, perm: u32) isize {
    var n: Name = .{};
    return call(CREATE, .{ n.of(name) orelse return -1, mode, perm, 0, 0 });
}

pub fn close(fd: isize) isize {
    return call(CLOSE, .{ i(fd), 0, 0, 0, 0 });
}

pub fn remove(name: []const u8) isize {
    var n: Name = .{};
    return call(REMOVE, .{ n.of(name) orelse return -1, 0, 0, 0, 0 });
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

pub fn stat(name: []const u8, buf: []u8) isize {
    var n: Name = .{};
    return call(STAT, .{ n.of(name) orelse return -1, @intFromPtr(buf.ptr), buf.len, 0, 0 });
}

pub fn fstat(fd: isize, buf: []u8) isize {
    return call(FSTAT, .{ i(fd), @intFromPtr(buf.ptr), buf.len, 0, 0 });
}

pub fn wstat(name: []const u8, buf: []const u8) isize {
    var n: Name = .{};
    return call(WSTAT, .{ n.of(name) orelse return -1, @intFromPtr(buf.ptr), buf.len, 0, 0 });
}

pub fn fwstat(fd: isize, buf: []const u8) isize {
    return call(FWSTAT, .{ i(fd), @intFromPtr(buf.ptr), buf.len, 0, 0 });
}

/// The room `exec` needs in its buffer for these arguments.
pub fn argvsize(args: []const []const u8) usize {
    var n: usize = (args.len + 1) * @sizeOf(usize);
    for (args) |a| n += a.len + 1;
    return n;
}

/// Replace the program with name, giving it args (args[0] first).
/// The kernel wants a 0-ended array of addresses of 0-ended strings;
/// they are laid out in buf, which must be 8-aligned and have
/// argvsize(args) bytes.  Returns only on failure.
pub fn exec(name: []const u8, buf: []align(@alignOf(usize)) u8, args: []const []const u8) isize {
    if (buf.len < argvsize(args)) {
        seterr("arguments too long");
        return -1;
    }
    const nptr = (args.len + 1) * @sizeOf(usize);
    const addrs: []usize = @as([*]usize, @ptrCast(buf.ptr))[0 .. args.len + 1];
    var p = nptr;
    for (args, 0..) |a, k| {
        for (a) |c| {
            if (c == 0) {
                seterr("bad character in argument");
                return -1;
            }
        }
        @memcpy(buf[p..][0..a.len], a);
        buf[p + a.len] = 0;
        addrs[k] = @intFromPtr(&buf[p]);
        p += a.len + 1;
    }
    addrs[args.len] = 0;
    return execaddrs(name, addrs.ptr);
}

/// exec with the array of string addresses already made, as the kernel
/// left it on initcode's stack: a 0-ended array of addresses.
pub fn execaddrs(name: []const u8, argv: [*]const usize) isize {
    var n: Name = .{};
    return call(EXEC, .{ n.of(name) orelse return -1, @intFromPtr(argv), 0, 0, 0 });
}

/// Exit with msg as the status; null or empty for success.  A message
/// of ERRMAX bytes or more is cut, and one with a 0 byte ends there.
pub fn exits(msg: ?[]const u8) noreturn {
    var buf: [ERRMAX]u8 = undefined;
    var a: usize = 0;
    if (msg) |m| {
        const n = @min(m.len, ERRMAX - 1);
        @memcpy(buf[0..n], m[0..n]);
        buf[n] = 0;
        a = @intFromPtr(&buf);
    }
    _ = call(EXITS, .{ a, 0, 0, 0, 0 });
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

pub fn segattach(attr: u32, class: []const u8, va: usize, len: u32) usize {
    var n: Name = .{};
    return @bitCast(call(SEGATTACH, .{ attr, n.of(class) orelse return ~@as(usize, 0), va, len, 0 }));
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

/// Swap buf with the process's error string; the kernel puts a 0 after
/// what it writes.
pub fn errstr(buf: []u8) isize {
    return call(ERRSTR, .{ @intFromPtr(buf.ptr), buf.len, 0, 0, 0 });
}

/// A note handler as the kernel calls it: the Ureg and the address of
/// the message, which span reads.  It must end with noted.
pub const Notehandler = *const fn (ureg: *anyopaque, msg: [*]const u8) callconv(.c) void;

/// Set the note handler.  The kernel enters it the Plan 9 way, with
/// its arguments on the stack, so f must be a trampoline (see proc.zig).
pub fn notify(f: ?*const anyopaque) isize {
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

/// The path of fd's file in buf, with a 0 after it.
pub fn fd2path(fd: isize, buf: []u8) isize {
    return call(FD2PATH, .{ i(fd), @intFromPtr(buf.ptr), buf.len, 0, 0 });
}

pub fn dup(old: isize, new: isize) isize {
    return call(DUP, .{ i(old), i(new), 0, 0, 0 });
}

pub fn chdir(name: []const u8) isize {
    var n: Name = .{};
    return call(CHDIR, .{ n.of(name) orelse return -1, 0, 0, 0, 0 });
}
