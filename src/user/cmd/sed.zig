//! sed -- stream editor
//! from cmd/sed.c
//!
//! DIFF:
//!   - The pattern space, the hold space, the work buffer and the text
//!     pool are rune arrays with lengths, not 0-terminated strings.
//!     Input lines cannot hold a 0 rune (gline drops it, as in C), so
//!     nothing changes; a script line is read through `at`, which gives
//!     0 past its end where the C reads its terminator.
//!   - Commands, labels and the pending appends are indices into their
//!     tables where the C has pointers, and SedCom's union is separate
//!     fields (re1, text, lb1, y's table).
//!   - The C's text() overruns fname[40] for a w file name of 40 bytes
//!     or more; here the name is cut at 39.  ycomp's table is indexed
//!     by the source character after a backslash that is not \n, which
//!     can be past the table in the C; here that is "y command garbled".
//!   - quit's %S takes a rune slice (RuneStr).
//!
//! Kept from the C: `c` prints its text only on a range's first line
//! (and never with no address); `N` at the end of the input deletes the
//! pattern space unprinted; `P` (and s///P) writes each rune's low byte;
//! s///P with a w file does not write the file; a w file is opened for
//! appending, not truncated; `w` with an empty name is standard output;
//! labels are at most 7 runes, and b/t labels run to ; or the end.

const std = @import("std");
const libc = @import("libc");
const re = libc.regexp;

const Rune = libc.Rune;
const Runemax = libc.Runemax;
const Reprog = re.Reprog;
const Biobuf = libc.Biobuf;

const DEPTH = 20; // max nesting depth of {}
const MAXCMDS = 512; // max sed commands
const ADDSIZE = 10000; // size of add & read buffer
const MAXADDS = 20; // max pending adds and reads
const LBSIZE = 32768; // input line size
const LABSIZE = 50; // max number of labels
const MAXSUB = 10; // max number of sub reg exp
const MAXFILES = 120; // max output files

/// An address is a line #, a R.E., "$", a reference to the last
/// R.E., or nothing.
const Addr = union(enum) {
    none,
    dol,
    line: i64, // Line #
    re: ?*Reprog, // Compiled R.E.; null for // before any R.E., as the C's lastre
    last,
};

const Cmd = enum {
    end, // the C's 0: past the last command
    acom,
    bcom,
    ccom,
    cdcom,
    cncom,
    cpcom,
    dcom,
    eqcom,
    gcom,
    cgcom,
    hcom,
    chcom,
    icom,
    lcom,
    ncom,
    pcom,
    qcom,
    rcom,
    scom,
    tcom,
    wcom,
    xcom,
    ycom,
};

const SedCom = struct {
    ad1: Addr = .none, // optional start address
    ad2: Addr = .none, // optional end address
    re1: ?*Reprog = null, // compiled R.E.
    text: []const Rune = &.{}, // added text or file name
    ytab: []const Rune = &.{}, // y's table, indexed by rune
    lb1: ?u32 = null, // destination command of branch
    rhs: []const Rune = &.{}, // Right-hand side of substitution
    fcode: ?*Biobuf = null, // File ID for read and write
    command: Cmd = .end, // command code
    gfl: bool = false, // 'Global' flag for substitutions
    pfl: u8 = 0, // 'print' flag for substitutions
    active: u8 = 0, // 1 => data between start and end
    negfl: bool = false, // negation flag
};

const Label = struct { // Label symbol table
    uninm: [9]Rune = @splat(0), // Label name
    len: usize = 0,
    chain: ?u32 = null,
    address: ?u32 = null, // Command associated with label

    fn name(l: *const Label) []const Rune {
        return l.uninm[0..l.len];
    }
};

var pspace: [MAXCMDS]SedCom = @splat(.{}); // Command storage
var rep: u32 = 0; // Current fill point

var dollars: u32 = 0; // Number of dollar (first) addresses

var lastre: ?*Reprog = null; // Last regular expression
var subexp: [MAXSUB]re.Resub = @splat(.{}); // sub-patterns of pattern match

var addspace: [ADDSIZE]Rune = undefined; // Buffer for a, c, & i commands
var addp: usize = 0; // the C's static p in fcomp

var abuf: [MAXADDS]u32 = undefined; // Queue of pending adds & reads
var naptr: usize = 0;

/// Sed program input control block
const Prog = union(enum) {
    arg: ?[]const u8, // what is left of the -e string; null after it
    file: *Biobuf,
};
var prog: Prog = .{ .arg = null };

var genbuf: [LBSIZE + 1]Rune = undefined; // Miscellaneous buffer

var fq: std.ArrayList(?[]const u8) = .empty; // the C's FileCache chain
var fqi: usize = 0;

var loc1: ?usize = null; // Start of pattern match
var loc2: ?usize = null; // End of pattern match
var seof: Rune = 0; // Pattern delimiter char

var linebuf: [LBSIZE + 1]Rune = undefined; // Input data buffer
const lbend = LBSIZE; // End of buffer
var spend: usize = 0; // End of input data
var cp: usize = 0; // Current scan point in linebuf
var linelen: usize = 0; // DIFF: the script line's length while compiling

var holdsp: [LBSIZE + 1]Rune = undefined; // Hold buffer
const hend = LBSIZE; // End of hold buffer
var hspend: usize = 0; // End of hold data

var nflag = false; // Command line flags
var gflag = false;
var uflag = false;

var dolflag = false; // Set when at true EOF
var sflag = false; // Set when substitution done
var jflag = false; // Set when jump required
var delflag = false; // Delete current line when set

var lnum: i32 = 0; // Input line count

// one more than MAXFILES: the C writes the name in before it counts
var fnamebuf: [MAXFILES + 1][40]u8 = undefined; // File name cache
var fnamelen: [MAXFILES + 1]usize = @splat(0);
var fcode: [MAXFILES]*Biobuf = undefined; // File ID cache
var nfiles: usize = 0; // Cache fill point

var fout: Biobuf = .{}; // Output stream
var stdin: Biobuf = .{}; // Default input
var f: ?*Biobuf = null; // Input data
var fbuf: Biobuf = .{}; // DIFF: the Bopen'd input file

var ltab: [LABSIZE]Label = @splat(.{}); // Label name symbol table
var lab: usize = 1; // Current Fill point

var depth: usize = 0; // {} stack pointer

const CGMES = "%S command garbled: %S";
const TMMES = "Too much text: %S";
const LTL = "Label too long: %S";
const AD0MES = "No addresses allowed: %S";
const AD1MES = "Only one address allowed: %S";

const a = libc.allocator;

/// A rune string for quit's %S.
const RuneStr = struct {
    s: []const Rune,

    pub fn fmt9(self: RuneStr, fm: *libc.fmt.Fmt) void {
        for (self.s) |r| {
            if (r == 0) break;
            var b: [libc.UTFmax]u8 = undefined;
            fm.puts(b[0..libc.runetochar(&b, r)]);
        }
    }
};

fn rs(s: []const Rune) RuneStr {
    return .{ .s = s };
}

fn lit(comptime s: []const u8) RuneStr {
    const t = comptime blk: {
        var r: [s.len]Rune = undefined;
        for (s, 0..) |c, i| r[i] = c;
        break :blk r;
    };
    return .{ .s = &t };
}

/// The script line being compiled, as %S prints it.
fn lb() RuneStr {
    return rs(linebuf[0..linelen]);
}

/// The script line's rune at i; past its end, the C's terminator.
fn at(i: usize) Rune {
    return if (i < linelen) linebuf[i] else 0;
}

pub fn main(argv: []const []const u8) void {
    lnum = 0;
    fout.init(1, libc.OWRITE);
    fcode[nfiles] = &fout;
    fnamelen[nfiles] = 0;
    nfiles += 1;
    var compfl = false;

    if (argv.len == 1)
        libc.exits(null);
    var args = libc.Args.init(argv);
    while (args.next()) |c| {
        // the C's argc here counts the current argument and those after
        const argc = argv.len - args.i;
        switch (c) {
            'e' => {
                if (argc <= 1)
                    quit("missing pattern", .{});
                newfile(.{ .arg = args.value() });
                fcomp();
                compfl = true;
            },
            'f' => {
                if (argc <= 1)
                    quit("no pattern-file", .{});
                newfile(.{ .file = openpattern(args.value()) });
                fcomp();
                compfl = true;
            },
            'g' => gflag = true,
            'n' => nflag = true,
            'u' => uflag = true,
            'E', 'r' => {}, // unix compat
            else => quit("Unknown flag: %c", .{c}),
        }
    }
    var rest = args.rest();

    if (!compfl) {
        if (rest.len == 0)
            quit("missing pattern", .{});
        newfile(.{ .arg = rest[0] });
        rest = rest[1..];
        fcomp();
    }

    if (depth != 0)
        quit("Too many {'s", .{});

    ltab[0].address = rep;

    dechain();

    if (rest.len == 0)
        enroll(null) // Add stdin to cache
    else for (rest) |name|
        enroll(name);
    execute();
    libc.exits(null);
}

fn fcomp() void {
    var cmpend: [DEPTH]u32 = undefined; // stack of {} operations

    lines: while (rline()) {
        cp = 0;
        comploop: while (true) {
            while (at(cp) == ' ' or at(cp) == '\t')
                cp += 1;
            if (at(cp) == 0 or at(cp) == '#')
                continue :lines;
            if (at(cp) == ';') {
                cp += 1;
                continue :comploop;
            }

            const r = &pspace[rep];
            address(&r.ad1);
            if (r.ad1 != .none) {
                if (r.ad1 == .dol)
                    dollars += 1;
                if (r.ad1 == .last) {
                    r.ad1 = .{ .re = lastre orelse quit("First RE may not be null", .{}) };
                }
                if (at(cp) == ',' or at(cp) == ';') {
                    cp += 1;
                    address(&r.ad2);
                    if (r.ad2 == .last) {
                        // the C takes lastre as it is, nil or not
                        r.ad2 = .{ .re = lastre };
                    }
                } else r.ad2 = .none;
            }

            swit: while (true) {
                while (at(cp) == ' ' or at(cp) == '\t')
                    cp += 1;
                const c = at(cp);
                cp += 1;
                const rp = &pspace[rep];
                switch (c) {
                    '!' => {
                        rp.negfl = true;
                        continue :swit;
                    },
                    '{' => {
                        rp.command = .bcom;
                        rp.negfl = !rp.negfl;
                        cmpend[depth] = rep;
                        depth += 1;
                        rep += 1;
                        if (rep >= MAXCMDS)
                            quit("Too many commands: %S", .{lb()});
                        if (at(cp) == 0)
                            continue :lines;
                        continue :comploop;
                    },
                    '}' => {
                        if (rp.ad1 != .none)
                            quit(AD0MES, .{lb()});
                        if (depth == 0)
                            quit("Too many }'s", .{});
                        depth -= 1;
                        pspace[cmpend[depth]].lb1 = rep;
                        if (at(cp) == 0)
                            continue :lines;
                        continue :comploop;
                    },
                    '=' => {
                        rp.command = .eqcom;
                        if (rp.ad2 != .none)
                            quit(AD1MES, .{lb()});
                    },
                    ':' => {
                        if (rp.ad1 != .none)
                            quit(AD0MES, .{lb()});

                        while (at(cp) == ' ')
                            cp += 1;
                        const l = &ltab[lab];
                        l.len = 0;
                        while (at(cp) != 0 and at(cp) != ';' and at(cp) != ' ' and
                            at(cp) != '\t' and at(cp) != '#')
                        {
                            l.uninm[l.len] = at(cp);
                            l.len += 1;
                            cp += 1;
                            if (l.len >= 8)
                                quit(LTL, .{lb()});
                        }

                        if (l.len == 0) // no label?
                            quit(CGMES, .{ lit(":"), lb() });
                        var lpt: usize = undefined;
                        if (search(lab)) |x| {
                            lpt = x;
                            if (ltab[lpt].address != null)
                                quit("Duplicate labels: %S", .{lb()});
                        } else {
                            l.chain = null;
                            lpt = lab;
                            lab += 1;
                            if (lab >= LABSIZE)
                                quit("Too many labels: %S", .{lb()});
                        }
                        ltab[lpt].address = rep;
                        if (at(cp) == '#')
                            continue :lines;
                        rep -%= 1; // reuse this slot
                    },
                    'a', 'c', 'i' => {
                        rp.command = switch (c) {
                            'a' => .acom,
                            'c' => .ccom,
                            else => .icom,
                        };
                        if (c != 'c' and rp.ad2 != .none)
                            quit(AD1MES, .{lb()});
                        if (at(cp) == '\\')
                            cp += 1;
                        const n = at(cp);
                        cp += 1;
                        if (n != '\n') switch (c) {
                            'a' => quit(CGMES, .{ lit("a"), lb() }),
                            'c' => quit(CGMES, .{ lit("c"), lb() }),
                            else => quit(CGMES, .{ lit("i"), lb() }),
                        };
                        rp.text = stext();
                    },
                    'g' => rp.command = .gcom,
                    'G' => rp.command = .cgcom,
                    'h' => rp.command = .hcom,
                    'H' => rp.command = .chcom,
                    't', 'b' => {
                        rp.command = if (c == 't') .tcom else .bcom;
                        while (at(cp) == ' ')
                            cp += 1;
                        if (at(cp) == 0 or at(cp) == ';') {
                            // no label; jump to end
                            if (ltab[0].chain) |first| {
                                var pt = first;
                                while (pspace[pt].lb1) |pt1|
                                    pt = pt1;
                                pspace[pt].lb1 = rep;
                            } else ltab[0].chain = rep;
                            break :swit;
                        }

                        // copy label into lab->uninm
                        const l = &ltab[lab];
                        l.len = 0;
                        while (true) {
                            const x = at(cp);
                            cp += 1;
                            if (x == 0 or x == ';')
                                break;
                            l.uninm[l.len] = x;
                            l.len += 1;
                            if (l.len >= 8)
                                quit(LTL, .{lb()});
                        }
                        cp -= 1;

                        if (l.len == 0) // shouldn't get here
                            quit(CGMES, .{ lit("b or t"), lb() });
                        if (search(lab)) |lpt| {
                            if (ltab[lpt].address) |addr|
                                rp.lb1 = addr
                            else {
                                var pt = ltab[lpt].chain;
                                while (pt) |p| {
                                    const pt1 = pspace[p].lb1 orelse break;
                                    pt = pt1;
                                }
                                if (pt) |p|
                                    pspace[p].lb1 = rep;
                            }
                        } else { // add new label
                            l.chain = rep;
                            l.address = null;
                            lab += 1;
                            if (lab >= LABSIZE)
                                quit("Too many labels: %S", .{lb()});
                        }
                    },
                    'n' => rp.command = .ncom,
                    'N' => rp.command = .cncom,
                    'p' => rp.command = .pcom,
                    'P' => rp.command = .cpcom,
                    'r' => {
                        rp.command = .rcom;
                        if (rp.ad2 != .none)
                            quit(AD1MES, .{lb()});
                        const n = at(cp);
                        cp += 1;
                        if (n != ' ')
                            quit(CGMES, .{ lit("r"), lb() });
                        rp.text = stext();
                    },
                    'd' => rp.command = .dcom,
                    'D' => {
                        rp.command = .cdcom;
                        rp.lb1 = 0;
                    },
                    'q' => {
                        rp.command = .qcom;
                        if (rp.ad2 != .none)
                            quit(AD1MES, .{lb()});
                    },
                    'l' => rp.command = .lcom,
                    's' => {
                        rp.command = .scom;
                        seof = at(cp);
                        cp += 1;
                        rp.re1 = compile() orelse
                            (lastre orelse quit("First RE may not be null", .{}));
                        rp.rhs = compsub() orelse quit(CGMES, .{ lit("s"), lb() });
                        if (at(cp) == 'g') {
                            cp += 1;
                            rp.gfl = true;
                        } else if (gflag)
                            rp.gfl = true;

                        if (at(cp) == 'p') {
                            cp += 1;
                            rp.pfl = 1;
                        }

                        if (at(cp) == 'P') {
                            cp += 1;
                            rp.pfl = 2;
                        }

                        if (at(cp) == 'w') {
                            cp += 1;
                            const n = at(cp);
                            cp += 1;
                            if (n != ' ')
                                quit(CGMES, .{ lit("s"), lb() });
                            rp.fcode = wfile(false);
                        }
                    },
                    'w' => {
                        rp.command = .wcom;
                        const n = at(cp);
                        cp += 1;
                        if (n != ' ')
                            quit(CGMES, .{ lit("w"), lb() });
                        rp.fcode = wfile(true);
                    },
                    'x' => rp.command = .xcom,
                    'y' => {
                        rp.command = .ycom;
                        seof = at(cp);
                        cp += 1;
                        if (!ycomp(rp))
                            quit(CGMES, .{ lit("y"), lb() });
                    },
                    else => quit("Unrecognized command: %S", .{lb()}),
                }
                break :swit;
            }
            // done:
            rep +%= 1;
            if (rep >= MAXCMDS)
                quit("Too many commands, last: %S", .{lb()});
            const n = at(cp);
            cp += 1;
            if (n != 0) {
                if (n == ';')
                    continue :comploop;
                quit(CGMES, .{ rs(linebuf[cp - 1 .. @max(cp - 1, linelen)]), lb() });
            }
            continue :lines;
        }
    }
}

/// The file of a w command or s///w: the one already open under the
/// same name, or a new one.  `w` says which message to give when there
/// are too many.
fn wfile(w: bool) *Biobuf {
    text(nfiles);
    var i = nfiles;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, fname(nfiles), fname(i)))
            return fcode[i];
    }
    if (nfiles >= MAXFILES) {
        if (!w)
            quit("Too many files in w commands 1", .{});
        libc.fprint(2, "sed: Too many files in w commands 2 \n", .{});
        libc.fprint(2, "nfiles = %d; MAXF = %d\n", .{ nfiles, MAXFILES });
        errexit();
    }
    return open_file(fname(nfiles));
}

fn fname(i: usize) []const u8 {
    return fnamebuf[i][0..fnamelen[i]];
}

fn open_file(name: []const u8) *Biobuf {
    const bp = a.create(Biobuf) catch quit("Out of memory", .{});
    bp.* = .{};
    const fd = libc.open(name, libc.OWRITE) catch
        libc.create(name, libc.OWRITE, 0o666) catch
        quit("Cannot create %s", .{name});
    bp.init(fd, libc.OWRITE);
    _ = bp.seek(0, 2);
    fcode[nfiles] = bp;
    nfiles += 1;
    return bp;
}

/// The right-hand side of a substitution, into the text pool: a
/// backslash becomes Runemax before the character it quotes (\n a
/// newline).  Null when the pool is full or the line ends first.
fn compsub() ?[]const Rune {
    const start = addp;
    while (true) {
        var r = at(cp);
        cp += 1;
        if (r == 0)
            return null;
        if (r == '\\') {
            if (addp < ADDSIZE) {
                addspace[addp] = Runemax;
                addp += 1;
            } else return null;
            r = at(cp);
            cp += 1;
            if (r == 'n')
                r = '\n';
        } else if (r == seof) {
            if (addp < ADDSIZE) {
                addspace[addp] = 0;
                addp += 1;
            } else return null;
            return addspace[start .. addp - 1];
        }
        if (addp < ADDSIZE) {
            addspace[addp] = r;
            addp += 1;
        } else return null;
    }
}

/// The regular expression up to seof, compiled; null for an empty one
/// (the last R.E.).
fn compile() ?*Reprog {
    var expbuf: [512]u8 = undefined;
    var ep: usize = 0;
    var c = at(cp);
    cp += 1;
    if (c == seof) // L'//'
        return null;
    while (true) {
        if (c == 0 or c == '\n')
            quit(TMMES, .{lb()});
        if (c == '\\') {
            if (ep >= expbuf.len - libc.UTFmax)
                quit(TMMES, .{lb()});
            ep += libc.runetochar(expbuf[ep..], c);
            c = at(cp);
            cp += 1;
            if (c == 'n')
                c = '\n';
        }
        // DIFF: the C checks ep against the buffer's end before writing
        // up to UTFmax bytes; this leaves the room
        if (ep >= expbuf.len - libc.UTFmax)
            quit(TMMES, .{lb()});
        ep += libc.runetochar(expbuf[ep..], c);
        c = at(cp);
        cp += 1;
        if (c == seof)
            break;
    }
    var diag: re.Diag = .{};
    const exp = a.dupe(u8, expbuf[0..ep]) catch quit("Out of memory", .{});
    lastre = re.regcomp(a, exp, &diag) catch regerror();
    return lastre;
}

fn regerror() noreturn {
    quit(CGMES, .{ lit("r.e.-using"), lb() });
}

fn flushout(bp: *Biobuf, v: []u8) isize {
    for (fcode[0..nfiles]) |b|
        b.flush() catch {};
    return libc.sys.read(bp.fid, v);
}

fn openpattern(name_: ?[]const u8) *Biobuf {
    const name = name_ orelse quit("Cannot open pattern-file: %s\n", .{"<nil>"});
    const bp = a.create(Biobuf) catch quit("Out of memory", .{});
    bp.* = .{};
    bp.open(name, libc.OREAD) catch quit("Cannot open pattern-file: %s\n", .{name});
    if (uflag)
        bp.setiofn(flushout);
    return bp;
}

fn newfile(p: Prog) void {
    prog = p;
}

/// The next script line into linebuf, a backslash keeping the
/// character after it (a newline too); false at the end, which drops a
/// last line with no newline.
fn rline() bool {
    var n: usize = 0;
    defer linelen = n;
    while (getrune()) |c_| {
        var r = c_;
        if (r == '\\') {
            if (n <= lbend) {
                linebuf[n] = r;
                n += 1;
            }
            r = getrune() orelse break;
        } else if (r == '\n') {
            return true;
        }
        if (n <= lbend) {
            linebuf[n] = r;
            n += 1;
        }
    }
    return false;
}

/// The next rune of the script, or null at its end.
fn getrune() ?Rune {
    switch (prog) {
        .arg => |*p| {
            const s = p.* orelse return null;
            if (s.len > 0 and s[0] != 0) {
                const d = libc.chartorune(s);
                p.* = s[d.n..];
                return d.r;
            }
            p.* = null;
            return '\n'; // fake an end-of-line
        },
        .file => |bp| {
            if (bp.getrune()) |r|
                return r;
            bp.term() catch {};
            return null;
        },
    }
}

fn address(ap: *Addr) void {
    const c = at(cp);
    cp += 1;
    if (c == '$')
        ap.* = .dol
    else if (c == '/') {
        seof = c;
        ap.* = if (compile()) |p| .{ .re = p } else .last;
    } else if (c >= '0' and c <= '9') {
        var lno: i64 = c - '0';
        while (at(cp) >= '0' and at(cp) <= '9') {
            lno = lno *% 10 +% (at(cp) - '0');
            cp += 1;
        }
        if (lno == 0)
            quit("line number 0 is illegal", .{});
        ap.* = .{ .line = lno };
    } else {
        cp -= 1;
        ap.* = .none;
    }
}

/// The file name of a w command into fname[i], as UTF-8: blanks skipped
/// first, a backslash quoting the next rune, blanks after a newline
/// skipped.
fn text(i: usize) void {
    var p: usize = 0;
    const buf = &fnamebuf[i];
    while (at(cp) == ' ' or at(cp) == '\t')
        cp += 1;
    while (at(cp) != 0) {
        var r = at(cp);
        cp += 1;
        if (r == '\\') {
            r = at(cp);
            cp += 1;
            if (r == 0)
                break;
        }
        if (r == '\n') {
            while (at(cp) == ' ' or at(cp) == '\t')
                cp += 1;
        }
        var b: [libc.UTFmax]u8 = undefined;
        const n = libc.runetochar(&b, r);
        if (p + n <= buf.len - 1) {
            @memcpy(buf[p..][0..n], b[0..n]);
            p += n;
        }
    }
    fnamelen[i] = p;
}

/// Text for a, c, i and r into the pool: blanks skipped first, a
/// backslash quoting the next rune, blanks after a newline skipped.
fn stext() []const Rune {
    while (at(cp) == ' ' or at(cp) == '\t')
        cp += 1;
    const start = addp;
    while (at(cp) != 0) {
        if (at(cp) == '\\') {
            cp += 1;
            if (at(cp) == 0)
                break;
        }
        if (addp >= ADDSIZE - 1)
            quit(TMMES, .{lb()});
        const r = at(cp);
        addspace[addp] = r;
        addp += 1;
        cp += 1;
        if (r == '\n') {
            while (at(cp) == ' ' or at(cp) == '\t')
                cp += 1;
        }
    }
    addspace[addp] = 0;
    addp += 1;
    return addspace[start .. addp - 1];
}

fn search(ptr: usize) ?usize {
    for (ltab[0..ptr], 0..) |*l, i| {
        if (std.mem.eql(Rune, l.name(), ltab[ptr].name()))
            return i;
    }
    return null;
}

fn dechain() void {
    for (ltab[0..lab]) |*l| {
        const addr = l.address orelse quit("Undefined label: %S", .{rs(l.name())});
        if (l.chain) |first| {
            var rptr = first;
            while (pspace[rptr].lb1) |trptr| {
                pspace[rptr].lb1 = addr;
                rptr = trptr;
            }
            pspace[rptr].lb1 = addr;
        }
    }
}

/// y/source/dest/: a table from each rune up to the highest in source.
fn ycomp(r: *SedCom) bool {
    var highc: Rune = 0;
    var tsp = cp;
    while (at(tsp) != seof) : (tsp += 1) {
        if (at(tsp) == '\\')
            tsp += 1;
        if (at(tsp) == '\n' or at(tsp) == 0)
            return false;
        if (at(tsp) > highc)
            highc = at(tsp);
    }
    tsp += 1;
    const t = a.alloc(Rune, @as(usize, highc) + 1) catch quit("Out of memory", .{});
    for (t, 0..) |*x, i| x.* = @intCast(i);
    var sp = cp;
    while (true) {
        var c = at(sp);
        sp += 1;
        if (c == seof)
            break;
        if (c == '\\' and at(sp) == 'n') {
            sp += 1;
            c = '\n';
        }
        if (c > highc) // DIFF: past the C's table; see the header
            return false;
        t[c] = at(tsp);
        tsp += 1;
        if (t[c] == '\\' and at(tsp) == 'n') {
            t[c] = '\n';
            tsp += 1;
        }
        if (t[c] == seof or t[c] == 0)
            return false;
    }
    if (at(tsp) != seof)
        return false;
    r.ytab = t;
    cp = tsp + 1;
    return true;
}

fn execute() void {
    while (gline(0)) |e| {
        spend = e;
        var ipc: u32 = 0;
        while (pspace[ipc].command != .end) {
            if (!executable(&pspace[ipc])) {
                ipc += 1;
                continue;
            }
            command(&pspace[ipc]);

            if (delflag)
                break;
            if (jflag) {
                jflag = false;
                ipc = pspace[ipc].lb1 orelse break;
            } else ipc += 1;
        }
        if (!nflag and !delflag)
            putline(&fout, linebuf[0..spend]);
        if (naptr > 0)
            arout();
        delflag = false;
    }
}

/// determine if a statement should be applied to an input line
fn executable(ipc: *SedCom) bool {
    if (ipc.active != 0) { // Addr1 satisfied - accept until Addr2
        if (ipc.active == 1) // Second line
            ipc.active = 2;
        switch (ipc.ad2) {
            .none => ipc.active = 0, // No second addr; use first
            .dol => return !ipc.negfl, // Accept everything
            .line => |l| { // Line at end of range?
                if (lnum <= l) {
                    if (l == lnum)
                        ipc.active = 0;
                    return !ipc.negfl;
                }
                ipc.active = 0; // out of range
                return ipc.negfl;
            },
            .re => |p| { // Check for matching R.E.
                if (match(p, 0))
                    ipc.active = 0;
                return !ipc.negfl;
            },
            .last => quit("Internal error", .{}),
        }
    }
    switch (ipc.ad1) { // Check first address
        .none => return !ipc.negfl, // Everything matches
        .dol => { // Only last line
            if (dolflag)
                return !ipc.negfl;
        },
        .line => |l| { // Check line number
            if (l == lnum) {
                ipc.active = 1; // In range
                return !ipc.negfl;
            }
        },
        .re => |p| { // Check R.E.
            if (match(p, 0)) {
                ipc.active = 1; // In range
                return !ipc.negfl;
            }
        },
        .last => quit("Internal error", .{}),
    }
    return ipc.negfl;
}

/// Match pattern in the pattern space from offset buf.
fn match(pattern: ?*Reprog, buf: usize) bool {
    const p = pattern orelse return false;
    subexp[0].sp = buf;
    subexp[0].ep = null;
    if (p.rexec(linebuf[0..spend], &subexp)) {
        loc1 = subexp[0].sp;
        loc2 = subexp[0].ep;
        return true;
    }
    loc1 = null;
    loc2 = null;
    return false;
}

fn substitute(ipc: *SedCom) bool {
    if (!match(ipc.re1, 0))
        return false;

    // we have at least one match.  some patterns, e.g. '$' or '^', can
    // produce 0-length matches, so during a global substitute we must
    // bump to the character after a 0-length match to keep from looping.
    sflag = true;
    if (!ipc.gfl) // single substitution
        dosub(ipc.rhs)
    else while (true) { // global substitution
        const len = loc2.? - loc1.?; // length of match
        dosub(ipc.rhs); // dosub moves loc2
        if (loc2.? >= spend) // end of string
            break;
        if (len == 0) // zero-length R.E. match
            loc2.? += 1; // bump over 0-length match
        if (loc2.? >= spend) // end of string
            break;
        if (!match(ipc.re1, loc2.?))
            break;
    }
    return true;
}

fn outlong(sp: usize) void {
    if (sp >= LBSIZE)
        quit("Output line too long", .{});
}

fn dosub(rhsbuf: []const Rune) void {
    var sp: usize = 0;
    @memcpy(genbuf[0..loc1.?], linebuf[0..loc1.?]);
    sp = loc1.?;
    var i: usize = 0;
    while (i < rhsbuf.len) {
        var c = rhsbuf[i];
        i += 1;
        if (c == '&') {
            sp = place(sp, loc1.?, loc2.?);
            continue;
        }
        if (c == Runemax) {
            c = if (i < rhsbuf.len) rhsbuf[i] else 0;
            i += 1;
            if (c >= '1' and c < MAXSUB + '0') {
                const n = c - '0';
                if (subexp[n].sp != null and subexp[n].ep != null) {
                    sp = place(sp, subexp[n].sp.?, subexp[n].ep.?);
                    continue;
                } else quit("Invalid back reference \\%d", .{n});
            }
            if (c == 0) // the rhs ended after the backslash
                break;
        }
        genbuf[sp] = c;
        sp += 1;
        outlong(sp);
    }
    const lp = loc2.?;
    loc2 = sp;
    for (linebuf[lp..spend]) |r| {
        genbuf[sp] = r;
        sp += 1;
        outlong(sp);
    }
    @memcpy(linebuf[0..sp], genbuf[0..sp]);
    spend = sp;
}

fn place(sp_: usize, l1: usize, l2: usize) usize {
    var sp = sp_;
    for (linebuf[l1..l2]) |r| {
        genbuf[sp] = r;
        sp += 1;
        outlong(sp);
    }
    return sp;
}

/// How `l` shows c: an escape, or \x and four hex digits.
fn trans(c: Rune, buf: *[6]u8) []const u8 {
    switch (c) {
        0x08 => return "\\b",
        '\n' => return "\\n",
        '\r' => return "\\r",
        '\t' => return "\\t",
        '\\' => return "\\\\",
        else => {},
    }
    const hex = "0123456789abcdef";
    buf.* = "\\x0000".*;
    buf[2] = hex[(c >> 12) & 0xF];
    buf[3] = hex[(c >> 8) & 0xF];
    buf[4] = hex[(c >> 4) & 0xF];
    buf[5] = hex[c & 0xF];
    return buf;
}

fn putc(c: u8) void {
    fout.putc(c) catch {};
}

fn putrunes(s: []const Rune) void {
    for (s) |r|
        _ = fout.putrune(r) catch {};
}

fn cpcom() void {
    for (linebuf[0..spend]) |r| {
        if (r == '\n')
            break;
        putc(@truncate(r)); // the C's Bputc of a rune
    }
    putc('\n');
}

fn command(ipc: *SedCom) void {
    switch (ipc.command) {
        .acom => {
            abuf[naptr] = @intCast(ipc - &pspace[0]);
            naptr += 1;
            if (naptr >= MAXADDS)
                quit("Too many appends after line %ld", .{lnum});
        },
        .ccom => {
            delflag = true;
            if (ipc.active == 1) {
                putrunes(ipc.text);
                putc('\n');
            }
        },
        .dcom => delflag = true,
        .cdcom => {
            const nl = std.mem.findScalar(Rune, linebuf[0..spend], '\n') orelse {
                delflag = true;
                return;
            };
            const rest = spend - (nl + 1);
            std.mem.copyForwards(Rune, linebuf[0..rest], linebuf[nl + 1 .. spend]);
            spend = rest;
            jflag = true;
        },
        .eqcom => fout.print("%ld\n", .{lnum}) catch {},
        .gcom => {
            @memcpy(linebuf[0..hspend], holdsp[0..hspend]);
            spend = hspend;
        },
        .cgcom => {
            linebuf[spend] = '\n';
            spend += 1;
            // copying stops at lbend, which drops the rune there
            const room = lbend - spend;
            if (hspend >= room) {
                @memcpy(linebuf[spend..lbend], holdsp[0..room]);
                spend = lbend - 1;
            } else {
                @memcpy(linebuf[spend..][0..hspend], holdsp[0..hspend]);
                spend += hspend;
            }
        },
        .hcom => {
            @memcpy(holdsp[0..spend], linebuf[0..spend]);
            hspend = spend;
        },
        .chcom => {
            holdsp[hspend] = '\n';
            hspend += 1;
            const room = hend - hspend;
            if (spend >= room) {
                @memcpy(holdsp[hspend..hend], linebuf[0..room]);
                hspend = hend - 1;
            } else {
                @memcpy(holdsp[hspend..][0..spend], linebuf[0..spend]);
                hspend += spend;
            }
        },
        .icom => {
            putrunes(ipc.text);
            putc('\n');
        },
        .bcom => jflag = true,
        .lcom => {
            var c: Rune = 0;
            var i: u32 = 0;
            for (linebuf[0..spend]) |r| {
                c = r;
                if (c >= 0x20 and c < 0x7F and c != '\\') {
                    putc(@intCast(c));
                    if (i > 71) {
                        fout.print("\\\n", .{}) catch {};
                        i = 0;
                    } else i += 1;
                } else {
                    var tb: [6]u8 = undefined;
                    for (trans(r, &tb)) |u| {
                        c = u;
                        putc(u);
                        if (i > 71) {
                            fout.print("\\\n", .{}) catch {};
                            i = 0;
                        } else i += 1;
                    }
                }
            }
            if (c == ' ')
                fout.print("\\n", .{}) catch {};
            putc('\n');
        },
        .ncom => {
            if (!nflag)
                putline(&fout, linebuf[0..spend]);

            if (naptr > 0)
                arout();
            const e = gline(0) orelse {
                delflag = true;
                return;
            };
            spend = e;
        },
        .cncom => {
            if (naptr > 0)
                arout();
            linebuf[spend] = '\n';
            spend += 1;
            const e = gline(spend) orelse {
                delflag = true;
                return;
            };
            spend = e;
        },
        .pcom => putline(&fout, linebuf[0..spend]),
        .cpcom => cpcom(),
        .qcom => {
            if (!nflag)
                putline(&fout, linebuf[0..spend]);
            if (naptr > 0)
                arout();
            libc.exits(null);
        },
        .rcom => {
            abuf[naptr] = @intCast(ipc - &pspace[0]);
            naptr += 1;
            if (naptr >= MAXADDS)
                quit("Too many reads after line %ld", .{lnum});
        },
        .scom => {
            const i = substitute(ipc);
            if (i and ipc.pfl != 0) {
                if (ipc.pfl == 1)
                    putline(&fout, linebuf[0..spend])
                else
                    return cpcom();
            }
            if (i and ipc.fcode != null)
                putline(ipc.fcode.?, linebuf[0..spend]);
        },
        .tcom => {
            if (sflag) {
                sflag = false;
                jflag = true;
            }
        },
        .wcom => putline(ipc.fcode.?, linebuf[0..spend]),
        .xcom => {
            const n = spend;
            @memcpy(genbuf[0..n], linebuf[0..n]);
            @memcpy(linebuf[0..hspend], holdsp[0..hspend]);
            spend = hspend;
            @memcpy(holdsp[0..n], genbuf[0..n]);
            hspend = n;
        },
        .ycom => {
            const t = ipc.ytab;
            for (linebuf[0..spend]) |*r| {
                if (r.* < t.len)
                    r.* = t[r.*];
            }
        },
        .end => {},
    }
}

fn putline(bp: *Biobuf, buf: []const Rune) void {
    for (buf) |r|
        _ = bp.putrune(r) catch {};
    bp.putc('\n') catch {};
}

var rbuf: Biobuf = .{};

fn arout() void {
    for (abuf[0..naptr]) |k| {
        const c = &pspace[k];
        if (c.command == .acom) {
            putrunes(c.text);
            putc('\n');
        } else {
            var buf: [128]u8 = undefined;
            var s: usize = 0;
            const e = buf.len - libc.UTFmax - 1;
            for (c.text) |r| {
                if (s >= e) break;
                s += libc.runetochar(buf[s..], r);
            }
            rbuf.open(buf[0..s], libc.OREAD) catch continue;
            if (uflag)
                rbuf.setiofn(flushout);
            while (rbuf.getc()) |x|
                putc(x);
            rbuf.term() catch {};
            rbuf.setiofn(null);
        }
    }
    naptr = 0;
}

fn errexit() noreturn {
    libc.exits("error");
}

fn quit(comptime fmt_: []const u8, args: anytype) noreturn {
    var msg: [256]u8 = undefined;
    const end = msg.len - 1;
    var p = libc.fmt.snprint(msg[0..end], "sed: ", .{}).len;
    p += libc.fmt.snprint(msg[p..end], fmt_, args).len;
    p += libc.fmt.snprint(msg[p..end], "\n", .{}).len;
    _ = libc.write(2, msg[0..p]) catch {};
    errexit();
}

/// The next input line into linebuf at addr; the end of the data, or
/// null at the end of the input.
var peekc: i64 = 0;

fn gline(addr: usize) ?usize {
    if (f == null and !opendata())
        return null;
    sflag = false;
    lnum +%= 1;
    while (true) {
        var p = addr;
        var c: i64 = if (peekc != 0) peekc else getr(f.?);
        while (c >= 0) : (c = getr(f.?)) {
            if (c == '\n') {
                if (dollars != 0) {
                    peekc = getr(f.?);
                    if (peekc < 0 and fqi >= fq.items.len)
                        dolflag = true;
                }
                return p;
            }
            if (c != 0 and p < lbend) {
                linebuf[p] = @intCast(c);
                p += 1;
            }
        }
        // return partial final line, adding implicit newline
        if (p != addr) {
            peekc = -1;
            if (fqi >= fq.items.len)
                dolflag = true;
            return p;
        }
        peekc = 0;
        f.?.term() catch {};
        if (!opendata())
            break; // Switch to next stream
    }
    f = null;
    return null;
}

fn getr(bp: *Biobuf) i64 {
    return if (bp.getrune()) |r| r else -1;
}

/// Data file input section - the intent is to transparently
/// catenate all data input streams.
fn enroll(filename: ?[]const u8) void { // Add a file to the input file cache
    fq.append(a, filename) catch quit("Out of memory", .{}); // null => stdin
}

fn opendata() bool {
    if (fqi >= fq.items.len)
        return false;
    if (fq.items[fqi]) |name| {
        fbuf.open(name, libc.OREAD) catch quit("Can't open %s", .{name});
        f = &fbuf;
    } else {
        stdin.init(0, libc.OREAD);
        f = &stdin;
    }
    if (uflag)
        f.?.setiofn(flushout);
    fqi += 1;
    return true;
}
