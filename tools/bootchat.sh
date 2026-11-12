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
# connect the serial port to stdio.  With CHATLOG=file in the
# environment, the serial output of a completed conversation is kept there.
#
# A `send` that starts with "@host " is not typed: the rest is run here
# as a shell command (to press keys or take a picture through QEMU's
# monitor, say), and the conversation fails if the command does.

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

# 9front's kbdfs cooks typed lines in a 256-rune buffer and hands each
# rune to its cooking thread with a non-blocking send: when the buffer
# fills, the thread is busy passing it on and the next rune is lost,
# every time (stock 9front and planZ alike).  So no typed line may be
# that long.  (A character typed just after a newline can be lost the
# same way, now and then; waiting for output between lines avoids it.)
i=0
for a in "$@"; do
	[ $i -ge $n ] && break
	if [ $((i % 2)) -eq 1 ] && [ "${a#@host }" = "$a" ] && [ ${#a} -ge 256 ]; then
		echo "boot chat: a typed line of ${#a} bytes; kbdfs loses the 257th character of a line, so keep them under 256: $(printf '%s' "$a" | cut -c1-60)..." >&2
		exit 2
	fi
	i=$((i + 1))
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
		[ -z "$want" ] && break		# nothing to wait for
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
		case $(cat "$dir/step$i") in
		"@host "*)
			if ! sh -c "$(cut -c7- "$dir/step$i")"; then
				echo "boot chat: host command failed: $(cat "$dir/step$i")" >&2
				exit 1
			fi
			i=$((i + 1))
			continue
			;;
		esac
		# A little at a time: with rio running, 9front's kbdfs drops
		# typed characters once 128 of them are waiting.
		fold -b -w 24 "$dir/step$i" | while IFS= read -r part || [ -n "$part" ]; do
			printf '%s' "$part" >&3
			sleep 0.05
		done
		printf '\n' >&3
		i=$((i + 1))
	fi
done
[ -n "$CHATLOG" ] && cp "$log" "$CHATLOG"
echo "boot chat: conversation completed"
exit 0
