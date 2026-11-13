//! grepwrap - write a pattern and an input on which 9front's grep
//! misses a matching line, for tools/usbzig.rc.  Not part of 9front; run
//! on the host by build.zig: grepwrap pattern-file input-file
//!
//! grep marks the nodes a walk of its pattern has visited with a 16-bit
//! generation, one more for each new transition of its DFA.  After 65536
//! transitions the number comes round again, and a node last visited
//! exactly that many transitions before looks visited already and is
//! skipped.  This drives planZ's port of the same machine, which makes
//! the same transitions in the same order as the C (its generation is 32
//! bits, so the C's is its low 16), to make that happen:
//! the pattern is "zz" or 'a' and 15 of a or b, which has 2^16 states;
//! the input starts with "zq", which visits the second z's node once, then
//! runs random lines of a and b until the C's generation is about to come
//! back to that visit's, and ends with a line ending in "zz".  The C does
//! not print that last line; planZ's grep does.

const std = @import("std");
const re = @import("re");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const a = std.heap.page_allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    var pat: std.ArrayList(u8) = .empty;
    try pat.appendSlice(a, "zz\na");
    for (0..15) |_|
        try pat.appendSlice(a, "(a|b)");

    const g = try arena.allocator().create(re.Grep);
    g.* = try re.Grep.init(arena.allocator());
    try g.str2top(pat.items);
    try g.initstate();

    var out: std.ArrayList(u8) = .empty;
    var s = g.state0.?;
    const Feed = struct {
        fn f(gg: *re.Grep, st: **re.State, o: *std.ArrayList(u8), c: u8) !void {
            while (st.*.next[c] == null)
                try gg.increment(st.*, c);
            st.* = st.*.next[c].?;
            try o.append(std.heap.page_allocator, c);
        }
    };
    for ("zq\n") |c|
        try Feed.f(g, &s, &out, c);

    // the second z: what the first z's node leads to
    var z2: u32 = 0;
    for (g.re.items[1..], 1..) |r, i| {
        if (r.op == .class and r.op.class.lo == 'z') {
            z2 = g.re.items[i].next;
            break;
        }
    }
    const stamp = g.re.items[z2].gen;
    const c16 = struct {
        fn f(x: anytype) u16 {
            return @truncate(x);
        }
    }.f;

    var prng = std.Random.DefaultPrng.init(5);
    const rnd = prng.random();
    var linelen: usize = 0;
    var made: u64 = 0;
    while (true) {
        if (made > 70000 and linelen > 0 and g.re.items[z2].gen == stamp) {
            // the generation of the transition that will walk from the
            // node: the one after "z", made now or already there
            var ok = false;
            if (s.next['z'] == null)
                ok = c16(g.gen +% 2) == c16(stamp)
            else if (s.next['z'].?.next['z'] == null)
                ok = c16(g.gen +% 1) == c16(stamp);
            if (ok) {
                for ("zz\n") |c|
                    try Feed.f(g, &s, &out, c);
                break;
            }
        }
        const before = g.gen;
        const r = rnd.uintLessThan(u32, 40);
        const c: u8 = if (r == 0) '\n' else if (r < 20) 'a' else 'b';
        try Feed.f(g, &s, &out, c);
        linelen = if (c == '\n') 0 else linelen + 1;
        made += g.gen -% before;
    }

    const io = init.io;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = args[1], .data = pat.items });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = args[2], .data = out.items });
}
