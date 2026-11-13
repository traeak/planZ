#!/bin/sh
# Make Zig parser tables for a 9front yacc grammar with 9front's own yacc:
# boot stock 9front from the disk image, run yacc -d there, print y.tab.c
# and y.tab.h on the serial console with their SHA-1s, cut them out of
# the log here, check them, and convert them with yacc2zig.py.
#
# usage: yacctab.sh grammar-in-guest out.zig timeout-seconds qemu-command...
#	e.g. yacctab.sh /sys/src/cmd/rc/syn.y src/user/cmd/rc/syn_tab.zig 300 ...
#
# The QEMU command must connect the serial port to stdio and have the
# 9front disk (build.zig's test-zuser command will do).

if [ $# -lt 4 ]; then
	echo "usage: $0 grammar out.zig seconds qemu-command..." >&2
	exit 2
fi
grammar=$1
out=$2
timeout=$3
shift 3
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
case " $* " in
*qemu-xhci*) tablet="-device usb-tablet" ;;
*) tablet="-device qemu-xhci -device usb-tablet" ;;
esac

CHATLOG=$tmp/log sh "$here/bootchat.sh" "$timeout" \
	"bootargs is" "" \
	"user[" "" \
	"starting /bin/rc" "" \
	"term%" "@host sh $here/riofocus.sh $tmp/qmp" \
	"" "cd /tmp && yacc -d $grammar && sha1sum y.tab.c y.tab.h && echo yacc^ok" \
	"yaccok" "echo BEGIN^C; cat y.tab.c; echo END^C; echo BEGIN^H; cat y.tab.h; echo END^H; echo dump^ok" \
	"dumpok" \
	-- "$@" $tablet -qmp "unix:$tmp/qmp,server=on,wait=off" || exit 1

tr -d '\r' <"$tmp/log" >"$tmp/log2"
awk '/^BEGINC/{f=1;next}/^ENDC/{f=0}f' "$tmp/log2" >"$tmp/y.tab.c"
awk '/^BEGINH/{f=1;next}/^ENDH/{f=0}f' "$tmp/log2" >"$tmp/y.tab.h"
for f in y.tab.c y.tab.h; do
	want=$(awk -v f="$f" '$2==f && length($1)==40 {print $1}' "$tmp/log2" | head -1)
	got=$(sha1sum "$tmp/$f" | cut -d' ' -f1)
	if [ "$want" != "$got" ]; then
		echo "yacctab: $f came through damaged ($got, want $want)" >&2
		exit 1
	fi
done
python3 -I "$here/yacc2zig.py" "$tmp/y.tab.c" "$tmp/y.tab.h" "$grammar" "$out"
