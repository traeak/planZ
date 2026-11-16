//! The context switch and a new thread's first stack, for amd64.
//! from libthread/amd64.c, and libc/amd64/setjmp.s for what the C
//! switches with
//!
//! DIFF:
//!   - The C saves a context with setjmp and enters one with longjmp:
//!     the stack pointer and the pc, since 6c keeps nothing in
//!     registers over a call.  Zig's code does (the System V
//!     convention: rbx, rbp, r12 to r15), so swtch pushes those, saves
//!     the stack pointer in the context it leaves, and takes the stack
//!     pointer of the one it enters; it returns when something
//!     switches back.  One call is the C's
//!     `if(setjmp(from)==0) longjmp(to, 1)`.
//!   - The floating point control words are not switched: no thread
//!     changes them.
//!   - callon enters a function on another part of the stack, for the
//!     new process of _schedfork (the C's longjmp(mainjmp)).

const impl = @import("impl.zig");
const exit = @import("exit.zig");

pub const Ctx = extern struct {
    sp: usize = 0,
};

comptime {
    asm (
        \\ .text
        \\ .globl _threadswtch
        \\_threadswtch:                 /* _threadswtch(from, to) */
        \\ pushq %rbp
        \\ pushq %rbx
        \\ pushq %r12
        \\ pushq %r13
        \\ pushq %r14
        \\ pushq %r15
        \\ movq %rsp, (%rdi)
        \\ movq (%rsi), %rsp
        \\ popq %r15
        \\ popq %r14
        \\ popq %r13
        \\ popq %r12
        \\ popq %rbx
        \\ popq %rbp
        \\ ret
        \\
        \\ .globl _threadstart
        \\_threadstart:                 /* a new thread: f in r12, arg in r13 */
        \\ movq %r12, %rdi
        \\ movq %r13, %rsi
        \\ andq $-16, %rsp
        \\ call _threadlauncher
        \\ hlt
        \\
        \\ .globl _threadcallon
        \\_threadcallon:                /* _threadcallon(sp, f) */
        \\ movq %rdi, %rsp
        \\ andq $-16, %rsp
        \\ call *%rsi
        \\ hlt
        \\
        \\ .globl _threadgetsp
        \\_threadgetsp:
        \\ leaq 8(%rsp), %rax
        \\ ret
    );
}

extern fn _threadswtch(from: *Ctx, to: *Ctx) callconv(.c) void;
extern fn _threadstart() callconv(.c) void;
extern fn _threadcallon(sp: usize, f: *const fn () callconv(.c) noreturn) callconv(.c) noreturn;
extern fn _threadgetsp() callconv(.c) usize;

/// Leave the context `from`, which is saved, and enter `to`.
pub fn swtch(from: *Ctx, to: *Ctx) void {
    _threadswtch(from, to);
}

pub const callon = _threadcallon;
pub const getsp = _threadgetsp;

pub const Threadfn = *const fn (arg: usize) void;

export fn _threadlauncher(fp: usize, arg: usize) callconv(.c) noreturn {
    const f: Threadfn = @ptrFromInt(fp);
    f(arg);
    exit.threadexits(null);
}

pub fn threadinitstack(t: *impl.Thread, f: Threadfn, arg: usize) void {
    var tos: [*]usize = @ptrFromInt((@intFromPtr(t.stk.ptr) + t.stk.len) & ~@as(usize, 15));
    tos -= 1;
    tos[0] = 0; // where _threadstart's caller would be
    tos -= 1;
    tos[0] = @intFromPtr(&_threadstart); // swtch returns here
    tos -= 6;
    tos[5] = 0; // rbp
    tos[4] = 0; // rbx
    tos[3] = @intFromPtr(f); // r12
    tos[2] = arg; // r13
    tos[1] = 0; // r14
    tos[0] = 0; // r15
    t.sched.sp = @intFromPtr(tos);
}
