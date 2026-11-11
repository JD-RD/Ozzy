#!/usr/bin/env bash
# The US-600 bench on the Raspberry Pi, measured instead of remembered.
#
# One pass runs the Phase 4 checks of docs/plan.md and prints a table: for each step the exit
# status, how long it took, how many `MIDI output error` lines the kernel logged while it ran,
# and the engine's own counters ("Ozzy Stats": recoveries, then per direction transfers /
# errors / short transfers / late completions / longest gap) afterwards. Two runs are then
# comparable (Mint, 3B, before and after a setting), which is the point: what this bench has
# failed on so far depends on the order the streams are opened, not on the rate alone.
#
# Usage: scripts/pi-bench.sh [-r] [-c] [-j] [-t FRAMES] [-q TRANSFERS] [-s SECONDS]
#   (no option)      playback 44.1/48/88.2/96 kHz, then capture 44.1/48/96 kHz, twice each
#   -c               add the step that broke first here: playback and capture at once
#   -r               reload the module first (root, or via sudo)
#   -t FRAMES        set "PCM Capture Transfer" (e.g. 8) before the steps
#   -q TRANSFERS     set "PCM Capture Queue" (1-4) before the steps
#   -s SECONDS       concurrency step length (default 5)
#   -j               JSON lines instead of the table
#
# Exit status: 0 every step passed, 1 at least one failed, 2 no card.
#
# "Ozzy Stats" is engine/shared/ozzy_stats.h, served as a bytes control. The two knobs are the
# ones docs/plan.md §6 names; they are plain ALSA controls, so amixer does the job and
# ozzy-cli is not needed on the Pi.
set -uo pipefail

RELOAD=0
CONCURRENCY=0
JSON=0
CAP_TRANSFER=""
CAP_QUEUE=""
SECS=5

while getopts "rcjt:q:s:h" opt; do
	case $opt in
	r) RELOAD=1 ;;
	c) CONCURRENCY=1 ;;
	j) JSON=1 ;;
	t) CAP_TRANSFER=$OPTARG ;;
	q) CAP_QUEUE=$OPTARG ;;
	s) SECS=$OPTARG ;;
	h) sed -n '2,27p' "$0"; exit 0 ;;
	*) exit 2 ;;
	esac
done

CARD=""
for id in /proc/asound/card*/id; do
	[ "$(cat "$id" 2>/dev/null)" = "US600" ] || continue
	idx=${id#/proc/asound/card}
	CARD=${idx%%/*}
done
if [ -z "$CARD" ]; then
	echo "no US600 card: is the device plugged in? (lsusb -d 0644:8035)" >&2
	exit 2
fi

SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo"

FAILED=0

# --- where the numbers come from -------------------------------------------------------------

# The driver's own error log line, the metric of scripts/midi-health.sh. journalctl keeps what a
# flood pushes out of the dmesg ring (29654 lines in 30 s, measured 2026-11-11).
errors() {
	if command -v journalctl >/dev/null 2>&1; then
		journalctl -k --no-pager 2>/dev/null | grep -c 'MIDI output error'
	else
		dmesg 2>/dev/null | grep -c 'MIDI output error'
	fi
}

stats() {
	amixer -c "$CARD" cget iface=CARD,name='Ozzy Stats' 2>/dev/null | python3 -c '
import re, struct, sys
m = re.search(r"^\s*: values=(.*)$", sys.stdin.read(), re.M)
if not m:
    print("?")
    raise SystemExit
b = bytes(int(x, 16) for x in m.group(1).split(","))
rec, recf = struct.unpack_from("<II", b, 8)
out = struct.unpack_from("<QIIII", b, 16)
inp = struct.unpack_from("<QIIII", b, 40)
print(f"{rec}/{recf} {out[0]}/{out[1]}/{out[2]}/{out[3]}/{out[4]}us "
      f"{inp[0]}/{inp[1]}/{inp[2]}/{inp[3]}/{inp[4]}us")
'
}

now_ms() { date +%s%3N; }

# step LABEL SNIPPET [-s]: run the snippet, report what it did and what the counters did.
# The snippet runs in this shell, so `&` and multiple commands are fine.
step() {
	local label=$1 snippet=$2
	local before after t0 t1 rc="0" out=""
	before=$(errors)
	t0=$(now_ms)
	out=$(eval "$snippet" 2>&1) || rc=$?
	t1=$(now_ms)
	after=$(errors)
	[ "$rc" -ne 0 ] && FAILED=1
	if [ "$JSON" -eq 1 ]; then
		printf '{"step":"%s","rc":%d,"ms":%d,"proto":%d,"stats":"%s"}\n' \
			"$label" "$rc" "$((t1 - t0))" "$((after - before))" "$(stats)"
	else
		printf '%-26s %s %6s ms  +%-5s %s\n' \
			"$label" "$([ "$rc" -eq 0 ] && echo 'ok  ' || echo 'FAIL')" \
			"$((t1 - t0))" "$((after - before))" "$(stats)"
		[ "$rc" -ne 0 ] && [ -n "$out" ] && \
			printf '%-26s   %s\n' "" "$(printf '%s\n' "$out" | tail -1)"
	fi
	return 0
}

play() { aplay   -q -D "hw:$CARD,0" -f S24_3LE -c 4 -r "$1" -d "$2" /dev/zero; }
capt() { arecord -q -D "hw:$CARD,0" -f S24_3LE -c 6 -r "$1" -d "$2" /dev/null; }

# --- the pass --------------------------------------------------------------------------------

if [ "$JSON" -eq 0 ]; then
	echo "carte $CARD, noyau $(uname -r), $(lsusb -d 0644:8035 | sed 's/.*US-600/US-600/')"
	echo
	printf '%-26s %s %9s  %-6s %s\n' étape '' durée EPROTO \
		'rép/échecs  out(transf/err/courts/retard/gap)  in(...)'
fi

if [ "$RELOAD" -eq 1 ]; then
	$SUDO modprobe -r snd_usb_ozzy
	$SUDO modprobe snd_usb_ozzy
	sleep 2
	if [ -z "$(cat /proc/asound/card*/id 2>/dev/null | grep -x US600)" ]; then
		echo "the module did not bring the card back" >&2
		exit 2
	fi
fi

[ -n "$CAP_TRANSFER" ] && amixer -c "$CARD" -q sset 'PCM Capture Transfer' "$CAP_TRANSFER"
[ -n "$CAP_QUEUE" ] && amixer -c "$CARD" -q sset 'PCM Capture Queue' "$CAP_QUEUE"

[ "$JSON" -eq 0 ] && printf '%-26s %s %6s ms  %-6s %s\n' repos 'ok  ' 0 '-' "$(stats)"

step 'midi-health 2s' '"$(dirname "$0")/midi-health.sh" -s 2 -q >/dev/null'

# A rate the device is not on at the time gets a handshake, one it already runs does not; so
# each capture is measured right after a playback set that rate (fraîche: no handshake) and
# once more (encore), and the two lines are the comparison.
for r in 44100 48000 88200 96000; do
	step "play $r" "play $r 1"
	case " 44100 48000 96000 " in *" $r "*)
		step "capture $r (fraîche)" "capt $r 2"
		step "capture $r (encore)" "capt $r 2"
		;;
	esac
done

if [ "$CONCURRENCY" -eq 1 ]; then
	step 'play+capture simultanés' "
		play 48000 $SECS & ap=\$!
		sleep 1
		capt 48000 $((SECS - 1)) & ar=\$!
		wait \$ap; rc=\$?
		wait \$ar; rc=\$((rc + \$?))
		[ \$rc -eq 0 ]"
	step 'capture après concurrence' "capt 48000 2"
fi

if [ "$JSON" -eq 0 ]; then
	echo
	sed -n '/US600/,$p' /proc/asound/cards
	[ "$FAILED" -eq 1 ] && echo "au moins une étape a échoué" || echo "toutes les étapes ont passé"
fi
exit "$FAILED"
