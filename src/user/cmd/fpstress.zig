//! fpstress - check that a process keeps its registers across the
//! kernel's context switches.
//!
//! usage: fpstress [rounds]
//!
//! Each round loads xmm0-xmm15 and r12-r15 with values made from the
//! pid and the round, spins in one asm block long enough to be
//! preempted (more processes than processors), stores the registers
//! back and compares.  A mismatch prints the register, what it held
//! and what it should have, and the process exits "bad"; the values
//! show whose they were (another fpstress's pid, or zeros).
//!
//! Not part of 9front.

const std = @import("std");
const libc = @import("libc");

const nx = 16;

pub fn main() void {
    var rounds: u32 = 200;
    if (libc.argv.len > 1)
        rounds = std.fmt.parseInt(u32, libc.argv[1], 10) catch 200;
    const pid: u64 = libc.getpid();
    var bad: u32 = 0;

    var r: u32 = 0;
    while (r < rounds) : (r += 1) {
        var want: [nx][2]u64 align(16) = undefined;
        var got: [nx][2]u64 align(16) = undefined;
        for (&want, 0..) |*w, i| {
            w[0] = pid << 32 | @as(u64, r) << 8 | i;
            w[1] = ~w[0];
        }
        var gwant: [4]u64 = undefined;
        for (&gwant, 0..) |*g, i| g.* = pid << 32 | 0xa00 | @as(u64, r) << 12 | i;
        var gget: [4]u64 = undefined;

        asm volatile (
            \\ movdqa 0(%%rsi), %%xmm0
            \\ movdqa 16(%%rsi), %%xmm1
            \\ movdqa 32(%%rsi), %%xmm2
            \\ movdqa 48(%%rsi), %%xmm3
            \\ movdqa 64(%%rsi), %%xmm4
            \\ movdqa 80(%%rsi), %%xmm5
            \\ movdqa 96(%%rsi), %%xmm6
            \\ movdqa 112(%%rsi), %%xmm7
            \\ movdqa 128(%%rsi), %%xmm8
            \\ movdqa 144(%%rsi), %%xmm9
            \\ movdqa 160(%%rsi), %%xmm10
            \\ movdqa 176(%%rsi), %%xmm11
            \\ movdqa 192(%%rsi), %%xmm12
            \\ movdqa 208(%%rsi), %%xmm13
            \\ movdqa 224(%%rsi), %%xmm14
            \\ movdqa 240(%%rsi), %%xmm15
            \\ movq 0(%%rdx), %%r12
            \\ movq 8(%%rdx), %%r13
            \\ movq 16(%%rdx), %%r14
            \\ movq 24(%%rdx), %%r15
            \\ movq $20000000, %%rcx
            \\ 1: decq %%rcx
            \\ jnz 1b
            \\ movdqa %%xmm0, 0(%%rdi)
            \\ movdqa %%xmm1, 16(%%rdi)
            \\ movdqa %%xmm2, 32(%%rdi)
            \\ movdqa %%xmm3, 48(%%rdi)
            \\ movdqa %%xmm4, 64(%%rdi)
            \\ movdqa %%xmm5, 80(%%rdi)
            \\ movdqa %%xmm6, 96(%%rdi)
            \\ movdqa %%xmm7, 112(%%rdi)
            \\ movdqa %%xmm8, 128(%%rdi)
            \\ movdqa %%xmm9, 144(%%rdi)
            \\ movdqa %%xmm10, 160(%%rdi)
            \\ movdqa %%xmm11, 176(%%rdi)
            \\ movdqa %%xmm12, 192(%%rdi)
            \\ movdqa %%xmm13, 208(%%rdi)
            \\ movdqa %%xmm14, 224(%%rdi)
            \\ movdqa %%xmm15, 240(%%rdi)
            \\ movq %%r12, 0(%%r8)
            \\ movq %%r13, 8(%%r8)
            \\ movq %%r14, 16(%%r8)
            \\ movq %%r15, 24(%%r8)
            :
            : [w] "{rsi}" (&want),
              [g] "{rdi}" (&got),
              [gw] "{rdx}" (&gwant),
              [gg] "{r8}" (&gget),
            : .{ .rcx = true, .r12 = true, .r13 = true, .r14 = true, .r15 = true, .xmm0 = true, .xmm1 = true, .xmm2 = true, .xmm3 = true, .xmm4 = true, .xmm5 = true, .xmm6 = true, .xmm7 = true, .xmm8 = true, .xmm9 = true, .xmm10 = true, .xmm11 = true, .xmm12 = true, .xmm13 = true, .xmm14 = true, .xmm15 = true, .memory = true });

        for (want, got, 0..) |w, g, i| {
            if (w[0] != g[0] or w[1] != g[1]) {
                libc.print("pid %d round %d xmm%d: %#.16llux %#.16llux want %#.16llux %#.16llux\n", .{ pid, r, i, g[1], g[0], w[1], w[0] });
                bad += 1;
            }
        }
        for (gwant, gget, 0..) |w, g, i| {
            if (w != g) {
                libc.print("pid %d round %d r%d: %#.16llux want %#.16llux\n", .{ pid, r, 12 + i, g, w });
                bad += 1;
            }
        }
    }
    libc.print("pid %d rounds %d bad %d\n", .{ pid, rounds, bad });
    libc.exits(if (bad != 0) "bad" else null);
}
