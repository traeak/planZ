//! Text console on the boot framebuffer.
//! Stands in for the software console of 9/pc/screen.c (screenputs and
//! friends) until devdraw and memdraw are ported.
//!
//! DIFF: the C draws through memdraw onto gscreen.  This writes glyphs
//! of the default font straight into a 32-bit linear framebuffer, and
//! keeps the text in memory so scrolling redraws instead of reading
//! video memory back, which is very slow on real hardware.

const std = @import("std");
const arch = @import("../arch.zig");
const taslock = @import("taslock.zig");
const alloc = @import("alloc.zig");
const p9 = @import("print.zig");

/// The kernel's default font: vga/vga00 from 9front's libdraw/defont.c,
/// an uncompressed 1-bit image followed by a subfont header.
const defont = @embedFile("defont.bin");

const Font = struct {
    /// Bytes per line of the glyph image.
    bpl: usize,
    height: usize,
    /// Characters in the font.
    n: usize,
    pixels: []const u8,
    /// n+1 six-byte Fontchar records: x (2 bytes), top, bottom, left, width.
    info: []const u8,

    fn field(comptime data: []const u8, comptime i: usize) usize {
        return std.fmt.parseInt(usize, std.mem.trim(u8, data[i * 12 ..][0..12], " "), 10) catch
            @compileError("defont: bad header");
    }

    fn parse(comptime data: []const u8) Font {
        // Image header: ldepth, min.x, min.y, max.x, max.y.
        const width = field(data, 3) - field(data, 1);
        const height = field(data, 4) - field(data, 2);
        const bpl = (width + 7) / 8;
        const sub = data[60 + bpl * height ..];
        // Subfont header: n, height, ascent.
        return .{
            .bpl = bpl,
            .height = height,
            .n = field(sub, 0),
            .pixels = data[60..][0 .. bpl * height],
            .info = sub[36..],
        };
    }

    /// Left edge of character `c` in the glyph image.
    fn x(f: Font, c: usize) usize {
        return @as(usize, f.info[c * 6]) | @as(usize, f.info[c * 6 + 1]) << 8;
    }
};

const font = Font.parse(defont);
/// Every glyph of the default font is this wide.
const fontw = 8;

const Background: u32 = 0x00ffffff;
const Foreground: u32 = 0x00000000;

var screen: struct {
    lock: taslock.Lock = .{},
    on: bool = false,
    /// Framebuffer: `stride` pixels per line.
    fb: [*]volatile u32 = undefined,
    stride: usize = 0,
    /// Size of a character cell in pixels.
    cw: usize = 0,
    ch: usize = 0,
    /// Pixels per font pixel.
    scale: usize = 1,
    cols: usize = 0,
    rows: usize = 0,
    /// The characters on screen, rows*cols of them.
    text: []u8 = &.{},
    /// Cursor.
    cx: usize = 0,
    cy: usize = 0,
} = .{};

/// Start the console on a 32-bit framebuffer mapped at `fb`, and show
/// what was printed before there was a screen.
pub fn screeninit(fb: usize, width: usize, height: usize, stride: usize) void {
    const s = &screen;
    s.scale = if (height >= 1440) 2 else 1;
    s.cw = fontw * s.scale;
    s.ch = font.height * s.scale;
    s.cols = width / s.cw;
    s.rows = height / s.ch;
    if (s.cols == 0 or s.rows == 0) return;
    const text = alloc.malloc(s.cols * s.rows) orelse return;
    s.text = text[0 .. s.cols * s.rows];
    @memset(s.text, ' ');
    s.fb = @ptrFromInt(fb);
    s.stride = stride;

    // Clear all of it, including the edges no character cell covers.
    for (0..height) |y| {
        const line = s.fb + y * stride;
        for (0..width) |x| line[x] = Background;
    }
    s.on = true;
    screenputs(p9.kmesg.buf[0..p9.kmesg.n]);
    p9.addconsole(screenputs);
}

fn drawchar(col: usize, row: usize, c: u8) void {
    const s = &screen;
    const gx = font.x(c);
    var dst = s.fb + row * s.ch * s.stride + col * s.cw;
    for (0..font.height) |y| {
        const bits = font.pixels[y * font.bpl + gx / 8]; // glyphs are byte aligned
        for (0..s.scale) |_| {
            var px: usize = 0;
            for (0..fontw) |bx| {
                const v = if (bits & (@as(u8, 0x80) >> @intCast(bx)) != 0) Foreground else Background;
                for (0..s.scale) |_| {
                    dst[px] = v;
                    px += 1;
                }
            }
            dst += s.stride;
        }
    }
}

fn redraw() void {
    const s = &screen;
    for (0..s.rows) |r| {
        for (0..s.cols) |c| drawchar(c, r, s.text[r * s.cols + c]);
    }
}

/// Move everything up to make room at the bottom.  Several lines at a
/// time, as the C does, so a long listing redraws less often.
fn scroll() void {
    const s = &screen;
    const o = @min(8, s.rows - 1);
    std.mem.copyForwards(u8, s.text[0 .. (s.rows - o) * s.cols], s.text[o * s.cols ..]);
    @memset(s.text[(s.rows - o) * s.cols ..], ' ');
    s.cy -= o;
    redraw();
}

fn newline() void {
    const s = &screen;
    s.cx = 0;
    s.cy += 1;
    if (s.cy >= s.rows) scroll();
}

fn screenputc(c: u8) void {
    const s = &screen;
    switch (c) {
        '\n' => newline(),
        '\r' => s.cx = 0,
        '\t' => {
            const n = 8 - s.cx % 8;
            for (0..n) |_| screenputc(' ');
        },
        0x08 => if (s.cx > 0) {
            s.cx -= 1;
            s.text[s.cy * s.cols + s.cx] = ' ';
            drawchar(s.cx, s.cy, ' ');
        },
        else => {
            if (s.cx >= s.cols) newline();
            s.text[s.cy * s.cols + s.cx] = c;
            drawchar(s.cx, s.cy, c);
            s.cx += 1;
        },
    }
}

pub fn screenputs(str: []const u8) void {
    if (!screen.on) return;
    taslock.ilock(&screen.lock);
    defer taslock.iunlock(&screen.lock);
    for (str) |c| screenputc(c);
}
