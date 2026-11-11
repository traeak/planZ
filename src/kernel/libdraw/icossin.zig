//! Integer sine and cosine for integral degree argument.
//! From /sys/src/libdraw/icossin.c.
//!
//! DIFF: none.

const draw = @import("draw.zig");

//
// Integer sine and cosine for integral degree argument.
// Tables computed by (sin,cos)(PI*d/180).
//
const sinus = [91]i16{
    0, // 0
    18, // 1
    36, // 2
    54, // 3
    71, // 4
    89, // 5
    107, // 6
    125, // 7
    143, // 8
    160, // 9
    178, // 10
    195, // 11
    213, // 12
    230, // 13
    248, // 14
    265, // 15
    282, // 16
    299, // 17
    316, // 18
    333, // 19
    350, // 20
    367, // 21
    384, // 22
    400, // 23
    416, // 24
    433, // 25
    449, // 26
    465, // 27
    481, // 28
    496, // 29
    512, // 30
    527, // 31
    543, // 32
    558, // 33
    573, // 34
    587, // 35
    602, // 36
    616, // 37
    630, // 38
    644, // 39
    658, // 40
    672, // 41
    685, // 42
    698, // 43
    711, // 44
    724, // 45
    737, // 46
    749, // 47
    761, // 48
    773, // 49
    784, // 50
    796, // 51
    807, // 52
    818, // 53
    828, // 54
    839, // 55
    849, // 56
    859, // 57
    868, // 58
    878, // 59
    887, // 60
    896, // 61
    904, // 62
    912, // 63
    920, // 64
    928, // 65
    935, // 66
    943, // 67
    949, // 68
    956, // 69
    962, // 70
    968, // 71
    974, // 72
    979, // 73
    984, // 74
    989, // 75
    994, // 76
    998, // 77
    1002, // 78
    1005, // 79
    1008, // 80
    1011, // 81
    1014, // 82
    1016, // 83
    1018, // 84
    1020, // 85
    1022, // 86
    1023, // 87
    1023, // 88
    1024, // 89
    1024, // 90
};

pub fn icossin(deg_: i32, cosp: *i32, sinp: *i32) void {
    var deg = deg_;
    var sinsign: i32 = 1;
    var cossign: i32 = 1;
    var stp: usize = 0;
    var ctp: usize = 0;

    deg = @rem(deg, 360);
    if (deg < 0)
        deg += 360;
    sw: switch (@divTrunc(deg, 90)) {
        2 => {
            sinsign = -1;
            cossign = -1;
            deg -= 180;
            continue :sw 0;
        },
        0 => {
            stp = @intCast(deg);
            ctp = @intCast(90 - deg);
        },
        3 => {
            sinsign = -1;
            cossign = -1;
            deg -= 180;
            continue :sw 1;
        },
        1 => {
            deg = 180 - deg;
            cossign = -cossign;
            stp = @intCast(deg);
            ctp = @intCast(90 - deg);
        },
        else => {},
    }
    sinp.* = sinsign * sinus[stp];
    cosp.* = cossign * sinus[ctp];
}

test "icossin" {
    const std = @import("std");
    var c: i32 = 0;
    var s: i32 = 0;
    var d: i32 = -720;
    while (d <= 720) : (d += 1) {
        icossin(d, &c, &s);
        const a = @as(f64, @floatFromInt(d)) * std.math.pi / 180.0;
        try std.testing.expect(@abs(@as(f64, @floatFromInt(c)) - @cos(a) * draw.ICOSSCALE) <= 1.0);
        try std.testing.expect(@abs(@as(f64, @floatFromInt(s)) - @sin(a) * draw.ICOSSCALE) <= 1.0);
    }
}
