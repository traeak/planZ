//! The standard colour map.
//! From /sys/src/libdraw/rgb.c.
//!
//! DIFF: none.

//
// This original version, although fast and a true inverse of
// cmap2rgb, in the sense that rgb2cmap(cmap2rgb(c))
// returned the original color, does a terrible job for RGB
// triples that do not appear in the color map, so it has been
// replaced by the much slower version below, that loops
// over the color map looking for the nearest point in RGB
// space.  There is no visual psychology reason for that
// criterion, but it's easy to implement and the results are
// far more pleasing.
//
// int
// rgb2cmap(int cr, int cg, int cb)
// {
//      int r, g, b, v, cv;
//
//      if(cr < 0)
//              cr = 0;
//      else if(cr > 255)
//              cr = 255;
//      if(cg < 0)
//              cg = 0;
//      else if(cg > 255)
//              cg = 255;
//      if(cb < 0)
//              cb = 0;
//      else if(cb > 255)
//              cb = 255;
//      r = cr>>6;
//      g = cg>>6;
//      b = cb>>6;
//      cv = cr;
//      if(cg > cv)
//              cv = cg;
//      if(cb > cv)
//              cv = cb;
//      v = (cv>>4)&3;
//      return ((((r<<2)+v)<<4)+(((g<<2)+b+v-r)&15));
// }
//

pub fn rgb2cmap(cr: i32, cg: i32, cb: i32) i32 {
    var best: i32 = 0;
    var bestsq: i32 = 0x7FFFFFFF;
    var i: i32 = 0;
    while (i < 256) : (i += 1) {
        const rgb = cmap2rgb(i);
        const r = (rgb >> 16) & 0xFF;
        const g = (rgb >> 8) & 0xFF;
        const b = (rgb >> 0) & 0xFF;
        const sq = (r - cr) * (r - cr) + (g - cg) * (g - cg) + (b - cb) * (b - cb);
        if (sq < bestsq) {
            bestsq = sq;
            best = i;
        }
    }
    return best;
}

pub fn cmap2rgb(c: i32) i32 {
    var rgb: i32 = undefined;

    const r = c >> 6;
    var v = (c >> 4) & 3;
    const j = (c - v + r) & 15;
    const g = j >> 2;
    const b = j & 3;
    var den = r;
    if (g > den)
        den = g;
    if (b > den)
        den = b;
    if (den == 0) {
        v *= 17;
        rgb = (v << 16) | (v << 8) | v;
    } else {
        const num = 17 * (4 * den + v);
        rgb = (@divTrunc(r * num, den) << 16) | (@divTrunc(g * num, den) << 8) | @divTrunc(b * num, den);
    }
    return rgb;
}

pub fn cmap2rgba(c: i32) i32 {
    return @bitCast((@as(u32, @bitCast(cmap2rgb(c))) << 8) | 0xFF);
}

test "rgb" {
    const std = @import("std");
    const t = std.testing;
    try t.expectEqual(@as(i32, 0), cmap2rgb(0));
    try t.expectEqual(@as(i32, 0xFFFFFF), cmap2rgb(255));
    try t.expectEqual(@as(i32, 0x111111), cmap2rgb(17));
    var i: i32 = 0;
    while (i < 256) : (i += 1)
        try t.expectEqual(i, rgb2cmap((cmap2rgb(i) >> 16) & 0xFF, (cmap2rgb(i) >> 8) & 0xFF, cmap2rgb(i) & 0xFF));
    try t.expectEqual(@as(i32, -1), cmap2rgba(255));
}
