#!/bin/sh
# Boot stock 9front from the disk image with session=text (see
# tools/session) and check what comes up:
#   - the profile has run as for service=con: its prompt is "cpu% ";
#   - no rio is running;
#   - a command typed on the emulated keyboard runs in that shell.
# With console=0 kbdfs reads the serial line as well as the keyboard,
# so the conversation is held on the serial port.
#
# usage: texttest.sh timeout-seconds qemu-command...
#
# The QEMU command must connect the serial port to stdio and have the
# 9front disk; the boot volume's plan9.ini must say session=text.

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

sh "$here/bootchat.sh" "$timeout" \
	"bootargs is" "" \
	"user[" "" \
	"cpu% " "if(! ps | grep -s ' rio\$') echo no^rio" \
	"norio" "@host $qmp type 'echo key^ok\\n'" \
	"keyok" \
	-- "$@" -qmp "unix:$tmp/qmp,server=on,wait=off"
