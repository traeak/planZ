//! memlayer.h: the types of libmemlayer.
//! From /sys/include/memlayer.h.
//!
//! Convention (see libdraw/draw.zig for the whole of it and for the
//! type rules): this file holds types only.  It does NOT re-export
//! functions; import the file named after the C file that implements
//! one (`memlalloc` is in libmemlayer/lalloc.zig, `memdraw` in
//! libmemlayer/draw.zig, `memload` in libmemlayer/load.zig, ...).
//!
//! DIFF:
//!   - Memlayer.clear is bool.
//!   - Pointers the C leaves nil are optionals: front, rear, save,
//!     refreshfn, refreshptr; Memscreen.frontmost, rearmost and fill.

const draw = @import("../libdraw/draw.zig");
const memdraw = @import("../libmemdraw/memdraw.zig");

pub const Point = draw.Point;
pub const Rectangle = draw.Rectangle;
pub const Memimage = memdraw.Memimage;

pub const Refreshfn = *const fn (*Memimage, Rectangle, ?*anyopaque) void;

pub const Memscreen = struct {
    frontmost: ?*Memimage, // frontmost layer on screen
    rearmost: ?*Memimage, // rearmost layer on screen
    image: *Memimage, // upon which all layers are drawn
    fill: ?*Memimage, // if non-zero, picture to use when repainting
};

pub const Memlayer = struct {
    screenr: Rectangle, // true position of layer on screen
    delta: Point, // add delta to go from image coords to screen
    screen: *Memscreen, // screen this layer belongs to
    front: ?*Memimage, // window in front of this one
    rear: ?*Memimage, // window behind this one
    clear: bool, // layer is fully visible
    save: ?*Memimage, // save area for obscured parts
    refreshfn: ?Refreshfn, // function to call to refresh obscured parts if save==nil
    refreshptr: ?*anyopaque, // argument to refreshfn
};

//
// The functions (all task 2's, each in the file named after its C file):
//
// These functions accept local coordinates
//      memload, memunload
//
// All these functions accept screen coordinates, not local ones.
//      _memlayerop, memlalloc, memldelete, memlfree, memltofront,
//      memltofrontn, _memltofrontfill, memltorear, memltorearn,
//      memlsetrefresh, memlhide, memlexpose, _memlsetclear, memlorigin,
//      memlnorefresh
//
