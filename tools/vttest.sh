#!/bin/sh
# Boot stock 9front from the disk image to its default session (see
# tools/session): vtfs's consoles in place of rio.  With console=0 its
# first console is copied to the serial line, and kbdfs merges what
# comes in on the serial line with the keyboard, so the conversation is
# held there, with console 1 current.  Keys go through QEMU's monitor.
# Checked:
#   - no rio; vtfs running; a command typed on the keyboard runs;
#   - Ctl-Alt-2 shows console 2 (another picture) and what is typed
#     goes there; Ctl-Alt-1 shows console 1 again, the same picture as
#     before;
#   - Ctl-Alt-Left and -Right wrap round: 1, 4, 3, then 4 and 1;
#   - the kernel's messages are on console 4;
#   - Delete interrupts the command running on console 1;
#   - console 2's rc, exited, is started again.
# Each console's text is read from /dev/vt/N/text on console 1.
#
# usage: vttest.sh timeout-seconds qemu-command...
#
# The QEMU command must connect the serial port to stdio and have the
# 9front disk; the boot volume's plan9.ini must say console=0 and no
# session= other than vt.  With VTSHOT=dir in the environment the
# screenshots are kept there.

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
shots=${VTSHOT:-$tmp}

# console 1, console 2, console 1 again
switch="sleep 1; $qmp shot $shots/one.ppm"
switch="$switch && $qmp key ctrl alt 2 , type 'echo two^two\\n' && sleep 2 && $qmp shot $shots/two.ppm"
switch="$switch && $qmp key ctrl alt 1 && sleep 2 && $qmp shot $shots/again.ppm"
switch="$switch && cmp -s $shots/one.ppm $shots/again.ppm && ! cmp -s $shots/one.ppm $shots/two.ppm"
switch="$switch && echo vt test: console 1 looks the same after a switch"
# 1, 4, 3: typed there; 4, 1
wrap="$qmp key ctrl alt left , key ctrl alt left , type 'echo three^three\\n'"
wrap="$wrap && sleep 1 && $qmp key ctrl alt right , key ctrl alt right"
# console 2's rc exits and comes back
again="$qmp key ctrl alt 2 , type 'exit\\n' && sleep 3 && $qmp type 'echo again^two\\n' && sleep 1 && $qmp key ctrl alt 1"

sh "$here/bootchat.sh" "$timeout" \
	"bootargs is" "" \
	"user[" "" \
	"cpu% " "  echo go^on" \
	"goon" "if(! ps | grep -s ' rio\$') echo no^rio" \
	"norio" "ps | grep -s ' vtfs\$' && echo vt^runs" \
	"vtruns" "@host $qmp type 'echo key^ok\\n'" \
	"keyok" "@host $switch" \
	"" "grep -s twotwo /dev/vt/2/text && echo found^two" \
	"foundtwo" "@host $wrap" \
	"" "grep -s threethree /dev/vt/3/text && grep -s ' current ' /dev/wctl && echo found^three" \
	"foundthree" "echo hello^kernel >'#c/cons'; sleep 1; grep -s hellokernel /dev/vt/4/text && echo kernel^ok" \
	"kernelok" "sleep 100" \
	"" "@host sleep 2; $qmp key delete" \
	"" "echo after^int" \
	"afterint" "@host $again" \
	"" "grep -s againtwo /dev/vt/2/text && echo restart^ok" \
	"restartok" \
	-- "$@" -qmp "unix:$tmp/qmp,server=on,wait=off"
