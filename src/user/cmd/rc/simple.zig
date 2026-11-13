//! rc's simple commands and builtins.
//! from cmd/rc/simple.c, with the builtin table of plan9.c
//!
//! In progress: so far the builtins' names, which the compiler uses.
//!
//! DIFF: a builtin is a name in an enum, dispatched by a switch, where
//! the C's table holds function pointers.

const std = @import("std");

/// plan9.c's Builtin table, in its order.
pub const Builtin = enum {
    cd,
    whatis,
    eval,
    exec,
    exit,
    shift,
    wait,
    dot,
    flag,
    finit,
    rfork,

    pub fn name(b: Builtin) []const u8 {
        return switch (b) {
            .dot => ".",
            inline else => |tag| @tagName(tag),
        };
    }
};

pub fn builtinfunc(name: []const u8) ?Builtin {
    for (std.enums.values(Builtin)) |b| {
        if (std.mem.eql(u8, name, b.name()))
            return b;
    }
    return null;
}
