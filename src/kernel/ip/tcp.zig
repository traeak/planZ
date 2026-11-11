//! TCP: the control block, timers, the limbo of half-open calls, input,
//! output, retransmission and newreno congestion control, the
//! resequencing queue, keep alives, and the splice of two local
//! conversations.
//! from 9/ip/tcp.c
//!
//! Sequence numbers, windows and times are u32 and are added and
//! subtracted with the wrapping operators everywhere, as the C's ulong
//! arithmetic does.  Where the C compares an int with a ulong the
//! comparison is unsigned (both are 32 bits wide in the Plan 9
//! compilers), and it is written that way here; each such place has a
//! comment.
//!
//! DIFF:
//!   - Tcp4hdr and Tcp6hdr stop before the C's tcpopt[1]; opt4() and
//!     opt6() give the option bytes.  Their sizes are then
//!     TCP4_TCBPHDRSZ and TCP6_TCBPHDRSZ, which is what the C copies.
//!   - ntohtcp4 and ntohtcp6 look at the header again after their
//!     second pullupblock, and tcpiput after calling them: the C keeps
//!     using a pointer into the block from before, which is stale if
//!     pullupblock had to make a new block.
//!   - tcpmssclamp returns at once for a packet too short to hold a
//!     TCP header (40 bytes for v4, 60 for v6).  The C reads the flags
//!     of such a packet before finding it has no options to look at;
//!     the result is the same.
//!   - tcpbypass cannot pass on the error of qbwrite (a queue's bypass
//!     routine returns void), so a write into a splice whose other end
//!     has hung up is dropped silently instead of failing.
//!   - tcpcreate fails with Enomem if a queue cannot be allocated; the
//!     C stores the nil.
//!   - tcpackproc: an interrupted sleep starts the loop again, which is
//!     what `while(waserror());` does; the timer functions cannot fail
//!     here, so the waserror around each call is gone.
//!   - tcpoutput never hands qcopy a negative offset (it would be a
//!     trap here); see the comment there.
//!   - The union of pseudo headers on the stack of sndrst and
//!     sndsynack is two variables.
//!   - Error strings returned by connect, announce and ctl are errors
//!     (rule 2 of ipdat.zig); tcpgc returns bool.

const std = @import("std");
const fmt = @import("fmt");
const arch = @import("../arch.zig");
const portdat = @import("../port/portdat.zig");
const proc = @import("../port/proc.zig");
const alloc = @import("../port/alloc.zig");
const ab = @import("../port/allocb.zig");
const qio = @import("../port/qio.zig");
const ql = @import("../port/qlock.zig");
const random = @import("../port/random.zig");
const netif = @import("../port/netif.zig");
const errmod = @import("../port/error.zig");
const p9 = @import("../port/print.zig");
const ipdat = @import("ipdat.zig");
const ipaux = @import("ipaux.zig");
const netlog_ = @import("netlog.zig");
const devip = @import("devip.zig");
const ipifc = @import("ipifc.zig");
const iproute = @import("iproute.zig");
const ip_ = @import("ip.zig");
const ipv6 = @import("ipv6.zig");
const icmp = @import("icmp.zig");

const print = p9.print;
const panic = p9.panic;
const netlog = netlog_.netlog;

const Error = ipdat.Error;
const Block = ipdat.Block;
const Conv = ipdat.Conv;
const Proto = ipdat.Proto;
const Fs = ipdat.Fs;
const Ipifc = ipdat.Ipifc;
const Ipht = ipdat.Ipht;
const Route = ipdat.Route;
const Routehint = ipdat.Routehint;
const QLock = ipdat.QLock;

const IPaddrlen = ipdat.IPaddrlen;
const IPv4off = ipdat.IPv4off;
const V4 = ipdat.V4;
const V6 = ipdat.V6;
const IP_VER4 = ipdat.IP_VER4;
const IP_VER6 = ipdat.IP_VER6;
const IP_FO = ipdat.IP_FO;
const IP_TCPPROTO = ipdat.IP_TCPPROTO;
const MAXTTL = ipdat.MAXTTL;
const DFLTTOS = ipdat.DFLTTOS;
const Logtcp = ipdat.Logtcp;
const Logtcpwin = ipdat.Logtcpwin;
const Logtcprxmt = ipdat.Logtcprxmt;
const Rifc = ipdat.Rifc;
const Runi = ipdat.Runi;

const NOW = ipdat.NOW;
const ipcmp = ipdat.ipcmp;
const ipmove = ipdat.ipmove;
const iphconv = ipdat.iphconv;

const hnputs = ipaux.hnputs;
const hnputl = ipaux.hnputl;
const nhgets = ipaux.nhgets;
const nhgetl = ipaux.nhgetl;
const hnputs_csum = ipaux.hnputs_csum;
const ptclcsum = ipaux.ptclcsum;
const v4tov6 = ipaux.v4tov6;
const v6tov4 = ipaux.v6tov4;
const iphtadd = ipaux.iphtadd;
const iphtrem = ipaux.iphtrem;
const iphtlook = ipaux.iphtlook;

const qlock = ql.qlock;
const qunlock = ql.qunlock;
const canqlock = ql.canqlock;

const BLEN = ab.BLEN;
const allocb = ab.allocb;
const freeblist = qio.freeblist;
const blocklen = qio.blocklen;
const qlen = qio.qlen;
const qhangup = qio.qhangup;
const qclose = qio.qclose;
const qsetlimit = qio.qsetlimit;
const qsetbypass = qio.qsetbypass;

const TCP4_IPLEN = 8;
const TCP4_PHDRSIZE = 12;
const TCP4_HDRSIZE = 20;
const TCP4_TCBPHDRSZ = 40;
const TCP4_PKT = TCP4_IPLEN + TCP4_PHDRSIZE;

const TCP6_IPLEN = 0;
const TCP6_PHDRSIZE = 40;
const TCP6_HDRSIZE = 20;
const TCP6_TCBPHDRSZ = 60;
const TCP6_PKT = TCP6_IPLEN + TCP6_PHDRSIZE;

const TcptimerOFF = 0;
const TcptimerON = 1;
const TcptimerDONE = 2;
const MSPTICK = 50; // Milliseconds per timer tick
const TCP_ACK = 50; // Timed ack sequence in ms
const MAXBACKMS = 9 * 60 * 1000; // longest backoff time (ms) before hangup

const URG: u8 = 0x20; // Data marked urgent
const ACK: u8 = 0x10; // Acknowledge is valid
const PSH: u8 = 0x08; // Whole data pipe is pushed
const RST: u8 = 0x04; // Reset connection
const SYN: u8 = 0x02; // Pkt. is synchronise
const FIN: u8 = 0x01; // Start close down

const EOLOPT = 0;
const NOOPOPT = 1;
const MSSOPT = 2;
const MSS_LENGTH = 4; // Maximum segment size
const WSOPT = 3;
const WS_LENGTH = 3; // Bits to scale window size by
const MSL2 = 10;
const DEF_MSS = 1460; // Default maximum segment
const DEF_MSS6 = 1220; // Default maximum segment (min) for v6
const DEF_RTT = 500; // Default round trip
const DEF_KAT = 120000; // Default time (ms) between keep alives
const MAX_KAT = 3; // Maximum number of keep-alive timeouts
const TCP_LISTEN = 0; // Listen connection
const TCP_CONNECT = 1; // Outgoing connection

const TCPREXMTTHRESH = 3; // dupack threshhold for rxt

const FORCE: u8 = 1;
const SYNACK: u8 = 2;

const LOGAGAIN = 3; // alpha 1/8
const LOGDGAIN = 2; // beta 1/4

// Connection states
const Closed: u8 = 0;
const Listen: u8 = 1;
const Syn_sent: u8 = 2;
const Syn_received: u8 = 3;
const Established: u8 = 4;
const Finwait1: u8 = 5;
const Finwait2: u8 = 6;
const Close_wait: u8 = 7;
const Closing: u8 = 8;
const Last_ack: u8 = 9;
const Time_wait: u8 = 10;

const Maxlimbo = 1000; // maximum procs waiting for response to SYN ACK
const NLHT = 256; // hash table size, must be a power of 2
const LHTMASK = NLHT - 1;

// window is 64kb * 2^n
// these factors determine the ultimate bandwidth-delay product.
// 64kb * 2^5 = 2mb, or 2x overkill for 100mbps * 70ms.
// 64kb * 2^7 = 8mb, or around 1000mbps * 70ms.
const QSCALE = 7;
const QMAX = 64 * 1024 - 1;

/// negative return from ipoput means no route
const Enoroute = "no route";

const Econrefused = errmod.errstr(error.Econrefused);
const Etimedout = errmod.errstr(error.Etimedout);

/// Must correspond to the enumeration above
const tcpstates = [_][]const u8{
    "Closed",      "Listen",   "Syn_sent",  "Syn_received",
    "Established", "Finwait1", "Finwait2",  "Close_wait",
    "Closing",     "Last_ack", "Time_wait",
};

const Tcptimer = struct {
    next: ?*Tcptimer = null,
    prev: ?*Tcptimer = null,
    readynext: ?*Tcptimer = null,
    state: i32 = 0,
    start: i32 = 0,
    count: i32 = 0,
    func: ?*const fn (?*anyopaque) void = null,
    arg: ?*anyopaque = null,
};

//
//  v4 and v6 pseudo headers used for
//  checksuming tcp
//
const Tcp4hdr = extern struct {
    vihl: u8, // Version and header length
    tos: u8, // Type of service
    length: [2]u8, // packet length
    id: [2]u8, // Identification
    frag: [2]u8, // Fragment information
    ttl: u8,
    proto: u8,
    tcplen: [2]u8,
    tcpsrc: [4]u8,
    tcpdst: [4]u8,
    tcpsport: [2]u8,
    tcpdport: [2]u8,
    tcpseq: [4]u8,
    tcpack: [4]u8,
    tcpflag: [2]u8,
    tcpwin: [2]u8,
    tcpcksum: [2]u8,
    tcpurg: [2]u8,
    // Options segment: opt4()
};

const Tcp6hdr = extern struct {
    vcf: [4]u8,
    ploadlen: [2]u8,
    proto: u8,
    ttl: u8,
    tcpsrc: [IPaddrlen]u8,
    tcpdst: [IPaddrlen]u8,
    tcpsport: [2]u8,
    tcpdport: [2]u8,
    tcpseq: [4]u8,
    tcpack: [4]u8,
    tcpflag: [2]u8,
    tcpwin: [2]u8,
    tcpcksum: [2]u8,
    tcpurg: [2]u8,
    // Options segment: opt6()
};

comptime {
    std.debug.assert(@sizeOf(Tcp4hdr) == TCP4_TCBPHDRSZ and @alignOf(Tcp4hdr) == 1);
    std.debug.assert(@sizeOf(Tcp6hdr) == TCP6_TCBPHDRSZ and @alignOf(Tcp6hdr) == 1);
}

/// The C's h->tcpopt.
fn opt4(h: *Tcp4hdr) [*]u8 {
    return @as([*]u8, @ptrCast(h)) + @sizeOf(Tcp4hdr);
}

fn opt6(h: *Tcp6hdr) [*]u8 {
    return @as([*]u8, @ptrCast(h)) + @sizeOf(Tcp6hdr);
}

///  this represents the control info
///  for a single packet.  It is derived from
///  a packet in ntohtcp{4,6}() and stuck into
///  a packet in htontcp{4,6}().
const Tcp = struct {
    source: u16 = 0,
    dest: u16 = 0,
    seq: u32 = 0,
    ack: u32 = 0,
    flags: u8 = 0,
    update: u8 = 0,
    ws: u8 = 0, // window scale option
    wnd: u32 = 0, // prescaled window
    mss: u16 = 0, // max segment size option (if not zero)
    len: u16 = 0, // size of data
};

///  this header is malloc'd to thread together fragments
///  waiting to be coalesced
const Reseq = struct {
    next: ?*Reseq = null,
    seg: Tcp = .{},
    bp: ?*Block = null,
    length: u16 = 0,
};

///  the qlock in the Conv locks this structure
const Tcpctl = struct {
    bypass: ?*Conv = null, // The other when bypassing
    state: u8 = 0, // Connection state
    flags: u8 = 0, // State flags
    flgcnt: u8 = 0, // Number of flags in the send sequence (FIN,SYN)
    snd: struct {
        una: u32 = 0, // Unacked data pointer
        nxt: u32 = 0, // Next sequence expected
        ptr: u32 = 0, // Data pointer
        wnd: u32 = 0, // Tcp send window
        wl2: u32 = 0, // Seg.ack of last window update
        wl1: u32 = 0, // Seg.seq of last window update
        scale: u8 = 0, // how much to left shift window in received packets
        rto: u8 = 0, // retransmit timeout counter
        // to implement tahoe and reno TCP
        recovery: u8 = 0, // loss recovery flag
        rxt: u32 = 0, // right window marker for recovery "recover" rfc3782
        dupacks: u32 = 0, // number of duplicate acks rcvd
        partialack: u32 = 0, // partial acks received during recovery
    } = .{},
    rcv: struct {
        nxt: u32 = 0, // Receive pointer to next uchar slot
        ackptr: u32 = 0, // Last acked sequence
        wptr: u32 = 0, // Right side of receive window
        wsnt: u32 = 0, // Last wptr sent
        wnd: u32 = 0, // Receive window incoming
        scale: u8 = 0, // how much to right shift window in transmitted packets
    } = .{},
    iss: u32 = 0, // Initial sequence number
    cwind: u32 = 0, // Congestion window
    abcbytes: u32 = 0, // appropriate byte counting rfc 3465
    ssthresh: u32 = 0, // Slow start threshold
    mss: u16 = 0, // Maximum segment size
    scale: u8 = 0, // desired rcv.scale
    window: u32 = 0, // Our receive window (queue)
    overlap: u32 = 0, // Overlap of data re-recevived
    reseq: ?*Reseq = null, // Resequencing queue
    nreseq: i32 = 0,
    reseqlen: i32 = 0,
    backoff: i32 = 0, // Exponential backoff counter
    backedoff: i32 = 0, // ms we've backed off for rexmits
    timer: Tcptimer = .{}, // Activity timer
    acktimer: Tcptimer = .{}, // Acknowledge timer
    katimer: Tcptimer = .{}, // keep alive timer
    kato: u32 = 0, // keep alive timeouts
    time: u32 = 0, // time Finwait2 or Syn_received or timer was set
    timeuna: u32 = 0, // snd.una when time was set
    rttime: u32 = 0, // Sent time for rtt measurement
    rttseq: u32 = 0, // Round trip sequence
    srtt: i32 = 0, // Smoothed round trip
    mdev: i32 = 0, // Mean deviation of round trip

    protohdr: extern union {
        tcp4hdr: Tcp4hdr,
        tcp6hdr: Tcp6hdr,
    } = .{ .tcp6hdr = std.mem.zeroes(Tcp6hdr) }, // prototype header
};

///  New calls are put in limbo rather than having a conversation structure
///  allocated.  Thus, a SYN attack results in lots of limbo'd calls but not
///  any real Conv structures mucking things up.  Calls in limbo rexmit their
///  SYN ACK up to 4 times. They disappear after 2.5 seconds.
const Limbo = struct {
    next: ?*Limbo = null,

    laddr: [IPaddrlen]u8 = @splat(0),
    raddr: [IPaddrlen]u8 = @splat(0),
    lport: u16 = 0,
    rport: u16 = 0,
    irs: u32 = 0, // initial received sequence
    iss: u32 = 0, // initial sent sequence
    mss: u16 = 0, // mss from the other end
    ws: u8 = 0, // ws from the other end
    rexmits: u8 = 0, // number of retransmissions
    lastsend: u32 = 0, // last time we sent a synack
    version: u8 = 0, // v4 or v6
};

var tcp_irtt: i32 = DEF_RTT; // Initial guess at round trip time

// MIB stats
const MaxConn = 0;
const ActiveOpens = 1;
const PassiveOpens = 2;
const EstabResets = 3;
const CurrEstab = 4;
const InSegs = 5;
const OutSegs = 6;
const RetransSegs = 7;
const RetransSegsSent = 8;
const RetransTimeouts = 9;
const InErrs = 10;
const OutRsts = 11;

// non-MIB stats
const CsumErrs = 12;
const HlenErrs = 13;
const LenErrs = 14;
const Resequenced = 15;
const OutOfOrder = 16;
const ReseqBytelim = 17;
const ReseqPktlim = 18;
const Delayack = 19;
const Wopenack = 20;

const Recovery = 21;
const RecoveryDone = 22;
const RecoveryRTO = 23;
const RecoveryNoSeq = 24;
const RecoveryCwind = 25;
const RecoveryPA = 26;

const InLimbo = 27;

const Nstats = 28;

const statnames: [Nstats][]const u8 = blk: {
    var t: [Nstats][]const u8 = undefined;
    t[MaxConn] = "MaxConn";
    t[ActiveOpens] = "ActiveOpens";
    t[PassiveOpens] = "PassiveOpens";
    t[EstabResets] = "EstabResets";
    t[CurrEstab] = "CurrEstab";
    t[InSegs] = "InSegs";
    t[OutSegs] = "OutSegs";
    t[RetransSegs] = "RetransSegs";
    t[RetransSegsSent] = "RetransSegsSent";
    t[RetransTimeouts] = "RetransTimeouts";
    t[InErrs] = "InErrs";
    t[OutRsts] = "OutRsts";
    t[CsumErrs] = "CsumErrs";
    t[HlenErrs] = "HlenErrs";
    t[LenErrs] = "LenErrs";
    t[OutOfOrder] = "OutOfOrder";
    t[Resequenced] = "Resequenced";
    t[ReseqBytelim] = "ReseqBytelim";
    t[ReseqPktlim] = "ReseqPktlim";
    t[Delayack] = "Delayack";
    t[Wopenack] = "Wopenack";

    t[Recovery] = "Recovery";
    t[RecoveryDone] = "RecoveryDone";
    t[RecoveryRTO] = "RecoveryRTO";

    t[RecoveryNoSeq] = "RecoveryNoSeq";
    t[RecoveryCwind] = "RecoveryCwind";
    t[RecoveryPA] = "RecoveryPA";

    t[InLimbo] = "InLimbo";
    break :blk t;
};

const Tcppriv = struct {
    // List of active timers
    tl: QLock = .{},
    timers: ?*Tcptimer = null,

    // hash table for matching conversations
    ht: Ipht = .{},

    // calls in limbo waiting for an ACK to our SYN ACK
    nlimbo: i32 = 0,
    lht: [NLHT]?*Limbo = @splat(null),

    stats: [Nstats]u64 = @splat(0),

    ackprocstarted: bool = false,
};

/// (Tcpctl*)c->ptcl
fn tcbof(c: *Conv) *Tcpctl {
    return @ptrCast(@alignCast(c.ptcl.?));
}

/// (Tcppriv*)tcp->priv
fn privof(tcp: *Proto) *Tcppriv {
    return @ptrCast(@alignCast(tcp.priv.?));
}

/// A void* timer or queue argument back to its Conv.
fn convof(arg: ?*anyopaque) *Conv {
    return @ptrCast(@alignCast(arg.?));
}

/// A shift count for a 32 bit value; the scales never exceed 14.
fn sh(scale: u8) u5 {
    return @truncate(scale);
}

fn tcpsetstate(s: *Conv, newstate: u8) void {
    const tcb = tcbof(s);

    const oldstate = tcb.state;
    if (oldstate == newstate)
        return;

    switch (newstate) {
        Closed => {
            qclose(s.rq);
            qclose(s.wq);
            qclose(s.eq);
            if (tcb.bypass != null) {
                tcb.bypass = null;
                qsetbypass(s.wq.?, null);
            }
        },

        Close_wait => { // Remote closes
            qhangup(s.rq.?, null);
        },

        else => {},
    }

    tcb.state = newstate;

    const tpriv = privof(s.p.?);
    if (oldstate == Established)
        tpriv.stats[CurrEstab] -%= 1;
    if (newstate == Established)
        tpriv.stats[CurrEstab] +%= 1;

    if (oldstate == Syn_sent and newstate != Closed)
        devip.Fsconnected(s, null);
}

fn tcpconnect(c: *Conv, argv: []const []const u8) Error!void {
    const tcb = tcbof(c);

    if (tcb.state != Closed)
        return error.Econinuse;

    try devip.Fsstdconnect(c, argv);
    tcpstart(c, TCP_CONNECT);
}

fn tcpstate(c: *Conv, state: []u8) usize {
    const tcb = tcbof(c);

    return fmt.snprint(state, "%s qin %d qout %d" ++
        " rq %d.%d ovl %lud" ++
        " srtt %d>>%d mdev %d" ++
        " timer %d/%d" ++
        " sst %lud cwin %lud" ++
        " swin %lud>>%d rwin %lud>>%d" ++
        " ka %d/%d %lud\n", .{
        tcpstates[tcb.state],
        if (c.rq) |q| qlen(q) else 0,
        if (c.wq) |q| qlen(q) else 0,
        tcb.nreseq,
        tcb.reseqlen,
        tcb.overlap,
        tcb.srtt,
        @as(i32, LOGAGAIN),
        tcb.mdev,
        tcb.timer.count *% MSPTICK,
        tcb.timer.start *% MSPTICK,
        tcb.ssthresh,
        tcb.cwind,
        tcb.snd.wnd,
        tcb.snd.scale,
        tcb.rcv.wnd,
        tcb.rcv.scale,
        tcb.katimer.count *% MSPTICK,
        tcb.katimer.start *% MSPTICK,
        tcb.kato,
    }).len;
}

fn tcpinuse(c: *Conv) bool {
    const tcb = tcbof(c);

    return tcb.state != Closed;
}

fn tcpannounce(c: *Conv, argv: []const []const u8) Error!void {
    const tcb = tcbof(c);

    if (tcb.state != Closed)
        return error.Econinuse;

    try devip.Fsstdannounce(c, argv);
    tcpstart(c, TCP_LISTEN);
    devip.Fsconnected(c, null);
}

///  tcpclose is always called with the c locked
fn tcpclose(c: *Conv) void {
    const tcb = tcbof(c);

    qhangup(c.rq.?, null);
    qhangup(c.wq.?, null);
    if (c.eq) |eq| qhangup(eq, null);
    qio.qflush(c.rq.?);

    switch (tcb.state) {
        Listen => {
            //  reset any incoming calls to this listener
            devip.Fsconnected(c, "Hangup");

            localclose(c, null);
        },
        Closed, Syn_sent => localclose(c, null),
        Established, Syn_received => {
            if (tcb.state == Established and tcb.bypass != null) {
                qhangup(tcb.bypass.?.rq.?, null);
                localclose(c, null);
                return;
            }
            // wet floor
            tcb.flgcnt +%= 1;
            tcb.snd.nxt +%= 1;
            tcpsetstate(c, Finwait1);
            tcpoutput(c);
        },
        Close_wait => {
            tcb.flgcnt +%= 1;
            tcb.snd.nxt +%= 1;
            tcpsetstate(c, Last_ack);
            tcpoutput(c);
        },
        else => {},
    }
}

fn tcpkick(arg: ?*anyopaque) void {
    const s = convof(arg);
    const tcb = tcbof(s);

    qlock(&s.qlock);
    switch (tcb.state) {
        Established, Syn_sent, Syn_received, Close_wait => {
            // Push data
            // (Established falls in here unless it is bypassing)
            if (!(tcb.state == Established and tcb.bypass != null))
                tcpoutput(s);
        },
        else => localclose(s, "Hangup"),
    }
    qunlock(&s.qlock);
}

/// The C compares (int)x < high with high a ulong: unsigned.
fn seq_in(x_: u32, low: u32, high_: u32) bool {
    const x = x_ -% low;
    const high = high_ -% low;
    return @as(i32, @bitCast(x)) >= 0 and x < high;
}

fn seq_lt(x: u32, y: u32) bool {
    return @as(i32, @bitCast(x -% y)) < 0;
}

fn seq_le(x: u32, y: u32) bool {
    return @as(i32, @bitCast(x -% y)) <= 0;
}

fn seq_gt(x: u32, y: u32) bool {
    return @as(i32, @bitCast(x -% y)) > 0;
}

fn seq_ge(x: u32, y: u32) bool {
    return @as(i32, @bitCast(x -% y)) >= 0;
}

/// Call with tcb locked
fn tcprcvwin(s: *Conv) void {
    const tcb = tcbof(s);

    var w: u32 = tcb.window -% @as(u32, @bitCast(qlen(s.rq.?)));

    // RFC 1122 § 4.2.3.3 silly window syndrome avoidance
    // (the C's `(int)w < tcb->rcv.wnd + tcb->mss` compares unsigned,
    // the right side being ulong)
    if (w < tcb.rcv.wnd +% tcb.mss)
        w = 0;

    w +%= tcb.rcv.nxt;

    // RFC 1122 § 4.2.2.16 do not move right edge of window left
    if (seq_lt(w, tcb.rcv.wptr))
        w = tcb.rcv.wptr;

    tcb.rcv.wptr = w;
    tcb.rcv.wnd = w -% tcb.rcv.nxt;
}

fn tcpacktimer(arg: ?*anyopaque) void {
    const s = convof(arg);
    const tcb = tcbof(s);

    // avoid deadlock during qsetbypass() oq->iq flush
    if (tcb.bypass != null)
        return;

    qlock(&s.qlock);
    if (tcb.state != Closed and tcb.bypass == null) {
        tcb.flags |= FORCE;
        tcpoutput(s);
    }
    qunlock(&s.qlock);
}

fn tcpcongestion(tcb: *Tcpctl) void {
    var inflight = tcb.snd.nxt -% tcb.snd.una;
    if (inflight > tcb.cwind)
        inflight = tcb.cwind;
    tcb.ssthresh = inflight / 2;
    if (tcb.ssthresh < 2 * @as(u32, tcb.mss))
        tcb.ssthresh = 2 * @as(u32, tcb.mss);
}

const L = 2; // aggressive slow start; legal values in (1.0, 2.0)

fn tcpabcincr(tcb: *Tcpctl, acked: u32) void {
    tcb.abcbytes +%= acked;
    if (tcb.cwind < tcb.ssthresh) {
        // slow start
        const limit: u32 = if (tcb.snd.rto != 0)
            1 * @as(u32, tcb.mss)
        else
            L * @as(u32, tcb.mss);
        tcb.cwind +%= @min(tcb.abcbytes, limit);
        tcb.abcbytes = 0;
    } else {
        tcb.snd.rto = 0;
        // avoidance
        if (tcb.abcbytes >= tcb.cwind) {
            tcb.abcbytes -= tcb.cwind;
            tcb.cwind +%= tcb.mss;
        }
    }
}

fn tcpcreate(c: *Conv) Error!void {
    // the control block is zeroed memory; make it a Tcpctl
    tcbof(c).* = .{};

    c.rq = qio.qopen(QMAX, qio.Qcoalesce, tcpacktimer, c) orelse return error.Enomem;
    c.wq = qio.qopen(QMAX, qio.Qkick, tcpkick, c) orelse return error.Enomem;
}

fn timerstate(priv: *Tcppriv, t: *Tcptimer, newstate: i32) void {
    if (newstate != TcptimerON) {
        if (t.state == TcptimerON) {
            // unchain
            if (priv.timers == t) {
                priv.timers = t.next;
                if (t.prev != null)
                    panic("timerstate1", .{});
            }
            if (t.next) |n|
                n.prev = t.prev;
            if (t.prev) |p|
                p.next = t.next;
            t.next = null;
            t.prev = null;
        }
    } else {
        if (t.state != TcptimerON) {
            // chain
            if (t.prev != null or t.next != null)
                panic("timerstate2", .{});
            t.prev = null;
            t.next = priv.timers;
            if (t.next) |n|
                n.prev = t;
            priv.timers = t;
        }
    }
    t.state = newstate;
}

fn tcpackproc(arg: ?*anyopaque) void {
    const tcp: *Proto = @ptrCast(@alignCast(arg.?));
    const priv = privof(tcp);

    while (true) {
        // DIFF: `while(waserror());` in C: an interrupted sleep starts
        // over.
        proc.tsleep(&arch.up().?.sleep, proc.return0, null, MSPTICK) catch continue;

        qlock(&priv.tl);
        var timeo: ?*Tcptimer = null;
        var tp: ?*Tcptimer = priv.timers;
        while (tp) |t| {
            tp = t.next;
            if (t.state == TcptimerON) {
                t.count -%= 1;
                if (t.count == 0) {
                    timerstate(priv, t, TcptimerDONE);
                    t.readynext = timeo;
                    timeo = t;
                }
            }
        }
        qunlock(&priv.tl);

        while (timeo) |t| {
            timeo = t.readynext;
            // DIFF: no waserror; the timer functions do not fail.
            if (t.state == TcptimerDONE)
                t.func.?(t.arg);
        }

        limborexmit(tcp);
    }
}

fn tcpgo(priv: *Tcppriv, t: *Tcptimer) void {
    if (t.start == 0)
        return;

    qlock(&priv.tl);
    t.count = t.start;
    timerstate(priv, t, TcptimerON);
    qunlock(&priv.tl);
}

fn tcphalt(priv: *Tcppriv, t: *Tcptimer) void {
    qlock(&priv.tl);
    timerstate(priv, t, TcptimerOFF);
    qunlock(&priv.tl);
}

/// called with c locked
fn localclose(s: *Conv, reason: ?[]const u8) void {
    const tcb = tcbof(s);
    const tpriv = privof(s.p.?);

    iphtrem(&tpriv.ht, &s.iphash);

    tcphalt(tpriv, &tcb.timer);
    tcphalt(tpriv, &tcb.acktimer);
    tcphalt(tpriv, &tcb.katimer);

    // Flush reassembly queue; nothing more can arrive
    _ = dumpreseq(tcb);

    if (tcb.state == Syn_sent)
        devip.Fsconnected(s, reason);
    if (s.state == ipdat.Announced)
        _ = proc.wakeup(&s.listenr);

    qhangup(s.rq.?, reason);
    qhangup(s.wq.?, reason);

    tcpsetstate(s, Closed);
}

/// mtu (- TCP + IP hdr len) of 1st hop
fn tcpmtu(r: ?*Route, scale: *u8, version: u8) i32 {
    scale.* = QSCALE;

    // currently we do not implement path MTU discovery
    // so use interface MTU *only* if directly reachable
    // or when we use V4 which allows routers to fragment.
    // otherwise, we use the default MSS which assumes a
    // safe minimum MTU of 1280 bytes for V6.
    if (r) |rt| if (rt.ifc) |ifc| {
        var mtu: i32 = @as(i32, @intCast(ifc.maxtu)) - @as(i32, @intCast(ifc.m.?.hsize));
        if (version == V4)
            return mtu - (TCP4_PKT + TCP4_HDRSIZE);
        mtu -= TCP6_PKT + TCP6_HDRSIZE;
        if ((rt.type & (Rifc | Runi)) != 0 or mtu <= DEF_MSS6)
            return mtu;
    };
    if (version == V6)
        return DEF_MSS6
    else
        return DEF_MSS;
}

/// What the C gets by storing tcpmtu's int in a ushort.
fn mtu2mss(mtu: i32) u16 {
    return @truncate(@as(u32, @bitCast(mtu)));
}

fn inittcpctl(s: *Conv, mode: i32) void {
    const tcb = tcbof(s);

    tcb.* = .{};

    tcb.srtt = tcp_irtt << LOGAGAIN;
    tcb.mdev = tcp_irtt << (LOGDGAIN - 1);

    // setup timers
    tcb.timer.start = @divTrunc(tcp_irtt, MSPTICK);
    tcb.timer.func = tcptimeout;
    tcb.timer.arg = s;

    tcb.acktimer.start = TCP_ACK / MSPTICK;
    tcb.acktimer.func = tcpacktimer;
    tcb.acktimer.arg = s;

    tcb.katimer.start = 0; // not enabled by default
    tcb.katimer.func = tcpkeepalive;
    tcb.katimer.arg = s;

    if (mode == TCP_LISTEN)
        return;

    if (ipcmp(&s.iphash.laddr, &ipaux.IPnoaddr) == 0)
        ipifc.findlocalip(s.p.?.f.?, &s.iphash.laddr, &s.iphash.raddr);

    // create a prototype(pseudo) header
    switch (s.ipversion) {
        V4 => {
            const h4 = &tcb.protohdr.tcp4hdr;
            h4.* = std.mem.zeroes(Tcp4hdr);
            h4.vihl = IP_VER4;
            h4.proto = IP_TCPPROTO;
            hnputs(&h4.tcpsport, s.iphash.lport);
            hnputs(&h4.tcpdport, s.iphash.rport);
            _ = v6tov4(&h4.tcpsrc, &s.iphash.laddr);
            _ = v6tov4(&h4.tcpdst, &s.iphash.raddr);

            tcb.mss = DEF_MSS;
        },
        V6 => {
            const h6 = &tcb.protohdr.tcp6hdr;
            h6.* = std.mem.zeroes(Tcp6hdr);
            h6.proto = IP_TCPPROTO;
            hnputs(&h6.tcpsport, s.iphash.lport);
            hnputs(&h6.tcpdport, s.iphash.rport);
            ipmove(&h6.tcpsrc, &s.iphash.laddr);
            ipmove(&h6.tcpdst, &s.iphash.raddr);

            tcb.mss = DEF_MSS6;
        },
        else => panic("inittcpctl: version %d", .{s.ipversion}),
    }
    tcpsetscale(s, 0);
}

///  called with s locked
fn tcpstart(s: *Conv, mode: i32) void {
    const tpriv = privof(s.p.?);

    if (!tpriv.ackprocstarted) {
        qlock(&tpriv.tl);
        if (!tpriv.ackprocstarted) {
            var kpname: [portdat.KNAMELEN]u8 = undefined;

            const name = fmt.snprint(kpname[0 .. kpname.len - 1], "#I%dtcpack", .{s.p.?.f.?.dev});
            proc.kproc(name, tcpackproc, s.p.?);
            tpriv.ackprocstarted = true;
        }
        qunlock(&tpriv.tl);
    }

    inittcpctl(s, mode);

    iphtadd(&tpriv.ht, &s.iphash);
    switch (mode) {
        TCP_LISTEN => {
            tpriv.stats[PassiveOpens] += 1;
            tcpsetstate(s, Listen);
        },

        TCP_CONNECT => {
            tpriv.stats[ActiveOpens] += 1;
            tcpsndsyn(s);
            tcpsetstate(s, Syn_sent);
            tcpoutput(s);
        },

        else => {},
    }
}

/// Unused in the C as well; kept for debugging.
fn tcpflag(buf: []u8, flag: u16) []u8 {
    var n = fmt.snprint(buf, "%d", .{flag >> 10}).len; // Head len
    if (flag & URG != 0)
        n += fmt.snprint(buf[n..], " URG", .{}).len;
    if (flag & ACK != 0)
        n += fmt.snprint(buf[n..], " ACK", .{}).len;
    if (flag & PSH != 0)
        n += fmt.snprint(buf[n..], " PSH", .{}).len;
    if (flag & RST != 0)
        n += fmt.snprint(buf[n..], " RST", .{}).len;
    if (flag & SYN != 0)
        n += fmt.snprint(buf[n..], " SYN", .{}).len;
    if (flag & FIN != 0)
        n += fmt.snprint(buf[n..], " FIN", .{}).len;
    return buf[0..n];
}

comptime {
    _ = &tcpflag;
    _ = &seq_le;
}

fn htontcp6(tcph: *const Tcp, data_: ?*Block, ph: *const Tcp6hdr) *Block {
    var dlen: usize = undefined;
    var data: *Block = undefined;
    var optpad: u16 = 0;

    var hdrlen: u16 = TCP6_HDRSIZE;
    if (tcph.flags & SYN != 0) {
        if (tcph.mss != 0)
            hdrlen += MSS_LENGTH;
        if (tcph.ws != 0)
            hdrlen += WS_LENGTH;
        optpad = hdrlen & 3;
        if (optpad != 0)
            optpad = 4 - optpad;
        hdrlen += optpad;
    }

    if (data_) |d| {
        dlen = blocklen(d);
        data = qio.padblock(d, @as(i32, hdrlen) + TCP6_PKT);
    } else {
        dlen = 0;
        data = allocb(@as(usize, hdrlen) + TCP6_PKT + 64); // the 64 pad is to meet mintu's
        data.wp += @as(usize, hdrlen) + TCP6_PKT;
    }

    // copy in pseudo ip header plus port numbers
    const h: *Tcp6hdr = @ptrCast(data.rp);
    h.* = ph.*;

    // compose pseudo tcp header, do cksum calculation
    hnputl(&h.vcf, @truncate(hdrlen + dlen));
    h.ploadlen[0] = 0;
    h.ploadlen[1] = 0;
    h.proto = 0;
    h.ttl = ph.proto;

    // copy in variable bits
    hnputl(&h.tcpseq, tcph.seq);
    hnputl(&h.tcpack, tcph.ack);
    hnputs(&h.tcpflag, (hdrlen << 10) | tcph.flags);
    hnputs(&h.tcpwin, @truncate(tcph.wnd));
    hnputs(&h.tcpurg, 0);

    if (tcph.flags & SYN != 0) {
        var opt = opt6(h);
        if (tcph.mss != 0) {
            opt[0] = MSSOPT;
            opt[1] = MSS_LENGTH;
            hnputs(opt[2..4], tcph.mss);
            opt += 4;
        }
        if (tcph.ws != 0) {
            opt[0] = WSOPT;
            opt[1] = WS_LENGTH;
            opt[2] = tcph.ws;
            opt += 3;
        }
        while (optpad > 0) : (optpad -= 1) {
            opt[0] = NOOPOPT;
            opt += 1;
        }
    }

    hnputs(&h.tcpcksum, ptclcsum(data, TCP6_IPLEN, hdrlen + dlen + TCP6_PHDRSIZE));

    // move from pseudo header back to normal ip header
    h.vcf = @splat(0);
    h.vcf[0] = IP_VER6;
    hnputs(&h.ploadlen, @truncate(hdrlen + dlen));
    h.proto = ph.proto;

    return data;
}

fn htontcp4(tcph: *const Tcp, data_: ?*Block, ph: *const Tcp4hdr) *Block {
    var dlen: usize = undefined;
    var data: *Block = undefined;
    var optpad: u16 = 0;

    var hdrlen: u16 = TCP4_HDRSIZE;
    if (tcph.flags & SYN != 0) {
        if (tcph.mss != 0)
            hdrlen += MSS_LENGTH;
        // always offer.  rfc1323 §2.2
        hdrlen += WS_LENGTH;
        optpad = hdrlen & 3;
        if (optpad != 0)
            optpad = 4 - optpad;
        hdrlen += optpad;
    }

    if (data_) |d| {
        dlen = blocklen(d);
        data = qio.padblock(d, @as(i32, hdrlen) + TCP4_PKT);
    } else {
        dlen = 0;
        data = allocb(@as(usize, hdrlen) + TCP4_PKT + 64); // the 64 pad is to meet mintu's
        data.wp += @as(usize, hdrlen) + TCP4_PKT;
    }

    // copy in pseudo ip header plus port numbers
    const h: *Tcp4hdr = @ptrCast(data.rp);
    h.* = ph.*;

    // copy in variable bits
    hnputs(&h.tcplen, @truncate(hdrlen + dlen));
    hnputl(&h.tcpseq, tcph.seq);
    hnputl(&h.tcpack, tcph.ack);
    hnputs(&h.tcpflag, (hdrlen << 10) | tcph.flags);
    hnputs(&h.tcpwin, @truncate(tcph.wnd));
    hnputs(&h.tcpurg, 0);

    if (tcph.flags & SYN != 0) {
        var opt = opt4(h);
        if (tcph.mss != 0) {
            opt[0] = MSSOPT;
            opt[1] = MSS_LENGTH;
            hnputs(opt[2..4], tcph.mss);
            opt += 4;
        }
        // always offer.  rfc1323 §2.2
        {
            opt[0] = WSOPT;
            opt[1] = WS_LENGTH;
            opt[2] = tcph.ws;
            opt += 3;
        }
        while (optpad > 0) : (optpad -= 1) {
            opt[0] = NOOPOPT;
            opt += 1;
        }
    }

    hnputs(&h.tcpcksum, ptclcsum(data, TCP4_IPLEN, hdrlen + dlen + TCP4_PHDRSIZE));

    return data;
}

/// The options of a header, shared by ntohtcp4 and ntohtcp6 (the C has
/// the loop twice).
fn ntohopts(tcph: *Tcp, optr_: [*]const u8, n_: i32) void {
    var optr = optr_;
    var n = n_;

    while (n > 0 and optr[0] != EOLOPT) {
        if (optr[0] == NOOPOPT) {
            n -= 1;
            optr += 1;
            continue;
        }
        const optlen: u16 = optr[1];
        if (optlen < 2 or optlen > n)
            break;
        switch (optr[0]) {
            MSSOPT => {
                if (optlen == MSS_LENGTH)
                    tcph.mss = nhgets(optr[2..4]);
            },
            WSOPT => {
                if (optlen == WS_LENGTH)
                    tcph.ws = optr[2];
            },
            else => {},
        }
        n -= optlen;
        optr += optlen;
    }
}

/// Returns the length of the TCP header, or -1 having freed the block
/// and set bpp.* to null.
fn ntohtcp6(tcph: *Tcp, bpp: *?*Block) i32 {
    bpp.* = qio.pullupblock(bpp.*.?, TCP6_PKT + TCP6_HDRSIZE);
    if (bpp.* == null)
        return -1;

    var h: *Tcp6hdr = @ptrCast(bpp.*.?.rp);
    tcph.source = nhgets(&h.tcpsport);
    tcph.dest = nhgets(&h.tcpdport);
    tcph.seq = nhgetl(&h.tcpseq);
    tcph.ack = nhgetl(&h.tcpack);
    const hdrlen: u16 = (h.tcpflag[0] >> 2) & ~@as(u16, 3);
    if (hdrlen < TCP6_HDRSIZE) {
        freeblist(bpp.*);
        bpp.* = null;
        return -1;
    }

    tcph.flags = h.tcpflag[1];
    tcph.wnd = nhgets(&h.tcpwin);
    tcph.mss = 0;
    tcph.ws = 0;
    tcph.update = 0;
    const len: i32 = @as(i32, nhgets(&h.ploadlen)) - hdrlen;
    if (len < 0) {
        freeblist(bpp.*);
        bpp.* = null;
        return -1;
    }
    tcph.len = @intCast(len);

    bpp.* = qio.pullupblock(bpp.*.?, @as(usize, hdrlen) + TCP6_PKT);
    if (bpp.* == null)
        return -1;

    // DIFF: the block may be a new one.
    h = @ptrCast(bpp.*.?.rp);
    ntohopts(tcph, opt6(h), @as(i32, hdrlen) - TCP6_HDRSIZE);
    return hdrlen;
}

fn ntohtcp4(tcph: *Tcp, bpp: *?*Block) i32 {
    bpp.* = qio.pullupblock(bpp.*.?, TCP4_PKT + TCP4_HDRSIZE);
    if (bpp.* == null)
        return -1;

    var h: *Tcp4hdr = @ptrCast(bpp.*.?.rp);
    tcph.source = nhgets(&h.tcpsport);
    tcph.dest = nhgets(&h.tcpdport);
    tcph.seq = nhgetl(&h.tcpseq);
    tcph.ack = nhgetl(&h.tcpack);

    const hdrlen: u16 = (h.tcpflag[0] >> 2) & ~@as(u16, 3);
    if (hdrlen < TCP4_HDRSIZE) {
        freeblist(bpp.*);
        bpp.* = null;
        return -1;
    }

    tcph.flags = h.tcpflag[1];
    tcph.wnd = nhgets(&h.tcpwin);
    tcph.mss = 0;
    tcph.ws = 0;
    tcph.update = 0;
    const len: i32 = @as(i32, nhgets(&h.length)) - (@as(i32, hdrlen) + TCP4_PKT);
    if (len < 0) {
        freeblist(bpp.*);
        bpp.* = null;
        return -1;
    }
    tcph.len = @intCast(len);

    bpp.* = qio.pullupblock(bpp.*.?, @as(usize, hdrlen) + TCP4_PKT);
    if (bpp.* == null)
        return -1;

    // DIFF: the block may be a new one.
    h = @ptrCast(bpp.*.?.rp);
    ntohopts(tcph, opt4(h), @as(i32, hdrlen) - TCP4_HDRSIZE);
    return hdrlen;
}

/// (nrand(1<<16)<<16)|nrand(1<<16)
fn newiss() u32 {
    const hi: u32 = @intCast(random.nrand(1 << 16));
    const lo: u32 = @intCast(random.nrand(1 << 16));
    return (hi << 16) | lo;
}

///  For outgoing calls, generate an initial sequence
///  number and put a SYN on the send queue
fn tcpsndsyn(s: *Conv) void {
    const tcb = tcbof(s);

    tcb.iss = newiss();
    tcb.snd.wl2 = tcb.iss;
    tcb.snd.una = tcb.iss;
    tcb.snd.rxt = tcb.iss;
    tcb.snd.ptr = tcb.iss;
    tcb.snd.nxt = tcb.iss;

    tcb.flags = (tcb.flags & ~SYNACK) | FORCE;
    tcb.flgcnt +%= 1;

    tcb.rttime = 0; // set in tcpoutput()

    // set desired mss and scale
    tcb.mss = mtu2mss(tcpmtu(iproute.v6lookup(s.p.?.f.?, &s.iphash.raddr, &s.iphash.laddr, &s.routehint), &tcb.scale, s.ipversion));
}

fn sndrst(
    tcp: *Proto,
    source: *const [IPaddrlen]u8,
    dest: *const [IPaddrlen]u8,
    length: u16,
    seg: *Tcp,
    version: u8,
    reason: []const u8,
    rh: ?*Routehint,
) i32 {
    const tpriv = privof(tcp);
    var ph4: Tcp4hdr = undefined;
    var ph6: Tcp6hdr = undefined;

    netlog(tcp.f.?, Logtcp, "sndrst: %s\n", .{reason});

    if (seg.flags & RST != 0)
        return -1;

    // make pseudo header
    switch (version) {
        V4 => {
            ph4 = std.mem.zeroes(Tcp4hdr);
            ph4.vihl = IP_VER4;
            ph4.proto = IP_TCPPROTO;
            hnputs(&ph4.tcplen, TCP4_HDRSIZE);
            hnputs(&ph4.tcpsport, seg.dest);
            hnputs(&ph4.tcpdport, seg.source);
            _ = v6tov4(&ph4.tcpsrc, dest);
            _ = v6tov4(&ph4.tcpdst, source);
        },
        V6 => {
            ph6 = std.mem.zeroes(Tcp6hdr);
            ph6.proto = IP_TCPPROTO;
            hnputs(&ph6.ploadlen, TCP6_HDRSIZE);
            hnputs(&ph6.tcpsport, seg.dest);
            hnputs(&ph6.tcpdport, seg.source);
            ipmove(&ph6.tcpsrc, dest);
            ipmove(&ph6.tcpdst, source);
        },
        else => panic("sndrst: version %d", .{version}),
    }

    tpriv.stats[OutRsts] += 1;
    var rflags: u8 = RST;

    // convince the other end that this reset is in band
    if (seg.flags & ACK != 0) {
        seg.seq = seg.ack;
        seg.ack = 0;
    } else {
        rflags |= ACK;
        seg.ack = seg.seq;
        seg.seq = 0;
        if (seg.flags & SYN != 0)
            seg.ack +%= 1;
        seg.ack +%= length;
        if (seg.flags & FIN != 0)
            seg.ack +%= 1;
    }
    seg.flags = rflags;
    seg.wnd = 0;
    seg.mss = 0;
    seg.ws = 0;
    switch (version) {
        V4 => {
            const bp = htontcp4(seg, null, &ph4);
            return ip_.ipoput4(tcp.f.?, bp, null, MAXTTL, DFLTTOS, rh);
        },
        V6 => {
            const bp = htontcp6(seg, null, &ph6);
            return ipv6.ipoput6(tcp.f.?, bp, null, MAXTTL, DFLTTOS, rh);
        },
        else => {},
    }
    return -1;
}

///  send a reset to the remote side and close the conversation
///  called with s locked
fn tcphangup(s: *Conv) Error!void {
    const tcb = tcbof(s);

    if (ipcmp(&s.iphash.raddr, &ipaux.IPnoaddr) != 0 and tcb.state != Closed and tcb.bypass == null) {
        var seg: Tcp = .{};

        seg.flags = RST | ACK;
        seg.seq = tcb.snd.ptr;
        tcb.rcv.ackptr = tcb.rcv.nxt;
        seg.ack = tcb.rcv.nxt;
        seg.wnd = 0;
        seg.mss = 0;
        seg.ws = 0;
        switch (s.ipversion) {
            V4 => {
                const bp = htontcp4(&seg, null, &tcb.protohdr.tcp4hdr);
                qunlock(&s.qlock);
                _ = ip_.ipoput4(s.p.?.f.?, bp, null, s.ttl, s.tos, &s.routehint);
            },
            V6 => {
                const bp = htontcp6(&seg, null, &tcb.protohdr.tcp6hdr);
                qunlock(&s.qlock);
                _ = ipv6.ipoput6(s.p.?.f.?, bp, null, s.ttl, s.tos, &s.routehint);
            },
            else => panic("tcphangup: version %d", .{s.ipversion}),
        }
        qlock(&s.qlock);
    }
    localclose(s, null);
}

///  (re)send a SYN ACK
fn sndsynack(tcp: *Proto, lp: *Limbo) i32 {
    var ph4: Tcp4hdr = undefined;
    var ph6: Tcp6hdr = undefined;
    var rh: Routehint = .{};

    const rt = iproute.v6lookup(tcp.f.?, &lp.raddr, &lp.laddr, &rh) orelse
        return -1;

    // make pseudo header
    switch (lp.version) {
        V4 => {
            ph4 = std.mem.zeroes(Tcp4hdr);
            ph4.vihl = IP_VER4;
            ph4.proto = IP_TCPPROTO;
            hnputs(&ph4.tcplen, TCP4_HDRSIZE);
            hnputs(&ph4.tcpsport, lp.lport);
            hnputs(&ph4.tcpdport, lp.rport);
            _ = v6tov4(&ph4.tcpsrc, &lp.laddr);
            _ = v6tov4(&ph4.tcpdst, &lp.raddr);
        },
        V6 => {
            ph6 = std.mem.zeroes(Tcp6hdr);
            ph6.proto = IP_TCPPROTO;
            hnputs(&ph6.ploadlen, TCP6_HDRSIZE);
            hnputs(&ph6.tcpsport, lp.lport);
            hnputs(&ph6.tcpdport, lp.rport);
            ipmove(&ph6.tcpsrc, &lp.laddr);
            ipmove(&ph6.tcpdst, &lp.raddr);
        },
        else => panic("sndsynack: version %d", .{lp.version}),
    }

    var seg: Tcp = .{};
    seg.seq = lp.iss;
    seg.ack = lp.irs +% 1;
    seg.flags = SYN | ACK;
    seg.mss = mtu2mss(tcpmtu(rt, &seg.ws, lp.version));
    seg.wnd = QMAX;

    // if the other did not set window scale, both should be zero
    if (lp.ws == 0)
        seg.ws = 0;

    lp.rexmits +%= 1;
    lp.lastsend = NOW();

    switch (lp.version) {
        V4 => {
            const bp = htontcp4(&seg, null, &ph4);
            return ip_.ipoput4(tcp.f.?, bp, null, MAXTTL, DFLTTOS, &rh);
        },
        V6 => {
            const bp = htontcp6(&seg, null, &ph6);
            return ipv6.ipoput6(tcp.f.?, bp, null, MAXTTL, DFLTTOS, &rh);
        },
        else => {},
    }
    return -1;
}

fn hashipa(a: *const [IPaddrlen]u8, p: u16) usize {
    return (@as(usize, a[IPaddrlen - 2]) + a[IPaddrlen - 1] + p) & LHTMASK;
}

fn limbohash(tpriv: *Tcppriv, raddr: *const [IPaddrlen]u8, rport: u16) *?*Limbo {
    return &tpriv.lht[hashipa(raddr, rport)];
}

fn limboent(
    tpriv: *Tcppriv,
    raddr: *const [IPaddrlen]u8,
    rport: u16,
    laddr: *const [IPaddrlen]u8,
    lport: u16,
    version: u8,
) *?*Limbo {
    var l = limbohash(tpriv, raddr, rport);
    while (l.*) |lp| : (l = &lp.next) {
        if (lp.lport != lport or lp.rport != rport or lp.version != version)
            continue;
        if (ipcmp(&lp.raddr, raddr) != 0)
            continue;
        if (ipcmp(&lp.laddr, laddr) != 0)
            continue;
        break;
    }
    return l;
}

///  put a call into limbo and respond with a SYN ACK
///
///  called with proto locked
fn limbo(s: *Conv, seg: *const Tcp, source: *const [IPaddrlen]u8, dest: *const [IPaddrlen]u8, version: u8) void {
    const tpriv = privof(s.p.?);
    var lp: *Limbo = undefined;

    var l = limboent(tpriv, source, seg.source, dest, seg.dest, version);
    if (l.*) |e| {
        lp = e;
        // each new SYN restarts the retransmits
        lp.irs = seg.seq;
    } else {
        const h = limbohash(tpriv, source, seg.source);
        if (tpriv.nlimbo >= Maxlimbo and h.* != null) {
            // reuse the oldest entry (head) of this hash bucket
            lp = h.*.?;
            h.* = lp.next;
            if (h.* == null)
                l = h;
        } else {
            lp = alloc.new(Limbo) orelse
                return;
            lp.* = .{};
            tpriv.nlimbo += 1;
        }
        lp.next = null;
        ipmove(&lp.laddr, dest);
        ipmove(&lp.raddr, source);
        lp.lport = seg.dest;
        lp.rport = seg.source;
        lp.mss = seg.mss;
        lp.ws = seg.ws;
        lp.irs = seg.seq;
        lp.iss = newiss();
        lp.rexmits = 0;
        lp.version = version;
        l.* = lp;
    }
    if (sndsynack(s.p.?, lp) < 0) {
        tpriv.nlimbo -= 1;
        l.* = lp.next;
        alloc.free(lp);
    }
}

///  resend SYN ACK's.
fn limborexmit(tcp: *Proto) void {
    if (!canqlock(&tcp.qlock))
        return;

    const now = NOW();
    const tpriv = privof(tcp);
    for (&tpriv.lht) |*head| {
        var l: *?*Limbo = head;
        while (l.*) |lp| {
            if (now -% lp.lastsend >= @as(u32, lp.rexmits) * 250) {
                if (lp.rexmits > 4 or sndsynack(tcp, lp) < 0) {
                    tpriv.nlimbo -= 1;
                    l.* = lp.next;
                    alloc.free(lp);
                    continue;
                }
            }
            l = &lp.next;
        }
    }
    qunlock(&tcp.qlock);
}

///  lookup call in limbo.  if found, throw it out.
///
///  called with proto locked
fn limborst(s: *Conv, seg: *const Tcp, source: *const [IPaddrlen]u8, dest: *const [IPaddrlen]u8, version: u8) void {
    const tpriv = privof(s.p.?);

    const l = limboent(tpriv, source, seg.source, dest, seg.dest, version);
    const lp = l.* orelse
        return;
    // RST can only follow the SYN
    if (seg.seq == lp.irs +% 1) {
        tpriv.nlimbo -= 1;
        l.* = lp.next;
        alloc.free(lp);
    }
}

///  use the time between the first SYN and it's ack as the
///  initial round trip time
fn tcpsynackrtt(tcb: *Tcpctl) void {
    const rtt: i32 = @bitCast(NOW() -% tcb.rttime);
    tcb.rttime = 0;
    tcb.srtt = rtt << LOGAGAIN;
    tcb.mdev = rtt << (LOGDGAIN - 1);
}

fn tcpbypass(arg: ?*anyopaque, b: *Block) void {
    const c = convof(arg);
    const tcb = tcbof(c);

    const o = tcb.bypass orelse {
        freeblist(b);
        return;
    };
    if (tcbof(o).bypass != c) {
        freeblist(b);
        return;
    }
    // DIFF: the C lets qbwrite's error (the other end hung up, or a
    // note during flow control) reach the writer.  qbwrite has taken
    // the block either way.
    _ = qio.qbwrite(o.rq.?, b) catch 0;
}

/// conf.pipeqsize, or what pipeinit would have made it.
fn pipeqsize() i32 {
    if (@hasField(arch.Conf, "pipeqsize")) {
        if (arch.conf.pipeqsize != 0)
            return @intCast(arch.conf.pipeqsize);
    }
    return 256 * 1024;
}

///  splice two local tcp conversations together,
///  having the wq directly bypass into the other
///  ends rq.
///
///  both new, old and proto are locked.
fn tcpsplice(new: *Conv, old: *Conv) void {
    const ntcb = tcbof(new);
    const otcb = tcbof(old);

    if (otcb.state != Established)
        return;

    ntcb.bypass = old;
    otcb.bypass = new;

    qsetlimit(new.rq.?, pipeqsize());
    qsetlimit(old.rq.?, pipeqsize());
    qsetbypass(new.wq.?, tcpbypass);
    qsetbypass(old.wq.?, tcpbypass);

    // stop timers and dump resequencing queue
    const tpriv = privof(new.p.?);
    tcphalt(tpriv, &ntcb.timer);
    tcphalt(tpriv, &otcb.timer);
    tcphalt(tpriv, &ntcb.acktimer);
    tcphalt(tpriv, &otcb.acktimer);
    tcphalt(tpriv, &ntcb.katimer);
    tcphalt(tpriv, &otcb.katimer);
    _ = dumpreseq(ntcb);
    _ = dumpreseq(otcb);
}

///  come here when we finally get an ACK to our SYN-ACK.
///  lookup call in limbo.  if found, create a new conversation
///
///  called with proto locked
fn tcpincoming(s: *Conv, seg: *const Tcp, src: *const [IPaddrlen]u8, dst: *const [IPaddrlen]u8, version: u8) ?*Conv {
    // unless it's just an ack, it can't be someone coming out of limbo
    if ((seg.flags & SYN) != 0 or (seg.flags & ACK) == 0)
        return null;

    const tpriv = privof(s.p.?);
    const l = limboent(tpriv, src, seg.source, dst, seg.dest, version);
    const lp = l.* orelse
        return null;
    if (seg.seq != lp.irs +% 1 or seg.ack != lp.iss +% 1) {
        netlog(s.p.?.f.?, Logtcp, "tcpincoming s %lux/%lux a %lux %lux\n", .{ seg.seq, lp.irs +% 1, seg.ack, lp.iss +% 1 });
        return null;
    }
    tpriv.nlimbo -= 1;
    l.* = lp.next;

    const new = devip.Fsnewcall(s, src, seg.source, dst, seg.dest, version) orelse {
        alloc.free(lp);
        return null;
    };

    const tcb = tcbof(new);
    tcb.* = tcbof(s).*;
    tcb.timer.arg = new;
    tcb.timer.state = TcptimerOFF;
    tcb.acktimer.arg = new;
    tcb.acktimer.state = TcptimerOFF;
    tcb.katimer.arg = new;
    tcb.katimer.state = TcptimerOFF;

    tcb.rcv.ackptr = seg.seq;
    tcb.rcv.nxt = seg.seq;
    tcb.rcv.wsnt = tcb.rcv.nxt;
    tcb.rcv.wptr = tcb.rcv.nxt;
    tcb.rcv.wnd = 0;

    tcb.iss = lp.iss;

    tcb.snd.una = seg.ack;
    tcb.snd.ptr = seg.ack;
    tcb.snd.nxt = seg.ack;
    tcb.snd.rxt = seg.ack;

    tcb.flgcnt = 0;
    tcb.flags |= SYNACK;

    tcb.rttime = lp.lastsend;
    tcpsynackrtt(tcb);

    // the same as what we sent in SYN,ACK
    const rp = iproute.v6lookup(s.p.?.f.?, src, dst, &new.routehint);
    tcb.mss = mtu2mss(tcpmtu(rp, &tcb.scale, version));

    tcpsetmss(new, lp.mss);
    tcpsetscale(new, lp.ws);

    alloc.free(lp);

    tcb.snd.wnd = seg.wnd << sh(tcb.snd.scale);
    tcb.snd.wl2 = seg.ack;
    tcb.snd.wl1 = seg.seq;

    // set up proto header
    switch (version) {
        V4 => {
            const h4 = &tcb.protohdr.tcp4hdr;
            h4.* = std.mem.zeroes(Tcp4hdr);
            h4.vihl = IP_VER4;
            h4.proto = IP_TCPPROTO;
            hnputs(&h4.tcpsport, new.iphash.lport);
            hnputs(&h4.tcpdport, new.iphash.rport);
            _ = v6tov4(&h4.tcpsrc, dst);
            _ = v6tov4(&h4.tcpdst, src);
        },
        V6 => {
            const h6 = &tcb.protohdr.tcp6hdr;
            h6.* = std.mem.zeroes(Tcp6hdr);
            h6.proto = IP_TCPPROTO;
            hnputs(&h6.tcpsport, new.iphash.lport);
            hnputs(&h6.tcpdport, new.iphash.rport);
            ipmove(&h6.tcpsrc, dst);
            ipmove(&h6.tcpdst, src);
        },
        else => panic("tcpincoming: version %d", .{new.ipversion}),
    }

    qlock(&new.qlock);
    tcpsetstate(new, Established);
    iphtadd(&tpriv.ht, &new.iphash);
    if (rp != null and (rp.?.type & Runi) != 0) {
        // see if we can find the local conversation and splice them together
        if (iphtlook(&tpriv.ht, &new.iphash.laddr, new.iphash.lport, &new.iphash.raddr, new.iphash.rport)) |iph| {
            if (iph.trans == 0) {
                const old = iphconv(iph);
                if (old != new) {
                    qlock(&old.qlock);
                    tcpsplice(new, old);
                    qunlock(&old.qlock);
                }
            }
        }
    }
    qunlock(&new.qlock);

    return new;
}

fn update(s: *Conv, seg: *Tcp) void {
    if (seg.update != 0)
        return;
    seg.update = 1;
    if ((seg.flags & ACK) == 0)
        return;

    const tcb = tcbof(s);
    const tpriv = privof(s.p.?);
    const f = s.p.?.f.?;

    // ghost acks should be ignored
    if (seq_gt(seg.ack, tcb.snd.nxt))
        return;

    // the C jumps to the label `recovery` inside the fast retransmit
    // test from the window update
    var recovery = false;
    var dupack = false;

    //
    //  update window
    //
    if (seq_gt(seg.seq, tcb.snd.wl1) or
        seg.seq == tcb.snd.wl1 and
            (seq_gt(seg.ack, tcb.snd.wl2) or
                seg.ack == tcb.snd.wl2 and seg.wnd > tcb.snd.wnd))
    {
        // clear dupack if we advance wl2
        if (tcb.snd.wl2 != seg.ack)
            tcb.snd.dupacks = 0;
        tcb.snd.wl2 = seg.ack;
        tcb.snd.wl1 = seg.seq;
        if (tcb.snd.wnd == 0 and seg.wnd > 0)
            recovery = true;
        tcb.snd.wnd = seg.wnd;
    }

    // newreno fast retransmit
    if (!recovery and
        tcb.snd.una != tcb.snd.nxt and
        seg.ack == tcb.snd.una and
        seg.len == 0 and (seg.flags & (SYN | FIN)) == 0)
    {
        dupack = true;
        tcb.snd.dupacks +%= 1;
        if (tcb.snd.dupacks == 3)
            recovery = true;
    }

    if (recovery) {
        if (tcb.snd.recovery != 0) {
            tpriv.stats[RecoveryCwind] += 1;
            tcb.cwind +%= tcb.mss;
        } else if (tcb.snd.wnd == 0) {
            netlog(f, Logtcpwin, "!recov %lud %lud window shut\n", .{ tcb.snd.rxt, seg.ack });
            // force window probe
            _ = tcprxmit(s);
        } else if (seq_ge(seg.ack, tcb.snd.rxt)) {
            tpriv.stats[Recovery] += 1;
            tcb.snd.recovery = 1;
            tcb.snd.partialack = 0;
            tcb.snd.rxt = tcb.snd.nxt;
            tcpcongestion(tcb);
            tcb.abcbytes = 0;
            tcb.cwind = tcb.ssthresh +% 3 * @as(u32, tcb.mss);
            netlog(f, Logtcpwin, "recovery inflate %ld ss %ld @%lud\n", .{ tcb.cwind, tcb.ssthresh, tcb.snd.rxt });
            // initial fast-retransmit, preserve send pointer
            tcb.snd.ptr = tcprxmit(s);
        } else {
            tpriv.stats[RecoveryNoSeq] += 1;
            netlog(f, Logtcpwin, "!recov %lud not ≤ %lud %ld\n", .{
                tcb.snd.rxt,
                seg.ack,
                @as(i32, @bitCast(tcb.snd.rxt -% seg.ack)),
            });
            // do not enter fast retransmit
            // do not change ssthresh
        }
    } else if (dupack and tcb.snd.recovery != 0) {
        tpriv.stats[RecoveryCwind] += 1;
        tcb.cwind +%= tcb.mss;
    }

    // Compute the new send window size
    var acked: i32 = @bitCast(seg.ack -% tcb.snd.una);
    if (acked <= 0) {
        //  don't let us hangup if sending into a closed window and
        //  we're still getting acks
        if (tcb.snd.wnd == 0)
            tcb.backedoff = MAXBACKMS / 4;
        return;
    }

    // RTT measurement
    if (tcb.rttime != 0 and seq_ge(seg.ack, tcb.rttseq)) {
        const rtt: i32 = @bitCast(NOW() -% tcb.rttime);
        tcb.rttime = 0;

        var delta = rtt -% (tcb.srtt >> LOGAGAIN);
        tcb.srtt +%= delta;
        if (delta < 0) delta = -%delta;
        tcb.mdev +%= delta -% (tcb.mdev >> LOGDGAIN);
    }

    //
    //  update queue
    //
    if ((tcb.flags & SYNACK) == 0) {
        tcb.flags |= SYNACK;
        tcb.flgcnt -%= 1;
        acked -= 1;
    }
    // acked is not negative here
    if (qio.qdiscard(s.wq.?, @intCast(acked)) < @as(usize, @intCast(acked)))
        tcb.flgcnt -%= 1;
    tcb.snd.una = seg.ack;
    if (seq_gt(seg.ack, tcb.snd.ptr))
        tcb.snd.ptr = seg.ack;

    //
    //  congestion control
    //
    const uacked: u32 = @bitCast(acked);
    if (tcb.snd.recovery != 0) {
        if (seq_ge(seg.ack, tcb.snd.rxt) or tcb.snd.wnd == 0) {
            // recovery finished; deflate window
            tpriv.stats[RecoveryDone] += 1;
            tcb.snd.dupacks = 0;
            tcb.snd.recovery = 0;

            // RFC 6582 2.3 (3) min(ssthresh, max(FlightSize, SMSS) + SMSS)
            tcb.cwind = tcb.snd.nxt -% tcb.snd.una;
            if (tcb.cwind < tcb.mss)
                tcb.cwind = tcb.mss;
            tcb.cwind +%= tcb.mss;
            if (tcb.cwind > tcb.ssthresh)
                tcb.cwind = tcb.ssthresh;
            netlog(f, Logtcpwin, "recovery deflate %ld %ld\n", .{ tcb.cwind, tcb.ssthresh });
        } else {
            // partial ack; we lost more than one segment
            tpriv.stats[RecoveryPA] += 1;
            if (tcb.cwind > uacked)
                tcb.cwind -= uacked
            else {
                netlog(f, Logtcpwin, "partial ack neg\n", .{});
                tcb.cwind = tcb.mss;
            }
            if (acked >= tcb.mss)
                tcb.cwind +%= tcb.mss;
            tcb.snd.partialack +%= 1;
            netlog(f, Logtcpwin, "partial ack %d left %ld cwind %ld\n", .{
                acked,
                @as(i32, @bitCast(tcb.snd.rxt -% seg.ack)),
                tcb.cwind,
            });
            // retransmit, preserve send pointer
            tcb.snd.ptr = tcprxmit(s);
        }
    } else {
        tcpabcincr(tcb, uacked);
    }

    tcb.backoff = 0;
    tcb.backedoff = 0;

    if (tcb.snd.una != tcb.snd.nxt) {
        // "impatient" variant
        if (tcb.snd.recovery == 0 or tcb.snd.partialack == 1)
            tcpsettimer(s);
    } else tcphalt(tpriv, &tcb.timer);
}

/// The C's label badhdr in tcpiput.
fn badhdr(f: *Fs, tpriv: *Tcppriv, bp: ?*Block) void {
    tpriv.stats[HlenErrs] += 1;
    tpriv.stats[InErrs] += 1;
    netlog(f, Logtcp, "bad tcp header\n", .{});
    freeblist(bp);
}

/// qlen(s->wq)+tcb->flgcnt
fn sndqlen(s: *Conv, tcb: *Tcpctl) i32 {
    return qlen(s.wq.?) + tcb.flgcnt;
}

/// The move to Time_wait that tcpiput makes in four places.
fn timewait(s: *Conv, tcb: *Tcpctl, tpriv: *Tcppriv) void {
    tcphalt(tpriv, &tcb.acktimer);
    tcphalt(tpriv, &tcb.katimer);
    tcpsetstate(s, Time_wait);
    tcb.timer.start = MSL2 * (1000 / MSPTICK);
    tcpgo(tpriv, &tcb.timer);
}

fn tcpiput(tcp: *Proto, ifc: *Ipifc, bp_: *Block) void {
    var bp: ?*Block = bp_;
    var seg: Tcp = .{};
    var source: [IPaddrlen]u8 = undefined;
    var dest: [IPaddrlen]u8 = undefined;
    var hdrlen: i32 = undefined;
    var length: u16 = undefined;
    var version: u8 = undefined;
    var ttl: u32 = undefined;

    const f = tcp.f.?;
    const tpriv = privof(tcp);
    tpriv.stats[InSegs] += 1;

    var h4: *Tcp4hdr = @ptrCast(bp_.rp);
    const h6: *Tcp6hdr = @ptrCast(bp_.rp);

    if ((h4.vihl & 0xF0) == IP_VER4) {
        if (BLEN(bp_) < TCP4_PKT + TCP4_HDRSIZE)
            return badhdr(f, tpriv, bp);
        version = V4;
        ttl = h4.ttl;
        length = nhgets(&h4.length);
        if (length < TCP4_PKT)
            return badhdr(f, tpriv, bp);
        length -= TCP4_PKT;
        v4tov6(&dest, &h4.tcpdst);
        v4tov6(&source, &h4.tcpsrc);

        h4.ttl = 0;
        hnputs(&h4.tcplen, length);
        if ((bp_.flag & ab.Btcpck) == 0 and (h4.tcpcksum[0] != 0 or h4.tcpcksum[1] != 0) and
            ptclcsum(bp, TCP4_IPLEN, @as(usize, length) + TCP4_PKT - TCP4_IPLEN) != 0)
        {
            tpriv.stats[CsumErrs] += 1;
            tpriv.stats[InErrs] += 1;
            netlog(f, Logtcp, "bad tcp proto cksum\n", .{});
            freeblist(bp);
            return;
        }
        h4.ttl = @truncate(ttl);

        hdrlen = ntohtcp4(&seg, &bp);
        if (hdrlen < 0) {
            tpriv.stats[HlenErrs] += 1;
            tpriv.stats[InErrs] += 1;
            netlog(f, Logtcp, "bad tcp hdr len\n", .{});
            return;
        }
        length -%= @as(u16, @intCast(hdrlen));
        hdrlen += TCP4_PKT;
    } else {
        if (BLEN(bp_) < TCP6_PKT + TCP6_HDRSIZE)
            return badhdr(f, tpriv, bp);

        version = V6;
        ttl = h6.ttl;
        const proto = h6.proto;
        length = nhgets(&h6.ploadlen);
        ipmove(&dest, &h6.tcpdst);
        ipmove(&source, &h6.tcpsrc);

        h6.ploadlen[0] = 0;
        h6.ploadlen[1] = 0;
        h6.proto = 0;
        h6.ttl = proto;
        hnputl(&h6.vcf, length);
        if ((h6.tcpcksum[0] != 0 or h6.tcpcksum[1] != 0) and
            ptclcsum(bp, TCP6_IPLEN, @as(usize, length) + TCP6_PHDRSIZE) != 0)
        {
            tpriv.stats[CsumErrs] += 1;
            tpriv.stats[InErrs] += 1;
            netlog(f, Logtcp, "bad tcpv6 proto cksum: got %#ux\n", .{@as(u32, h6.tcpcksum[0]) << 8 | h6.tcpcksum[1]});
            freeblist(bp);
            return;
        }
        h6.ttl = @truncate(ttl);
        h6.proto = proto;
        hnputs(&h6.ploadlen, length);

        hdrlen = ntohtcp6(&seg, &bp);
        if (hdrlen < 0) {
            tpriv.stats[HlenErrs] += 1;
            tpriv.stats[InErrs] += 1;
            netlog(f, Logtcp, "bad tcpv6 hdr len\n", .{});
            return;
        }
        length -%= @as(u16, @intCast(hdrlen));
        hdrlen += TCP6_PKT;
    }
    // DIFF: ntohtcp may have made a new block.
    h4 = @ptrCast(bp.?.rp);

    // lock protocol while searching for a conversation
    qlock(&tcp.qlock);

    // Look for a matching conversation
    const iph = iphtlook(&tpriv.ht, &source, seg.source, &dest, seg.dest) orelse {
        netlog(f, Logtcp, "iphtlook(src %I!%d, dst %I!%d) failed\n", .{ ipaux.ip(&source), seg.source, ipaux.ip(&dest), seg.dest });
        // reset:
        qunlock(&tcp.qlock);
        freeblist(bp);
        _ = sndrst(tcp, &source, &dest, length, &seg, version, "no conversation", null);
        return;
    };
    if (iph.trans != 0) {
        const q = (if (ttl <= 1) null else ipaux.transbackward(tcp, iph)) orelse {
            // reset:
            qunlock(&tcp.qlock);
            freeblist(bp);
            _ = sndrst(tcp, &source, &dest, length, &seg, version, "no conversation", null);
            return;
        };
        hnputs_csum(h4.tcpdst[0..2], nhgets(q.forward.raddr[IPv4off + 0 ..][0..2]), &h4.tcpcksum);
        hnputs_csum(h4.tcpdst[2..4], nhgets(q.forward.raddr[IPv4off + 2 ..][0..2]), &h4.tcpcksum);
        hnputs_csum(&h4.tcpdport, q.forward.rport, &h4.tcpcksum);
        qunlock(&tcp.qlock);
        _ = ip_.ipoput4(f, bp.?, ifc, ttl - 1, h4.tos, &q.routehint);
        return;
    }
    var s = iphconv(iph);

    // trim off ip and tcp headers
    bp = qio.trimblock(bp.?, hdrlen, length);
    if (bp == null) {
        tpriv.stats[LenErrs] += 1;
        tpriv.stats[InErrs] += 1;
        netlog(f, Logtcp, "tcp bad length after header trim off\n", .{});
        qunlock(&tcp.qlock);
        return;
    }

    // if it's a listener, look for the right flags and get a new conv
    var tcb = tcbof(s);
    if (tcb.state == Listen) {
        if (seg.flags & RST != 0) {
            limborst(s, &seg, &source, &dest, version);
            qunlock(&tcp.qlock);
            freeblist(bp);
            return;
        }

        // if this is a new SYN, put the call into limbo
        if ((seg.flags & SYN) != 0 and (seg.flags & ACK) == 0) {
            limbo(s, &seg, &source, &dest, version);
            qunlock(&tcp.qlock);
            freeblist(bp);
            return;
        }

        //  if there's a matching call in limbo, tcpincoming will
        //  return it in state Established
        s = tcpincoming(s, &seg, &source, &dest, version) orelse {
            // reset:
            qunlock(&tcp.qlock);
            freeblist(bp);
            _ = sndrst(tcp, &source, &dest, length, &seg, version, "no conversation", null);
            return;
        };
    }

    // The rest of the input state machine is run with the control block
    // locked and implements the state machine directly out of the RFC.
    // Out-of-band data is ignored - it was always a bad idea.
    tcb = tcbof(s);
    qlock(&s.qlock);
    qunlock(&tcp.qlock);

    // fix up window
    seg.wnd <<= sh(tcb.snd.scale);

    // every input packet in puts off the keep alive time out
    tcb.kato = 0;

    // The C's labels: every way out of the state machine is one of
    // these.
    const Next = enum { output, raise, reset2 };
    var reason: []const u8 = "sending to Closed";

    const next: Next = sw: {
        switch (tcb.state) {
            Closed => {
                // closed:
                reason = "sending to Closed";
                break :sw .reset2;
            },
            Syn_sent => {
                if (seg.flags & ACK != 0) {
                    if (!seq_in(seg.ack, tcb.snd.una, tcb.snd.nxt +% 1)) {
                        if (seg.flags & RST != 0)
                            break :sw .raise;
                        reason = "bad seq in Syn_sent";
                        break :sw .reset2;
                    }
                }
                if (seg.flags & RST != 0) {
                    if (seg.flags & ACK != 0)
                        localclose(s, Econrefused);
                    break :sw .raise;
                }
                if (seg.flags & SYN == 0)
                    break :sw .raise;

                procsyn(s, &seg);
                if (seg.flags & ACK != 0) {
                    tcb.snd.wnd = seg.wnd; // window in SYN,ACK must not be scaled
                    tcb.snd.wl2 = seg.ack;
                    tcb.snd.wl1 = seg.seq;
                    tcpsynackrtt(tcb);
                    update(s, &seg);
                    tcpsetstate(s, Established);
                } else {
                    tcb.time = NOW();
                    tcpsetstate(s, Syn_received); // DLP - shouldn't this be a reset?
                }
                if (!(length != 0 or (seg.flags & FIN) != 0)) {
                    freeblist(bp);
                    bp = null;
                    break :sw .output;
                }
            },
            Syn_received => {
                if (seg.flags & ACK != 0)
                    tcpsynackrtt(tcb);
            },
            else => {},
        }

        // Cut the data to fit the receive window
        tcprcvwin(s);
        if (tcptrim(tcb, &seg, &bp, &length) < 0) {
            netlog(f, Logtcp, "tcp: trim: !inwind: seq %lud-%lud (%d) win %lud-%lud (%lud) from %I!%d -> %I!%d\n", .{
                seg.seq,                   seg.seq +% length, length,
                tcb.rcv.nxt,               tcb.rcv.wptr,      tcb.rcv.wnd,
                ipaux.ip(&s.iphash.raddr), s.iphash.rport,    ipaux.ip(&s.iphash.laddr),
                s.iphash.lport,
            });
            tcb.flags |= FORCE;
            update(s, &seg);
            if (tcb.state == Closing and sndqlen(s, tcb) == 0)
                timewait(s, tcb, tpriv);
            if (seg.flags & RST != 0)
                break :sw .raise;
            break :sw .output;
        }

        // Cannot accept so answer with a rst
        if (length != 0 and tcb.state == Closed) {
            reason = "sending to Closed";
            break :sw .reset2;
        }

        // The segment is beyond the current receive pointer so
        // queue the data in the resequence queue
        if (seg.seq != tcb.rcv.nxt and (length != 0 or (seg.flags & (SYN | FIN)) != 0)) {
            //  force duplicate ack; RFC 5681 §3.2
            //
            //  FORCE must be set before update()
            //  which can send fast-retransmits
            //  (clearing FORCE flag) as we must
            //  only produce one output segment
            //  per input segment.
            tcb.flags |= FORCE;
            update(s, &seg);
            if (addreseq(f, tcb, tpriv, &seg, &bp, length) < 0)
                print("tcp: reseq: %I!%d -> %I!%d\n", .{ ipaux.ip(&s.iphash.raddr), s.iphash.rport, ipaux.ip(&s.iphash.laddr), s.iphash.lport });
            break :sw .output;
        }

        //  keep looping till we've processed this packet plus any
        //  adjacent packets in the resequence queue
        while (true) {
            if (seg.flags & RST != 0) {
                if (tcb.state == Established) {
                    tpriv.stats[EstabResets] += 1;
                    if (tcb.rcv.nxt != seg.seq)
                        print("out of order RST rcvd: %I.%d -> %I.%d, rcv.nxt %lux seq %lux\n", .{
                            ipaux.ip(&s.iphash.raddr), s.iphash.rport,
                            ipaux.ip(&s.iphash.laddr), s.iphash.lport,
                            tcb.rcv.nxt,               seg.seq,
                        });
                }
                localclose(s, Econrefused);
                break :sw .raise;
            }

            if ((seg.flags & ACK) == 0)
                break :sw .raise;

            switch (tcb.state) {
                Syn_received => {
                    if (!seq_in(seg.ack, tcb.snd.una, tcb.snd.nxt +% 1)) {
                        reason = "bad seq in Syn_received";
                        break :sw .reset2;
                    }
                    tcb.snd.wnd = seg.wnd; // already scaled
                    tcb.snd.wl2 = seg.ack;
                    tcb.snd.wl1 = seg.seq;
                    update(s, &seg);
                    tcpsetstate(s, Established);
                },
                Established, Close_wait, Finwait2 => {
                    if (tcb.state == Established and tcb.bypass != null)
                        break :sw .raise;
                    // wet floor
                    update(s, &seg);
                },
                Finwait1 => {
                    update(s, &seg);
                    if (sndqlen(s, tcb) == 0) {
                        tcphalt(tpriv, &tcb.acktimer);
                        tcphalt(tpriv, &tcb.katimer);
                        tcb.time = NOW();
                        tcpsetstate(s, Finwait2);
                        tcb.katimer.start = MSL2 * (1000 / MSPTICK);
                        tcpgo(tpriv, &tcb.katimer);
                    }
                },
                Closing => {
                    update(s, &seg);
                    if (sndqlen(s, tcb) == 0)
                        timewait(s, tcb, tpriv);
                },
                Last_ack, Time_wait => {
                    if (tcb.state == Last_ack) {
                        update(s, &seg);
                        if (sndqlen(s, tcb) == 0) {
                            localclose(s, null);
                            break :sw .raise;
                        }
                        // wet floor
                    }
                    if (seg.flags & FIN != 0)
                        tcb.flags |= FORCE;
                    if (tcb.timer.state != TcptimerON)
                        tcpsettimer(s);
                },
                else => {},
            }

            if (length == 0) {
                freeblist(bp);
                bp = null;
            } else {
                switch (tcb.state) {
                    Syn_received, Established, Finwait1 => {
                        // If we still have some data place on
                        // receive queue
                        if (bp) |b| {
                            _ = qio.qpassnolim(s.rq.?, qio.packblock(b).?);
                            bp = null;
                        }
                        tcb.rcv.nxt +%= length;
                    },
                    Finwait2 => {
                        reason = "send to Finwait2";
                        break :sw .reset2;
                    },
                    else => {
                        // Ignore segment text
                        freeblist(bp);
                        bp = null;
                    },
                }
            }

            if (seg.flags & FIN != 0) {
                tcb.flags |= FORCE;

                switch (tcb.state) {
                    Syn_received, Established => {
                        tcb.rcv.nxt +%= 1;
                        tcpsetstate(s, Close_wait);
                    },
                    Finwait1 => {
                        tcb.rcv.nxt +%= 1;
                        if (sndqlen(s, tcb) == 0)
                            timewait(s, tcb, tpriv)
                        else
                            tcpsetstate(s, Closing);
                    },
                    Finwait2 => {
                        tcb.rcv.nxt +%= 1;
                        timewait(s, tcb, tpriv);
                    },
                    Close_wait, Closing, Last_ack => {},
                    Time_wait => tcpsettimer(s),
                    else => {},
                }
            }

            //  get next adjacent segment from the resequence queue.
            //  dump/trim any overlapping segments
            while (true) {
                if (getreseq(tcb, &seg, &bp, &length) < 0)
                    break :sw .output;
                tcprcvwin(s);
                if (tcptrim(tcb, &seg, &bp, &length) == 0) {
                    // produce an ack when hole filled
                    tcb.flags |= FORCE;
                    break;
                }
            }
        }
    };

    switch (next) {
        .output => {
            tcpoutput(s);

            //  turn on the acktimer if there's something
            //  to ack and we delayed ack in tcpoutput().
            if (tcb.rcv.ackptr != tcb.rcv.nxt and tcb.acktimer.state != TcptimerON)
                tcpgo(tpriv, &tcb.acktimer);

            qunlock(&s.qlock);
        },
        .raise => {
            qunlock(&s.qlock);
            freeblist(bp);
        },
        .reset2 => {
            qunlock(&s.qlock);
            freeblist(bp);
            _ = sndrst(tcp, &source, &dest, length, &seg, version, reason, &s.routehint);
        },
    }
}

///  always enters and exits with the s locked.  We drop
///  the lock to ipoput the packet so some care has to be
///  taken by callers.
fn tcpoutput(s: *Conv) void {
    const f = s.p.?.f.?;
    const tcb = tcbof(s);
    const tpriv = privof(s.p.?);
    var seg: Tcp = .{};

    // force ack every second mss
    if ((tcb.flags & FORCE) == 0 and tcb.rcv.nxt -% tcb.rcv.ackptr > tcb.mss) {
        tpriv.stats[Delayack] += 1;
        tcb.flags |= FORCE;
    }

    while (true) {
        switch (tcb.state) {
            Listen, Closed, Finwait2 => return,
            else => {},
        }

        // Don't send anything else until our SYN has been acked
        if ((tcb.flags & SYNACK) == 0 and tcb.snd.ptr != tcb.iss)
            return;

        tcprcvwin(s);

        // force an ack when a window has opened up
        if ((tcb.flags & FORCE) == 0 and seq_in(tcb.rcv.nxt, tcb.rcv.wsnt, tcb.rcv.wptr)) {
            tpriv.stats[Wopenack] += 1;
            tcb.flags |= FORCE;
        }

        // figure out yow much to send
        const sndcnt: i32 = sndqlen(s, tcb);
        var ssize: i32 = sndcnt;
        var sent: i32 = undefined;
        if (tcb.snd.wnd == 0) {
            // zero window probe
            seg.seq = tcb.snd.una;
            sent = @bitCast(tcb.snd.ptr -% seg.seq);
            if (sent > 0)
                ssize = 0
            else if (ssize > 0)
                ssize = 1;
        } else {
            // calculate usable segment size
            // (int against ulong: the C compares unsigned)
            if (@as(u32, @bitCast(ssize)) > tcb.snd.wnd)
                ssize = @bitCast(tcb.snd.wnd);
            if (@as(u32, @bitCast(ssize)) > tcb.cwind)
                ssize = @bitCast(tcb.cwind);
            seg.seq = tcb.snd.ptr;
            sent = @bitCast(seg.seq -% tcb.snd.una);
            ssize -%= sent;
            if (ssize < 0)
                ssize = 0
            else if (ssize > tcb.mss)
                ssize = tcb.mss;
        }

        if ((tcb.flags & FORCE) == 0) {
            if (ssize == 0)
                return;
            if (ssize < tcb.mss and
                seg.seq == tcb.snd.nxt and
                sent > TCPREXMTTHRESH * @as(i32, tcb.mss))
                return;
        }
        tcb.flags &= ~FORCE;

        // By default we will generate an ack
        seg.source = s.iphash.lport;
        seg.dest = s.iphash.rport;
        seg.flags = ACK;
        seg.mss = 0;
        seg.ws = 0;
        seg.update = 0;

        tcb.rcv.ackptr = tcb.rcv.nxt;
        seg.ack = tcb.rcv.nxt;
        seg.wnd = tcb.rcv.wnd >> sh(tcb.rcv.scale);
        tcb.rcv.wsnt = tcb.rcv.wptr;

        var bp: ?*Block = null;
        if (ssize > 0) {
            switch (tcb.state) {
                Syn_sent, Syn_received => {
                    if (tcb.state == Syn_sent)
                        seg.flags = 0;
                    // wet floor

                    //  don't send any data with a SYN packet
                    //  because Linux rejects the packet in its
                    //  attempt to solve the SYN attack problem
                    seg.flags |= SYN;
                    seg.mss = tcb.mss;
                    seg.ws = tcb.scale;
                    ssize = 1;
                },
                else => {
                    // Pull out data to send
                    // DIFF: sent is the distance of the send pointer
                    // from snd.una and is not negative unless the
                    // pointers are out of order; the C would then hand
                    // qcopy a negative offset.  Send from the start of
                    // the queue instead of trapping.
                    const b = qio.qcopy(s.wq.?, @intCast(ssize), @intCast(@max(sent, 0)));
                    bp = b;
                    if (BLEN(b) != @as(usize, @intCast(ssize)))
                        seg.flags |= FIN
                    else if (sent +% ssize == sndcnt)
                        seg.flags |= PSH;
                },
            }

            // Pull up the send pointer so we can accept acks
            // for this window
            tcb.snd.ptr +%= @as(u32, @bitCast(ssize));
            if (seq_gt(tcb.snd.ptr, tcb.snd.nxt)) {
                tcb.snd.nxt = tcb.snd.ptr;

                // start RTT measurement
                if (tcb.rttime == 0) {
                    tcb.rttime = NOW();
                    tcb.rttseq = tcb.snd.ptr;
                }
            }

            // Start the transmission timers if there is new data and we
            // expect acknowledges
            if (tcb.timer.state != TcptimerON)
                tcpsettimer(s);
        }

        if (tcb.acktimer.state == TcptimerON)
            tcphalt(tpriv, &tcb.acktimer);

        tpriv.stats[OutSegs] += 1;
        if (tcb.snd.ptr != tcb.snd.nxt)
            tpriv.stats[RetransSegsSent] += 1;

        var r: i32 = undefined;
        switch (s.ipversion) {
            V4 => {
                const b = htontcp4(&seg, bp, &tcb.protohdr.tcp4hdr);
                qunlock(&s.qlock);
                r = ip_.ipoput4(f, b, null, s.ttl, s.tos, &s.routehint);
            },
            V6 => {
                const b = htontcp6(&seg, bp, &tcb.protohdr.tcp6hdr);
                qunlock(&s.qlock);
                r = ipv6.ipoput6(f, b, null, s.ttl, s.tos, &s.routehint);
            },
            else => panic("tcpoutput: version %d", .{s.ipversion}),
        }
        if (r < 0) {
            qlock(&s.qlock);
            localclose(s, Enoroute);
            return;
        }
        qlock(&s.qlock);
    }
}

///  the BSD convention (hack?) for keep alives.  resend last uchar acked.
fn tcpsendka(s: *Conv) i32 {
    const tcb = tcbof(s);
    var bp: ?*Block = null;
    var seg: Tcp = .{};
    var ret: i32 = undefined;

    seg.source = s.iphash.lport;
    seg.dest = s.iphash.rport;
    seg.flags = ACK | PSH;
    seg.mss = 0;
    seg.ws = 0;

    tcprcvwin(s);
    seg.seq = tcb.snd.una -% 1;
    tcb.rcv.ackptr = tcb.rcv.nxt;
    seg.ack = tcb.rcv.nxt;
    seg.wnd = tcb.rcv.wnd >> sh(tcb.rcv.scale);
    tcb.rcv.wsnt = tcb.rcv.wptr;

    if (tcb.state == Finwait2) {
        seg.flags |= FIN;
        bp = null;
    } else {
        const b = allocb(1);
        b.wp += 1;
        bp = b;
    }
    switch (s.ipversion) {
        V4 => {
            const b = htontcp4(&seg, bp, &tcb.protohdr.tcp4hdr);
            qunlock(&s.qlock);
            ret = ip_.ipoput4(s.p.?.f.?, b, null, s.ttl, s.tos, &s.routehint);
        },
        V6 => {
            const b = htontcp6(&seg, bp, &tcb.protohdr.tcp6hdr);
            qunlock(&s.qlock);
            ret = ipv6.ipoput6(s.p.?.f.?, b, null, s.ttl, s.tos, &s.routehint);
        },
        else => panic("tcpsendka: version %d", .{s.ipversion}),
    }
    qlock(&s.qlock);
    return ret;
}

///  if we've timed out, close the connection
///  otherwise, send a keepalive and restart the timer
fn tcpkeepalive(arg: ?*anyopaque) void {
    const s = convof(arg);
    const tcb = tcbof(s);

    qlock(&s.qlock);
    if (tcb.state != Closed and tcb.bypass == null) {
        tcb.kato +%= 1;
        if (tcb.kato > MAX_KAT) {
            localclose(s, Etimedout);
        } else if (tcpsendka(s) < 0) {
            localclose(s, Enoroute);
        } else {
            tcpgo(privof(s.p.?), &tcb.katimer);
        }
    }
    qunlock(&s.qlock);
}

///  start keepalive timer
fn tcpstartka(s: *Conv, f: []const []const u8) Error!void {
    const tcb = tcbof(s);

    if (tcb.state != Established)
        return proc.errorf("connection must be in Establised state", .{});

    if (tcb.bypass != null)
        return;

    var x: i32 = DEF_KAT;
    if (f.len > 1) {
        x = netif.atoi(f[1]);
        if (x <= 0)
            x = 0;
    }
    tcphalt(privof(s.p.?), &tcb.katimer);
    tcb.kato = 0;
    tcb.katimer.start = @divTrunc(x +% (MSPTICK - 1), MSPTICK);
    tcpgo(privof(s.p.?), &tcb.katimer);
}

///  retransmit (at most) one segment at snd.una.
///  preserve cwind and return original snd.ptr
fn tcprxmit(s: *Conv) u32 {
    const tcb = tcbof(s);

    tcb.flags |= FORCE;

    var tptr = tcb.snd.ptr;
    tcb.snd.ptr = tcb.snd.una;

    const tcwind = tcb.cwind;
    tcb.cwind = tcb.mss;

    tcpoutput(s);

    tcb.cwind = tcwind;

    const tpriv = privof(s.p.?);
    tpriv.stats[RetransSegs] += 1;

    // in case tcpoutput() released the lock
    if (seq_lt(tptr, tcb.snd.una))
        tptr = tcb.snd.una;

    return tptr;
}

///  todo: RFC 4138 F-RTO
fn tcptimeout(arg: ?*anyopaque) void {
    const s = convof(arg);
    const tcb = tcbof(s);
    const tpriv = privof(s.p.?);

    qlock(&s.qlock);
    sw: switch (tcb.state) {
        Time_wait => localclose(s, null),
        Closed => {},
        else => {
            if (tcb.backoff < 8)
                tcb.backoff += 1;
            const maxback: i32 = if (tcb.state == Syn_sent and tcb.backoff > 2)
                0
            else
                MAXBACKMS;
            tcb.backedoff +%= tcb.timer.start *% MSPTICK;
            if (tcb.backedoff >= maxback) {
                localclose(s, Etimedout);
                break :sw;
            }
            netlog(s.p.?.f.?, Logtcprxmt, "rxm %d/%d %ldms %lud rto %d %lud %s\n", .{
                tcb.srtt,                              tcb.mdev,
                @as(i32, @bitCast(NOW() -% tcb.time)), tcb.snd.una -% tcb.timeuna,
                tcb.snd.rto,                           tcb.snd.ptr,
                // the conversation's state, not the tcb's, as in C
                tcpstates[@intCast(s.state)],
            });
            tpriv.stats[RetransTimeouts] += 1;
            if (tcb.snd.rto == 0)
                tcpcongestion(tcb);
            tcb.snd.rto +%= 1;
            tcb.abcbytes = 0;
            tcb.cwind = tcb.mss;
            if (tcb.snd.recovery != 0) {
                tcb.snd.recovery = 0;
                tcb.snd.dupacks = 0; // reno rto
                tcb.snd.rxt = tcb.snd.nxt;
                netlog(s.p.?.f.?, Logtcpwin, "rto recovery rxt @%lud\n", .{tcb.snd.nxt});
                tpriv.stats[RecoveryRTO] += 1;
            }
            // resets the send pointer, retransmits and restarts timer
            _ = tcprxmit(s);
        },
    }
    qunlock(&s.qlock);
}

///  set up state for a received SYN (or SYN ACK) packet
fn procsyn(s: *Conv, seg: *const Tcp) void {
    const tcb = tcbof(s);

    tcb.flags |= FORCE;

    tcb.rcv.ackptr = seg.seq +% 1;
    tcb.rcv.nxt = seg.seq +% 1;
    tcb.rcv.wsnt = tcb.rcv.nxt;
    tcb.rcv.wptr = tcb.rcv.nxt;
    tcb.rcv.wnd = 0;

    tcpsetmss(s, seg.mss);
    tcpsetscale(s, seg.ws);
}

fn dumpreseq(tcb: *Tcpctl) i32 {
    var r = tcb.reseq;
    while (r) |rp| {
        r = rp.next;
        freeblist(rp.bp);
        alloc.free(rp);
    }
    tcb.reseq = null;
    tcb.nreseq = 0;
    tcb.reseqlen = 0;
    return -1;
}

fn logreseq(f: *Fs, r_: ?*Reseq, n_: u32) void {
    var n = n_;

    var r = r_;
    while (r) |rp| : (r = rp.next) {
        var s: ?[]const u8 = null;
        if (rp.next == null and rp.seg.seq != n)
            s = "hole/end"
        else if (rp.next == null)
            s = "end"
        else if (rp.seg.seq != n)
            s = "hole";
        if (s) |str|
            netlog(f, Logtcp, "%s %lud-%lud (%ld) %#ux\n", .{
                str,                                 n,            rp.seg.seq,
                @as(i32, @bitCast(rp.seg.seq -% n)), rp.seg.flags,
            });
        n = rp.seg.seq +% rp.seg.len;
    }
}

/// *bpp always consumed by addreseq
fn addreseq(f: *Fs, tcb: *Tcpctl, tpriv: *Tcppriv, seg: *const Tcp, bpp: *?*Block, length: u16) i32 {
    const rp = alloc.new(Reseq) orelse {
        freeblist(bpp.*); // *bpp always consumed by addreseq
        bpp.* = null;
        return 0;
    };
    rp.* = .{};

    rp.seg = seg.*;
    rp.bp = bpp.*;
    rp.length = length;
    bpp.* = null;

    tcb.reseqlen += length;
    tcb.nreseq += 1;

    // Place on reassembly list sorting by starting seq number
    var rr: *?*Reseq = &tcb.reseq;
    while (true) : (rr = &rr.*.?.next) {
        if (rr.* == null or seq_lt(seg.seq, rr.*.?.seg.seq)) {
            rp.next = rr.*;
            rr.* = rp;
            tpriv.stats[Resequenced] += 1;
            if (rp.next != null)
                tpriv.stats[OutOfOrder] += 1;
            break;
        }
    }

    var qmax: i32 = @bitCast(tcb.window);
    if (tcb.reseqlen > qmax) {
        netlog(f, Logtcp, "tcp: reseq: queue > window: %d > %d; %d packets\n", .{ tcb.reseqlen, qmax, tcb.nreseq });
        logreseq(f, tcb.reseq, tcb.rcv.nxt);
        tpriv.stats[ReseqBytelim] += 1;
        return dumpreseq(tcb);
    }
    qmax = @bitCast((tcb.window +% tcb.mss -% 1) / tcb.mss);
    if (tcb.nreseq > qmax) {
        netlog(f, Logtcp, "resequence queue > packets: %d %d; %d bytes\n", .{ tcb.nreseq, qmax, tcb.reseqlen });
        logreseq(f, tcb.reseq, tcb.rcv.nxt);
        tpriv.stats[ReseqPktlim] += 1;
        return dumpreseq(tcb);
    }

    return 0;
}

fn getreseq(tcb: *Tcpctl, seg: *Tcp, bp: *?*Block, length: *u16) i32 {
    const rp = tcb.reseq orelse
        return -1;
    if (seq_gt(rp.seg.seq, tcb.rcv.nxt))
        return -1;

    seg.* = rp.seg;
    bp.* = rp.bp;
    length.* = rp.length;

    tcb.reseq = rp.next;
    tcb.reseqlen -= rp.length;
    tcb.nreseq -= 1;

    alloc.free(rp);

    return 0;
}

fn tcptrim(tcb: *Tcpctl, seg: *Tcp, bp: *?*Block, length: *u16) i32 {
    var dupcnt: i32 = @bitCast(tcb.rcv.nxt -% seg.seq);
    if (dupcnt > 0) {
        if (seg.flags & SYN != 0) {
            seg.flags &= ~SYN;
            seg.seq +%= 1;
            dupcnt -= 1;
        }
        if (dupcnt >= length.*) {
            tcb.overlap +%= length.*;
            freeblist(bp.*);
            bp.* = null;
            return -1;
        }
        // 0 <= dupcnt < length here
        tcb.overlap +%= @as(u32, @intCast(dupcnt));
        _ = qio.pullblock(bp, @intCast(dupcnt));
        seg.seq +%= @as(u32, @intCast(dupcnt));
        length.* -= @as(u16, @intCast(dupcnt));
    }
    const excess: i32 = @bitCast(seg.seq +% length.* -% tcb.rcv.wptr);
    if (excess > 0) {
        if (excess >= length.*) {
            tcb.overlap +%= length.*;
            freeblist(bp.*);
            bp.* = null;
            return -1;
        }
        seg.flags &= ~FIN;
        // 0 < excess < length here
        tcb.overlap +%= @as(u32, @intCast(excess));
        length.* -= @as(u16, @intCast(excess));
        if (bp.*) |b|
            bp.* = qio.trimblock(b, 0, length.*);
    }
    if (bp.* == null)
        return -1;
    return 0;
}

fn tcpadvise(tcp: *Proto, bp: *Block, ifc: *Ipifc, msg: []const u8) void {
    var source: [IPaddrlen]u8 = undefined;
    var dest: [IPaddrlen]u8 = undefined;
    var psource: u16 = undefined;
    var pdest: u16 = undefined;

    const h4: *Tcp4hdr = @ptrCast(bp.rp);
    const h6: *Tcp6hdr = @ptrCast(bp.rp);

    if ((h4.vihl & 0xF0) == IP_VER4) {
        v4tov6(&dest, &h4.tcpdst);
        v4tov6(&source, &h4.tcpsrc);
        psource = nhgets(&h4.tcpsport);
        pdest = nhgets(&h4.tcpdport);
    } else {
        ipmove(&dest, &h6.tcpdst);
        ipmove(&source, &h6.tcpsrc);
        psource = nhgets(&h6.tcpsport);
        pdest = nhgets(&h6.tcpdport);
    }

    // Look for a connection (source/dest reversed; this is the original packet we sent)
    qlock(&tcp.qlock);
    raise: {
        const iph = iphtlook(tcp.ht.?, &dest, pdest, &source, psource) orelse
            break :raise;
        if (iph.match != ipdat.IPmatchexact)
            break :raise;
        if (iph.trans != 0) {
            const q = ipaux.transbackward(tcp, iph) orelse
                break :raise;

            // h4->tcplen is the ip header checksum
            hnputs_csum(h4.tcpsrc[0..2], nhgets(q.forward.raddr[IPv4off + 0 ..][0..2]), &h4.tcplen);
            hnputs_csum(h4.tcpsrc[2..4], nhgets(q.forward.raddr[IPv4off + 2 ..][0..2]), &h4.tcplen);

            // dont bother fixing tcp checksum, packet is most likely truncated
            hnputs(&h4.tcpsport, q.forward.rport);
            qunlock(&tcp.qlock);

            icmp.icmpproxyadvice(tcp.f.?, ifc, bp, &h4.tcpsrc);
            return;
        }
        const s = iphconv(iph);
        // Closed is the conversation's Idle here, as in C
        if (s.ignoreadvice or s.state == ipdat.Announced or s.state == Closed)
            break :raise;
        const tcb = tcbof(s);
        qlock(&s.qlock);
        qunlock(&tcp.qlock);
        if (tcb.state == Syn_sent)
            localclose(s, msg);
        qunlock(&s.qlock);
        freeblist(bp);
        return;
    }
    qunlock(&tcp.qlock);
    freeblist(bp);
}

fn tcpforward(tcp: *Proto, bp: *Block, r_: *Route) ?*Block {
    var da: [IPaddrlen]u8 = undefined;
    var sa: [IPaddrlen]u8 = undefined;
    var r: ?*Route = r_;

    if (BLEN(bp) < TCP4_PKT + TCP4_HDRSIZE) {
        freeblist(bp);
        return null;
    }

    const h4: *Tcp4hdr = @ptrCast(bp.rp);
    v4tov6(&da, &h4.tcpdst);
    v4tov6(&sa, &h4.tcpsrc);
    const dp = nhgets(&h4.tcpdport);
    const sp = nhgets(&h4.tcpsport);

    // don't make new translation when not syn packet
    if ((h4.tcpflag[1] & (ACK | RST | SYN | FIN)) != SYN)
        r = null;

    qlock(&tcp.qlock);
    const q = ipaux.transforward(tcp, &sa, sp, &da, dp, r) orelse {
        qunlock(&tcp.qlock);
        freeblist(bp);
        return null;
    };
    hnputs_csum(h4.tcpsrc[0..2], nhgets(q.backward.laddr[IPv4off + 0 ..][0..2]), &h4.tcpcksum);
    hnputs_csum(h4.tcpsrc[2..4], nhgets(q.backward.laddr[IPv4off + 2 ..][0..2]), &h4.tcpcksum);
    hnputs_csum(&h4.tcpsport, q.backward.lport, &h4.tcpcksum);
    qunlock(&tcp.qlock);

    return bp;
}

/// pkt is the packet from its IP header on.
pub fn tcpmssclamp(pkt: []u8, mtu: usize) void {
    var n: i32 = @intCast(pkt.len);
    var p: [*]u8 = undefined;
    var pcksum: *[2]u8 = undefined;
    var newmss: i32 = undefined;

    // DIFF: the C tests n < TCP4_PKT here and n < TCP6_PKT below, and
    // reads the flags beyond that; see the head of the file.
    if (n < TCP4_PKT + TCP4_HDRSIZE)
        return;
    const h4: *Tcp4hdr = @ptrCast(pkt.ptr);
    const h6: *Tcp6hdr = @ptrCast(pkt.ptr);
    if ((h4.vihl & 0xF0) == IP_VER4) {
        if (h4.proto != IP_TCPPROTO)
            return;
        if ((h4.frag[0] & (IP_FO >> 8)) | (h4.frag[1] & (IP_FO & 0xff)) != 0)
            return;
        if (h4.tcpflag[1] & SYN == 0)
            return;
        const hdrlen: i32 = (h4.tcpflag[0] >> 2) & ~@as(u8, 3);
        if (hdrlen > (n - TCP4_PKT))
            return;
        n = hdrlen - TCP4_HDRSIZE;
        p = opt4(h4);
        pcksum = &h4.tcpcksum;
        newmss = @as(i32, @intCast(mtu)) - (TCP4_PKT + TCP4_HDRSIZE);
    } else {
        if (n < TCP6_PKT + TCP6_HDRSIZE)
            return;
        if (h6.proto != IP_TCPPROTO)
            return;
        if (h6.tcpflag[1] & SYN == 0)
            return;
        const hdrlen: i32 = (h6.tcpflag[0] >> 2) & ~@as(u8, 3);
        if (hdrlen > (n - TCP6_PKT))
            return;
        n = hdrlen - TCP6_HDRSIZE;
        p = opt6(h6);
        pcksum = &h6.tcpcksum;
        newmss = @as(i32, @intCast(mtu)) - (TCP6_PKT + TCP6_HDRSIZE);
    }
    while (n > 0 and p[0] != EOLOPT) {
        if (p[0] == NOOPOPT) {
            n -= 1;
            p += 1;
            continue;
        }
        const optlen: i32 = p[1];
        if (optlen < 2 or optlen > n)
            break;
        if (p[0] == MSSOPT) {
            if (optlen != MSS_LENGTH)
                break;
            const oldmss: i32 = nhgets(p[2..4]);
            if (newmss >= oldmss)
                break;
            hnputs_csum(p[2..4], @truncate(@as(u32, @bitCast(newmss))), pcksum);
            break;
        }
        n -= optlen;
        p += @as(usize, @intCast(optlen));
    }
}

/// called with c qlocked
fn tcpctl(c: *Conv, f: []const []const u8) Error!void {
    const n = f.len;

    if (n == 1 and std.mem.eql(u8, f[0], "close"))
        return tcpclose(c);
    if (n == 1 and std.mem.eql(u8, f[0], "hangup"))
        return tcphangup(c);
    if (n >= 1 and std.mem.eql(u8, f[0], "keepalive"))
        return tcpstartka(c, f);
    return proc.errorf("unknown control request", .{});
}

fn tcpstats(tcp: *Proto, buf: []u8) usize {
    const tpriv = privof(tcp);

    tpriv.stats[InLimbo] = @bitCast(@as(i64, tpriv.nlimbo));

    var n: usize = 0;
    for (statnames, 0..) |name, i|
        n += fmt.snprint(buf[n..], "%s: %llud\n", .{ name, tpriv.stats[i] }).len;
    return n;
}

///  garbage collect any stale conversations:
///      - SYN received but no SYN-ACK after 5 seconds (could be the SYN attack)
///      - Finwait2 after 5 minutes
///
///  this is called whenever we run out of channels.  Both checks are
///  of questionable validity so we try to use them only when we're
///  up against the wall.
fn tcpgc(tcp: *Proto) bool {
    var n: usize = 0;
    const now = NOW();
    for (tcp.conv[0..tcp.nc]) |cp| {
        const c = cp orelse
            break;
        if (!canqlock(&c.qlock))
            continue;
        const tcb = tcbof(c);
        switch (tcb.state) {
            Syn_received => {
                if (now -% tcb.time > 5000) {
                    localclose(c, Etimedout);
                    n += 1;
                }
            },
            Finwait2 => {
                if (now -% tcb.time > 5 * 60 * 1000) {
                    localclose(c, Etimedout);
                    n += 1;
                }
            },
            else => {},
        }
        qunlock(&c.qlock);
    }
    return n != 0;
}

fn tcpsettimer(s: *Conv) void {
    const tcb = tcbof(s);

    tcb.time = NOW();
    tcb.timeuna = tcb.snd.una;

    // round trip dependency
    var x: i32 = tcb.mdev;
    x +%= tcb.srtt >> LOGAGAIN;
    x <<= @as(u5, @truncate(@as(u32, @bitCast(tcb.backoff))));

    // bounded twixt 0.3 and 64 seconds
    if (x < 300)
        x = 300
    else if (x > 64000)
        x = 64000;

    // reset the timer
    tcb.timer.start = @divTrunc(x + MSPTICK - 1, MSPTICK);
    if (tcb.timer.state == TcptimerON) {
        tcb.timer.count = tcb.timer.start;
    } else {
        const tpriv = privof(s.p.?);
        tcpgo(tpriv, &tcb.timer);
    }
}

pub fn tcpinit(fs: *Fs) void {
    const tcp = alloc.snew(Proto);
    tcp.* = .{};
    const tpriv = alloc.snew(Tcppriv);
    tpriv.* = .{};
    tcp.priv = tpriv;
    tcp.ht = &tpriv.ht;
    tcp.name = "tcp";
    tcp.connect = tcpconnect;
    tcp.announce = tcpannounce;
    tcp.ctl = tcpctl;
    tcp.state = tcpstate;
    tcp.create = tcpcreate;
    tcp.close = tcpclose;
    tcp.rcv = tcpiput;
    tcp.advise = tcpadvise;
    tcp.forward = tcpforward;
    tcp.stats = tcpstats;
    tcp.inuse = tcpinuse;
    tcp.gc = tcpgc;
    tcp.ipproto = IP_TCPPROTO;
    tcp.nc = devip.scalednconv();
    tcp.ptclsize = @sizeOf(Tcpctl);

    tpriv.stats[MaxConn] = tcp.nc;

    _ = devip.Fsproto(fs, tcp);
}

fn tcpsetmss(s: *Conv, mss: u16) void {
    const tcb = tcbof(s);

    // our sending max segment size cannot be bigger than what he asked for
    if (mss != 0 and mss < tcb.mss)
        tcb.mss = mss;

    // RFC 3390 initial window
    if (tcb.mss < 1095)
        tcb.cwind = 4 * @as(u32, tcb.mss)
    else if (tcb.mss < 2190)
        tcb.cwind = 4380
    else
        tcb.cwind = 2 * @as(u32, tcb.mss);
}

fn tcpsetscale(s: *Conv, scale_: u8) void {
    const tcb = tcbof(s);
    var scale = scale_;

    if (scale == 0)
        tcb.scale = 0
    else if (scale > 14)
        scale = 14; // RFC 7323 2.3

    tcb.rcv.scale = tcb.scale;
    tcb.window = @as(u32, QMAX) << sh(tcb.rcv.scale);
    qsetlimit(s.rq.?, @intCast(tcb.window));

    tcb.snd.scale = scale;
    var window: u32 = @as(u32, QMAX) << sh(tcb.snd.scale);
    if (window > tcb.window)
        window = tcb.window;
    tcb.ssthresh = window;
    qsetlimit(s.wq.?, @intCast(window));
}
