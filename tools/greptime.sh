#!/bin/sh
# Time planZ's grep against stock 9front's, in the guest, on planZ.
#
# usage: [ROUNDS=5] [TCG=1] [OUT=dir] greptime.sh
#
# planZ boots the 9front disk image (a snapshot: never written) in a
# QEMU machine as kbench.sh's: q35, OVMF, KVM with the host's CPU, one
# processor, 4GB.  The session is text (no rio).  The guest takes
# planZ's grep and tools/greptime.rc from the boot volume and runs the
# script (see its header): the manual repeated to 32MB in a ramfs,
# read 8 times a run, each case by both programs in turn, ROUNDS
# times.  Both programs' outputs over the text are compared first.
#
# Results go to OUT (default zig-out/greptime): the serial log and
# summary.txt, which is also printed: per case, the lines both printed
# (for -c, the count), the user and real seconds of each program's
# fastest round, and stock's time over planZ's.
#
# Needs KVM (TCG=1 runs without it, slowly and with timings that mean
# less), qemu-system-x86_64, OVMF, python3, and ref/ as for the other
# tests.

here=$(cd "$(dirname "$0")" && pwd)
top=$(cd "$here/.." && pwd)
cd "$top" || exit 1
rounds=${ROUNDS:-5}
out=${OUT:-zig-out/greptime}
disk=$top/ref/disk/9front-11952.amd64.qcow2
firmware=/usr/share/qemu/edk2-x86_64-code.fd

for f in "$disk" ref/boot/boot ref/boot/bootfs.paq "$firmware"; do
	if [ ! -e "$f" ]; then
		echo "greptime: missing $f" >&2
		exit 1
	fi
done
if [ -n "$TCG" ]; then
	accel=""
	cpu=max
else
	if [ ! -w /dev/kvm ]; then
		echo "greptime: /dev/kvm is not usable; TCG=1 runs without it" >&2
		exit 1
	fi
	accel=-enable-kvm
	cpu=host,host-phys-bits-limit=39
fi

zig build && zig build user || exit 1
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$out"
rm -f "$out/serial.log" "$out/summary.txt"

esp=$tmp/esp
mkdir -p "$esp/EFI/BOOT" "$esp/boot"
cp zig-out/esp/EFI/BOOT/BOOTX64.EFI "$esp/EFI/BOOT/BOOTX64.EFI"
cp zig-out/esp/planz "$esp/planz"
cp ref/boot/boot ref/boot/bootfs.paq "$esp/boot/"
cp ref/root/amd64/bin/paqfs "$esp/boot/paqfs"
cp ref/root/amd64/bin/auth/factotum "$esp/boot/factotum"
cp tools/session "$esp/boot/session"
cp zig-out/user/bin/grep "$esp/zgrep"
cp tools/greptime.rc "$esp/gt.rc"
printf 'console=0\n*selftest=off\ninit=/boot/session\nsession=text\n' >"$esp/plan9.ini"

if ! CHATLOG=$out/serial.log sh tools/bootchat.sh $((300 + rounds * 240)) \
	"bootargs is" "" \
	"user[" "" \
	"cpu% " "dossrv -f /dev/sdE0/dos gt && mount /srv/gt /n/esp && echo mnt^ok" \
	"mntok" "rc /n/esp/gt.rc /n/esp/zgrep $rounds" \
	"gt done" \
	-- qemu-system-x86_64 -machine q35 $accel -cpu "$cpu" -m 4G -smp 1 \
	-drive if=pflash,format=raw,readonly=on,file=$firmware \
	-drive format=raw,file=fat:rw:"$esp" -net none \
	-drive if=none,id=d0,snapshot=on,file="$disk" -device virtio-blk-pci,drive=d0,disable-legacy=on \
	-serial stdio -display none -no-reboot >"$tmp/chat" 2>&1; then
	echo "greptime: the run failed:" >&2
	tail -30 "$tmp/chat" >&2
	exit 1
fi

python3 -I - "$out/serial.log" "$rounds" "${TCG:+TCG}" >"$out/summary.txt" <<'PY'
import re, sys
path, rounds, tcg = sys.argv[1:4]
cases, t, same, cur, text, bad = [], {}, {}, None, "", False
for l in open(path, errors="replace").read().replace("\r", "").split("\n"):
    m = re.match(r"gt run (\S+) (stock|zig)$", l)
    if m:
        cur = m.groups()
        continue
    m = re.match(r"(\d+\.\d+)u (\d+\.\d+)s (\d+\.\d+)r", l)
    if m and cur:
        t.setdefault(cur, []).append([float(x) for x in m.groups()])
        cur = None
        continue
    m = re.match(r"gt same (\S+) (\d+) lines ?(\d+$)?", l)
    if m:
        cases.append(m.group(1))
        # the lines printed, or what -c printed
        same[m.group(1)] = m.group(3) if m.group(2) == "1" and m.group(3) else m.group(2)
    m = re.match(r"gt differ (\S+)", l)
    if m:
        cases.append(m.group(1))
        bad = True
        print("greptime: the outputs DIFFER in case %s" % m.group(1))
    m = re.match(r"gt text (\d+) bytes (\d+) lines", l)
    if m:
        text = "%.0fMB, %s lines" % (int(m.group(1)) / 1e6, m.group(2))
print("greptime: %s, read 8 times a run; %s, 1 processor; seconds, the fastest of %s rounds"
      % (text, "TCG" if tcg else "KVM", rounds))
print("%-8s %10s  %6s %6s  %6s %6s  %s" % ("case", "lines", "stock", "", "planZ", "", "stock/planZ"))
print("%-8s %10s  %6s %6s  %6s %6s  %6s %6s" % ("", "", "user", "real", "user", "real", "user", "real"))
for c in cases:
    s, z = t.get((c, "stock"), []), t.get((c, "zig"), [])
    if len(s) != int(rounds) or len(z) != int(rounds):
        print("%-8s incomplete: %d and %d runs" % (c, len(s), len(z)))
        bad = True
        continue
    # the fastest: other work on the host only ever adds time
    best = lambda v, i: min(x[i] for x in v)
    su, sr, zu, zr = best(s, 0), best(s, 2), best(z, 0), best(z, 2)
    ratio = lambda a, b: "%6.2f" % (a / b) if b else "     -"
    print("%-8s %10s  %6.2f %6.2f  %6.2f %6.2f  %s %s"
          % (c, same.get(c, "?"), su, sr, zu, zr, ratio(su, zu), ratio(sr, zr)))
sys.exit(1 if bad or not cases else 0)
PY
status=$?
cat "$out/summary.txt"
exit $status
