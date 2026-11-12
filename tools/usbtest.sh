#!/bin/sh
# Boot the USB stick image (zig build usb-image) the way a PC without
# serial and PS/2 ports would: the image is the only disk, on a USB
# mass-storage device, with a USB keyboard and a USB tablet.  Checks
# that the firmware starts the loader from it, that 9front boots from
# its Plan 9 partition into rio without a key being pressed, that a
# click and typed commands reach rio's window, that the root is the USB
# disk and can be written, that the pointer moves, and that planZ's
# Zig programs on the boot volume (zig/run) install and match the
# stock programs.
#
# usage: usbtest.sh timeout-seconds image qemu-command...
#
# The image is opened as a snapshot and never changed.  The QEMU command
# must connect the serial port to stdio and must not have another disk.
#
# The image's plan9.ini has no console= line, so nothing typed on the
# serial line is read; keys and the pointer go through QEMU's monitor
# to the USB devices, as a person's would.  What the test reads comes
# from the serial line all the same: the kernel copies its console
# there, and the typed commands write their results to /dev/eia0.
# With USBSHOT=file.png in the environment a screenshot is kept there.

if [ $# -lt 3 ]; then
	echo "usage: $0 seconds image qemu-command..." >&2
	exit 2
fi
timeout=$1
image=$2
shift 2
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
qmp="python3 -I $here/qmp.py $tmp/qmp"

# rio's background is the grey 0x777777.
cat >"$tmp/grey.py" <<'PY'
import sys
d = open(sys.argv[1], "rb").read()
f, i = [], 0
while len(f) < 4:
    j = i
    while not d[j:j + 1].isspace():
        j += 1
    f.append(d[i:j])
    i = j + 1
n = int(f[1]) * int(f[2])
grey = sum(1 for k in range(i, i + n * 3, 3) if d[k:k + 3] == b"\x77\x77\x77")
sys.exit(0 if grey * 5 > n else 1)
PY

# Wait for rio to draw its background and windows, then click in the
# shell window: riostart makes two windows and either can end up the
# current one.  The window is somewhere near the top left, so a point
# a quarter of the way into a screen of 1280x800 is inside it.
cat >"$tmp/rio.sh" <<EOF2
n=0
until $qmp shot $tmp/s.ppm && python3 -I $tmp/grey.py $tmp/s.ppm; do
	n=\$((n + 1))
	[ \$n -gt 60 ] && { echo "usb test: rio did not appear" >&2; exit 1; }
	sleep 1
done
sleep 3
$qmp abs 8000 12000 , abs 8200 12200 , btn left click
EOF2

sh "$here/bootchat.sh" "$timeout" \
	"usbroot: hjfs on /dev/sdU" "" \
	"init: starting /bin/rc" "@host sh $tmp/rio.sh" \
	"" "@host $qmp type 'echo key^ok >/dev/eia0\\n'" \
	"keyok" "@host $qmp type 'ls /dev/sdU*/fs /srv/boot >/dev/eia0\\n'" \
	"/srv/boot" "@host $qmp type 'echo planZ^usb >/usr/glenda/zt && cat /usr/glenda/zt >/dev/eia0\\n'" \
	"planZusb" "@host $qmp abs 16384 16384 , abs 16390 16390 , type 'dd -if /dev/mousein -bs 60 -count 1 -quiet 1 >/dev/eia0; echo >/dev/eia0\\n'" \
	"  640         400" "@host ${USBSHOT:+$qmp shot $USBSHOT} :" \
	"" "@host $qmp type 'dossrv -f /dev/sdU*/esp esp; mount -c /srv/esp /n/esp; rc /n/esp/zig/run >/dev/eia0\\n'" \
	"zig: all the same as stock, libctest ok" \
	-- "$@" -machine q35,i8042=off -device qemu-xhci \
	-drive "if=none,id=u0,format=raw,snapshot=on,file=$image" -device usb-storage,drive=u0 \
	-device usb-kbd -device usb-tablet \
	-qmp "unix:$tmp/qmp,server=on,wait=off"
