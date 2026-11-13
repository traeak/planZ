//! rc's flags.
//! from cmd/rc/getflags.c and getflags.h
//!
//! In progress: so far the table the rest of rc reads.

pub const NFLAG = 128;

/// flag[c]: null when the flag is not set, else its arguments.
pub var flag: [NFLAG]?[]const []const u8 = @splat(null);
pub const flagset: []const []const u8 = &.{"<flag>"};
