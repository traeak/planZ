//! retest - run planZ's regexp over a table and print every result, for
//! comparison with 9front's libregexp, which tools/retest.c runs over
//! the same table with the same output.  See tools/retest.c for the
//! table's format and what is printed.
//!
//! Not part of 9front.

const std = @import("std");
const libc = @import("libc");
const re = libc.regexp;

const NSUB = 10;
const NSCAN = 20;
const template = "<&|\\1|\\2>";

var bout: libc.Biobuf = .{};

fn print(comptime f: []const u8, args: anytype) void {
    bout.print(f, args) catch {};
}

fn hexval(c: u8) u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => 0,
    };
}

/// \n \t \\ \xHH, in place, as the C does it on its string; the result
/// ends at a 0 byte if one is made.
fn unescape(s: []u8) []u8 {
    var r: usize = 0;
    var w: usize = 0;
    while (r < s.len) : (r += 1) {
        if (s[r] != '\\' or r + 1 >= s.len) {
            s[w] = s[r];
            w += 1;
            continue;
        }
        r += 1;
        switch (s[r]) {
            'n' => s[w] = '\n',
            't' => s[w] = '\t',
            'x' => {
                var c: u8 = 0;
                if (r + 2 < s.len) {
                    c = hexval(s[r + 1]) *% 16 +% hexval(s[r + 2]);
                    r += 2;
                }
                s[w] = c;
            },
            else => s[w] = s[r],
        }
        w += 1;
    }
    return s[0..w];
}

fn upto0(s: []const u8) []const u8 {
    return s[0 .. std.mem.findScalar(u8, s, 0) orelse s.len];
}

fn prsubs(m: []const re.Resub) void {
    for (m[1..], 1..) |x, i| {
        if (x.sp == null and x.ep == null)
            continue;
        print(" %d:", .{i});
        if (x.sp) |v| print("%d", .{v}) else print("-", .{});
        print("-", .{});
        if (x.ep) |v| print("%d", .{v}) else print("-", .{});
    }
}

fn bytes(ln: usize, p: *re.Reprog, str: []const u8) void {
    var m: [NSUB]re.Resub = undefined;
    var out: [24]u8 = undefined;
    var any = false;
    var sp: usize = 0;
    var n: usize = 0;
    while (n < NSCAN and sp <= str.len) : (n += 1) {
        m = @splat(.{});
        m[0].sp = sp;
        if (!p.exec(str, &m))
            break;
        any = true;
        print("%d match %d %d", .{ ln, m[0].sp.?, m[0].ep.? });
        prsubs(&m);
        print(" [%s]\n", .{re.regsub(u8, template, &out, str, &m)});
        const ep = m[0].ep.?;
        if (ep > m[0].sp.?)
            sp = ep
        else if (ep < str.len)
            sp = ep + libc.chartorune(str[ep..]).n
        else
            break;
    }
    if (!any)
        print("%d none\n", .{ln});

    m = @splat(.{});
    m[0].sp = 0;
    m[0].ep = str.len / 2;
    if (p.exec(str, &m))
        print("%d half %d %d\n", .{ ln, m[0].sp.?, m[0].ep.? })
    else
        print("%d half none\n", .{ln});
}

fn runes(ln: usize, p: *re.Reprog, s: []const u8) void {
    var m: [NSUB]re.Resub = undefined;
    var str: [1024]libc.Rune = undefined;
    var out: [24]libc.Rune = undefined;
    var len: usize = 0;
    var k: usize = 0;
    while (k < s.len and len < str.len - 1) {
        const d = libc.chartorune(s[k..]);
        str[len] = d.r;
        len += 1;
        k += d.n;
    }

    const tmpl = comptime blk: {
        var t: [template.len]libc.Rune = undefined;
        for (template, 0..) |c, i| t[i] = c;
        break :blk t;
    };

    var any = false;
    var sp: usize = 0;
    var n: usize = 0;
    while (n < NSCAN and sp <= len) : (n += 1) {
        m = @splat(.{});
        m[0].sp = sp;
        if (!p.rexec(str[0..len], &m))
            break;
        any = true;
        print("%d rmatch %d %d", .{ ln, m[0].sp.?, m[0].ep.? });
        prsubs(&m);
        const r = re.regsub(libc.Rune, &tmpl, &out, str[0..len], &m);
        print(" [", .{});
        for (r) |c| print("%C", .{c});
        print("]\n", .{});
        const ep = m[0].ep.?;
        if (ep > m[0].sp.?)
            sp = ep
        else if (ep < len)
            sp = ep + 1
        else
            break;
    }
    if (!any)
        print("%d rnone\n", .{ln});
}

pub fn main(argv: []const []const u8) !void {
    if (argv.len != 2) {
        libc.fprint(2, "usage: retest table\n", .{});
        libc.exits("usage");
    }
    bout.init(1, libc.OWRITE);
    var b: libc.Biobuf = .{};
    b.open(argv[1], libc.OREAD) catch libc.sysfatal("open %s: %r", .{argv[1]});
    var ln: usize = 1;
    while (b.rdline('\n')) |full| : (ln += 1) {
        const line = full[0 .. full.len - 1];
        if (line.len == 0 or line[0] == '#')
            continue;
        // getfields(line, f, 3, 0, "\t"): the third field keeps any
        // further tabs
        const t1 = std.mem.findScalar(u8, line, '\t') orelse {
            print("%d bad line\n", .{ln});
            continue;
        };
        const t2 = std.mem.findScalarPos(u8, line, t1 + 1, '\t') orelse {
            print("%d bad line\n", .{ln});
            continue;
        };
        const flags = line[0..t1];
        const pat = unescape(line[t1 + 1 .. t2]);
        const subj = upto0(unescape(line[t2 + 1 ..]));
        var diag: re.Diag = .{};
        const p = switch (if (flags.len > 0) flags[0] else 0) {
            'n' => re.regcompnl(libc.allocator, pat, &diag),
            'l' => re.regcomplit(libc.allocator, pat, &diag),
            else => re.regcomp(libc.allocator, pat, &diag),
        } catch |e| {
            if (e == error.Regexp)
                print("%d error %s\n", .{ ln, diag.msg })
            else
                print("%d error %s\n", .{ ln, "" });
            continue;
        };
        // as retest.c does, to step around stock regcomp's unset
        // generations (see there)
        _ = p.exec("", null);
        bytes(ln, p, subj);
        runes(ln, p, subj);
        p.deinit();
    }
    bout.flush() catch {};
}
