#!/usr/bin/env bash
# One number for "is the US-600's MIDI engine healthy right now".
#
# The metric is the driver's own error log: `[ploytec] isoc: MIDI output error 0xffffffb9`
# (-71 = -EPROTO). It only tells you something while the engine is streaming — with no PCM
# substream open the driver submits nothing, so "0 errors" proves nothing. This script
# therefore opens playback for ~2 s, counts the new lines, and closes it.
#
# Usage: scripts/midi-health.sh [-s seconds] [-q]
#   -s  measurement window (default 2)
#   -q  quiet: print only the count
#
# 0 errors  -> the device accepts the 9-byte MIDI URBs (engine running, MIDI out drains)
# ~1000/s   -> every transfer is refused: the device is in the state this project spent a day
#              on. A real power cycle (external supply AND USB, 10 s) clears it; a module
#              reload and a USB-only unplug do not. See docs/us600-findings.md.
#
# Exit status: 0 healthy, 1 unhealthy, 2 no card.
set -uo pipefail

SECS=2
QUIET=0

while getopts "s:qh" opt; do
	case $opt in
	s) SECS=$OPTARG ;;
	q) QUIET=1 ;;
	h) sed -n '2,19p' "$0"; exit 0 ;;
	*) exit 2 ;;
	esac
done

say() { [ "$QUIET" -eq 1 ] || echo "$@"; }

CARDIDX=""
for id in /proc/asound/card*/id; do
	[ "$(cat "$id" 2>/dev/null)" = "US600" ] || continue
	idx=${id#/proc/asound/card}
	CARDIDX=${idx%%/*}
done
if [ -z "$CARDIDX" ]; then
	say "no US600 card: is the device plugged in? (lsusb -d 0644:8035)"
	exit 2
fi

DEV=$(lsusb -d 0644:8035 2>/dev/null | sed 's/.*Device \([0-9]*\).*/\1/')
say "card $CARDIDX, device ${DEV:-?}"

# The engine only submits MIDI URBs while a PCM substream runs.
aplay -D "hw:$CARDIDX,0" -f S24_3LE -c 4 -r 48000 /dev/zero 2>/dev/null &
AP=$!
sleep 0.8

ERRORS=$(timeout "$SECS" dmesg -W 2>/dev/null | grep -c 'MIDI output error')

kill $AP 2>/dev/null
wait $AP 2>/dev/null

say "MIDI output errors in ${SECS}s: $ERRORS"
[ "$QUIET" -eq 1 ] && echo "$ERRORS"
if [ "$ERRORS" -eq 0 ]; then
	say "healthy"
	exit 0
fi
say "unhealthy: power cycle the device (external supply AND USB), then measure again"
exit 1
