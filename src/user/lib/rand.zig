//! Random numbers: the additive feedback generator.
//! from libc/port/lrand.c, rand.c, nrand.c, lnrand.c
//!
//! Meant to give the same numbers as the C from the same seed: the
//! comparison of libthread's alt with stock relies on it, and shows
//! it only as far as alt's choices go (some thirty calls of nrand
//! with 2 and 3, unseeded).
//!
//! DIFF:
//!   - nrand and lnrand of 0 return 0; the C divides by 0.

const lock_ = @import("lock.zig");

// algorithm by
// D. P. Mitchell & J. A. Reeds

const LEN = 607;
const TAP = 273;
const MASK = 0x7fffffff;
const A = 48271;
const M = 2147483647;
const Q = 44488;
const R = 3399;

var rng_vec: [LEN]u32 = @splat(0);
var rng_tap: usize = 0;
var rng_feed: usize = 0;
var seeded = false;
var lk: lock_.Lock = .{};

fn isrand(seed_: i32) void {
    rng_tap = 0;
    rng_feed = LEN - TAP;
    seeded = true;
    var seed: i64 = @rem(seed_, M);
    if (seed < 0)
        seed += M;
    if (seed == 0)
        seed = 89482311;
    var x: i64 = seed;
    // Initialize by x[n+1] = 48271 * x[n] mod (2**31 - 1)
    var i: i32 = -20;
    while (i < LEN) : (i += 1) {
        const hi = @divTrunc(x, Q);
        const lo = @rem(x, Q);
        // the C's longs wrap; this product does not reach 2^31
        x = A * lo - R * hi;
        if (x < 0)
            x += M;
        if (i >= 0)
            rng_vec[@intCast(i)] = @intCast(x);
    }
}

pub fn srand(seed: i32) void {
    lock_.lock(&lk);
    isrand(seed);
    lock_.unlock(&lk);
}

/// A number from 0 to 2^31-1.
pub fn lrand() i32 {
    lock_.lock(&lk);
    defer lock_.unlock(&lk);

    // the C's pointers step down and wrap by LEN
    if (rng_tap == 0) {
        if (!seeded)
            isrand(1);
        rng_tap = LEN;
    }
    rng_tap -= 1;
    if (rng_feed == 0)
        rng_feed = LEN;
    rng_feed -= 1;
    const x = (rng_vec[rng_feed] +% rng_vec[rng_tap]) & MASK;
    rng_vec[rng_feed] = x;
    return @intCast(x);
}

/// A number from 0 to 32767.
pub fn rand() i32 {
    return lrand() & 0x7fff;
}

/// A number from 0 to n-1.
pub fn nrand(n: i32) i32 {
    if (n < 0)
        return n;
    if (n <= 1)
        return 0;
    const slop = @rem(@as(i32, MASK), n);
    while (true) {
        const v = lrand();
        if (v > slop)
            return @rem(v, n);
    }
}

pub fn lnrand(n: i32) i32 {
    if (n < 0)
        return n;
    if (n == 0)
        return 0;
    const slop = @rem(@as(i32, MASK), n);
    while (true) {
        const v = lrand();
        if (v > slop)
            return @rem(v, n);
    }
}
