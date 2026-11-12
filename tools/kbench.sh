#!/bin/sh
# Compare kernels on the same machine, the same disk and the same
# user programs: stock 9front's 9pc64 and planZ at any revisions.
#
# usage: [RUNS=5] [SMP=1] [PAR=4] [TCG=1] [OUT=dir] kbench.sh kernel...
#
# A kernel is "9front" (ref/root/amd64/9pc64, booted by 9front's own
# UEFI loader taken from the ISO in ref/iso), "." (this tree) or a git
# revision of planZ (built in a temporary worktree).  Every kernel
# boots in the same QEMU machine: q35, OVMF, KVM with the host's CPU,
# SMP processors, 4GB, virtio-net, and the disk as a virtio disk.
#
# First, once, this tree's planZ boots a writable overlay of the 9front
# disk image (made here; the image itself is never written), compiles
# tools/kbench/bench.c there with 6c and 6l into /usr/glenda/bench,
# and changes glenda's profile so that it does not start rio when
# plan9.ini sets norio=1.  Every timed boot then opens that overlay as
# a snapshot with norio=1: the profile ends, init starts a plain rc on
# the console, and the same binary runs with nothing drawing on the
# screen (see bench.c's header for the tests).  Runs are interleaved,
# kernel by kernel, RUNS times.  The host also times each benchmark
# run, from typing the command to seeing its last line, as a check on
# each kernel's clock.
#
# Needs KVM (TCG=1 runs without it, slowly and with timings that mean
# less), qemu-system-x86_64 and qemu-img, OVMF, python3, 7z (to take
# 9front's loader out of the ISO), and ref/ as for the other tests.
#
# Results go to OUT (default zig-out/kbench): the preparation's and
# each run's serial log, results.tsv, and summary.txt, which is also
# printed: per test and kernel, the median time per operation and the
# fastest and slowest run.

here=$(cd "$(dirname "$0")" && pwd)
top=$(cd "$here/.." && pwd)
cd "$top" || exit 1
runs=${RUNS:-5}
smp=${SMP:-1}
par=${PAR:-4}
out=${OUT:-zig-out/kbench}
disk=$top/ref/disk/9front-11952.amd64.qcow2
firmware=/usr/share/qemu/edk2-x86_64-code.fd

if [ $# -lt 1 ]; then
	echo "usage: [RUNS=n] [SMP=n] [PAR=n] [TCG=1] [OUT=dir] $0 9front|.|revision..." >&2
	exit 2
fi
for f in "$disk" ref/root/amd64/9pc64 ref/iso/9front-11952.amd64.iso ref/boot/boot ref/boot/bootfs.paq "$firmware"; do
	if [ ! -e "$f" ]; then
		echo "kbench: missing $f" >&2
		exit 1
	fi
done
if [ -n "$TCG" ]; then
	accel=""
	cpu=max
else
	if [ ! -w /dev/kvm ]; then
		echo "kbench: /dev/kvm is not usable; TCG=1 runs without it" >&2
		exit 1
	fi
	accel=-enable-kvm
	# The host's full address width lets OVMF put devices near 56TiB,
	# which the two kernels map by different code; keep them low.
	cpu=host,host-phys-bits-limit=39
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$out"
rm -f "$out"/run-*.log "$out/results.tsv" "$out/prepare.log" "$out/summary.txt"

# The QEMU command line, for a processor count, a boot volume and the
# disk's drive options.
qemucmd() {
	echo qemu-system-x86_64 -machine q35 $accel -cpu "$cpu" -m 4G -smp "$1" \
		-drive if=pflash,format=raw,readonly=on,file=$firmware \
		-drive format=raw,file=fat:rw:"$2" -net none \
		-netdev user,id=n0 -device virtio-net-pci,netdev=n0,disable-legacy=on \
		-drive if=none,id=d0,"$3" -device virtio-blk-pci,drive=d0,disable-legacy=on \
		-serial stdio -display none -no-reboot
}

# A boot volume for planZ from a built source tree.
planzesp() {
	mkdir -p "$2/EFI/BOOT" "$2/boot"
	cp "$1/zig-out/esp/EFI/BOOT/BOOTX64.EFI" "$2/EFI/BOOT/BOOTX64.EFI"
	cp "$1/zig-out/esp/planz" "$2/planz"
	cp ref/boot/boot ref/boot/bootfs.paq "$2/boot/"
	cp ref/root/amd64/bin/paqfs "$2/boot/paqfs"
	cp ref/root/amd64/bin/auth/factotum "$2/boot/factotum"
}

# The overlay, prepared by this tree's kernel.  The profile still
# starts rio here, so the console window is clicked first, as the tests
# do (see riofocus.sh): rio's focus race otherwise sends what is typed
# to another window now and then.
echo "kbench: building planZ . and preparing the disk" >&2
zig build || exit 1
planzesp "$top" "$tmp/prep"
cp tools/kbench/bench.c "$tmp/prep/bench.c"
printf 'console=0\n*selftest=off\n' >"$tmp/prep/plan9.ini"
qemu-img create -q -f qcow2 -F qcow2 -b "$disk" "$tmp/disk.qcow2" || exit 1
if ! CHATLOG=$out/prepare.log sh tools/bootchat.sh 400 \
	"bootargs is" "" \
	"user[" "" \
	"term%" "@host sh tools/riofocus.sh $tmp/qmp" \
	"" "dossrv -f /dev/sdE0/dos kb && mount -c /srv/kb /n/kb && echo mnt^ok" \
	"mntok" "cd /usr/glenda && cp /n/kb/bench.c . && 6c bench.c && 6l -o bench bench.6 && echo cc^ok" \
	"ccok" "sed 's/rio -i riostart/if(! ~ \$norio 1) rio -i riostart/' lib/profile >/tmp/p && cp /tmp/p lib/profile && grep -c norio lib/profile && echo pr^ok" \
	"prok" "fshalt" \
	"done halting" \
	-- $(qemucmd 1 "$tmp/prep" "file=$tmp/disk.qcow2") \
	-device qemu-xhci -device usb-tablet -qmp "unix:$tmp/qmp,server=on,wait=off" >"$tmp/chat" 2>&1; then
	echo "kbench: preparing the disk failed:" >&2
	tail -20 "$tmp/chat" >&2
	exit 1
fi

# One boot volume per kernel.
n=0
for k in "$@"; do
	n=$((n + 1))
	esp=$tmp/esp$n
	case $k in
	9front)
		mkdir -p "$esp/EFI/BOOT"
		7z x -o"$tmp/iso" -y ref/iso/9front-11952.amd64.iso 386/bootx64.efi >/dev/null || exit 1
		cp "$tmp/iso/386/bootx64.efi" "$esp/EFI/BOOT/BOOTX64.EFI"
		cp ref/root/amd64/9pc64 "$esp/9pc64"
		printf 'bootfile=/9pc64\nconsole=0\nnorio=1\n' >"$esp/plan9.ini"
		;;
	*)
		if [ "$k" = . ]; then
			src=$top
		else
			src=$tmp/wt$n
			git worktree add --detach "$src" "$k" >/dev/null 2>&1 || { echo "kbench: no revision $k" >&2; exit 1; }
			echo "kbench: building planZ $k" >&2
			(cd "$src" && zig build) || { git worktree remove --force "$src"; exit 1; }
		fi
		planzesp "$src" "$esp"
		[ "$k" != . ] && git worktree remove --force "$src"
		printf 'console=0\n*selftest=off\nnorio=1\n' >"$esp/plan9.ini"
		;;
	esac
done

args=""
[ "$smp" -gt 1 ] && args="-p $par"

r=0
while [ $r -lt "$runs" ]; do
	r=$((r + 1))
	n=0
	for k in "$@"; do
		n=$((n + 1))
		log=$out/run-$r-$n.log
		rm -f "$tmp/t0" "$tmp/t1"
		echo "kbench: run $r, kernel $k" >&2
		CHATLOG=$log sh tools/bootchat.sh 400 \
			"bootargs is" "" \
			"user[" "" \
			"starting /bin/rc" "" \
			"starting /bin/rc" "@host date +%s%N >$tmp/t0" \
			"" "/usr/glenda/bench $args" \
			"bench done" "@host date +%s%N >$tmp/t1" \
			"" \
			-- $(qemucmd "$smp" "$tmp/esp$n" "snapshot=on,file=$tmp/disk.qcow2") >"$tmp/chat" 2>&1
		if [ $? -ne 0 ] || [ ! -s "$tmp/t1" ]; then
			echo "kbench: run $r of $k failed:" >&2
			tail -20 "$tmp/chat" >&2
			continue
		fi
		# Which kernel ran: planZ's loader names itself.
		if grep -a -q "planz loader" "$log"; then ran=planZ; else ran=9front; fi
		case $k in
		9front) want=9front ;;
		*) want=planZ ;;
		esac
		if [ $ran != $want ]; then
			echo "kbench: run $r: expected $want, saw $ran" >&2
			exit 1
		fi
		host=$(($(cat "$tmp/t1") - $(cat "$tmp/t0")))
		tr -d '\r' <"$log" | awk -v k="$k" -v r="$r" -v h="$host" '
			$1 == "bench" && $3 == "n" { print k "\t" r "\t" $2 "\t" $4 "\t" $6 "\t" $8 }
			$1 == "bench" && $2 == "done" { print k "\t" r "\ttotal\t1\t" $4 "\t" $4; print k "\t" r "\thost\t1\t" h "\t" h }
		' >>"$out/results.tsv"
	done
done

[ -s "$out/results.tsv" ] || { echo "kbench: no results" >&2; exit 1; }
python3 -I - "$out/results.tsv" "$smp" "$runs" "${TCG:+TCG}" "$@" <<'PY' | tee "$out/summary.txt"
import sys, statistics
path, smp, runs, tcg = sys.argv[1:5]
kernels = sys.argv[5:]
rows = [l.rstrip("\n").split("\t") for l in open(path) if l.strip()]
tests = []
for k, r, t, n, ns, per in rows:
    if t not in tests and t not in ("total", "host"):
        tests.append(t)
print("kbench: %s processor(s), %s runs, %s, planZ built ReleaseSafe; ns per operation, median [fastest, slowest]"
      % (smp, runs, "TCG" if tcg else "KVM"))
w = max(max(len(k) for k in kernels) + 2, 24)
print("%-10s" % "test" + "".join("%*s" % (w, k) for k in kernels))
def cell(vals):
    if not vals:
        return "-"
    return "%d [%d, %d]" % (statistics.median(vals), min(vals), max(vals))
for t in tests + ["total", "host"]:
    line = "%-10s" % t
    for k in kernels:
        vals = [int(per) for kk, r, tt, n, ns, per in rows if kk == k and tt == t]
        if t in ("total", "host"):
            vals = [v // 1000000 for v in vals]
        line += "%*s" % (w, cell(vals))
    print(line)
print("(total and host: milliseconds for the whole timed run, by the guest's clock and by the host's)")
for k in kernels:
    tot = {r: int(ns) for kk, r, t, n, ns, per in rows if kk == k and t == "total"}
    hst = {r: int(ns) for kk, r, t, n, ns, per in rows if kk == k and t == "host"}
    ratios = [hst[r] / tot[r] for r in tot if r in hst and tot[r]]
    if ratios:
        print("%s: host/guest time %.3f (median of %d runs)" % (k, statistics.median(ratios), len(ratios)))
PY
