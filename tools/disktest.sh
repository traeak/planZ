#!/bin/sh
# Boot stock 9front from the disk image and use the system that comes
# up: list /amd64/bin from the root, checksum a binary, write a file
# and read it back, and read the network card's address.
#
# usage: disktest.sh timeout-seconds qemu-command...
#
# The QEMU command must connect the serial port to stdio and have the
# 9front disk.  A USB tablet (and an xHCI controller, unless the
# command has one) and a monitor socket are added, for riofocus.sh.

if [ $# -lt 2 ]; then
	echo "usage: $0 seconds qemu-command..." >&2
	exit 2
fi
timeout=$1
shift
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
case " $* " in
*qemu-xhci*) tablet="-device usb-tablet" ;;
*) tablet="-device qemu-xhci -device usb-tablet" ;;
esac

sh "$here/bootchat.sh" "$timeout" \
	"bootargs is" "" \
	"user[" "" \
	"starting /bin/rc" "" \
	"term%" "@host sh $here/riofocus.sh $tmp/qmp" \
	"" "ls /amd64/bin | wc -l && echo root^ok" \
	"rootok" "sum /amd64/bin/acme && echo sum^ok" \
	"sumok" "echo planZ > /usr/glenda/zt && cat /usr/glenda/zt && rm /usr/glenda/zt && echo write^ok" \
	"writeok" "cat '#l0/ether0/addr' && echo && echo ether^ok" \
	"etherok" \
	-- "$@" $tablet -qmp "unix:$tmp/qmp,server=on,wait=off"
