//! Root for the host tests of the draw libraries (`zig build test`).
//! The expected values of the shape and layer tests come from 9front's
//! own C libraries built for the host; tools/drawref regenerates them.
//! libmemdraw/fuzz.zig is the fuzz test of what a draw client can make
//! the libraries do; its header says how to run it for longer.

test {
    _ = @import("libdraw/arith.zig");
    _ = @import("libdraw/rectclip.zig");
    _ = @import("libdraw/bytesperline.zig");
    _ = @import("libdraw/chan.zig");
    _ = @import("libdraw/rgb.zig");
    _ = @import("libdraw/drawrepl.zig");
    _ = @import("libdraw/icossin.zig");
    _ = @import("libdraw/icossin2.zig");
    _ = @import("libdraw/badrect.zig");
    _ = @import("libdraw/computil.zig");
    _ = @import("libdraw/defont.zig");
    _ = @import("libmemdraw/cmap.zig");
    _ = @import("libmemdraw/alloc.zig");
    _ = @import("libmemdraw/load.zig");
    _ = @import("libmemdraw/unload.zig");
    _ = @import("libmemdraw/cload.zig");
    _ = @import("libmemdraw/subfont.zig");
    _ = @import("libmemdraw/defont.zig");
    _ = @import("libmemdraw/draw.zig");
    _ = @import("libmemdraw/hwdraw.zig");
    _ = @import("libmemdraw/line.zig");
    _ = @import("libmemdraw/ellipse.zig");
    _ = @import("libmemdraw/arc.zig");
    _ = @import("libmemdraw/fillpoly.zig");
    _ = @import("libmemdraw/poly.zig");
    _ = @import("libmemdraw/string.zig");
    _ = @import("libmemdraw/warp.zig");
    _ = @import("libmemlayer/draw.zig");
    _ = @import("libmemlayer/lalloc.zig");
    _ = @import("libmemlayer/layerop.zig");
    _ = @import("libmemlayer/ldelete.zig");
    _ = @import("libmemlayer/lhide.zig");
    _ = @import("libmemlayer/line.zig");
    _ = @import("libmemlayer/load.zig");
    _ = @import("libmemlayer/lorigin.zig");
    _ = @import("libmemlayer/lsetrefresh.zig");
    _ = @import("libmemlayer/ltofront.zig");
    _ = @import("libmemlayer/ltorear.zig");
    _ = @import("libmemlayer/unload.zig");
    _ = @import("libmemlayer/warp.zig");
    _ = @import("libmemdraw/fuzz.zig");
}
