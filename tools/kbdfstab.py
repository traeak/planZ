#!/usr/bin/env python3
"""Make kbdfs's tables for the Zig port from 9front's sources:

    kbdfstab.py ascii  kbdfs.c        the scan code layers (ascii[][])
    kbdfstab.py latin1 /lib/keyboard  the compose table (latin1.h, which
                                      9front makes with mklatin.c)

The output is src/user/cmd/kbdfs/ascii.zig and latin1.zig.  The files
are read as bytes: the Ctl layer of kbdfs.c has control characters
between its quotes.
"""
import re
import sys


def ascii_tab(path):
    src = open(path, 'rb').read()
    i = src.index(b'Rune ascii[Nlayers][Nscan] = {')
    j = src.index(b'\nRune kbtabs[Nlayers][Nscan];')
    body = src[i:j]
    # take the comments out
    body = re.sub(rb'/\*.*?\*/', b'', body, flags=re.S)
    out = []
    out.append('//! The scan code layers kbdfs starts with (/sys/lib/kbmap/ascii).')
    out.append('//! Made by tools/kbdfstab.py from 9front 11952\'s')
    out.append('//! /sys/src/cmd/aux/kbdfs/kbdfs.c (ascii[Nlayers][Nscan]); not to be')
    out.append('//! edited.')
    out.append('')
    out.append('const k = @import("libc").keyboard;')
    out.append('const KF = k.KF;')
    out.append('')
    out.append('pub const Nscan = 128;')
    out.append('pub const Nlayers = 10;')
    out.append('')
    out.append('/// One layer for each of kbdfs.zig\'s Layer, in its order.')
    out.append('pub const ascii = blk: {')
    out.append('    var t: [Nlayers][Nscan]u21 = @splat(@splat(0));')
    order = ['Lnone', 'Lshift', 'Lesc1', 'Laltgr', 'Lctl', 'Lctrlesc1',
             'Lshiftesc1', 'Lshiftaltgr', 'Lmod4', 'Laltgrmod4']
    layers = re.split(rb'\[(L[a-z0-9]+)\]\s*\{', body)[1:]
    seen = set()
    for name, text in zip(layers[0::2], layers[1::2]):
        name = name.decode()
        seen.add(name)
        text = text[:text.index(b'\n\t}')]
        vals = []
        pos = 0
        n = len(text)
        while pos < n:
            c = text[pos:pos + 1]
            if c in b' \t\r\n,':
                pos += 1
            elif c == b'[':
                e = text.index(b']', pos)
                at = int(text[pos + 1:e], 0)
                assert at == len(vals), (name, at, len(vals))
                pos = e + 1
            elif c == b"'":
                if text[pos + 1:pos + 2] == b'\\':
                    ch = text[pos + 2:pos + 3]
                    v = {b'b': 8, b't': 9, b'n': 10, b'\\': 92, b"'": 39}[ch]
                    assert text[pos + 3:pos + 4] == b"'"
                    pos += 4
                else:
                    v = text[pos + 1]
                    assert text[pos + 2:pos + 3] == b"'", (name, text[pos:pos + 6])
                    pos += 3
                if 0x20 < v < 0x7f and v not in (39, 92):
                    vals.append("'%c'" % v)
                else:
                    vals.append('0x%02x' % v)
            else:
                m = re.match(rb'[A-Za-z0-9|]+', text[pos:])
                assert m, (name, text[pos:pos + 10])
                tok = m.group(0).decode()
                pos += len(tok)
                if tok == '0':
                    vals.append('0')
                elif tok.startswith('KF|'):
                    vals.append('KF | ' + tok[3:])
                else:
                    assert tok.startswith('K'), tok
                    vals.append('k.' + tok)
        assert len(vals) == 128, (name, len(vals))
        out.append('    t[%d] = .{ // %s' % (order.index(name), name))
        for r in range(0, 128, 8):
            out.append('        ' + ' '.join(v + ',' for v in vals[r:r + 8]) + ' // 0x%02x' % r)
        out.append('    };')
    assert seen == set(order), seen
    out.append('    break :blk t;')
    out.append('};')
    return '\n'.join(out) + '\n'


class Trie:
    def __init__(self):
        self.n = 0
        self.seq = b''
        self.r = [0] * 256
        self.link = [None] * 256


def latin1(path):
    """mklatin.c: the same table in the same order."""
    root = Trie()

    def insert(s, r):
        # mktrie
        t = root
        for q in range(len(s) - 1):
            c = s[q]
            if t.link[c] is None:
                t.link[c] = Trie()
                t.link[c].seq = s[:q + 1]
            t = t.link[c]
        last = s[-1]
        if t.r[last]:
            return  # warning: table duplicate
        t.r[last] = r
        t.n += 1

    for line in open(path, 'rb').read().split(b'\n')[:-1]:
        ln = len(line)
        if ln < 1 or line[0:1] == b'#':
            continue
        m = re.match(rb'[ \t]*[-+]?[0-9A-Fa-f]+', line)
        r = int(m.group(0), 16) if m else 0
        end = len(m.group(0)) if m else 0
        if r == 0 or line[end:end + 1] != b' ' or ln < 21:
            continue
        p = 6
        inseq = True
        seq = p
        while True:
            c = line[p] if p < ln else 0
            if c >= 0x80:
                break
            if c == 0 or c in b' \t\n\r\v\f':
                if inseq and p - seq >= 2:
                    inseq = False
                    insert(line[seq:p], r)
                if c == 0:
                    break
            elif not inseq:
                seq = p
                inseq = True
            p += 1

    rows = []

    def walk(t):
        for i in range(256):
            if t.link[i] is not None:
                walk(t.link[i])
        if t.n > 0:
            si = bytes(i for i in range(256) if t.r[i])
            so = [t.r[i] for i in range(256) if t.r[i]]
            rows.append((t.seq, si, so))

    walk(root)

    def zstr(b):
        s = ''
        for c in b:
            if c in (34, 92):
                s += '\\' + chr(c)
            elif 0x20 <= c < 0x7f:
                s += chr(c)
            else:
                s += '\\x%02x' % c
        return '"' + s + '"'

    out = []
    out.append('//! The compose sequences: after Alt, the characters of `ld` and then')
    out.append('//! one of `si` give the rune of `so` at the same place.')
    out.append('//! Made by tools/kbdfstab.py from 9front 11952\'s /lib/keyboard, as')
    out.append('//! 9front makes latin1.h with mklatin.c (the same entries in the same')
    out.append('//! order); not to be edited.')
    out.append('')
    out.append('pub const Entry = struct {')
    out.append('    ld: []const u8, // must be seen before using this conversion')
    out.append('    si: []const u8, // options for last input characters')
    out.append('    so: []const u21, // the corresponding Rune for each si entry')
    out.append('};')
    out.append('')
    out.append('pub const tab = [_]Entry{')
    for seq, si, so in rows:
        out.append('    .{ .ld = %s, .si = %s, .so = &.{ %s } },' % (
            zstr(seq), zstr(si), ', '.join('0x%04x' % r for r in so)))
    out.append('};')
    return '\n'.join(out) + '\n'


if __name__ == '__main__':
    if len(sys.argv) != 3 or sys.argv[1] not in ('ascii', 'latin1'):
        sys.stderr.write(__doc__)
        sys.exit(2)
    sys.stdout.write(ascii_tab(sys.argv[2]) if sys.argv[1] == 'ascii' else latin1(sys.argv[2]))
