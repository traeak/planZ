#!/bin/sh
# Boot the kernel in QEMU and hold a conversation on its serial console.
#
# usage: bootchat.sh timeout-seconds expect [send expect]... -- qemu-command...
#
# Waits for the first `expect` text in the serial output, then types
# `send` followed by a newline and waits for the next `expect`, and so
# on.  Each text is looked for only in what was printed after the
# previous one matched.  Exits 0 when the last text has appeared, 1 on
# timeout, if QEMU exits, or on a kernel panic.  The QEMU command must
# connect the serial port to stdio.

if [ $# -lt 4 ]; then
	echo "usage: $0 seconds expect [send expect]... -- qemu-command..." >&2
	exit 2
fi
timeout=$1
shift

dir=$(mktemp -d)
log=$dir/log
mkfifo "$dir/in"

# Split the arguments at "--".
n=0
for a in "$@"; do
	[ "$a" = "--" ] && break
	n=$((n + 1))
done
steps=$n
i=0
for a in "$@"; do
	[ $i -ge $steps ] && break
	printf '%s' "$a" >"$dir/step$i"
	i=$((i + 1))
done
shift $((steps + 1))

"$@" <"$dir/in" >"$log" 2>&1 &
qemu=$!
exec 3>"$dir/in"
trap 'kill $qemu 2>/dev/null; exec 3>&-; rm -rf "$dir"' EXIT

ticks=$((timeout * 10))
pos=1		# byte of the log to search from
i=0
while [ $i -lt $steps ]; do
	want=$(cat "$dir/step$i")
	while :; do
		if tail -c +$pos "$log" | grep -a -q -F -- "$want"; then
			break
		fi
		if tail -c +$pos "$log" | grep -a -q -F -- "panic: "; then
			echo "boot chat: kernel panic while waiting for '$want'; serial output was:" >&2
			cat "$log" >&2
			exit 1
		fi
		if [ $ticks -le 0 ] || ! kill -0 $qemu 2>/dev/null; then
			echo "boot chat: '$want' not seen; serial output was:" >&2
			cat "$log" >&2
			exit 1
		fi
		sleep 0.1
		ticks=$((ticks - 1))
	done
	# Later texts must come after this point.
	pos=$(($(wc -c <"$log") + 1))
	i=$((i + 1))
	if [ $i -lt $steps ]; then
		printf '%s\n' "$(cat "$dir/step$i")" >&3
		i=$((i + 1))
	fi
done
echo "boot chat: conversation completed"
exit 0
