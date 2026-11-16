//! from libthread/ref.c

const libc = @import("libc");

pub const Ref = extern struct {
    ref: i32 = 0,
};

pub fn incref(r: *Ref) void {
    _ = libc.ainc(&r.ref);
}

/// returns 0 iff value is now zero
pub fn decref(r: *Ref) i32 {
    return libc.adec(&r.ref);
}
