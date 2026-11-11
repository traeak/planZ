//! The data structures, constants and macros of the IP stack: what
//! every file in ip/ includes.
//! from 9/ip/ip.h and 9/ip/ipv6.h; Arp from 9/ip/arp.c, Ipself and
//! Ipselftab from 9/ip/ipifc.c (see DIFF).
//!
//! This file is also the contract between the files of ip/, which were
//! ported separately.  Read the three parts of this header before
//! porting or calling anything: the file list, the signature rules,
//! and the notes on the types.  The Zig signature of every function
//! that crosses a file is at the end of the file.
//!
//! FILES.  A C function `f` defined in `x.c` is `pub fn f` in
//! `ip/x.zig`: same name, same place, signature by the rules below.
//!
//!     9/ip/arp.c              arp.zig
//!     9/ip/chandial.c         chandial.zig
//!     9/ip/devip.c            devip.zig
//!     9/ip/ethermedium.c      ethermedium.zig
//!     9/ip/icmp.c             icmp.zig
//!     9/ip/icmp6.c            icmp6.zig
//!     9/ip/inferno.c          inferno.zig
//!     9/ip/ip.c               ip.zig
//!     9/ip/ipaux.c + libip    ipaux.zig
//!     9/ip/ipifc.c            ipifc.zig
//!     9/ip/iproute.c          iproute.zig
//!     9/ip/ipv6.c             ipv6.zig
//!     9/ip/loopbackmedium.c   loopbackmedium.zig
//!     9/ip/netdevmedium.c     netdevmedium.zig
//!     9/ip/netlog.c           netlog.zig
//!     9/ip/nullmedium.c       nullmedium.zig
//!     9/ip/pktmedium.c        pktmedium.zig
//!     9/ip/tcp.c              tcp.zig
//!     9/ip/udp.c              udp.zig
//!     9/ip/ip.h, 9/ip/ipv6.h  ipdat.zig (this file)
//!
//! Not ported: il.c, rudp.c, gre.c, ipmux.c, igmp.c, esp.c, and with
//! them everything in the headers that only they use.
//!
//! SIGNATURE RULES, for functions and for the function pointers in
//! Proto and Medium.
//!
//!  1. Errors.  `Error` is proc.Error.  A C function that can call
//!     error(), itself or through what it calls outside a waserror,
//!     returns `Error!T`.  One that cannot returns plain `T`; do not
//!     add an error union "to be safe", callers are written against
//!     the lines at the end of this file.
//!
//!  2. `char*` error strings.  The C has functions that return an
//!     error string, nil for success (Proto.connect, announce, bind
//!     and ctl, Fsstdconnect, Fsstdannounce, Fsstdbind, setladdrport,
//!     setluniqueport, ipifcadd, ipifcdel, ipifcadd6, ipifcdel6,
//!     mediumunbindifc and the static ones around them).  They ALL
//!     return `Error!void` here, and nothing returns `?[]const u8`:
//!       - a returned literal, `return "bad args to bind";`, is
//!         `return proc.errorf("bad args to bind", .{});`
//!       - a returned E-constant, `return Ebadip;`, is
//!         `return error.Ebadip;`
//!       - the caller's `if(p != nil) error(p);` is `try`.
//!     The reason is that these functions raise as well as return
//!     strings in C: setladdrport calls error(Eperm), so the three
//!     Fsstd* functions and every protocol's connect/announce/bind
//!     raise; ipifcbind passes on what Medium.bind raises; ipifcadd
//!     turns a raised error into a returned up->errstr.  One channel
//!     is enough.  Where the C caller treats the two differently
//!     (connectctlmsg and announcectlmsg in devip.c set the state
//!     back to Idle only for a returned string) the Zig does the
//!     returned-string thing for every error.  All of them run in a
//!     process, so errorf's use of up.errstr is safe.
//!
//!  3. Output buffers.  `(char *buf, int len)` and `(char *p, char *e)`
//!     become `buf: []u8` and the function returns the number of bytes
//!     written (`usize`).  No NUL is written or counted: use
//!     `fmt.snprint(buf[n..], ...).len`.
//!
//!  4. Reads and writes.  `(char *a, ulong offset, int n)` becomes
//!     `(a: []u8, offset: usize)` returning the count; `(char *a, int
//!     n)` input becomes `a: []const u8`.  `(uchar *data, int n)` is a
//!     slice.
//!
//!  5. `char **argv, int argc` (in either order) becomes
//!     `argv: []const []const u8`; argc is argv.len.  Cmdbuf.f
//!     coerces to it.  The C edits argv strings in place (setladdrport
//!     writes NULs); the Zig must not, it cuts sub-slices instead.
//!     Other `char*` inputs are `[]const u8`, `?[]const u8` where the
//!     C passes nil.
//!
//!  6. Addresses.
//!       - an IP address is `*const [IPaddrlen]u8`, `*[IPaddrlen]u8`
//!         when the function writes it;
//!       - a v4 address in 4 byte form is `*const [IPv4addrlen]u8` or
//!         `*[IPv4addrlen]u8`.  The C's `a+IPv4off` is `a[IPv4off..]`,
//!         which has that type when `a` is a 16 byte array or a
//!         pointer to one;
//!       - where the length depends on a `version` argument (4 bytes
//!         for V4, 16 for V6: Medium.bwrite, ipifcoput, arpget,
//!         arpenter, arpforme) the address is `[]const u8` of that
//!         length;
//!       - MAC and other medium addresses are slices, and a `maclen`
//!         argument that only says how long one is disappears into
//!         the slice.
//!
//!  7. Integers.  An int used as a truth value is `bool`.  Counts,
//!     lengths, sizes and indexes that are never negative are `usize`.
//!     Ports are `u16`.  An IP version (V4, V6) is `u8`.  Route type
//!     bits (Rv4 ... Rsrc) are `u16` everywhere, including Iplifc.type
//!     and Ipself.type, which are uchar in C.  ttl and tos stay `u32`
//!     as arguments (the C's int, truncated where stored in a header).
//!     Times in milliseconds or seconds are `u32` (the C's ulong).
//!
//!  8. Blocks.  `Block*` is `*Block`, `?*Block` where the C passes or
//!     returns nil.  A function that is handed a block owns it from
//!     then on IN EVERY CASE, also when it returns an error: it frees
//!     it or passes it on.  The exceptions say "bp stays with the
//!     caller" on their line at the end of this file (the icmp error
//!     senders, which copy from the packet they complain about).
//!
//!  9. `void*` arguments and private pointers (Conv.ptcl, Proto.priv,
//!     Ipifc.arg) are `?*anyopaque`.  The owner casts:
//!     `const tcb: *Tcpctl = @ptrCast(@alignCast(s.ptcl.?));`
//!
//! 10. Format verbs.  %I, %M, %V and %E need a wrapped argument:
//!     ipaux.ip(a), ipaux.mask(m), ipaux.v4(a), ipaux.ea(mac).  This
//!     holds for netlog() too.
//!
//! NOTES ON THE TYPES.
//!
//!   - Every struct here except the wire headers has a default for
//!     every field.  Memory from alloc.new/snew must be initialised:
//!     `p.* = .{};`.  Conv.ptcl is malloc(Proto.ptclsize), zeroed, as
//!     in C; a protocol's `create` initialises its control block.
//!   - An embedded anonymous struct is a field named after its type in
//!     lower case: `qlock`, `rwlock`, `lock`, `rendez`, `iphash`,
//!     `routehint`.  So the C's qlock(c) is qlock(&c.qlock), rlock(ifc)
//!     is rlock(&ifc.rwlock), c->laddr is c.iphash.laddr, c->lport is
//!     c.iphash.lport, and passing a Conv as a Routehint (the last
//!     argument of ipoput4) is &c.routehint.  iphconv, iphforward and
//!     iphbackward go back from the Iphash to what holds it.
//!   - Route: the embedded RouteTree is flattened into Route (r.mid,
//!     r.type, r.ifc as in C) and the anonymous union is the field
//!     `u`: r.u.v4.gate, r.u.v6.address.  It is an extern union so
//!     either arm may be read or copied at any time.  There is no
//!     RouteTree type: the C uses it only to allocate v4 routes
//!     shorter than v6 ones, and here every Route is whole, so `r.* =
//!     x.*` and stack copies are safe.
//!   - Strings: `char *name` members are `[]const u8`; Conv.owner and
//!     IPaux.owner are kstrdup'd `[]u8` starting as portdat.nostr;
//!     fixed arrays (Ipifc.dev, Conv.cerr, tags) stay NUL-padded
//!     arrays as in C, read with std.mem.sliceTo(&x, 0) or
//!     Ipifc.devname().
//!   - Media are `pub const x: Medium`; Ipifc.m is `?*const Medium`
//!     and is compared by address as in C (`ifc.m == &unboundmedium`).
//!   - Proto.conv is a slice of nc+1 optional pointers; the entry
//!     after the last conversation in use is null, as in C.
//!   - Ipfrag and Ip6hdr end in a flexible array member in C; here the
//!     struct stops before it and payload() gives the bytes that
//!     follow.
//!   - Wire headers are extern structs of bytes, alignment 1, to be
//!     laid over packet data: `const h: *Ip4hdr = @ptrCast(bp.rp);`.
//!
//! DIFF:
//!   - Arp, Ipself and Ipselftab are defined here and not in arp.zig
//!     and ipifc.zig, so that Fs and Iplink can name them without
//!     those files; the C keeps them incomplete in ip.h.  Their hash
//!     macro is hashipa() here.
//!   - Fs.ipmux and the `Hwaddr` typedef are gone (ipmux is not
//!     ported; Hwaddr is never defined).  Fsrcvpcol is then the same
//!     as Fsrcvpcolx.
//!   - IPv4bcastobs is declared in ip.h but defined nowhere; it is not
//!     here.  The other address constants are in ipaux.zig, where the
//!     C defines them, and are constants.
//!   - Protocol numbers (IP_ICMPPROTO, IP_TCPPROTO, IP_UDPPROTO) are
//!     private enums of each protocol file in C; they are here once.
//!   - Log flags of protocols that are not ported are left out, and so
//!     are their names in netlog.zig.
//!   - ipcmp returns 0 or 1 as an i32 so `ipcmp(a, b) == 0` reads as
//!     in C; MIN is @min.
//!   - See rule 7 for the integer widths that changed, rule 2 for the
//!     error strings.

const std = @import("std");
const arch = @import("../arch.zig");
const portdat = @import("../port/portdat.zig");
const proc = @import("../port/proc.zig");
const portclock = @import("../port/portclock.zig");
const ab = @import("../port/allocb.zig");
const qio = @import("../port/qio.zig");
const ipaux = @import("ipaux.zig");

pub const Error = proc.Error;
pub const Block = ab.Block;
pub const Queue = qio.Queue;
pub const Chan = portdat.Chan;
pub const Proc = portdat.Proc;
pub const Lock = portdat.Lock;
pub const QLock = portdat.QLock;
pub const RWLock = portdat.RWLock;
pub const Rendez = portdat.Rendez;
pub const Ref = portdat.Ref;
pub const Qid = portdat.Qid;
pub const ERRMAX = portdat.ERRMAX;

pub const Netlog = @import("netlog.zig").Netlog;

pub const Addrlen = 64;
pub const Maxproto = 20;
pub const Maxincall = 10;
pub const Nchans = 1024;
pub const MAClen = 8; // longest mac address

pub const MAXTTL = 255;
pub const DFLTTOS = 0;

pub const IPaddrlen = 16;
pub const IPv4addrlen = 4;
pub const IPv4off = 12;
pub const IPllen = 4;

// ip versions
pub const V4 = 4;
pub const V6 = 6;
pub const IP_VER4 = 0x40;
pub const IP_VER6 = 0x60;
pub const IP_HLEN4 = 5; // v4: Header length in words
pub const IP_DF = 0x4000; // v4: Don't fragment
pub const IP_MF = 0x2000; // v4: More fragments
pub const IP_FO = 0x1fff; // v4: Fragment offset
pub const IP4HDR = IP_HLEN4 << 2; // sizeof(Ip4hdr)
pub const IP_MAX = 64 * 1024; // Max. Internet packet size, v4 & v6
pub const v4MINTU = 68; // The minimum MTU for IPv4 is 68 bytes

// 2^Lroot trees in the root table
pub const Lroot = 10;

pub const Maxpath = 64;

// DIFF: private to icmp.c, tcp.c and udp.c in C.
pub const IP_ICMPPROTO = 1;
pub const IP_TCPPROTO = 6;
pub const IP_UDPPROTO = 17;

// Conv.state
pub const Idle = 0;
pub const Announcing = 1;
pub const Announced = 2;
pub const Connecting = 3;
pub const Connected = 4;

// MIB II counters
pub const Forwarding = 0;
pub const DefaultTTL = 1;
pub const InReceives = 2;
pub const InHdrErrors = 3;
pub const InAddrErrors = 4;
pub const ForwDatagrams = 5;
pub const InUnknownProtos = 6;
pub const InDiscards = 7;
pub const InDelivers = 8;
pub const OutRequests = 9;
pub const OutDiscards = 10;
pub const OutNoRoutes = 11;
pub const ReasmTimeout = 12;
pub const ReasmReqds = 13;
pub const ReasmOKs = 14;
pub const ReasmFails = 15;
pub const FragOKs = 16;
pub const FragFails = 17;
pub const FragCreates = 18;

pub const Nipstats = 19;

pub const Fragment4 = struct {
    blist: ?*Block = null,
    next: ?*Fragment4 = null,
    src: u32 = 0,
    dst: u32 = 0,
    id: u16 = 0,
    age: u32 = 0,
};

pub const Fragment6 = struct {
    blist: ?*Block = null,
    next: ?*Fragment6 = null,
    src: [IPaddrlen]u8 = @splat(0),
    dst: [IPaddrlen]u8 = @splat(0),
    id: u32 = 0,
    age: u32 = 0,
};

/// Kept at the base of a block that holds a fragment.
pub const Ipfrag = extern struct {
    foff: u16,
    flen: u16,

    /// The C's flexible member payload[].
    pub fn payload(fp: *Ipfrag) [*]u8 {
        return @as([*]u8, @ptrCast(fp)) + IPFRAGSZ;
    }
};

pub const IPFRAGSZ = @sizeOf(Ipfrag);

/// an instance of IP
pub const IP = struct {
    stats: [Nipstats]u64 = @splat(0),

    fraglock4: QLock = .{},
    flisthead4: ?*Fragment4 = null,
    fragfree4: ?*Fragment4 = null,
    id4: Ref = .{},

    fraglock6: QLock = .{},
    flisthead6: ?*Fragment6 = null,
    fragfree6: ?*Fragment6 = null,
    id6: Ref = .{},

    iprouting: bool = false, // true if we route like a gateway
};

/// on the wire packet header
pub const Ip4hdr = extern struct {
    vihl: u8, // Version and header length
    tos: u8, // Type of service
    length: [2]u8, // packet length
    id: [2]u8, // ip->identification
    frag: [2]u8, // Fragment information
    ttl: u8, // Time to live
    proto: u8, // Protocol
    cksum: [2]u8, // Header checksum
    src: [4]u8, // IP source
    dst: [4]u8, // IP destination
};

/// cache for route and arp table lookups.
/// one per Conv so conversations with a
/// fixed target can avoid the per packet
/// lookup overhead.
pub const Routehint = struct {
    r: ?*Route = null, // last route used
    rgen: u32 = 0, // routetable generation for *r
    a: ?*Arpent = null, // last arp entry used
};

// hash table for 2 ip addresses + 2 ports
pub const Nipht = 521; // convenient prime

pub const IPmatchexact = 0; // match on 4 tuple
pub const IPmatchany = 1; // *!*
pub const IPmatchport = 2; // *!port
pub const IPmatchaddr = 3; // addr!*
pub const IPmatchpa = 4; // addr!port

pub const Iphash = struct {
    nextiphash: ?*Iphash = null,

    trans: u8 = 0, // 0 = conv, 1 = foward, 2 = backward
    match: u8 = 0,
    lport: u16 = 0, // local port number
    rport: u16 = 0, // remote port number
    laddr: [IPaddrlen]u8 = @splat(0), // local IP address
    raddr: [IPaddrlen]u8 = @splat(0), // remote IP address
};

pub const Ipht = struct {
    lock: Lock = .{},
    tab: [Nipht]?*Iphash = @splat(null),
};

/// NAT entry.
///
/// This holds the 5 tuple as two Iphashes.
/// The "forward" hash matches the the packets from
/// the source that need to be translated and
/// "backward" matches the packets coming back
/// from the destination.
pub const Translation = struct {
    next: ?*Translation = null,
    link: ?*?*Translation = null,

    time: u32 = 0,

    forward: Iphash = .{},
    backward: Iphash = .{},

    // used for forwarding to the source
    routehint: Routehint = .{},
};

pub fn iphforward(h: *Iphash) *Translation {
    return @fieldParentPtr("forward", h);
}

pub fn iphbackward(h: *Iphash) *Translation {
    return @fieldParentPtr("backward", h);
}

/// one per conversation directory
pub const Conv = struct {
    qlock: QLock = .{},

    x: usize = 0, // conversation index
    p: ?*Proto = null,

    ttl: u32 = 0, // max time to live
    tos: u32 = 0, // type of service

    restricted: bool = false, // remote port is restricted
    ignoreadvice: bool = false, // don't terminate connection on icmp errors
    ipversion: u8 = 0,

    iphash: Iphash = .{},

    owner: []u8 = portdat.nostr, // protections
    perm: u32 = 0,
    inuse: i32 = 0, // opens of listen/data/ctl
    length: usize = 0,
    state: i32 = Idle,
    ctime: u32 = 0,

    // udp specific
    headers: i32 = 0, // data src/dst headers in udp

    incall: ?*Conv = null, // calls waiting to be listened for
    next: ?*Conv = null,

    rq: ?*Queue = null, // queued data waiting to be read
    wq: ?*Queue = null, // queued data waiting to be written
    eq: ?*Queue = null, // returned error packets
    sq: ?*Queue = null, // snooping queue
    snoopers: Ref = .{}, // number of processes with snoop open

    cr: Rendez = .{},
    cerr: [ERRMAX]u8 = @splat(0),

    listenq: QLock = .{},
    listenr: Rendez = .{},

    multi: ?*Ipmulti = null, // multicast bindings for this interface

    ptcl: ?*anyopaque = null, // protocol specific stuff

    routehint: Routehint = .{},
};

pub fn iphconv(h: *Iphash) *Conv {
    return @fieldParentPtr("iphash", h);
}

pub const Medium = struct {
    name: []const u8,
    hsize: usize = 0, // medium header size
    mintu: usize = 0, // default min mtu
    maxtu: usize = 0, // default max mtu
    maclen: usize = 0, // mac address length
    /// argv is the whole "bind" request: argv[1] the medium name,
    /// argv[2] the device if there is one.
    bind: ?*const fn (ifc: *Ipifc, argv: []const []const u8) Error!void = null,
    /// Cannot fail: a medium waits out or ignores its own errors.
    unbind: ?*const fn (ifc: *Ipifc) void = null,
    /// Called with ifc rlock'd.  ip is 4 bytes for V4, 16 for V6.
    /// Owns bp in every case: on an error it has already freed it.
    bwrite: ?*const fn (ifc: *Ipifc, bp: *Block, version: u8, ip: []const u8, rh: ?*Routehint) Error!void = null,

    // for arming interfaces to receive multicast
    addmulti: ?*const fn (ifc: *Ipifc, a: *const [IPaddrlen]u8, ia: *const [IPaddrlen]u8) Error!void = null,
    delmulti: ?*const fn (ifc: *Ipifc, a: *const [IPaddrlen]u8, ia: *const [IPaddrlen]u8) Error!void = null,

    // address resolution
    areg: ?*const fn (f: *Fs, ifc: *Ipifc, lifc: *Iplifc, ip: *const [IPaddrlen]u8) Error!void = null,

    // v6 address generation
    pref2addr: ?*const fn (pref: *[IPaddrlen]u8, ea: []const u8) void = null,

    unbindonclose: bool = false, // if true, unbind on last close
};

/// logical interface associated with a physical one
pub const Iplifc = struct {
    local: [IPaddrlen]u8 = @splat(0),
    mask: [IPaddrlen]u8 = @splat(0),
    remote: [IPaddrlen]u8 = @splat(0),
    net: [IPaddrlen]u8 = @splat(0),
    type: u16 = 0, // route type
    tentative: bool = false, // true => v6 dup disc on, false => confirmed unique
    onlink: bool = false, // true => onlink, false offlink.
    autoflag: bool = false, // v6 autonomous flag
    validlt: u32 = 0, // v6 valid lifetime
    preflt: u32 = 0, // v6 preferred lifetime
    origint: u32 = 0, // time when addr was added
    link: ?*Iplink = null, // addresses linked to this lifc
    next: ?*Iplifc = null,
};

/// binding twixt Ipself and Iplifc
pub const Iplink = struct {
    self: ?*Ipself = null,
    lifc: ?*Iplifc = null,
    selflink: ?*Iplink = null, // next link for this local address
    lifclink: ?*Iplink = null, // next link for this lifc
    next: ?*Iplink = null, // free list
    expire: u32 = 0,
    ref: i32 = 0,
};

// rfc 2461, pp.40—43.

/// default values, one per stack
pub const Routerparams = struct {
    mflag: i32 = 0, // flag: managed address configuration
    oflag: i32 = 0, // flag: other stateful configuration
    maxraint: i32 = 0, // max. router adv interval (ms)
    minraint: i32 = 0, // min. router adv interval (ms)
    linkmtu: i32 = 0, // mtu options
    reachtime: i32 = 0, // reachable time
    rxmitra: i32 = 0, // retransmit interval
    ttl: i32 = 0, // cur hop count limit
    routerlt: i32 = 0, // router lifetime
};

pub const Hostparams = struct {
    rxmithost: i32 = 0,
};

pub const Ipifc = struct {
    rwlock: RWLock = .{},

    conv: ?*Conv = null, // link to its conversation structure
    dev: [64]u8 = @splat(0), // device we're attached to
    m: ?*const Medium = null, // Media pointer
    maxtu: usize = 0, // Maximum transfer unit
    arg: ?*anyopaque = null, // medium specific

    reflect: bool = false, // allow forwarded packets to go out the same interface
    reassemble: bool = false, // reassemble IP packets before forwarding to this interface

    ifcid: u8 = 0, // incremented each 'bind/unbind/add/remove'

    mac: [MAClen]u8 = @splat(0), // MAC address

    lifc: ?*Iplifc = null, // logical interfaces on this physical one
    loopback: ?*Queue = null,

    in: u32 = 0, // message statistics
    out: u32 = 0,
    inerr: u32 = 0, // ...
    outerr: u32 = 0,

    sendra6: bool = false, // flag: send router advs on this ifc
    recvra6: bool = false, // flag: recv router advs on this ifc
    rp: Routerparams = .{}, // router parameters as in RFC 2461, pp.40—43.
    // used only if node is router

    speed: i32 = 0, // link speed in bits per second
    delay: i32 = 0, // burst delay in ms
    burst: i32 = 0, // burst delay in bytes
    load: i32 = 0, // bytes in flight
    ticks: u32 = 0,

    /// dev as a string.
    pub fn devname(ifc: *const Ipifc) []const u8 {
        return std.mem.sliceTo(&ifc.dev, 0);
    }
};

/// one per multicast-lifc pair used by a Conv
pub const Ipmulti = struct {
    ma: [IPaddrlen]u8 = @splat(0),
    ia: [IPaddrlen]u8 = @splat(0),
    next: ?*Ipmulti = null,
};

/// one per multiplexed protocol
pub const Proto = struct {
    qlock: QLock = .{},
    name: []const u8 = "", // protocol name
    x: usize = 0, // protocol index
    ipproto: i32 = 0, // ip protocol type, -1 for none

    /// argv is the whole control message, argv[0] the request.
    connect: ?*const fn (c: *Conv, argv: []const []const u8) Error!void = null,
    announce: ?*const fn (c: *Conv, argv: []const []const u8) Error!void = null,
    bind: ?*const fn (c: *Conv, argv: []const []const u8) Error!void = null,
    state: ?*const fn (c: *Conv, buf: []u8) usize = null,
    /// Sets c.rq and c.wq; the caller frees what was made when this
    /// fails.
    create: ?*const fn (c: *Conv) Error!void = null,
    close: ?*const fn (c: *Conv) void = null,
    /// Owns bp.  Cannot fail: no protocol's input routine raises.
    rcv: ?*const fn (p: *Proto, ifc: *Ipifc, bp: *Block) void = null,
    ctl: ?*const fn (c: *Conv, argv: []const []const u8) Error!void = null,
    /// Owns bp.
    advise: ?*const fn (p: *Proto, bp: *Block, ifc: *Ipifc, msg: []const u8) void = null,
    stats: ?*const fn (p: *Proto, buf: []u8) usize = null,
    local: ?*const fn (c: *Conv, buf: []u8) usize = null,
    remote: ?*const fn (c: *Conv, buf: []u8) usize = null,
    inuse: ?*const fn (c: *Conv) bool = null,
    gc: ?*const fn (p: *Proto) bool = null, // returns true if any conversations are freed

    f: ?*Fs = null, // file system this proto is part of
    conv: []?*Conv = &.{}, // array of conversations
    ptclsize: usize = 0, // size of per protocol ctl block
    nc: usize = 0, // number of conversations
    ac: usize = 0,
    qid: Qid = .{}, // qid for protocol directory
    nextrport: u16 = 0,

    // network address translation
    translations: ?*Translation = null,
    freetranslations: ?*Translation = null,
    /// Owns bp; returns the block to send on, or null if it dropped it.
    forward: ?*const fn (p: *Proto, bp: *Block, r: *Route) ?*Block = null,
    ht: ?*Ipht = null,

    priv: ?*anyopaque = null,
};

pub const Ndb = struct {
    qlock: QLock = .{},
    buf: ?[*]u8 = null,
    len: usize = 0,
    vers: u32 = 0,
    mtime: u32 = 0,
};

/// one per IP protocol stack
pub const Fs = struct {
    rwlock: RWLock = .{},
    dev: u32 = 0,

    np: usize = 0,
    p: [Maxproto + 1]?*Proto = @splat(null), // list of supported protocols
    t2p: [256]?*Proto = @splat(null), // vector of all protocols
    ipifc: ?*Proto = null, // kludge for findipifc

    ip: ?*IP = null,
    self: ?*Ipselftab = null,
    arp: ?*Arp = null,
    v6p: ?*v6params = null,

    v4root: [1 << Lroot]?*Route = @splat(null), // v4 routing forest
    v6root: [1 << Lroot]?*Route = @splat(null), // v6 routing forest
    queue: ?*Route = null, // used as temp when reinjecting routes

    alog: ?*Netlog = null,

    ndb: Ndb = .{}, // an ndb entry for this interface
};

pub const v6params = struct {
    rp: Routerparams = .{}, // v6 params, one copy per node now
    hp: Hostparams = .{},
};

// logging
pub const Logip: u32 = 1 << 1;
pub const Logtcp: u32 = 1 << 2;
pub const Logfs: u32 = 1 << 3;
pub const Logicmp: u32 = 1 << 5;
pub const Logudp: u32 = 1 << 6;
pub const Logcompress: u32 = 1 << 7;
pub const Logppp: u32 = 1 << 10;
pub const Logtcprxmt: u32 = 1 << 11;
pub const Logudpmsg: u32 = 1 << 13;
pub const Logipmsg: u32 = 1 << 14;
pub const Logtcpwin: u32 = 1 << 18;
pub const Logtrans: u32 = 1 << 19;

// iproute.c

// type bits
pub const Rv4: u16 = 1 << 0; // this is a version 4 route
pub const Rifc: u16 = 1 << 1; // this route is a directly connected interface
pub const Rptpt: u16 = 1 << 2; // this route is a pt to pt interface
pub const Runi: u16 = 1 << 3; // a unicast self address
pub const Rbcast: u16 = 1 << 4; // a broadcast self address
pub const Rmulti: u16 = 1 << 5; // a multicast self address
pub const Rproxy: u16 = 1 << 6; // this route should be proxied
pub const Rtrans: u16 = 1 << 7; // this route translates source address (NAT)

pub const Rsrc: u16 = 1 << 8; // source specific route

pub const V4route = extern struct {
    address: u32 = 0,
    endaddress: u32 = 0,

    source: u32 = 0,
    endsource: u32 = 0,

    gate: [IPv4addrlen]u8 = @splat(0),
};

pub const V6route = extern struct {
    address: [IPllen]u32 = @splat(0),
    endaddress: [IPllen]u32 = @splat(0),

    source: [IPllen]u32 = @splat(0),
    endsource: [IPllen]u32 = @splat(0),

    gate: [IPaddrlen]u8 = @splat(0),
};

/// DIFF: the C's RouteTree is the part before `u`; see the head of the
/// file.
pub const Route = struct {
    mid: ?*Route = null,
    left: ?*Route = null,
    right: ?*Route = null,
    ifc: ?*Ipifc = null,
    ifcid: u8 = 0, // must match ifc->ifcid
    depth: u8 = 0,
    type: u16 = 0,
    tag: [4]u8 = @splat(0),
    ref: i32 = 0,

    u: extern union {
        v6: V6route,
        v4: V4route,
    } = .{ .v6 = .{} },
};

// devip.c

/// Hanging off every ip channel's ->aux is the following structure.
/// It maintains the state used by devip and iproute.
pub const IPaux = struct {
    owner: []u8 = portdat.nostr, // the user that did the attach
    tag: [4]u8 = @splat(0),
};

// arp.c

pub const Arpent = struct {
    ip: [IPaddrlen]u8 = @splat(0),
    mac: [MAClen]u8 = @splat(0),
    hash: ?*Arpent = null,
    nextrxt: ?*Arpent = null, // re-transmit chain
    hold: ?*Block = null,
    last: ?*Block = null,
    ifc: ?*Ipifc = null,
    ifcid: u8 = 0, // must match ifc->ifcid
    state: u8 = 0,
    rxtsrem: u8 = 0, // re-tranmissions remaining
    ctime: u32 = 0, // time entry was created or refreshed
    utime: u32 = 0, // time entry was last used
};

/// Size of the hash tables of Arp and Ipselftab (NHASH in both arp.c
/// and ipifc.c) and of the arp cache.
pub const NHASH = 1 << 6;
pub const NCACHE = 256;

/// quick hash for ip addresses
pub fn hashipa(a: *const [IPaddrlen]u8) usize {
    return (@as(usize, a[IPaddrlen - 2]) + a[IPaddrlen - 1]) % NHASH;
}

/// address resolution tables, one per Fs
/// DIFF: from arp.c; see the head of the file.
pub const Arp = struct {
    rwlock: RWLock = .{},
    f: ?*Fs = null,
    hash: [NHASH]?*Arpent = @splat(null),
    cache: [NCACHE]Arpent = @splat(.{}),
    rxmt: [2]?*Arpent = @splat(null),
    rxmitp: ?*Proc = null, // neib sol re-transmit proc
    rxmtq: Rendez = .{},
    dropf: ?*Block = null,
    dropl: ?*Block = null,
};

// ipifc.c

/// cache of local addresses (addresses we answer to)
/// DIFF: from ipifc.c; see the head of the file.
pub const Ipself = struct {
    a: [IPaddrlen]u8 = @splat(0),
    next: ?*Ipself = null, // next address in the hash table
    link: ?*Iplink = null, // binding twixt Ipself and Ipifc
    expire: u32 = 0,
    type: u16 = 0, // type of address
};

/// DIFF: from ipifc.c; see the head of the file.
pub const Ipselftab = struct {
    qlock: QLock = .{},
    inited: bool = false,
    acceptall: bool = false, // true if an interface has the null address
    hash: [NHASH]?*Ipself = @splat(null), // hash chains
};

// ipaux.c

pub fn ipmove(x: *[IPaddrlen]u8, y: *const [IPaddrlen]u8) void {
    x.* = y.*;
}

/// 0 if the addresses are the same, 1 if not.
pub fn ipcmp(x: *const [IPaddrlen]u8, y: *const [IPaddrlen]u8) i32 {
    return @intFromBool(!std.mem.eql(u8, x, y));
}

pub fn isv4mcast(ip4: *const [IPv4addrlen]u8) bool {
    return ip4[0] >= 0xe0 and ip4[0] < 0xf0;
}

/// Milliseconds since boot.
pub fn NOW() u32 {
    return portclock.tk2ms(arch.MACHP(0).ticks);
}

//
// Internet Protocol Version 6
// from 9/ip/ipv6.h
//
// rfc2460 defines the protocol, rfc2461 neighbour discovery, and
// rfc2462 address autoconfiguration.  rfc4443 defines ICMP; was rfc2463.
// rfc4291 defines the address architecture (including prefices), was rfc3513.
// rfc4007 defines the scoped address architecture.
//
// global unicast is anything but unspecified (::), loopback (::1),
// multicast (ff00::/8), and link-local unicast (fe80::/10).
//
// site-local (fec0::/10) is now deprecated, originally by rfc3879.
//
// Unique Local IPv6 Unicast Addresses are defined by rfc4193.
// prefix is fc00::/7, scope is global, routing is limited to roughly a site.
//

pub fn isv6mcast(addr: *const [IPaddrlen]u8) bool {
    return addr[0] == 0xff;
}

pub fn islinklocal(addr: *const [IPaddrlen]u8) bool {
    return addr[0] == 0xfe and (addr[1] & 0xc0) == 0x80;
}

pub fn isula(addr: *const [IPaddrlen]u8) bool {
    return (addr[0] & 0xfe) == 0xfc;
}

pub fn issmcast(addr: *const [IPaddrlen]u8) bool {
    return std.mem.eql(u8, addr[0..13], ipaux.v6solicitednode[0..13]);
}

// Header Types
pub const HBH = 0; // hop-by-hop multicast routing protocol
pub const ICMP = 1;
pub const IGMP = 2;
pub const GGP = 3;
pub const IPINIP = 4;
pub const ST = 5;
pub const TCP = 6;
pub const UDP = 17;
pub const ISO_TP4 = 29;
pub const RH = 43;
pub const FH = 44;
pub const IDRP = 45;
pub const RSVP = 46;
pub const AH = 51;
pub const ESP = 52;
pub const ICMPv6 = 58;
pub const NNH = 59;
pub const DOH = 60;
pub const ISO_IP = 80;
pub const IGRP = 88;
pub const OSPF = 89;

pub const Maxhdrtype = 256;

// multicast flags and scopes

// Well_known_flg = 0,
// Transient_flg = 1,

// Interface_local_scop = 1,
pub const Link_local_scop = 2;
// Site_local_scop = 5,
// Org_local_scop = 8,
pub const Global_scop = 14;

// various prefix lengths
pub const SOLN_PREF_LEN = 13;

// various flags & constants
pub const v6MINTU = 1280;
pub const IP6HDR = 40; // sizeof(Ip6hdr) = 8 + 2*16
pub const IP6FHDR = 8; // sizeof(Fraghdr6)

// option types

// neighbour discovery
pub const SRC_LLADDR = 1;
pub const TARGET_LLADDR = 2;
pub const PREFIX_INFO = 3;
pub const REDIR_HEADER = 4;
pub const MTU_OPTION = 5;
// new since rfc2461; see iana.org/assignments/icmpv6-parameters
pub const V6nd_home = 8;
pub const V6nd_srcaddrs = 9; // rfc3122
pub const V6nd_ip = 17;
// /lib/rfc/drafts/draft-jeong-dnsop-ipv6-dns-discovery-12.txt
pub const V6nd_rdns = 25;
// plan 9 extensions
pub const V6nd_9fs = 250;
pub const V6nd_9auth = 251;

pub const SRC_UNSPEC = 0;
pub const SRC_UNI = 1;
pub const TARG_UNI = 2;
pub const TARG_MULTI = 3;

// Node constants
pub const MAX_MULTICAST_SOLICIT = 3;
pub const RETRANS_TIMER = 1000;

/// The C's IPV6HDR macro, followed in the packet by the payload.
pub const Ip6hdr = extern struct {
    vcf: [4]u8, // version:4, traffic class:8, flow label:20
    ploadlen: [2]u8, // payload length: packet length - 40
    proto: u8, // next header type
    ttl: u8, // hop limit
    src: [IPaddrlen]u8,
    dst: [IPaddrlen]u8,

    /// The C's flexible member payload[].
    pub fn payload(h: *Ip6hdr) [*]u8 {
        return @as([*]u8, @ptrCast(h)) + IP6HDR;
    }
};

pub const Opthdr = extern struct { // unused
    nexthdr: u8,
    len: u8,
};

/// Beware routing header type 0 (loose source routing); see
/// http://www.secdev.org/conf/IPv6_RH_security-csw07.pdf.
/// Type 1 is unused.  Type 2 is for MIPv6 (mobile IPv6) filtering
/// against type 0 header.
pub const Routinghdr = extern struct { // unused
    nexthdr: u8,
    len: u8,
    rtetype: u8,
    segrem: u8,
};

pub const Fraghdr6 = extern struct {
    nexthdr: u8,
    res: u8,
    offsetRM: [2]u8, // Offset, Res, M flag
    id: [4]u8,
};

comptime {
    std.debug.assert(@sizeOf(Ip4hdr) == IP4HDR and @alignOf(Ip4hdr) == 1);
    std.debug.assert(@sizeOf(Ip6hdr) == IP6HDR and @alignOf(Ip6hdr) == 1);
    std.debug.assert(@sizeOf(Fraghdr6) == IP6FHDR);
    std.debug.assert(IPFRAGSZ == 4);
}

// =====================================================================
// CONTRACT: functions that cross files.
//
// One line for every function that a file of ip/ exports to another
// (or to the kernel configuration), grouped by the file that defines
// it.  Port and call them exactly as written here.  Anything else in a
// C file is private to its Zig file, whatever the C's linkage says.
// `A` stands for `*const [IPaddrlen]u8`, `A4` for `*const
// [IPv4addrlen]u8`, `Args` for `[]const []const u8`; write the types
// out in the code.
//
// ipaux.zig, netlog.zig, nullmedium.zig, pktmedium.zig, inferno.zig
//   exist: read their pub declarations.  In short: the address
//   constants, parseip..., v4tov6..., ptclbsum/ptclcsum, iphtadd/
//   iphtrem/iphtlook, trans*, hnputs_csum, the format wrappers and
//   hnputs/nhgets... are ipaux.x; netlog(f, mask, fmt, args) is
//   netlog.netlog; commonuser/commonerror/bootpread are inferno.x;
//   nullmedium, unboundmedium and nullmediumlink are nullmedium.x;
//   pktmedium and pktmediumlink are pktmedium.x.
//
// devip.zig:
//   pub const ipdevtab: dev.Dev
//   pub var ipprotoinit: []const *const fn (f: *Fs) void = &.{};
//       The C's table from the kernel configuration (tcpinit, udpinit,
//       ipifcinit, icmpinit, icmp6init in that order in pc64); devip
//       calls each at the first attach.  Whoever wires the stack into
//       conf/ sets it and calls the medium link functions; devip.zig
//       does not import the protocol files for this.
//   pub fn newipaux(owner: []const u8, tag: []const u8) *IPaux
//   pub fn closeconv(cv: *Conv) void
//   pub fn setluniqueport(c: *Conv, lport: u16) Error!void
//   pub fn lportinuse(p: *Proto, lport: u16) bool
//   pub fn unusedlport(p: *Proto) ?u16
//       null where the C returns -1.  p is locked.
//   pub fn setladdrport(c: *Conv, str: []const u8, announcing: bool) Error!void
//   pub fn Fsstdconnect(c: *Conv, argv: Args) Error!void
//   pub fn Fsstdannounce(c: *Conv, argv: Args) Error!void
//   pub fn Fsstdbind(c: *Conv, argv: Args) Error!void
//   pub fn Fsproto(f: *Fs, p: *Proto) i32
//       0, or -1 if there is no room or the protocol number is taken.
//   pub fn Fsbuiltinproto(f: *Fs, proto: u8) bool
//   pub fn Fsprotoclone(p: *Proto, user: []const u8) ?*Conv
//       called with p locked; catches the errors of Proto.create.
//   pub fn Fsconnected(c: *Conv, msg: ?[]const u8) void
//       the C returns 0, always.
//   pub fn Fsrcvpcol(f: *Fs, proto: u8) ?*Proto
//   pub fn Fsrcvpcolx(f: *Fs, proto: u8) ?*Proto
//   pub fn Fsnewcall(c: *Conv, raddr: A, rport: u16, laddr: A, lport: u16, version: u8) ?*Conv
//   pub fn scalednconv() usize
//
// chandial.zig:
//   pub fn chandial(dest: []const u8, local: ?[]const u8, dir: ?*[Maxpath]u8, ctlp: ?*?*Chan) Error!*Chan
//       dir receives the conversation directory, NUL terminated.
//
// ipifc.zig:
//   pub var multicastreportfn: ?*const fn (f: *Fs, ifc: *Ipifc, ma: A, ia: A, done: bool) Error!void = null;
//       nothing sets it (igmp.c is not ported); ipifc.zig still calls
//       it where the C does.
//   pub fn addipmedium(med: *const Medium) void
//   pub fn ipfindmedium(name: []const u8) ?*const Medium
//   pub fn mediumunbindifc(ifc: *Ipifc) Error!void
//       the C returns the string Eunbound when someone else is
//       unbinding; callers that test the result use `if (...) |_| ...
//       else |_| ...`.
//   pub fn ipifcoput(ifc: *Ipifc, bp: *Block, version: u8, ip: []const u8, rh: ?*Routehint) Error!void
//       ifc is rlock'd.  Fails only as Medium.bwrite fails; bp is
//       gone either way.
//   pub fn ipifcadd(ifc: *Ipifc, argv: Args, tentative: bool, lifcp: ?*const Iplifc) Error!void
//   pub fn ipifcdel(ifc: *Ipifc, argv: Args) Error!void
//   pub fn ipifcadd6(ifc: *Ipifc, argv: Args) Error!void
//   pub fn ipifcdel6(ifc: *Ipifc, argv: Args) Error!void
//   pub fn ipifcstats(ipifc: *Proto, buf: []u8) usize
//   pub fn ipifcinit(f: *Fs) void
//   pub fn ipselftabread(f: *Fs, a: []u8, offset: usize) usize
//   pub fn ipforme(f: *Fs, addr: A) u16
//       0, Runi, Rbcast or Rmulti.
//   pub fn findipifc(f: *Fs, local: A, remote: A, typ: u16) ?*Ipifc
//   pub fn findipifcdev(f: *Fs, dev: []const u8) ?*Ipifc
//   pub fn findipifcstr(f: *Fs, s: []const u8) ?*Ipifc
//       these three return the ifc rlock'd.
//   pub fn findlocalip(f: *Fs, local: *[IPaddrlen]u8, remote: A) void
//   pub fn ipv4local(ifc: *Ipifc, local: *[IPv4addrlen]u8, prefixlen: usize, remote: A4) bool
//   pub fn ipv6local(ifc: *Ipifc, local: *[IPaddrlen]u8, prefixlen: usize, remote: A) bool
//       local is read as well as written when prefixlen is not 0.
//   pub fn iplocalonifc(ifc: *Ipifc, ip: A) ?*Iplifc
//   pub fn ipremoteonifc(ifc: *Ipifc, ip: A) ?*Iplifc
//   pub fn iplinklocalifc(ifc: *Ipifc) ?*Iplifc
//   pub fn ipifcgetmulti(f: *Fs, ifc: *Ipifc, ma: A) ?*Ipmulti
//   pub fn ipifcaddmulti(c: *Conv, ma: A, ia: A) Error!void
//   pub fn ipifcdelmulti(c: *Conv, ma: A, ia: A) void
//
// iproute.zig:
//   pub fn addroute(f: *Fs, a: A, mask: A, s: A, smask: A, gate: A, typ: u16, ifc: *Ipifc, tag: ?[]const u8) void
//   pub fn delroute(f: *Fs, a: A, mask: A, s: A, smask: A, gate: A, typ: u16, ifc: *Ipifc, tag: ?[]const u8) void
//       at most 4 bytes of tag are used.
//   pub fn v4lookup(f: *Fs, a: A4, s: A4, rh: ?*Routehint) ?*Route
//   pub fn v6lookup(f: *Fs, a: A, s: A, rh: ?*Routehint) ?*Route
//   pub fn v4source(f: *Fs, a: A4, s: *[IPv4addrlen]u8) ?*Route
//   pub fn v6source(f: *Fs, a: A, s: *[IPaddrlen]u8) ?*Route
//   pub fn routeread(f: *Fs, a: []u8, offset: usize) usize
//   pub fn routewrite(f: *Fs, c: *Chan, a: []const u8) Error!usize
//   pub fn flushrouteifc(f: *Fs, ifc: *Ipifc) void
//   pub fn routetype(typ: u16, p: *[8]u8) []const u8
//       returns the letters written, a slice of p; p is also NUL
//       terminated as in C.
//
// ip.zig:
//   pub fn ip_init(f: *Fs) void
//   pub fn iprouting(f: *Fs, on: bool) void
//   pub fn ipoput4(f: *Fs, bp: *Block, gating: ?*Ipifc, ttl: u32, tos: u32, rh: ?*Routehint) i32
//       0, or -1 if the packet could not be sent.  Never raises: it
//       catches what ipifcoput returns.  bp is gone either way.
//   pub fn ipiput4(f: *Fs, ifc: *Ipifc, bp: *Block) void
//       ifc is rlock'd.  Cannot fail (see Proto.rcv), so the read
//       loops of the media need no error handling around it.
//   pub fn ipstats(f: *Fs, buf: []u8) usize
//   pub fn ipcsum(addr: [*]const u8) u16
//       addr is the start of an Ip4hdr; the header length in it says
//       how much is summed.
//
// ipv6.zig:
//   pub fn ip_init_6(f: *Fs) void
//   pub fn ipoput6(f: *Fs, bp: *Block, gating: ?*Ipifc, ttl: u32, tos: u32, rh: ?*Routehint) i32
//   pub fn ipiput6(f: *Fs, ifc: *Ipifc, bp: *Block) void
//       as their v4 namesakes.
//
// arp.zig:
//   pub fn arpinit(f: *Fs) void
//   pub fn arpread(arp: *Arp, s: []u8, offset: usize) usize
//   pub fn arpwrite(fs: *Fs, s: []const u8) Error!usize
//   pub fn arpget(arp: *Arp, bp: ?*Block, version: u8, ifc: *Ipifc, ip: []const u8, mac: []u8, rh: ?*Routehint) ?*Arpent
//       null: mac[0..ifc.m.maclen] is filled in and bp is still the
//       caller's.  Otherwise the entry has taken bp and arp is
//       wlock'd; arprelease, arpcontinue or arpresolve unlocks it.
//   pub fn arprelease(arp: *Arp, a: *Arpent) void
//   pub fn arpcontinue(arp: *Arp, a: *Arpent) void
//   pub fn arpresolve(arp: *Arp, a: *Arpent, mac: []const u8, rh: ?*Routehint) ?*Block
//       the first maclen bytes of mac are used; the block returned is
//       the caller's.
//   pub fn arpenter(fs: *Fs, version: u8, ip: []const u8, mac: []const u8, ia: []const u8, ifc: *Ipifc, refresh: bool) i32
//       mac.len is the C's maclen.  -1, 0 or 1 as in C.
//   pub fn arpforme(fs: *Fs, version: u8, targ: []const u8, src: []const u8, ifc: *Ipifc) u16
//       0, Runi or Rproxy.
//   pub fn ndpsendsol(f: *Fs, a: *Arpent) void
//
// icmp.zig:
//   pub fn icmpinit(fs: *Fs) void
//   pub fn icmpnohost(f: *Fs, ifc: *Ipifc, bp: *Block, rh: ?*Routehint) void
//   pub fn icmpnoconv(f: *Fs, ifc: *Ipifc, bp: *Block) void
//   pub fn icmpcantfrag(f: *Fs, ifc: *Ipifc, bp: *Block, mtu: usize) void
//   pub fn icmpttlexceeded(f: *Fs, ifc: *Ipifc, bp: *Block) void
//       bp stays with the caller in these four.
//   pub fn icmpproxyadvice(f: *Fs, ifc: *Ipifc, bp: *Block, ip4: A4) void
//       owns bp.
//   pub fn icmpconnect(c: *Conv, argv: Args) Error!void
//   pub fn icmpannounce(c: *Conv, argv: Args) Error!void
//   pub fn icmpstate(c: *Conv, buf: []u8) usize
//   pub fn icmpclose(c: *Conv) void
//       these four are shared with icmp6.zig.
//
// icmp6.zig:
//   pub fn icmp6init(fs: *Fs) void
//   pub fn icmpns6(f: *Fs, src: ?A, suni: u8, targ: A, tuni: u8, mac: []const u8) void
//       src may be null when suni is SRC_UNSPEC.
//   pub fn icmpna6(f: *Fs, src: A, dst: A, targ: A, mac: []const u8, flags: u8) void
//   pub fn icmpnohost6(f: *Fs, ifc: *Ipifc, bp: *Block, rh: ?*Routehint) void
//   pub fn icmpnoconv6(f: *Fs, ifc: *Ipifc, bp: *Block) void
//   pub fn icmpttlexceeded6(f: *Fs, ifc: *Ipifc, bp: *Block) void
//   pub fn icmppkttoobig6(f: *Fs, ifc: *Ipifc, bp: *Block, mtu: usize) void
//       bp stays with the caller in these four.
//
// tcp.zig:
//   pub fn tcpinit(fs: *Fs) void
//   pub fn tcpmssclamp(p: []u8, mtu: usize) void
//       p is the packet from its IP header on (the C's p, n).
//
// udp.zig:
//   pub fn udpinit(fs: *Fs) void
//
// ethermedium.zig:
//   pub const ethermedium: Medium
//   pub const gbemedium: Medium
//   pub fn ethermediumlink() void
//
// loopbackmedium.zig:
//   pub const loopbackmedium: Medium
//   pub fn loopbackmediumlink() void
//
// netdevmedium.zig:
//   pub const netdevmedium: Medium
//   pub fn netdevmediumlink() void
//
// Things the C does that the kernel's interfaces settle differently:
//   - a Queue's kick and bypass routines (qio.Kick, qio.Bypass) return
//     void, so udpkick, icmpkick, ipifckick and tcpkick handle their
//     own errors, as the C's do in effect: free the block, set the
//     error text for the next read where the C does, return.
//   - kproc's function is fn (?*anyopaque) void and ends by calling
//     proc.pexit.
//   - sleep, tsleep, eqlock, qbread, qbwrite, qread, qwrite and a
//     device's read/write/bread/bwrite return error unions; qlock,
//     rlock, wlock, lock, qpass, allocb, smalloc, kproc and wakeup do
//     not fail.
// =====================================================================
