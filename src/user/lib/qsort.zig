//! qsort -- simple quicksort
//! from libc/port/qsort.c
//!
//! The same algorithm, step for step, so that a comparison function
//! that breaks ties by the elements' addresses (as ls's does) puts
//! equal elements in the same order as 9front.
//!
//! DIFF: generic over the element type; the comparison function gets
//! pointers to elements and a context, and swapping is a swap of
//! elements (the C picks a byte or a long loop by alignment, which
//! comes to the same).  Indices stand for the C's pointers.

const std = @import("std");

pub fn qsort(comptime T: type, a: []T, ctx: anytype, comptime cmp: fn (@TypeOf(ctx), *const T, *const T) i32) void {
    const S = struct {
        fn c(cx: @TypeOf(ctx), x: *const T, y: *const T) i32 {
            return cmp(cx, x, y);
        }

        fn pivot(cx: @TypeOf(ctx), v: []T) usize {
            const n = v.len;
            var j = n / 6;
            const pi = j; // 1/6
            j += j;
            const pj = pi + j; // 1/2
            const pk = pj + j; // 5/6
            if (c(cx, &v[pi], &v[pj]) < 0) {
                if (c(cx, &v[pi], &v[pk]) < 0) {
                    if (c(cx, &v[pj], &v[pk]) < 0)
                        return pj;
                    return pk;
                }
                return pi;
            }
            if (c(cx, &v[pj], &v[pk]) < 0) {
                if (c(cx, &v[pi], &v[pk]) < 0)
                    return pi;
                return pk;
            }
            return pj;
        }

        fn qsorts(cx: @TypeOf(ctx), v0: []T) void {
            var v = v0;
            while (v.len > 1) {
                const n = v.len;
                const p0 = if (n > 10) pivot(cx, v) else n >> 1;

                std.mem.swap(T, &v[0], &v[p0]);
                var pi: usize = 0;
                const pn = n;
                var pj = pn;
                while (true) {
                    while (true) {
                        pi += 1;
                        if (!(pi < pn and c(cx, &v[pi], &v[0]) < 0)) break;
                    }
                    while (true) {
                        pj -= 1;
                        if (!(pj > 0 and c(cx, &v[pj], &v[0]) > 0)) break;
                    }
                    if (pj < pi)
                        break;
                    std.mem.swap(T, &v[pi], &v[pj]);
                }
                std.mem.swap(T, &v[0], &v[pj]);
                const j = pj;

                const rest = n - j - 1;
                if (j < rest) {
                    qsorts(cx, v[0..j]);
                    v = v[j + 1 ..];
                } else {
                    qsorts(cx, v[j + 1 ..]);
                    v = v[0..j];
                }
            }
        }
    };
    S.qsorts(ctx, a);
}
