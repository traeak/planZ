#!/bin/sh
# Boot zig-out/esp in headless QEMU for a while and print the kernel's
# serial output.  For looking at a boot by hand.
#
# usage: [SMP=n] [DISK=image [DISKBUS=virtio|nvme|ahci]] qrun.sh [seconds [cpu [plan9.ini text]]]
case ${DISKBUS:-virtio} in
nvme) diskdev=nvme,drive=d0,serial=planz0 ;;
ahci) diskdev=ide-hd,drive=d0,bus=ide.2 ;;
*) diskdev=virtio-blk-pci,drive=d0,disable-legacy=on ;;
esac
secs=${1:-10}
cpu=${2:-SandyBridge}
d=$(mktemp -d)
trap 'rm -rf "$d"' EXIT
cp -r zig-out/esp "$d/esp"
[ -n "$3" ] && printf '%b' "$3" >"$d/esp/plan9.ini"
timeout "$secs" qemu-system-x86_64 -machine q35 -cpu "$cpu" -m 512M -smp "${SMP:-4}" \
	-drive if=pflash,format=raw,readonly=on,file=/usr/share/qemu/edk2-x86_64-code.fd \
	-drive format=raw,file=fat:rw:"$d/esp" -net none -serial file:"$d/log" \
	-netdev user,id=n0 -device virtio-net-pci,netdev=n0,disable-legacy=on \
	${DISK:+-drive if=none,id=d0,snapshot=on,file="$DISK" -device "$diskdev"} \
	-no-reboot -display none >/dev/null 2>&1
sed 's/\x1b\[[0-9;=?]*[a-zA-Z]//g' "$d/log" | tr -d '\r' | sed -n '/^Plan 9/,$p'
