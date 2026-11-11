//! The pool allocator: variable-size blocks with coalescing, in arenas
//! taken from a coarser allocator.
//! from libc/port/pool.c and /sys/include/pool.h
//!
//! This file depends on nothing in the kernel: everything outside it
//! is reached through the Pool's function pointers, so the same file
//! runs in the host tests (pooltest.zig) and can be compared with the
//! C built for the host (tools/poolref).
//!
//! DIFF:
//!   - Layout.  None: Bhdr, Btail, Free and Arena have the sizes and
//!     field offsets of the C on amd64 (4-byte magic and size, 8-byte
//!     block header and tail, 32-byte arena header, 8-byte data
//!     alignment), the magic numbers are the same, and every
//!     placement decision is the C's.  tools/poolref replays the same
//!     operations on the C and on this file and compares every
//!     address.  The 16-byte alignment the kernel's malloc promises is
//!     arranged outside, in alloc.zig (see there): the pool itself
//!     aligns data to 8 as in C, and needs only that p.alloc returns
//!     memory aligned to 8.
//!   - Sizes.  Block and arena sizes stay 32 bits as in the C on amd64
//!     (ulong), so one arena is smaller than 4GiB and so is a block;
//!     the C has the same limit, and arenamerge already refuses a
//!     merge that would exceed it.  The pool's totals (maxsize,
//!     cursize, curfree, curalloc) are usize, the C's uintptr, and do
//!     not wrap.  Requested sizes, alignments and spans are usize
//!     parameters where the C has ulong: a request of 2GiB or more is
//!     refused as in C, but one of 4GiB or more is refused too instead
//!     of being truncated by the call, and dsize+align in
//!     poolallocalignl saturates instead of wrapping.
//!   - alignptr takes the remainder of the whole address.  The C
//!     truncates the address to 32 bits first, which gives the same
//!     answer only when align divides 4GiB.
//!   - print and panic take the finished text: the formatting is done
//!     here with the Plan 9 verbs of src/lib/fmt.zig.  panic does not
//!     return (the C's default case in blockcheck relies on that too).
//!   - werrstr is a hook of the Pool (nil: nothing is recorded); the C
//!     calls libc's, or the kernel's.
//!   - assert is a function here and panics with the text of the C's
//!     condition.
//!   - Poison is the C's value with the low three bits cleared
//!     (...cafebab8): a Zig pointer to a Free must be aligned.  The
//!     32-bit copy of it that blockmerge leaves in a dead tail is the
//!     C's cafebabe.
//!   - checktree walks the free tree in order without recursion (a
//!     Morris traversal, which threads the tree through its right
//!     pointers and restores them) and checks that sizes increase,
//!     which is the same as the C's bounds.  The C recurses once per
//!     level, and a splay tree can be as deep as it has nodes: that
//!     does not fit a kernel stack.  The C's upper bound of 1<<30
//!     for a free block's size is gone: a free block may be as large
//!     as an arena.
//!   - Bugs of the C with blocks from poolallocalign whose data does
//!     not start at the start of the block (skip > 0), fixed here:
//!       poolmsize returned the size from the start of the block, not
//!       from the pointer, so the caller could write `skip` bytes past
//!       the end;
//!       poolreallocl copied getdsize bytes, which counts the skipped
//!       bytes, from the pointer, so it read `skip` bytes past the
//!       data;
//!       poolfreel under POOL_NOREUSE filled with 0xDA from the
//!       pointer for getdsize-8 bytes, `skip` bytes past the data and
//!       possibly past the block, and left the ALIGN_MAGIC words that
//!       blockcheck then reports as a dangling pointer write.  It
//!       fills from the start of the block's data, which is what
//!       blockcheck checks.
//!   - A bug of the C in freefromfront, fixed here.  It cuts the unused
//!     front off a block that poolallocalignl is about to return
//!     without looking at what is left, which can be 32 bytes: less
//!     than the smallest block (MINBLOCKSIZE rounded up to the
//!     quantum, 64).  trim then subtracts the larger from the smaller
//!     and writes a block header and tail megabytes away.  It takes
//!     an alignment that is not a multiple of the quantum and a small
//!     size, e.g. poolallocalign(p, 7, 100, 4, 0) when the block
//!     happens to lie so that the pointer is 96 bytes in; the kernel's
//!     callers align to 64 and up.  Here the front is cut off only if
//!     a whole block remains.
//!   - A bug of the C in poolallocalignl, fixed here: a request for 0
//!     bytes with a span.  Its last byte is the one before its first,
//!     so when the aligned pointer falls on a multiple of the span the
//!     block "crosses" it, the pointer is moved on by a whole span,
//!     out of the block, and freefromfront writes there.  The
//!     kernel's mallocalign never asks for 0 bytes (it adds the tag
//!     words).  Here 0 bytes cross nothing.
//!   - A bug of the C in poolreallocl, fixed here: when the block it
//!     has just allocated turns out to be next to the old one (which
//!     happens when the allocation grew the arena by merging a new one
//!     onto it) the two are merged, but the new block's size stayed in
//!     curalloc for ever; and if the old block was the last of its
//!     arena, the merge of the arenas had grown it, and the size
//!     subtracted from curalloc was the one from before.  Only the
//!     statistic was wrong: curalloc crept upwards.
//!   - A bug of the C that is NOT fixed: poolrealloc on a pool with a
//!     move hook.  When poolreallocl has to allocate a new block and
//!     the pool is full, poolnewarena compacts it, which can move the
//!     block being reallocated; poolreallocl then copies from and
//!     frees the old address.  The only pool with a move hook in
//!     9front is the image pool, which nothing reallocates in.
//!   - memmark's word is the signature and the offset of that word;
//!     the C's expression reads and increments the pointer in one
//!     statement without saying which comes first.
//!   - dumpblock is given the six header words its format prints; the
//!     C passes a seventh.

const std = @import("std");
const fmt = @import("fmt");

pub const Pool = struct {
    name: []const u8,
    maxsize: usize,

    cursize: usize = 0,
    curfree: usize = 0,
    curalloc: usize = 0,

    /// smallest size of new arena
    minarena: u32,
    /// allocated blocks should be multiple of
    quantum: u32,
    /// smallest newly allocated block
    minblock: u32 = 0,

    freeroot: ?*Free = null,
    arenalist: ?*Arena = null,

    alloc: *const fn (usize) ?*anyopaque,
    merge: ?*const fn (*anyopaque, *anyopaque) bool = null,
    move: ?*const fn (from: *anyopaque, to: *anyopaque) void = null,
    free: ?*const fn (*anyopaque, usize) void = null,

    flags: u32 = 0,
    nfree: u32 = 0,
    lastcompact: u32 = 0,

    lock: *const fn (*Pool) void,
    unlock: *const fn (*Pool) void,
    print: *const fn (*Pool, []const u8) void,
    panic: *const fn (*Pool, []const u8) noreturn,
    logstack: ?*const fn (*Pool) void = null,
    /// DIFF: see the header
    werrstr: ?*const fn ([]const u8) void = null,

    private: ?*anyopaque = null,
};

// flags
pub const POOL_ANTAGONISM = 1 << 0;
pub const POOL_PARANOIA = 1 << 1;
pub const POOL_VERBOSITY = 1 << 2;
pub const POOL_DEBUGGING = 1 << 3;
pub const POOL_LOGGING = 1 << 4;
pub const POOL_TOLERANCE = 1 << 5;
pub const POOL_NOREUSE = 1 << 6;
pub const POOL_SCRUB = 1 << 7;

//
// This allocator takes blocks from a coarser allocator (p->alloc) and
// uses them as arenas.
//
// An arena is split into a sequence of blocks of variable size.  The
// blocks begin with a Bhdr that denotes the length (including the Bhdr)
// of the block.  An arena begins with an Arena header block (Arena,
// ARENA_MAGIC) and ends with a Bhdr block with magic ARENATAIL_MAGIC and
// size 0.  Intermediate blocks are either allocated or free.  At the end
// of each intermediate block is a Btail, which contains information
// about where the block starts.  This is useful for walking backwards.
//
// Free blocks (Free*) have a magic value of FREE_MAGIC in their Bhdr
// headers.  They are kept in a binary tree (p->freeroot) traversible by
// walking ->left and ->right.  Each node of the binary tree is a pointer
// to a circular doubly-linked list (next, prev) of blocks of identical
// size.  Blocks are added to this ``tree of lists'' by pooladd(), and
// removed by pooldel().
//
// When freed, adjacent blocks are coalesced to create larger blocks when
// possible.
//
// Allocated blocks (Alloc*) have one of two magic values: ALLOC_MAGIC or
// UNALLOC_MAGIC.  When blocks are released from the pool, they have
// magic value UNALLOC_MAGIC.  Once the block has been trimmed by trim()
// and the amount of user-requested data has been recorded in the
// datasize field of the tail, the magic value is changed to ALLOC_MAGIC.
// All blocks returned to callers should be of type ALLOC_MAGIC, as
// should all blocks passed to us by callers.  The amount of data the user
// asked us for can be found by subtracting the short in tail->datasize
// from header->size.  Further, the up to at most four bytes between the
// end of the user-requested data block and the actual Btail structure are
// marked with a magic value, which is checked to detect user overflow.
//
// The arenas returned by p->alloc are kept in a doubly-linked list
// (p->arenalist) running through the arena headers, sorted by descending
// base address (prev, next).  When a new arena is allocated, we attempt
// to merge it with its two neighbors via p->merge.
//

pub const Bhdr = extern struct {
    magic: u32,
    size: u32,
};
const NOT_MAGIC = 0xdeadfa11;
const DEAD_MAGIC = 0xdeaddead;

inline fn addr(p: anytype) usize {
    return if (@TypeOf(p) == usize) p else @intFromPtr(p);
}

inline fn B2NB(b: *Bhdr) *Bhdr {
    return @ptrFromInt(addr(b) + b.size);
}

inline fn SHORT(x: [2]u8) u32 {
    return (@as(u32, x[0]) << 8) | x[1];
}

inline fn PSHORT(p: *[2]u8, x: u32) void {
    p[0] = @truncate(x >> 8);
    p[1] = @truncate(x);
}

const TAIL_MAGIC0 = 0xBE;
const TAIL_MAGIC1 = 0xEF;

const Btail = extern struct {
    magic0: u8,
    datasize: [2]u8,
    magic1: u8,
    /// same as Bhdr->size
    size: u32,
};

inline fn B2T(b: *Bhdr) *Btail {
    return @ptrFromInt(addr(b) + b.size - @sizeOf(Btail));
}

inline fn B2PT(b: *Bhdr) *Btail {
    return @ptrFromInt(addr(b) - @sizeOf(Btail));
}

inline fn T2HDR(t: *Btail) *Bhdr {
    return @ptrFromInt(addr(t) + @sizeOf(Btail) -% t.size);
}

pub const Free = extern struct {
    magic: u32,
    size: u32,
    left: ?*Free,
    right: ?*Free,
    next: ?*Free,
    prev: ?*Free,
};
const FREE_MAGIC = 0xBA5EBA11;

//
// the point of the notused fields is to make 8c differentiate
// between Bhdr and Allocblk, and between Kempt and Unkempt.
//
const Alloc = Bhdr;
const ALLOC_MAGIC = 0x0A110C09;
const UNALLOC_MAGIC = 0xCAB00D1E + 1;

pub const Arena = extern struct {
    magic: u32,
    size: u32,
    aup: ?*Arena,
    down: ?*Arena,
    asize: u32,
    /// to a multiple of 8 bytes
    pad: u32,
};
const ARENA_MAGIC = 0xC0A1E5CE + 1;
const ARENATAIL_MAGIC = 0xEC5E1A0C + 1;

inline fn A2TB(a: *Arena) *Bhdr {
    return @ptrFromInt(addr(a) + a.asize - @sizeOf(Bhdr));
}

inline fn A2B(a: *Arena) *Bhdr {
    return B2NB(@ptrCast(a));
}

const ALIGN_MAGIC = 0xA1F1D1C1;

const MINBLOCKSIZE = @sizeOf(Free) + @sizeOf(Btail);

const datamagic = [_]u8{ 0xFE, 0xF1, 0xF0, 0xFA };

// cafebabe; DIFF: aligned, see the header
const Poison32: u32 = 0xCAFEBABE;
const Poison: ?*Free = @ptrFromInt((0 -% @as(usize, 0x35014542)) & ~@as(usize, 7));

inline fn _B2D(a: anytype) [*]u8 {
    return @ptrFromInt(addr(a) + @sizeOf(Bhdr));
}

inline fn _D2B(v: anytype) *Alloc {
    return @ptrFromInt(addr(v) - @sizeOf(Bhdr));
}

comptime {
    if (@sizeOf(Bhdr) != 8 or @sizeOf(Btail) != 8 or @sizeOf(Free) != 40 or
        @sizeOf(Arena) != 32 or MINBLOCKSIZE != 48)
        @compileError("pool: block layout differs from the C's on amd64");
}

/// Free and Arena start with a Bhdr.
inline fn tofree(b: *Bhdr) *Free {
    return @ptrCast(@alignCast(b));
}

inline fn hdr(b: anytype) *Bhdr {
    return @ptrCast(b);
}

inline fn bytes(p: [*]u8, n: usize) []u8 {
    return p[0..n];
}

/// DIFF: the C's assert macro; `what` is the condition as the C has it.
inline fn assert(ok: bool, comptime what: []const u8) void {
    if (!ok) @panic("pool: assert failed: " ++ what);
}

/// DIFF: p->print(p, fmt, ...) and p->panic(p, fmt, ...), see the header.
fn pprint(p: *Pool, comptime format: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    p.print(p, fmt.snprint(&buf, format, args));
}

fn ppanic(p: *Pool, comptime format: []const u8, args: anytype) noreturn {
    var buf: [256]u8 = undefined;
    p.panic(p, fmt.snprint(&buf, format, args));
}

fn werrstr(p: *Pool, comptime format: []const u8, args: anytype) void {
    const w = p.werrstr orelse return;
    var buf: [128]u8 = undefined;
    w(fmt.snprint(&buf, format, args));
}

//
// Debugging
//
// Antagonism causes blocks to always be filled with garbage if their
// contents are undefined.  This tickles both programs and the library.
// It's a linear time hit but not so noticeable during nondegenerate use.
// It would be worth leaving in except that it negates the benefits of the
// kernel's demand-paging.  The tail magic and end-of-data magic
// provide most of the user-visible benefit that antagonism does anyway.
//
// Paranoia causes the library to recheck the entire pool on each lock
// or unlock.  A failed check on unlock means we tripped over ourselves,
// while a failed check on lock tends to implicate the user.  Paranoia has
// the potential to slow things down a fair amount for pools with large
// numbers of allocated blocks.  It completely negates all benefits won
// by the binary tree.  Turning on paranoia in the kernel makes it painfully
// slow.
//
// Verbosity induces the dumping of the pool via p->print at each lock operation.
// By default, only one line is logged for each alloc, free, and realloc.
//

inline fn antagonism(p: *Pool) bool {
    return p.flags & POOL_ANTAGONISM != 0;
}

inline fn paranoia(p: *Pool) bool {
    return p.flags & POOL_PARANOIA != 0;
}

inline fn verbosity(p: *Pool) bool {
    return p.flags & POOL_VERBOSITY != 0;
}

inline fn scrub(p: *Pool) bool {
    return p.flags & POOL_SCRUB != 0;
}

inline fn DPRINT(p: *Pool, comptime format: []const u8, args: anytype) void {
    if (p.flags & POOL_DEBUGGING != 0) pprint(p, format, args);
}

inline fn LOG(p: *Pool, comptime format: []const u8, args: anytype) void {
    if (p.flags & POOL_LOGGING != 0) pprint(p, format, args);
}

//
// Tree walking
//

fn checklist(t: *Free) void {
    var q = t.next.?;
    while (q != t) : (q = q.next.?) {
        assert(q.magic == FREE_MAGIC, "q->magic==FREE_MAGIC");
        assert(q.size == t.size, "q->size==t->size");
        assert(q.left == Poison, "q->left==Poison");
        assert(q.right == Poison, "q->right==Poison");
        assert(q.next != null and q.next != Poison and q.next.?.prev == q, "q->next!=nil && q->next!=Poison && q->next->prev==q");
        assert(q.prev != null and q.prev != Poison and q.prev.?.next == q, "q->prev!=nil && q->prev!=Poison && q->prev->next==q");
    }
}

/// What the C's checktree checks at each node, but for the bounds.
fn checknode(t: *Free) void {
    assert(t.magic == FREE_MAGIC, "t->magic==FREE_MAGIC");
    assert(t.left != Poison, "t->left!=Poison");
    assert(t.right != Poison, "t->right!=Poison");
    assert(t.next != null and t.next != Poison and t.next.?.prev == t, "t->next!=nil && t->next!=Poison && t->next->prev==t");
    assert(t.prev != null and t.prev != Poison and t.prev.?.next == t, "t->prev!=nil && t->prev!=Poison && t->prev->next==t");
    checklist(t);
}

/// DIFF: in order and without recursion, see the header.  The C is
/// checktree(t, a, b), with a < t->size < b at every node.
fn checktree(root: *Free) void {
    var last: u64 = 0;
    var t: ?*Free = root;
    while (t) |n| {
        assert(n.magic == FREE_MAGIC, "t->magic==FREE_MAGIC");
        assert(n.left != Poison and n.right != Poison, "t->left!=Poison && t->right!=Poison");
        if (n.left) |l| {
            // the rightmost node of the left subtree comes just before n
            var pre = l;
            while (true) {
                assert(pre.magic == FREE_MAGIC, "t->magic==FREE_MAGIC");
                assert(pre.right != Poison, "t->right!=Poison");
                const r = pre.right orelse break;
                if (r == n) break;
                pre = r;
            }
            if (pre.right == null) {
                // first time here: go left, and come back through pre
                pre.right = n;
                t = l;
                continue;
            }
            // the left subtree is done
            pre.right = null;
        }
        checknode(n);
        assert(last < n.size, "a < t->size && t->size < b");
        last = n.size;
        t = n.right;
    }
}

/// treelookupgt: find smallest node in tree with size >= size
fn treelookupgt(t_: ?*Free, size: u32) ?*Free {
    var t = t_;
    var lastgood: ?*Free = null; // last node we saw that was big enough

    while (true) {
        const n = t orelse return lastgood;
        assert(n.magic == FREE_MAGIC, "t->magic == FREE_MAGIC");
        if (size == n.size)
            return n;
        if (size < n.size) {
            lastgood = n;
            t = n.left;
        } else t = n.right;
    }
}

/// treesplay: splay node of size size to the root and return new root
fn treesplay(t_: *Free, size: u32) *Free {
    var t = t_;
    var N: Free = undefined;

    N.left = null;
    N.right = null;
    var l: *Free = &N;
    var r: *Free = &N;

    while (true) {
        assert(t.magic == FREE_MAGIC, "t->magic == FREE_MAGIC");
        if (size < t.size) {
            if (t.left) |y| {
                assert(y.magic == FREE_MAGIC, "y->magic == FREE_MAGIC");
                if (size < y.size) {
                    t.left = y.right;
                    y.right = t;
                    t = y;
                }
            }
            if (t.left == null)
                break;
            r.left = t;
            r = t;
            t = t.left.?;
        } else if (size > t.size) {
            if (t.right) |y| {
                assert(y.magic == FREE_MAGIC, "y->magic == FREE_MAGIC");
                if (size > y.size) {
                    t.right = y.left;
                    y.left = t;
                    t = y;
                }
            }
            if (t.right == null)
                break;
            l.right = t;
            l = t;
            t = t.right.?;
        } else break;
    }

    l.right = t.left;
    r.left = t.right;
    t.left = N.right;
    t.right = N.left;

    return t;
}

/// pooladd: add anode to the free pool
fn pooladd(p: *Pool, anode: *Alloc) *Free {
    if (antagonism(p)) {
        memmark(_B2D(anode), 0xF7, anode.size - @sizeOf(Bhdr) - @sizeOf(Btail));
    }

    const node = tofree(anode);
    node.magic = FREE_MAGIC;
    node.left = null;
    node.right = null;
    node.next = node;
    node.prev = node;

    if (p.freeroot) |fr| {
        const root = treesplay(fr, node.size);
        if (root.size > node.size) {
            node.left = root.left;
            node.right = root;
            root.left = null;
        } else if (root.size < node.size) {
            node.right = root.right;
            node.left = root;
            root.right = null;
        } else {
            node.left = root.left;
            node.right = root.right;
            root.left = Poison;
            root.right = Poison;

            node.prev = root.prev;
            node.next = root;
            node.prev.?.next = node;
            node.next.?.prev = node;
        }
    }
    p.freeroot = node;
    p.curfree += node.size;

    return node;
}

/// pooldel: remove node from the free pool
fn pooldel(p: *Pool, node: *Free) *Alloc {
    var root = treesplay(p.freeroot.?, node.size);
    var nroot: ?*Free = root;
    if (node == root and node.next == node) {
        if (node.left == null) {
            nroot = node.right;
        } else {
            root = treesplay(node.left.?, node.size);
            assert(root.right == null, "root->right == nil");
            root.right = node.right;
            nroot = root;
        }
    } else {
        if (node == root) {
            root = node.next.?;
            root.left = node.left;
            root.right = node.right;
            nroot = root;
        }
        assert(root.magic == FREE_MAGIC and root.size == node.size, "root->magic == FREE_MAGIC && root->size == node->size");
        node.next.?.prev = node.prev;
        node.prev.?.next = node.next;
    }
    p.freeroot = nroot;
    p.curfree -= node.size;

    node.left = Poison;
    node.right = Poison;
    node.next = Poison;
    node.prev = Poison;

    if (antagonism(p)) {
        memmark(_B2D(node), 0xF9, node.size - @sizeOf(Bhdr) - @sizeOf(Btail));
    }

    node.magic = UNALLOC_MAGIC;

    return hdr(node);
}

//
// Block maintenance
//
// block allocation
fn dsize2bsize(p: *Pool, sz_: u32) u32 {
    // wrapping, as the C's ulong: blockcheck calls this with the size
    // from a tail that may be corrupt
    var sz = sz_;
    sz +%= @sizeOf(Bhdr) + @sizeOf(Btail);
    if (sz < p.minblock)
        sz = p.minblock;
    if (sz < MINBLOCKSIZE)
        sz = MINBLOCKSIZE;
    sz = (sz +% p.quantum -% 1) & ~(p.quantum - 1);
    return sz;
}

fn bsize2asize(p: *Pool, sz_: u32) u32 {
    var sz = sz_;
    sz += @sizeOf(Arena) + @sizeOf(Btail);
    if (sz < p.minarena)
        sz = p.minarena;
    sz = (sz + p.quantum) & ~(p.quantum - 1);
    return sz;
}

/// blockmerge: merge a and b, known to be adjacent
/// both are removed from pool if necessary.
fn blockmerge(pool: *Pool, a: *Bhdr, b: *Bhdr) *Alloc {
    assert(B2NB(a) == b, "B2NB(a) == b");

    if (a.magic == FREE_MAGIC)
        _ = pooldel(pool, tofree(a));
    if (b.magic == FREE_MAGIC)
        _ = pooldel(pool, tofree(b));

    var t = B2T(a);
    t.size = Poison32;
    t.magic0 = @truncate(NOT_MAGIC);
    t.magic1 = @truncate(NOT_MAGIC);
    PSHORT(&t.datasize, NOT_MAGIC);

    a.size += b.size;
    t = B2T(a);
    t.size = a.size;
    PSHORT(&t.datasize, 0xFFFF);

    b.size = NOT_MAGIC;
    b.magic = NOT_MAGIC;

    a.magic = UNALLOC_MAGIC;
    return a;
}

/// blocksetsize: set the total size of a block, fixing tail pointers
fn blocksetsize(b: *Bhdr, bsize: u32) *Bhdr {
    assert(b.magic != FREE_MAGIC, "b->magic != FREE_MAGIC /* blocksetsize */");

    b.size = bsize;
    const t = B2T(b);
    t.size = b.size;
    t.magic0 = TAIL_MAGIC0;
    t.magic1 = TAIL_MAGIC1;
    return b;
}

/// getdsize: return the requested data size for an allocated block
fn getdsize(b: *Alloc) u32 {
    const t = B2T(b);
    return b.size -% SHORT(t.datasize);
}

/// blocksetdsize: set the user data size of a block
fn blocksetdsize(p: *Pool, b: *Alloc, dsize: u32) *Alloc {
    assert(b.size >= dsize2bsize(p, dsize), "b->size >= dsize2bsize(p, dsize)");
    assert(b.size - dsize < 0x10000, "b->size - dsize < 0x10000");

    const t = B2T(b);
    PSHORT(&t.datasize, b.size - dsize);

    var q = addr(_B2D(b)) + dsize;
    var eq = addr(t);
    if (eq > q + 4)
        eq = q + 4;
    while (q < eq) : (q += 1)
        @as(*u8, @ptrFromInt(q)).* = datamagic[q % datamagic.len];

    return b;
}

/// trim: trim a block down to what is needed to hold dsize bytes of user data
fn trim(p: *Pool, b: *Alloc, dsize: u32) *Alloc {
    const bsize = dsize2bsize(p, dsize);
    const extra = b.size - bsize;
    if (b.size - dsize >= 0x10000 or
        (extra >= bsize >> 2 and extra >= MINBLOCKSIZE and extra >= p.minblock))
    {
        _ = blocksetsize(b, bsize);
        const frag: *Alloc = B2NB(b);

        if (antagonism(p)) {
            memmark(@ptrCast(frag), 0xF1, extra);
        }

        frag.magic = UNALLOC_MAGIC;
        _ = blocksetsize(frag, extra);
        _ = pooladd(p, frag);
    }

    b.magic = ALLOC_MAGIC;
    _ = blocksetdsize(p, b, dsize);
    return b;
}

fn freefromfront(p: *Pool, b: *Alloc, skip_: u32) *Alloc {
    const skip = skip_ & ~(p.quantum - 1);
    // DIFF: and what stays must be a block, see the header
    if ((skip >= 0x1000 or (skip >= b.size >> 2 and skip >= MINBLOCKSIZE and skip >= p.minblock)) and
        b.size - skip >= dsize2bsize(p, 0))
    {
        const bb: *Alloc = @ptrFromInt(addr(b) + skip);
        bb.magic = UNALLOC_MAGIC;
        _ = blocksetsize(bb, b.size - skip);
        b.magic = UNALLOC_MAGIC;
        _ = blocksetsize(b, skip);
        _ = pooladd(p, b);
        return bb;
    }
    return b;
}

//
// Arena maintenance
//

/// arenasetsize: set arena size, updating tail
fn arenasetsize(a: *Arena, asize: u32) void {
    a.asize = asize;
    const atail = A2TB(a);
    atail.magic = ARENATAIL_MAGIC;
    atail.size = 0;
}

/// poolnewarena: allocate new arena
fn poolnewarena(p: *Pool, asize: u32) void {
    LOG(p, "newarena %lud\n", .{asize});
    if (asize > p.maxsize or p.cursize > p.maxsize - asize) {
        if (poolcompactl(p) == 0) {
            LOG(p, "pool too big: %llud+%lud > %llud\n", .{ @as(u64, p.cursize), asize, @as(u64, p.maxsize) });
            werrstr(p, "memory pool too large", .{});
        }
        return;
    }

    // assume errstr set by p->alloc
    const a: *Arena = @ptrCast(@alignCast(p.alloc(asize) orelse return));

    p.cursize += asize;

    // arena hdr
    a.magic = ARENA_MAGIC;
    _ = blocksetsize(hdr(a), @sizeOf(Arena));
    arenasetsize(a, asize);
    blockcheck(p, hdr(a));

    // create one large block in arena
    const b: *Alloc = A2B(a);
    b.magic = UNALLOC_MAGIC;
    _ = blocksetsize(b, @intCast(addr(A2TB(a)) - addr(b)));
    blockcheck(p, b);
    _ = pooladd(p, b);
    blockcheck(p, b);

    // sort arena into descending sorted arena list
    var lastap: ?*Arena = null;
    var ap = p.arenalist;
    while (addr(ap) > addr(a)) {
        lastap = ap;
        ap = ap.?.down;
    }

    a.down = ap;
    if (a.down) |d|
        d.aup = a;

    a.aup = lastap;
    if (a.aup) |u|
        u.down = a
    else
        p.arenalist = a;

    // merge with surrounding arenas if possible
    // must do a with up before down with a (think about it)
    if (a.aup) |u|
        _ = arenamerge(p, a, u);
    if (a.down) |d|
        _ = arenamerge(p, d, a);
}

/// blockresize: grow a block to encompass space past its end, possibly by
/// trimming it into two different blocks.
fn blockgrow(p: *Pool, b: *Bhdr, nsize: u32) void {
    if (b.magic == FREE_MAGIC) {
        var a = pooldel(p, tofree(b));
        blockcheck(p, a);
        _ = blocksetsize(a, nsize);
        blockcheck(p, a);
        const bnxt = B2NB(a);
        if (bnxt.magic == FREE_MAGIC)
            a = blockmerge(p, a, bnxt);
        blockcheck(p, a);
        _ = pooladd(p, a);
    } else {
        const a: *Alloc = b;
        p.curalloc -= a.size;
        const dsize = getdsize(a);
        _ = blocksetsize(a, nsize);
        _ = trim(p, a, dsize);
        p.curalloc += a.size;
    }
}

/// arenamerge: attempt to coalesce to arenas that might be adjacent
fn arenamerge(p: *Pool, bot: *Arena, top: *Arena) ?*Arena {
    blockcheck(p, hdr(bot));
    blockcheck(p, hdr(top));
    assert(bot.aup == top and addr(top) > addr(bot), "bot->aup == top && top > bot");

    const newsize: u32 = top.asize +% @as(u32, @truncate(addr(top) - addr(bot)));
    if (newsize < top.asize) return null;
    const merge = p.merge orelse return null;
    if (!merge(bot, top))
        return null;

    // remove top from list
    bot.aup = top.aup;
    if (bot.aup) |u|
        u.down = bot
    else
        p.arenalist = bot;

    // save ptrs to last block in bot, first block in top
    const t = B2PT(A2TB(bot));
    const bbot = T2HDR(t);
    const btop = A2B(top);
    blockcheck(p, bbot);
    blockcheck(p, btop);

    // grow bottom arena to encompass top
    arenasetsize(bot, newsize);

    // grow bottom block to encompass space between arenas
    blockgrow(p, bbot, @intCast(addr(btop) - addr(bbot)));
    blockcheck(p, bbot);
    return bot;
}

/// dumpblock: print block's vital stats
fn dumpblock(p: *Pool, b: *Bhdr) void {
    var dp: [*]align(1) u32 = @ptrCast(b);
    pprint(p, "pool %s block %p\nhdr %.8lux %.8lux %.8lux %.8lux %.8lux %.8lux\n", .{
        p.name, addr(b), dp[0], dp[1], dp[2], dp[3], dp[4], dp[5],
    });

    dp = @ptrCast(B2T(b));
    pprint(p, "tail %.8lux %.8lux %.8lux %.8lux %.8lux %.8lux | %.8lux %.8lux\n", .{
        (dp - 6)[0], (dp - 5)[0], (dp - 4)[0], (dp - 3)[0], (dp - 2)[0], (dp - 1)[0], dp[0], dp[1],
    });

    if (b.magic == ALLOC_MAGIC) {
        const dsize = getdsize(b);
        if (dsize >= b.size) // user data size corrupt
            return;

        const cp: [*]u8 = _B2D(b) + dsize;
        pprint(p, "user data ", .{});
        pprint(p, "%.2ux %.2ux %.2ux %.2ux  %.2ux %.2ux %.2ux %.2ux", .{
            (cp - 8)[0], (cp - 7)[0], (cp - 6)[0], (cp - 5)[0], (cp - 4)[0], (cp - 3)[0], (cp - 2)[0], (cp - 1)[0],
        });
        pprint(p, " | %.2ux %.2ux %.2ux %.2ux  %.2ux %.2ux %.2ux %.2ux\n", .{
            cp[0], cp[1], cp[2], cp[3], cp[4], cp[5], cp[6], cp[7],
        });
    }
}

fn printblock(p: *Pool, b: *Bhdr, msg: []const u8) void {
    pprint(p, "%s\n", .{msg});
    dumpblock(p, b);
}

fn panicblock(p: *Pool, b: *Bhdr, msg: []const u8) noreturn {
    pprint(p, "%s\n", .{msg});
    dumpblock(p, b);
    ppanic(p, "pool panic", .{});
}

/// blockcheck: ensure a block consistent with our expectations
/// should only be called when holding pool lock
fn blockcheck(p: *Pool, b_: *Bhdr) void {
    var b = b_;
    sw: switch (b.magic) {
        else => panicblock(p, b, "bad magic"),
        FREE_MAGIC, UNALLOC_MAGIC => {
            const t = B2T(b);
            if (t.magic0 != TAIL_MAGIC0 or t.magic1 != TAIL_MAGIC1)
                panicblock(p, b, "corrupt tail magic");
            if (T2HDR(t) != b)
                panicblock(p, b, "corrupt tail ptr");
        },
        DEAD_MAGIC => {
            const t = B2T(b);
            if (t.magic0 != TAIL_MAGIC0 or t.magic1 != TAIL_MAGIC1)
                panicblock(p, b, "corrupt tail magic");
            if (T2HDR(t) != b)
                panicblock(p, b, "corrupt tail ptr");
            const n = getdsize(b);
            var q = _B2D(b);
            q += 8;
            var i: u32 = 8;
            while (i < n) : (i += 1) {
                if (q[0] != 0xDA)
                    panicblock(p, b, "dangling pointer write");
                q += 1;
            }
        },
        ARENA_MAGIC => {
            b = A2TB(@ptrCast(@alignCast(b)));
            if (b.magic != ARENATAIL_MAGIC)
                panicblock(p, b, "bad arena size");
            // fall through
            continue :sw ARENATAIL_MAGIC;
        },
        ARENATAIL_MAGIC => {
            if (b.size != 0)
                panicblock(p, b, "bad arena tail size");
        },
        ALLOC_MAGIC => {
            const a: *Alloc = b;
            const t = B2T(b);
            const dsize = getdsize(a);
            const bq = addr(_B2D(a)) +% dsize;
            var eq = addr(t);

            if (t.magic0 != TAIL_MAGIC0) {
                // if someone wrote exactly one byte over and it was a NUL, we sometimes only complain.
                if ((p.flags & POOL_TOLERANCE) != 0 and bq == eq and t.magic0 == 0)
                    printblock(p, b, "mem user overflow (magic0)")
                else
                    panicblock(p, b, "corrupt tail magic0");
            }

            if (t.magic1 != TAIL_MAGIC1)
                panicblock(p, b, "corrupt tail magic1");
            if (T2HDR(t) != b)
                panicblock(p, b, "corrupt tail ptr");

            if (dsize2bsize(p, dsize) > a.size)
                panicblock(p, b, "too much block data");

            if (eq > bq + 4)
                eq = bq + 4;
            var q = bq;
            while (q < eq) : (q += 1) {
                const c = @as(*u8, @ptrFromInt(q)).*;
                if (c != datamagic[q % datamagic.len]) {
                    if (q == bq and c == 0 and (p.flags & POOL_TOLERANCE) != 0) {
                        printblock(p, b, "mem user overflow");
                        continue;
                    }
                    panicblock(p, b, "mem user overflow");
                }
            }
        },
    }
}

//
// compact an arena by shifting all the free blocks to the end.
// assumes pool lock is held.
//

// temporarily neither allocated nor in the free tree
const FLOATING_MAGIC = 0xCBCBCBCB;

fn arenacompact(p: *Pool, a: *Arena) u32 {
    const move = p.move orelse
        ppanic(p, "don't call me when pool->move is nil\n", .{});

    poolcheckarena(p, a);
    const eb = A2TB(a);
    var compacted: u32 = 0;
    var wb = A2B(a);
    var b = wb;
    while (addr(b) < addr(eb)) {
        const nxt = B2NB(b);
        switch (b.magic) {
            FREE_MAGIC => {
                _ = pooldel(p, tofree(b));
                b.magic = FLOATING_MAGIC;
            },
            ALLOC_MAGIC => {
                if (wb != b) {
                    const n = b.size;
                    @memmove(@as([*]u8, @ptrCast(wb))[0..n], @as([*]u8, @ptrCast(b))[0..n]);
                    move(_B2D(b), _B2D(wb));
                    compacted = 1;
                }
                wb = B2NB(wb);
            },
            else => {},
        }
        b = nxt;
    }

    //
    // the only free data is now at the end of the arena, pointed
    // at by wb.  all we need to do is set its size and get out.
    //
    if (addr(wb) < addr(eb)) {
        wb.magic = UNALLOC_MAGIC;
        _ = blocksetsize(wb, @intCast(addr(eb) - addr(wb)));
        _ = pooladd(p, wb);
    }

    return compacted;
}

//
// compact a pool by compacting each individual arena.
// 'twould be nice to shift blocks from one arena to the
// next but it's a pain to code.
//
fn poolcompactl(pool: *Pool) u32 {
    if (pool.move == null or pool.lastcompact == pool.nfree)
        return 0;

    pool.lastcompact = pool.nfree;
    var compacted: u32 = 0;
    var a = pool.arenalist;
    while (a) |x| : (a = x.down)
        compacted |= arenacompact(pool, x);
    return compacted;
}

//
// Actual allocators
//

fn B2D(p: *Pool, a: *Alloc) [*]u8 {
    if (a.magic != ALLOC_MAGIC)
        ppanic(p, "B2D called on unworthy block", .{});
    return _B2D(a);
}

fn D2B(p: *Pool, v_: *anyopaque) *Alloc {
    var v = addr(v_);
    if (v & (@sizeOf(u32) - 1) != 0)
        v = v - (v & (@sizeOf(u32) - 1));
    var u: [*]u32 = @ptrFromInt(v);
    while ((u - 1)[0] == ALIGN_MAGIC)
        u -= 1;
    const a = _D2B(u);
    if (a.magic != ALLOC_MAGIC)
        ppanic(p, "D2B called on non-block %p (double-free?)", .{addr(v_)});
    return a;
}

/// poolallocl: attempt to allocate block to hold dsize user bytes; assumes lock held
fn poolallocl(p: *Pool, dsize_: usize) ?[*]u8 {
    if (dsize_ >= 0x80000000) { // for sanity, overflow
        werrstr(p, "invalid allocation size", .{});
        return null;
    }
    const dsize: u32 = @intCast(dsize_);

    const bsize = dsize2bsize(p, dsize);

    var fb = treelookupgt(p.freeroot, bsize);
    if (fb == null) {
        poolnewarena(p, bsize2asize(p, bsize));
        fb = treelookupgt(p.freeroot, bsize);
        if (fb == null) {
            // assume poolnewarena failed and set %r
            return null;
        }
    }

    const ab = trim(p, pooldel(p, fb.?), dsize);
    p.curalloc += ab.size;
    if (antagonism(p)) {
        @memset(bytes(B2D(p, ab), dsize), 0xDF);
    }
    return B2D(p, ab);
}

/// poolreallocl: attempt to grow v to ndsize bytes; assumes lock held
fn poolreallocl(p: *Pool, v_: ?*anyopaque, ndsize_: usize) ?[*]u8 {
    const vp = v_ orelse // for ANSI
        return poolallocl(p, ndsize_);
    if (ndsize_ == 0) {
        poolfreel(p, vp);
        return null;
    }
    // DIFF: poolallocl would refuse it below, after the C had
    // computed with the truncated size.
    if (ndsize_ >= 0x80000000) {
        werrstr(p, "invalid allocation size", .{});
        return null;
    }
    const ndsize: u32 = @intCast(ndsize_);
    const v: [*]u8 = @ptrCast(vp);
    var a = D2B(p, vp);
    blockcheck(p, a);
    var odsize = getdsize(a);
    // DIFF: not the bytes in front of an aligned pointer, see the header
    odsize -= @intCast(addr(v) - addr(_B2D(a)));
    var obsize = a.size;

    // can reuse the same block?
    const nbsize = dsize2bsize(p, ndsize);
    returnblock: {
        if (nbsize <= a.size)
            break :returnblock;

        // can merge with surrounding blocks?
        var right = B2NB(a);
        if (right.magic == FREE_MAGIC and a.size + right.size >= nbsize) {
            a = blockmerge(p, a, right);
            break :returnblock;
        }

        const t = B2PT(a);
        var left = T2HDR(t);
        if (left.magic == FREE_MAGIC and left.size + a.size >= nbsize) {
            a = blockmerge(p, left, a);
            break :returnblock;
        }

        if (left.magic == FREE_MAGIC and right.magic == FREE_MAGIC and
            left.size + a.size + right.size >= nbsize)
        {
            a = blockmerge(p, blockmerge(p, left, a), right);
            break :returnblock;
        }

        const nv = poolallocl(p, ndsize) orelse
            return null;

        // maybe the new block is next to us; if so, merge
        left = T2HDR(B2PT(a));
        right = B2NB(a);
        const newb = D2B(p, nv);
        if (left == newb or right == newb) {
            // DIFF: the new block stops being one, and the old one
            // may have grown, see the header
            p.curalloc -= newb.size;
            obsize = a.size;
            if (left == newb or left.magic == FREE_MAGIC)
                a = blockmerge(p, left, a);
            if (right == newb or right.magic == FREE_MAGIC)
                a = blockmerge(p, a, right);
            assert(a.size >= nbsize, "a->size >= nbsize");
            break :returnblock;
        }

        // enough cleverness
        @memmove(nv[0..odsize], v[0..odsize]);
        if (antagonism(p)) {
            @memset(nv[odsize..ndsize], 0xDE);
        }
        poolfreel(p, vp);
        return nv;
    }

    // Returnblock:
    if (v != _B2D(a))
        @memmove(_B2D(a)[0..odsize], v[0..odsize]);
    a = trim(p, a, ndsize);
    p.curalloc -= obsize;
    p.curalloc += a.size;
    return B2D(p, a);
}

fn alignptr(v: usize, alignment: usize, offset_: isize) usize {
    var c = v;
    var offset = offset_;
    if (alignment != 0) {
        const off: isize = @intCast(c % alignment);
        if (off != offset) {
            offset -= off;
            if (offset < 0)
                offset += @intCast(alignment);
            c += @intCast(offset);
        }
    }
    return c;
}

/// poolspanallocl: allocate as described below; assumes pool locked
fn poolallocalignl(p: *Pool, dsize: usize, alignment: usize, offset_: isize, span: usize) ?[*]u8 {
    var offset = offset_;
    //
    // allocate block
    //   dsize bytes
    //   addr == offset (modulo align)
    //   does not cross span-byte block boundary
    //
    // to satisfy alignment, just allocate an extra
    // align bytes and then shift appropriately.
    //
    // to satisfy span, try once and see if we're
    // lucky.  the second time, allocate 2x asize
    // so that we definitely get one not crossing
    // the boundary.
    //
    if (alignment != 0) {
        const al: isize = @intCast(@min(alignment, std.math.maxInt(isize)));
        if (offset < 0)
            offset = al - @rem(-%offset, al);
        offset = @rem(offset, al);
    }
    const asize = dsize +| alignment;
    var v = addr(poolallocl(p, asize) orelse
        return null);
    if (span != 0 and v / span != (v + asize) / span) {
        // try again
        poolfreel(p, @ptrFromInt(v));
        v = addr(poolallocl(p, 2 *| asize) orelse
            return null);
    }

    //
    // figure out what pointer we want to return
    //
    var c = alignptr(v, alignment, offset);
    // DIFF: dsize != 0, see the header
    if (span != 0 and dsize != 0 and c / span != (c + dsize -% 1) / span) {
        c += span - c % span;
        c = alignptr(c, alignment, offset);
        if (c / span != (c + dsize -% 1) / span) {
            poolfreel(p, @ptrFromInt(v));
            werrstr(p, "cannot satisfy dsize %lud span %lud with align %lud+%ld", .{ dsize, span, alignment, offset });
            return null;
        }
    }
    var skip: u32 = @intCast(c - v);

    //
    // free up the skip bytes before that pointer
    // or mark it as unavailable.
    //
    var b = _D2B(v);
    p.curalloc -= b.size;
    b = freefromfront(p, b, skip);
    v = addr(_B2D(b));
    skip = @intCast(c - v);
    if (c > v) {
        var u: [*]u32 = @ptrFromInt(v);
        while (c >= addr(u) + @sizeOf(u32)) {
            u[0] = ALIGN_MAGIC;
            u += 1;
        }
    }
    _ = trim(p, b, skip + @as(u32, @intCast(dsize)));
    p.curalloc += b.size;
    assert(D2B(p, @ptrFromInt(c)) == b, "D2B(p, c) == b");
    const cp: [*]u8 = @ptrFromInt(c);
    if (antagonism(p)) {
        @memset(cp[0..dsize], 0xDD);
    }
    return cp;
}

/// poolfree: free block obtained from poolalloc; assumes lock held
fn poolfreel(p: *Pool, v_: ?*anyopaque) void {
    const v = v_ orelse // for ANSI
        return;

    var ab = D2B(p, v);
    blockcheck(p, ab);

    if (p.flags & POOL_NOREUSE != 0) {
        ab.magic = DEAD_MAGIC;
        const n = getdsize(ab);
        // DIFF: from the block's data, not from v, see the header
        if (n > 8)
            @memset((_B2D(ab) + 8)[0 .. n - 8], 0xDA);
        return;
    }

    p.nfree +%= 1;
    p.curalloc -= ab.size;
    const back = T2HDR(B2PT(ab));
    if (back.magic == FREE_MAGIC)
        ab = blockmerge(p, back, ab);

    const fwd = B2NB(ab);
    if (fwd.magic == FREE_MAGIC)
        ab = blockmerge(p, ab, fwd);

    if (scrub(p)) {
        @memset(bytes(_B2D(ab), ab.size - @sizeOf(Bhdr) - @sizeOf(Btail)), 0x00);
    }

    _ = pooladd(p, ab);
}

pub fn poolalloc(p: *Pool, n: usize) ?[*]u8 {
    p.lock(p);
    if (paranoia(p)) {
        poolcheckl(p);
    }
    if (verbosity(p)) {
        pooldumpl(p);
    }
    const v = poolallocl(p, n);
    if (paranoia(p)) {
        poolcheckl(p);
    }
    if (verbosity(p)) {
        pooldumpl(p);
    }
    if (p.logstack != null and (p.flags & POOL_LOGGING) != 0) p.logstack.?(p);
    LOG(p, "poolalloc %p %lud = %p\n", .{ addr(p), n, addr(v) });
    p.unlock(p);
    return v;
}

pub fn poolallocalign(p: *Pool, n: usize, alignment: usize, offset: isize, span: usize) ?[*]u8 {
    p.lock(p);
    if (paranoia(p)) {
        poolcheckl(p);
    }
    if (verbosity(p)) {
        pooldumpl(p);
    }
    const v = poolallocalignl(p, n, alignment, offset, span);
    if (paranoia(p)) {
        poolcheckl(p);
    }
    if (verbosity(p)) {
        pooldumpl(p);
    }
    if (p.logstack != null and (p.flags & POOL_LOGGING) != 0) p.logstack.?(p);
    LOG(p, "poolallocalign %p %lud %lud %ld %lud = %p\n", .{ addr(p), n, alignment, offset, span, addr(v) });
    p.unlock(p);
    return v;
}

pub fn poolcompact(p: *Pool) u32 {
    p.lock(p);
    if (paranoia(p)) {
        poolcheckl(p);
    }
    if (verbosity(p)) {
        pooldumpl(p);
    }
    const rv = poolcompactl(p);
    if (paranoia(p)) {
        poolcheckl(p);
    }
    if (verbosity(p)) {
        pooldumpl(p);
    }
    LOG(p, "poolcompact %p\n", .{addr(p)});
    p.unlock(p);
    return rv;
}

pub fn poolrealloc(p: *Pool, v: ?*anyopaque, n: usize) ?[*]u8 {
    p.lock(p);
    if (paranoia(p)) {
        poolcheckl(p);
    }
    if (verbosity(p)) {
        pooldumpl(p);
    }
    const nv = poolreallocl(p, v, n);
    if (paranoia(p)) {
        poolcheckl(p);
    }
    if (verbosity(p)) {
        pooldumpl(p);
    }
    if (p.logstack != null and (p.flags & POOL_LOGGING) != 0) p.logstack.?(p);
    LOG(p, "poolrealloc %p %p %ld = %p\n", .{ addr(p), addr(v), n, addr(nv) });
    p.unlock(p);
    return nv;
}

pub fn poolfree(p: *Pool, v: ?*anyopaque) void {
    p.lock(p);
    if (paranoia(p)) {
        poolcheckl(p);
    }
    if (verbosity(p)) {
        pooldumpl(p);
    }
    poolfreel(p, v);
    if (paranoia(p)) {
        poolcheckl(p);
    }
    if (verbosity(p)) {
        pooldumpl(p);
    }
    if (p.logstack != null and (p.flags & POOL_LOGGING) != 0) p.logstack.?(p);
    LOG(p, "poolfree %p %p\n", .{ addr(p), addr(v) });
    p.unlock(p);
}

//
// Return the real size of a block, and let the user use it.
//
pub fn poolmsize(p: *Pool, v: ?*anyopaque) usize {
    var dsize: u32 = undefined;

    p.lock(p);
    if (paranoia(p)) {
        poolcheckl(p);
    }
    if (verbosity(p)) {
        pooldumpl(p);
    }
    if (v) |x| {
        const b = D2B(p, x);
        dsize = (b.size & ~(p.quantum - 1)) - @sizeOf(Bhdr) - @sizeOf(Btail);
        assert(dsize >= getdsize(b), "dsize >= getdsize(b)");
        _ = blocksetdsize(p, b, dsize);
        // DIFF: what is usable from v, see the header
        dsize -= @intCast(addr(x) - addr(_B2D(b)));
    } else dsize = 0; // consistency with other braindead ANSI-ness
    if (paranoia(p)) {
        poolcheckl(p);
    }
    if (verbosity(p)) {
        pooldumpl(p);
    }
    if (p.logstack != null and (p.flags & POOL_LOGGING) != 0) p.logstack.?(p);
    LOG(p, "poolmsize %p %p = %ld\n", .{ addr(p), addr(v), dsize });
    p.unlock(p);
    return dsize;
}

pub fn poolisoverlap(p: *Pool, v: usize, n: usize) bool {
    p.lock(p);
    var a = p.arenalist;
    while (a) |x| : (a = x.down) {
        if (v +% n > addr(x) and v < addr(x) + x.asize)
            break;
    }
    p.unlock(p);
    return a != null;
}

pub fn poolreset(p_: ?*Pool) void {
    const p = p_ orelse return;

    p.lock(p);
    if (paranoia(p)) {
        poolcheckl(p);
    }
    if (verbosity(p)) {
        pooldumpl(p);
    }
    p.cursize = 0;
    p.curfree = 0;
    p.curalloc = 0;
    p.nfree = 0;
    p.lastcompact = 0;
    p.freeroot = null;
    var a = p.arenalist;
    p.arenalist = null;
    LOG(p, "poolreset %p\n", .{addr(p)});
    p.unlock(p);

    while (a) |x| {
        const next = x.down;
        const asize = x.asize;
        if (scrub(p)) {
            @memset(@as([*]u8, @ptrCast(x))[0..asize], 0x00);
        }
        if (antagonism(p)) {
            memmark(@ptrCast(x), 0xFF, asize);
        }
        if (p.free) |f|
            f(x, asize);
        a = next;
    }
}

//
// Debugging
//

fn poolcheckarena(p: *Pool, a: *Arena) void {
    const atail = A2TB(a);
    var b = hdr(a);
    while (b.magic != ARENATAIL_MAGIC and addr(b) < addr(atail)) : (b = B2NB(b))
        blockcheck(p, b);
    blockcheck(p, b);
    if (b != atail)
        ppanic(p, "found wrong tail", .{});
}

fn poolcheckl(p: *Pool) void {
    var a = p.arenalist;
    while (a) |x| : (a = x.down)
        poolcheckarena(p, x);
    if (p.freeroot) |r|
        checktree(r);
}

pub fn poolcheck(p: *Pool) void {
    p.lock(p);
    poolcheckl(p);
    p.unlock(p);
}

pub fn poolblockcheck(p: *Pool, v_: ?*anyopaque) void {
    const v = v_ orelse return;

    p.lock(p);
    blockcheck(p, D2B(p, v));
    p.unlock(p);
}

fn pooldumpl(p: *Pool) void {
    pprint(p, "pool %p %s\n", .{ addr(p), p.name });
    var a = p.arenalist;
    while (a) |x| : (a = x.down)
        pooldumparena(p, x);
}

pub fn pooldump(p: *Pool) void {
    p.lock(p);
    pooldumpl(p);
    p.unlock(p);
}

fn pooldumparena(p: *Pool, a: *Arena) void {
    var b = hdr(a);
    while (b.magic != ARENATAIL_MAGIC) : (b = B2NB(b))
        pprint(p, "(%p %.8lux %lud)", .{ addr(b), b.magic, b.size });
    pprint(p, "\n", .{});
}

//
// mark the memory in such a way that we know who marked it
// (via the signature) and we know where the marking started.
//
fn memmark(v: [*]u8, sig: u32, size: usize) void {
    const lp: [*]align(1) u32 = @ptrCast(v);
    const n = size / 4;
    for (0..n) |i|
        lp[i] = (sig << 24) ^ @as(u32, @truncate(i * 4));
    @memset(v[n * 4 .. size], @truncate(sig));
}
