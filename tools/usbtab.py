#!/usr/bin/env python3
"""Make the tables of the USB programs' Zig ports from 9front's sources:

    usbtab.py kb   kb.c         nusb/kb's scan codes and report descriptors
    usbtab.py scsi scsicodes    nusb/disk's error texts (scsierrs.c, which
                                9front makes from /sys/lib/scsicodes with
                                mkscsierrs)

The output is src/user/cmd/usbkb/tab.zig and
src/user/cmd/usbdisk/scsierrs.zig.
"""
import re
import sys


def rows(bs, per=8):
    return '\n'.join('    ' + ' '.join('0x%02x,' % b for b in bs[i:i + per])
                     for i in range(0, len(bs), per))


def hexes(text):
    return [int(x, 16) for x in re.findall(r'0x([0-9a-fA-F]{1,2})\b', text)]


def kb(path):
    src = open(path).read()
    body = re.search(r'static char sctab\[2\*256\] =\n\{(.*?)\n\};', src, re.S).group(1)
    vals = []
    for line in body.split('\n'):
        m = re.match(r'\[0x([0-9a-f]+)\]\s*(.*)', line.strip())
        if not m:
            continue
        assert int(m.group(1), 16) == len(vals)
        vals += [int(v, 16) for v in m.group(2).split(',') if v.strip()]
    assert len(vals) == 512
    kbd = hexes(re.search(r'static uchar kbdbootrep\[\] = \{(.*?)\};', src, re.S).group(1))
    ptr = hexes(re.search(r'static uchar ptrbootrep\[\] = \{(.*?)\};', src, re.S).group(1))
    gao = re.search(r'static uchar descr\[\] = \{(.*?)\n\t\};', src, re.S).group(1)
    gao = hexes(re.sub(r'/\*.*?\*/', '', gao))
    return '''//! The tables of nusb/kb: key codes to scan codes, the report
//! descriptors of the boot protocol, and the one for the Gaomon S620.
//! Made by tools/usbtab.py from 9front 11952's
//! /sys/src/cmd/nusb/kb/kb.c; not to be edited.

/// key code to scan code; for the page table used by
/// the logitech bluetooth keyboard.  The second half is the consumer
/// page to scan code.
/// scan codes >= 0x80 are extended (E0 XX)
pub const sctab = [2 * 256]u8{
%s
};

pub const kbdbootrep = [_]u8{
%s
};

pub const ptrbootrep = [_]u8{
%s
};

/// gaomons620's descriptor
pub const gaomon = [_]u8{
%s
};
''' % (rows(vals), rows(kbd), rows(ptr), rows(gao))


def scsi(path):
    out = ['''//! The texts of the SCSI errors (additional sense code and
//! qualifier).  Made by tools/usbtab.py from 9front 11952's
//! /sys/lib/scsicodes, as /sys/src/cmd/nusb/disk/mkscsierrs makes
//! scsierrs.c; not to be edited.

const Err = struct {
    n: u16,
    s: []const u8,
};

const scsierrs = [_]Err{''']
    for line in open(path, encoding='utf-8'):
        m = re.match(r'^([0-9a-c]{4})[ \t]', line)
        if not m:
            continue
        # sed -e 's/^(....) (.*)/{0x\\1, "\\2"},/'
        m2 = re.match(r'^(....) (.*)', line.rstrip('\n'))
        assert m2, line
        text = m2.group(2)
        assert '"' not in text and '\\' not in text
        out.append('    .{ .n = 0x%s, .s = "%s" },' % (m2.group(1), text))
    out.append('''};

pub fn scsierrmsg(n: u32) []const u8 {
    for (scsierrs) |e| {
        if (e.n == n)
            return e.s;
    }
    return "scsi error";
}
''')
    return '\n'.join(out)


if __name__ == '__main__':
    if len(sys.argv) != 3 or sys.argv[1] not in ('kb', 'scsi'):
        sys.exit(__doc__)
    sys.stdout.write({'kb': kb, 'scsi': scsi}[sys.argv[1]](sys.argv[2]))
