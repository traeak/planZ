//! Kernel console output.
//! from 9/port/print.c and the print half of 9/port/devcons.c
//!
//! M0 placeholder: strings and numbers only.  The Plan 9 format verbs
//! (print("%s %lud\n", ...)) arrive with lib/fmt in M1.

/// Set by the architecture once it has a console that can take output.
pub var consputs: ?*const fn ([]const u8) void = null;

pub fn puts(s: []const u8) void {
    if (consputs) |f| f(s);
}

pub fn hex(v: u64) void {
    var buf: [18]u8 = undefined;
    buf[0] = '0';
    buf[1] = 'x';
    for (0..16) |i| {
        const nib: u8 = @truncate(v >> @intCast(60 - 4 * i));
        buf[2 + i] = "0123456789abcdef"[nib & 0xf];
    }
    puts(&buf);
}

pub fn dec(v: u64) void {
    var buf: [20]u8 = undefined;
    var i: usize = buf.len;
    var n = v;
    while (true) {
        i -= 1;
        buf[i] = '0' + @as(u8, @intCast(n % 10));
        n /= 10;
        if (n == 0) break;
    }
    puts(buf[i..]);
}

pub fn panic(msg: []const u8) noreturn {
    puts("panic: ");
    puts(msg);
    puts("\n");
    while (true) asm volatile ("hlt");
}
