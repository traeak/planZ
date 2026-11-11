#!/bin/sh
# Boot stock 9front from the disk image into rio and check the screen,
# the keyboard and the mouse through QEMU's monitor:
#   - a screenshot must be mostly rio's grey background;
#   - a command typed on the emulated keyboard must run in rio's window;
#   - moving the emulated mouse must change the kernel's mouse position.
#
# usage: riotest.sh timeout-seconds qemu-command...
#
# The QEMU command must connect the serial port to stdio and have the
# 9front disk; plan9.ini should set mouseport=ps2 if the mouse is PS/2.
# With RIOSHOT=file.png in the environment a screenshot is kept there.

if [ $# -lt 2 ]; then
	echo "usage: $0 seconds qemu-command..." >&2
	exit 2
fi
timeout=$1
shift
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
print("rio test: %d%% of the screen is rio's background" % (grey * 100 // n))
sys.exit(0 if grey * 5 > n else 1)
PY

pos="dd -if '#m/mousein' -bs 60 -count 1 -quiet 1 | awk '{print \$2+\$3}'"

sh "$here/bootchat.sh" "$timeout" \
	"bootargs is" "" \
	"user[" "" \
	"term%" "echo serial^ok" \
	"serialok" "@host sleep 4; $qmp shot $tmp/s.ppm && python3 -I $tmp/grey.py $tmp/s.ppm" \
	"" "@host $qmp type 'echo key^ok >/dev/eia0\\n'" \
	"keyok" "a=\`{$pos}; echo a^is \$a" \
	"ais" "@host $qmp move 40 30 , move 40 30 , move 40 30" \
	"" "b=\`{$pos}; echo b^is \$b; ~ \$a \$b || echo mouse^ok" \
	"mouseok" "@host ${RIOSHOT:+$qmp shot $RIOSHOT} :" \
	"" \
	-- "$@" -qmp "unix:$tmp/qmp,server=on,wait=off"
