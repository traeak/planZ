#!/usr/bin/env python3
"""Write a raw disk image that boots planZ from a USB stick.

usage: mkusb.py -o IMAGE [--disk 9FRONT-IMAGE] [--esp-mb N] [--esp-type HEX]
                [--label NAME] DEST=SRC...

The image has an MBR partition table with two partitions:

  1  the boot volume, a FAT file system made here, holding each SRC file
     under the name DEST (EFI/BOOT/BOOTX64.EFI, planz, plan9.ini,
     boot/...).  UEFI firmware starts EFI/BOOT/BOOTX64.EFI from it.
  2  a copy of the Plan 9 partition (type 0x39) of the 9front disk
     image given with --disk, which holds the root file system.
     Without --disk the image has the boot volume only.

Needs nothing but Python 3 and, for --disk, qemu-img.  Nothing is
mounted and no root is needed.  The image file is sparse.

With --check IMAGE instead, the FAT file system in the first partition
of an image is read back and listed, each file named DEST=SRC is
compared with SRC, fsck.fat is run on the volume if the host has it,
and with --disk the Plan 9 partition is compared with its source.
"""

import argparse
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import time

SECT = 512
ESP_START = 2048  # 1MiB, where every partitioning tool starts
HEADS, SPT = 255, 63  # the geometry the CHS fields pretend


def die(msg):
    sys.exit("mkusb: " + msg)


# ---- FAT ----

SHORT_OK = set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&'()-@^_`{}~")


def short_name(name):
    """The 11-byte directory form of `name` and its lower-case flags if
    it is a plain 8.3 name, otherwise None (it then needs a long name)."""
    if name in (".", ".."):
        return name.ljust(11).encode(), 0
    base, dot, ext = name.rpartition(".")
    if not dot:
        base, ext = name, ""
    if not 1 <= len(base) <= 8 or len(ext) > 3 or (dot and not ext):
        return None
    flags = 0
    for part, bit in ((base, 0x08), (ext, 0x10)):
        if any(c not in SHORT_OK for c in part.upper()):
            return None
        if part != part.upper():
            if part != part.lower():
                return None  # mixed case
            flags |= bit  # all lower case: one bit says so
    return (base.upper().ljust(8) + ext.upper().ljust(3)).encode("ascii"), flags


def lfn_checksum(short):
    s = 0
    for b in short:
        s = (((s & 1) << 7) + (s >> 1) + b) & 0xFF
    return s


def fat_time(t):
    tm = time.localtime(max(t, 315532800))  # not before 1980
    date = (tm.tm_year - 1980) << 9 | tm.tm_mon << 5 | tm.tm_mday
    return tm.tm_hour << 11 | tm.tm_min << 5 | tm.tm_sec // 2, date


class Node:
    def __init__(self, name, data=None, mtime=0):
        self.name = name
        self.data = data  # None for a directory
        self.mtime = mtime
        self.kids = []  # of a directory
        self.cluster = 0

    def child(self, name):
        for k in self.kids:
            if k.name.lower() == name.lower():
                return k
        return None


class Fat:
    """A FAT16 or FAT32 file system of `nsect` sectors, built in memory
    and written at once."""

    def __init__(self, nsect, hidden, label, now):
        self.nsect = nsect
        self.hidden = hidden
        self.label = label.upper()[:11].ljust(11).encode("ascii")
        self.now = now
        self.root = Node("")
        # The cluster size decides the FAT type: FAT32 is "65525
        # clusters or more", FAT16 "4085 to 65524", by definition.
        # UEFI wants FAT32 on a system partition but must read FAT16 on
        # removable media, so a small volume becomes FAT16.
        self.bits = 0
        # 4K clusters if the volume is big enough for FAT32 with them.
        for spc in (8, 4, 2, 1):
            if self.layout(32, spc) and self.nclust >= 65525 + 16:
                self.bits = 32
                break
        if not self.bits:
            for spc in (1, 2, 4, 8, 16, 32, 64):
                if self.layout(16, spc) and 4085 + 16 <= self.nclust <= 65524 - 16:
                    self.bits = 16
                    break
        if not self.bits:
            die("no FAT16 or FAT32 layout for a volume of %d sectors" % nsect)
        self.fat = [0] * (self.nclust + 2)
        self.fat[0] = 0x0FFFFFF8  # media byte, as BPB_Media
        self.fat[1] = 0x0FFFFFFF
        self.next = 2
        self.chunks = {}  # first cluster -> bytes

    def layout(self, bits, spc):
        self.spc = spc
        self.csize = spc * SECT
        if bits == 32:
            self.reserved, self.rootsect = 32, 0
        else:
            self.reserved, self.rootsect = spc, 512 * 32 // SECT
            if self.reserved < 8:
                self.reserved = 8  # keep the data area on a 4K boundary with ESP_START
        left = self.nsect - self.reserved - self.rootsect
        if left <= 0:
            return False
        # Smallest FAT that describes the clusters left over beside two copies of it.
        fatsz = 1
        while True:
            self.nclust = (left - 2 * fatsz) // spc
            if self.nclust <= 0:
                return False
            if fatsz * SECT * 8 // bits >= self.nclust + 2:
                break
            fatsz += 1
        self.fatsz = fatsz
        self.datastart = self.reserved + 2 * fatsz + self.rootsect
        return True

    def add(self, dest, data, mtime):
        parts = [p for p in dest.replace("\\", "/").split("/") if p]
        if not parts:
            die("empty destination name")
        d = self.root
        for p in parts[:-1]:
            k = d.child(p)
            if k is None:
                k = Node(p, None, self.now)
                d.kids.append(k)
            elif k.data is not None:
                die("%s: %s is a file" % (dest, p))
            d = k
        if d.child(parts[-1]) is not None:
            die("%s: given twice" % dest)
        d.kids.append(Node(parts[-1], data, mtime))

    def alloc(self, data):
        """Store `data` in a chain of clusters; return the first."""
        n = max(1, -(-len(data) // self.csize))
        if self.next + n > self.nclust + 2:
            die("boot volume is too small for its files; raise --esp-mb")
        first = self.next
        for c in range(first, first + n - 1):
            self.fat[c] = c + 1
        self.fat[first + n - 1] = 0x0FFFFFFF
        self.next += n
        self.chunks[first] = data
        return first

    def entry(self, short, attr, flags, cluster, size, mtime):
        t, d = fat_time(mtime)
        return struct.pack("<11sBBBHHHHHHHI", short, attr, flags, 0, t, d, d,
                           cluster >> 16, t, d, cluster & 0xFFFF, size)

    def dirents(self, node, taken):
        """The directory entries for one child: long-name entries if the
        name is not 8.3, then the short one."""
        sn = short_name(node.name)
        out = b""
        if sn is not None and sn[0] not in taken:
            short, flags = sn
        else:
            # A numbered alias, and the real name in UTF-16.
            base, dot, ext = node.name.rpartition(".")
            if not dot:
                base, ext = node.name, ""
            clean = lambda s: "".join(c for c in s.upper() if c in SHORT_OK)
            n = 1
            while True:
                tail = "~%d" % n
                short = (clean(base)[:8 - len(tail)] + tail).ljust(8) + clean(ext)[:3].ljust(3)
                short = short.encode("ascii")
                if short not in taken:
                    break
                n += 1
            flags = 0
            u = node.name.encode("utf-16-le") + b"\0\0"
            if len(u) % 26:
                u += b"\xff" * (26 - len(u) % 26)
            nseq = len(u) // 26
            if nseq > 20:
                die("%s: name too long" % node.name)
            ck = lfn_checksum(short)
            for seq in range(nseq, 0, -1):
                p = u[(seq - 1) * 26:seq * 26]
                out += struct.pack("<B10sBBB12sH4s", seq | (0x40 if seq == nseq else 0),
                                   p[0:10], 0x0F, 0, ck, p[10:22], 0, p[22:26])
        taken.add(short)
        attr = 0x10 if node.data is None else 0x20
        size = 0 if node.data is None else len(node.data)
        cluster = node.cluster if size or node.data is None else 0
        return out + self.entry(short, attr, flags, cluster, size, node.mtime)

    def place(self, d, parent):
        """Give clusters to directory `d` and everything under it, and
        build its entries."""
        # A directory's size depends only on its entry count, so it can
        # take its clusters before its children have theirs (and the
        # root is cluster 2, as is usual).
        taken = set()
        probe = b"".join(self.dirents(k, taken) for k in d.kids)
        extra = 32 if d is self.root else 64  # label, or "." and ".."
        size = len(probe) + extra
        if d is self.root and self.bits == 16:
            if size > self.rootsect * SECT:
                die("too many files in the root directory for FAT16")
        else:
            d.cluster = self.alloc(b"\0" * size)
        for k in d.kids:
            if k.data:
                k.cluster = self.alloc(k.data)
        for k in d.kids:
            if k.data is None:
                self.place(k, d)
        taken = set()
        body = b""
        if d is self.root:
            body += self.entry(self.label, 0x08, 0, 0, 0, self.now)
        else:
            up = 0 if parent is self.root else parent.cluster
            body += self.entry(b".          ", 0x10, 0, d.cluster, 0, self.now)
            body += self.entry(b"..         ", 0x10, 0, up, 0, self.now)
        body += b"".join(self.dirents(k, taken) for k in d.kids)
        if d is self.root and self.bits == 16:
            self.rootdir = body
        else:
            self.chunks[d.cluster] = body

    def boot_sector(self):
        vid = int(self.now) & 0xFFFFFFFF
        bpb = struct.pack("<3s8sHBHBHHBHHHII", b"\xeb\x58\x90" if self.bits == 32 else b"\xeb\x3c\x90", b"PLANZ   ", SECT, self.spc,
                          self.reserved, 2, 512 if self.bits == 16 else 0,
                          self.nsect if self.nsect < 0x10000 and self.bits == 16 else 0,
                          0xF8, self.fatsz if self.bits == 16 else 0, SPT, HEADS,
                          self.hidden, 0 if self.nsect < 0x10000 and self.bits == 16 else self.nsect)
        if self.bits == 32:
            bpb += struct.pack("<IHHIHH12s", self.fatsz, 0, 0, self.root.cluster, 1, 6, b"")
        bpb += struct.pack("<BBBI11s8s", 0x80, 0, 0x29, vid, self.label,
                           b"FAT32   " if self.bits == 32 else b"FAT16   ")
        return bpb.ljust(510, b"\0") + b"\x55\xaa"

    def write(self, f, base):
        """Write the volume into file `f` at byte offset `base`."""
        self.place(self.root, None)
        boot = self.boot_sector()
        f.seek(base)
        f.write(boot)
        if self.bits == 32:
            free = self.nclust + 2 - self.next
            info = (struct.pack("<I480sIII", 0x41615252, b"", 0x61417272, free, self.next)
                    .ljust(508, b"\0") + b"\0\0\x55\xaa")
            f.write(info)
            f.seek(base + 6 * SECT)  # the backup copies
            f.write(boot)
            f.write(info)
        used = self.fat[:self.next]
        if self.bits == 32:
            table = struct.pack("<%dI" % len(used), *used)
        else:
            table = struct.pack("<%dH" % len(used), *(v & 0xFFFF for v in used))
        for copy in range(2):
            f.seek(base + (self.reserved + copy * self.fatsz) * SECT)
            f.write(table)
        if self.bits == 16:
            f.seek(base + (self.reserved + 2 * self.fatsz) * SECT)
            f.write(self.rootdir)
        for cluster, data in self.chunks.items():
            f.seek(base + (self.datastart + (cluster - 2) * self.spc) * SECT)
            f.write(data)


# ---- reading a FAT back (for --check) ----

class FatReader:
    def __init__(self, f, base):
        self.f, self.base = f, base
        f.seek(base)
        b = f.read(SECT)
        if b[510:] != b"\x55\xaa":
            die("check: no boot sector signature")
        (bps, self.spc, self.reserved, nfat, rootent, tot16, _, fat16,
         _, _, _, tot32) = struct.unpack_from("<HBHBHHBHHHII", b, 11)
        if bps != SECT:
            die("check: sector size %d" % bps)
        self.fatsz = fat16 or struct.unpack_from("<I", b, 36)[0]
        self.rootsect = rootent * 32 // SECT
        self.datastart = self.reserved + nfat * self.fatsz + self.rootsect
        total = tot16 or tot32
        self.nclust = (total - self.datastart) // self.spc
        self.bits = 32 if self.nclust >= 65525 else 16
        f.seek(base + self.reserved * SECT)
        raw = f.read(self.fatsz * SECT)
        f.seek(base + (self.reserved + self.fatsz) * SECT)
        if nfat != 2 or f.read(self.fatsz * SECT) != raw:
            die("check: the two FATs differ")
        if self.bits == 32:
            self.fat = [v & 0x0FFFFFFF for v in struct.unpack("<%dI" % (len(raw) // 4), raw)]
            self.eoc = 0x0FFFFFF8
            self.rootcluster = struct.unpack_from("<I", b, 44)[0]
        else:
            self.fat = list(struct.unpack("<%dH" % (len(raw) // 2), raw))
            self.eoc = 0xFFF8
            self.rootcluster = 0

    def chain(self, c):
        out = b""
        seen = 0
        while 2 <= c < self.eoc:
            self.f.seek(self.base + (self.datastart + (c - 2) * self.spc) * SECT)
            out += self.f.read(self.spc * SECT)
            c = self.fat[c]
            seen += 1
            if seen > self.nclust:
                die("check: cluster chain loops")
        return out

    def readdir(self, cluster):
        if cluster == 0 and self.bits == 16:
            self.f.seek(self.base + (self.reserved + 2 * self.fatsz) * SECT)
            raw = self.f.read(self.rootsect * SECT)
        else:
            raw = self.chain(cluster)
        out, long = [], []
        for i in range(0, len(raw), 32):
            e = raw[i:i + 32]
            if e[0] == 0:
                break
            if e[0] == 0xE5:
                continue
            if e[11] == 0x0F:
                long.append((e[0] & 0x3F, e[13], e[1:11] + e[14:26] + e[28:32]))
                continue
            short, attr, flags = e[0:11], e[11], e[12]
            if attr & 0x08:
                long = []
                continue
            if long:
                if any(ck != lfn_checksum(short) for _, ck, _ in long):
                    die("check: long name checksum")
                u = b"".join(p for _, _, p in sorted(long))
                name = u.decode("utf-16-le").split("\0")[0]
                long = []
            else:
                base = short[0:8].decode("ascii").rstrip()
                ext = short[8:11].decode("ascii").rstrip()
                if flags & 0x08:
                    base = base.lower()
                if flags & 0x10:
                    ext = ext.lower()
                name = base + ("." + ext if ext else "")
            hi, lo, size = struct.unpack_from("<H", e, 20)[0], struct.unpack_from("<H", e, 26)[0], struct.unpack_from("<I", e, 28)[0]
            out.append((name, bool(attr & 0x10), hi << 16 | lo, size))
        return out

    def walk(self, cluster=None, prefix=""):
        """Yield (path, data) for every file."""
        if cluster is None:
            cluster = self.rootcluster
        for name, isdir, c, size in self.readdir(cluster):
            if name in (".", ".."):
                continue
            if isdir:
                yield from self.walk(c, prefix + name + "/")
            else:
                yield prefix + name, self.chain(c)[:size] if size else b""


# ---- the disk ----

def chs(lba):
    c, rest = divmod(lba, HEADS * SPT)
    h, s = divmod(rest, SPT)
    if c > 1023:
        return bytes((0xFE, 0xFF, 0xFF))
    return bytes((h, (s + 1) | (c >> 8) << 6, c & 0xFF))


def mbr_entry(active, typ, start, size):
    return bytes((0x80 if active else 0,)) + chs(start) + bytes((typ,)) + chs(start + size - 1) + struct.pack("<II", start, size)


def read_mbr(f):
    f.seek(0)
    s = f.read(SECT)
    if len(s) < SECT or s[510:] != b"\x55\xaa":
        return []
    out = []
    for i in range(4):
        e = s[446 + 16 * i:462 + 16 * i]
        start, size = struct.unpack("<II", e[8:])
        out.append((e[4], start, size))
    return out


def copy_sparse(src, dst, src_off, dst_off, length):
    """Copy a byte range, skipping the parts that are holes in `src`."""
    end = src_off + length
    pos = src_off
    copied = 0
    while pos < end:
        try:
            data = os.lseek(src.fileno(), pos, os.SEEK_DATA)
        except OSError:  # ENXIO: nothing but a hole to the end
            break
        if data >= end:
            break
        try:
            hole = min(os.lseek(src.fileno(), data, os.SEEK_HOLE), end)
        except OSError:
            hole = end
        # pread and pwrite: the lseek calls above moved the descriptor
        # behind the back of Python's buffered file.
        at = data
        while at < hole:
            buf = os.pread(src.fileno(), min(hole - at, 4 << 20), at)
            if not buf:
                die("short read from the converted disk image")
            # A block of zeros can stay a hole in the output as well.
            if buf.count(0) != len(buf):
                done = 0
                while done < len(buf):
                    done += os.pwrite(dst.fileno(), buf[done:], dst_off + at - src_off + done)
                copied += len(buf)
            at += len(buf)
        pos = hole
    return copied


def convert(disk, tmpdir):
    """A raw copy of a disk image, as a temporary file.  qemu-img writes
    it sparse: only the allocated part costs time and space."""
    fd, raw = tempfile.mkstemp(prefix="mkusb-", suffix=".raw", dir=tmpdir)
    os.close(fd)
    if subprocess.run(["qemu-img", "convert", "-O", "raw", disk, raw]).returncode != 0:
        os.unlink(raw)
        die("qemu-img convert failed")
    return raw


def plan9_part(f, name):
    """Start and size, in sectors, of the Plan 9 partition of a raw disk."""
    p9 = [(s, n) for t, s, n in read_mbr(f) if t == 0x39]
    if len(p9) != 1:
        die("%s: expected one Plan 9 partition (type 0x39) in its MBR, found %d" % (name, len(p9)))
    start, size = p9[0]
    if (start + size) * SECT > os.fstat(f.fileno()).st_size:
        die("%s: Plan 9 partition runs past the end of the disk" % name)
    return start, size


def build(args, files):
    now = time.time()
    esp_sect = args.esp_mb * 1024 * 1024 // SECT
    fat = Fat(esp_sect, ESP_START, args.label, now)
    total = 0
    for dest, src in files:
        with open(src, "rb") as f:
            data = f.read()
        total += len(data)
        fat.add(dest, data, os.path.getmtime(src))

    p9_start = ESP_START + esp_sect
    p9_size = 0
    outdir = os.path.dirname(os.path.abspath(args.output))
    os.makedirs(outdir, exist_ok=True)
    tmp_out = args.output + ".tmp"
    raw = None
    try:
        with open(tmp_out, "wb") as out:
            if args.disk:
                raw = convert(args.disk, outdir)
                with open(raw, "rb") as src:
                    src_start, p9_size = plan9_part(src, args.disk)
                    out.flush()
                    copied = copy_sparse(src, out, src_start * SECT, p9_start * SECT, p9_size * SECT)
            end = p9_start + p9_size
            # Round the image up to a whole MiB.
            end = -(-end // 2048) * 2048
            out.truncate(end * SECT)

            fat.write(out, ESP_START * SECT)

            mbr = bytearray(SECT)
            struct.pack_into("<I", mbr, 440, int(now) & 0xFFFFFFFF or 1)  # disk signature
            mbr[446:462] = mbr_entry(False, args.esp_type, ESP_START, esp_sect)
            if p9_size:
                mbr[462:478] = mbr_entry(False, 0x39, p9_start, p9_size)
            mbr[510:512] = b"\x55\xaa"
            out.seek(0)
            out.write(mbr)
        os.replace(tmp_out, args.output)
    finally:
        if raw:
            os.unlink(raw)
        if os.path.exists(tmp_out):
            os.unlink(tmp_out)

    print("mkusb: %s: %d MiB" % (args.output, end * SECT >> 20))
    print("  1  type %#04x  sectors %8d..%-8d  FAT%d boot volume, %d files, %d KiB of %d MiB used" % (
        args.esp_type, ESP_START, ESP_START + esp_sect - 1, fat.bits, len(files),
        (fat.next - 2) * fat.csize >> 10, args.esp_mb))
    if p9_size:
        print("  2  type 0x39  sectors %8d..%-8d  Plan 9 partition from %s (%d MiB of data)" % (
            p9_start, p9_start + p9_size - 1, os.path.basename(args.disk), copied >> 20))


def check(image, files, disk):
    with open(image, "rb", buffering=0) as f:
        parts = read_mbr(f)
        if not parts or parts[0][0] not in (0xEF, 0x0C, 0x0B, 0x0E, 0x06):
            die("check: no FAT partition first in the MBR of " + image)
        for i, (t, s, n) in enumerate(parts):
            if t:
                print("  %d  type %#04x  start %d  size %d" % (i + 1, t, s, n))
        r = FatReader(f, parts[0][1] * SECT)
        found = dict(r.walk())
        for name in sorted(found):
            print("  %8d  %s" % (len(found[name]), name))
        bad = 0
        for dest, src in files:
            with open(src, "rb") as sf:
                want = sf.read()
            if found.get(dest) != want:
                print("mkusb: check: %s differs from %s" % (dest, src), file=sys.stderr)
                bad += 1
        if len(found) != len(files) and files:
            print("mkusb: check: %d files in the volume, %d expected" % (len(found), len(files)), file=sys.stderr)
            bad += 1
        if bad:
            sys.exit(1)
        print("mkusb: check: FAT%d volume reads back correctly" % r.bits)

        # A second opinion, where the host has one.
        fsck = shutil.which("fsck.fat", path=os.environ.get("PATH", "") + ":/usr/sbin:/sbin")
        if fsck:
            with tempfile.NamedTemporaryFile(prefix="mkusb-", suffix=".fat") as t:
                f.seek(parts[0][1] * SECT)
                t.write(f.read(parts[0][2] * SECT))
                t.flush()
                p = subprocess.run([fsck, "-n", t.name], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
                if p.returncode != 0:
                    sys.stderr.write(p.stdout.decode(errors="replace"))
                    die("check: fsck.fat finds fault with the boot volume")
            print("mkusb: check: fsck.fat agrees")

        if disk:
            mine = [(s, n) for t, s, n in parts if t == 0x39]
            if len(mine) != 1:
                die("check: no Plan 9 partition in " + image)
            raw = convert(disk, os.path.dirname(os.path.abspath(image)))
            try:
                with open(raw, "rb", buffering=0) as src:
                    start, size = plan9_part(src, disk)
                    if size != mine[0][1]:
                        die("check: Plan 9 partition has %d sectors, the one in %s has %d" % (mine[0][1], disk, size))
                    src.seek(start * SECT)
                    f.seek(mine[0][0] * SECT)
                    left = size * SECT
                    while left:
                        n = min(left, 8 << 20)
                        if src.read(n) != f.read(n):
                            die("check: Plan 9 partition differs from the one in %s near byte %d" % (disk, size * SECT - left))
                        left -= n
            finally:
                os.unlink(raw)
            print("mkusb: check: Plan 9 partition is the same as in %s" % os.path.basename(disk))


def main():
    ap = argparse.ArgumentParser(description="Write a bootable planZ USB disk image.",
                                 epilog="Each DEST=SRC puts the host file SRC into the boot volume as DEST.")
    ap.add_argument("-o", "--output", help="image file to write")
    ap.add_argument("--check", metavar="IMAGE", help="read the boot volume of IMAGE back instead")
    ap.add_argument("--disk", help="9front disk image (qcow2 or raw) to take the Plan 9 partition from")
    ap.add_argument("--esp-mb", type=int, default=40, help="size of the boot volume in MiB (default 40)")
    ap.add_argument("--esp-type", type=lambda s: int(s, 16), default=0xEF,
                    help="MBR type of the boot volume in hex (default ef, the EFI system partition; 0c is plain FAT32)")
    ap.add_argument("--label", default="PLANZ", help="volume label (default PLANZ)")
    ap.add_argument("files", nargs="*", metavar="DEST=SRC")
    args = ap.parse_args()

    files = []
    for a in args.files:
        dest, eq, src = a.partition("=")
        if not eq or not dest or not src:
            die("%s: want DEST=SRC" % a)
        files.append((dest, src))
    if args.check:
        check(args.check, files, args.disk)
    elif args.output:
        if not files:
            die("no files for the boot volume")
        build(args, files)
    else:
        ap.error("need -o IMAGE or --check IMAGE")


main()
