#!/usr/bin/env bash
# Watch the US-600's MIDI endpoints on the wire (usbmon) while sending one note.
# Needs root: re-runs itself with sudo. Saves the whole capture and prints the
# lines of this device's endpoints other than 0.
#
# Usage: scripts/usbmon-midi.sh [-s seconds] [-b bus] [-o file] [-m] [-p] [-c]
#   -m  reload the module while capturing: shows the start sequence and whether
#       the first MIDI URBs fail before or after the first PCM completions
#   -p  hold playback open during the capture (speaker-test on the card)
#   -c  hold 6-channel capture open during the capture (arecord)
#       -p / -c exist because the official Windows driver always has the PCM
#       engine streaming, and the MIDI pipes may need it; run the note with no
#       stream, with -p, with -c, and with -p -c to find out which one it takes
#
# What to look for, after the note is sent:
#   Bo  bulk OUT on EP 0x04, 9 bytes, payload 90 24 64 FD FD FD FD FD E0
#       -> the completion status must be 0; -EPIPE is a STALL, -EPROTO a
#       protocol error (the old failure mode)
#   Bi  bulk IN on EP 0x83, 9 bytes
#       -> a completion with 9 bytes means the DIN loopback came back; if the
#       lines only show submissions and no completions, the device sends nothing
#       (a running engine answers an empty read with 9 bytes of 0xFD ... 0x00
#       instead of NAKing, which is how you tell "engine on, nothing to send"
#       from "engine off")
set -uo pipefail

VID=${VID:-0644}
PID=${PID:-8035}
SECS=2
BUS=""
OUT=""
RELOAD=0
PLAY=0
CAPTURE=0

while getopts "s:b:o:mpch" opt; do
	case $opt in
	s) SECS=$OPTARG ;;
	b) BUS=$OPTARG ;;
	o) OUT=$OPTARG ;;
	m) RELOAD=1 ;;
	p) PLAY=1 ;;
	c) CAPTURE=1 ;;
	h) sed -n '2,24p' "$0"; exit 0 ;;
	*) exit 2 ;;
	esac
done

if [ "$(id -u)" -ne 0 ]; then
	echo "== usbmon needs root, re-running with sudo"
	exec sudo -- "$0" "$@"
fi

DEV=""
for d in /sys/bus/usb/devices/*; do
	[ -r "$d/idVendor" ] || continue
	if [ "$(cat "$d/idVendor")" = "$VID" ] && [ "$(cat "$d/idProduct")" = "$PID" ]; then
		DEV=$d
	fi
done
if [ -z "$DEV" ]; then
	echo "US-600 ($VID:$PID) not found on the USB bus." >&2
	exit 1
fi
[ -n "$BUS" ] || BUS=$(cat "$DEV/busnum")
DEVNUM=$(cat "$DEV/devnum")
echo "== device: $DEV (bus $BUS, device $DEVNUM)"

modprobe usbmon || exit 1
SRC=""
for f in "/sys/kernel/debug/usb/usbmon/${BUS}t" "/sys/kernel/debug/usb/usbmon/${BUS}u"; do
	[ -r "$f" ] && SRC=$f && break
done
if [ -z "$SRC" ]; then
	echo "no usbmon file for bus $BUS (is debugfs mounted?)" >&2
	exit 1
fi
OUT=${OUT:-/tmp/us600-usbmon-$BUS-$DEVNUM-$(date +%H%M%S).txt}

CARD=""
CARDIDX=""
# The card (and udev's node) can lag behind the module by a moment, e.g. when the
# capture is started right after a reload.
for try in $(seq 1 30); do
	for id in /proc/asound/card*/id; do
		[ "$(cat "$id" 2>/dev/null)" = "US600" ] || continue
		idx=${id#/proc/asound/card}
		CARDIDX=${idx%%/*}
		[ -e "/dev/snd/midiC${CARDIDX}D0" ] && CARD=/dev/snd/midiC${CARDIDX}D0
	done
	[ -n "$CARD" ] && break
	sleep 0.1
done
[ -n "$CARD" ] && echo "== rawmidi: $CARD (card $CARDIDX)" || echo "== rawmidi: none yet, capturing without sending a note"

STREAMS=""
stop_streams() {
	[ -n "$STREAMS" ] || return 0
	# shellcheck disable=SC2086
	kill $STREAMS 2>/dev/null
	# shellcheck disable=SC2086
	wait $STREAMS 2>/dev/null
	STREAMS=""
}
trap stop_streams EXIT

if [ "$PLAY" -eq 1 ] || [ "$CAPTURE" -eq 1 ]; then
	if [ -z "$CARDIDX" ]; then
		echo "== -p/-c need the ALSA card, none found" >&2
	else
		if [ "$PLAY" -eq 1 ]; then
			speaker-test -D "plughw:$CARDIDX,0" -c 4 -r 48000 -t sine -l 0 >/dev/null 2>&1 &
			STREAMS="$STREAMS $!"
		fi
		if [ "$CAPTURE" -eq 1 ]; then
			arecord -D "plughw:$CARDIDX,0" -c 6 -r 48000 -f S16_LE /dev/null 2>/dev/null &
			STREAMS="$STREAMS $!"
		fi
		sleep 0.7
		for s in /proc/asound/card$CARDIDX/pcm*/sub0/status; do
			[ -e "$s" ] || continue
			echo "   ${s%/status}: $(tr '\n' ' ' < "$s")"
		done
	fi
fi

errors_before=$(dmesg | grep -c 'MIDI output error')

echo "== capturing $SRC for ${SECS}s -> $OUT"
cat "$SRC" > "$OUT" &
CAP=$!
sleep 0.3

if [ "$RELOAD" -eq 1 ]; then
	echo "   reloading the module inside the capture"
	modprobe -r snd_usb_ozzy
	sleep 0.3
	modprobe snd-usb-ozzy
	sleep 1.5
fi

# one note on, 0.4 s, one note off (only when the rawmidi node is there)
if [ -n "$CARD" ]; then
	python3 - "$CARD" <<'EOF'
import os, sys, time
fd = os.open(sys.argv[1], os.O_WRONLY)
for msg in (bytes([0x90, 0x24, 0x64]), bytes([0x80, 0x24, 0x00])):
	os.write(fd, msg)
	print("   sent", msg.hex(" "))
	time.sleep(0.4)
os.close(fd)
EOF
fi

sleep "$SECS"
kill "$CAP" 2>/dev/null
wait "$CAP" 2>/dev/null
stop_streams

errors_after=$(dmesg | grep -c 'MIDI output error')
echo "== MIDI output errors: $(( errors_after - errors_before )) since the start"
echo

# Text format: <tag> <timestamp> <S|C> <type>:<bus>:<dev>:<ep> [status] [length] ...
python3 - "$OUT" "$BUS" "$DEVNUM" <<'EOF'
import sys

path, bus, dev = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
lines, seen, first = [], {}, {}
bad = {}   # completions with a non-zero status per endpoint: the discriminator

for line in open(path, errors="replace"):
	f = line.split()
	if len(f) < 4 or f[2] not in ("S", "C"):
		continue
	head, _, rest = f[3].partition(":")
	# `dev:ep` in a per-bus file, `bus:dev:ep` in the all-buses one
	parts = rest.split(":")
	try:
		if len(parts) == 3:
			b, d, ep = (int(x) for x in parts)
		elif len(parts) == 2:
			b, d, ep = None, int(parts[0]), int(parts[1])
		else:
			continue
	except ValueError:
		continue
	if (b is not None and b != bus) or d != dev or ep == 0:
		continue
	lines.append(line.rstrip())

	status = f[4] if len(f) > 4 else ""
	length = f[5] if len(f) > 5 else ""
	key = (f[3][:2], ep)
	seen[key] = seen.get(key, [0, 0])
	seen[key][0 if f[2] == "S" else 1] += 1
	if f[2] == "C":
		seen[key].append((status, length))
	if f[2] == "C" and status != "0":
		bad[key] = bad.get(key, 0) + 1
	if f[2] == "C" and key not in first:
		first[key] = (status, length, f[1])

print("== endpoints other than 0, first 30 lines")
for line in lines[:30]:
	print("  " + line)
print("== ... last 10 lines")
for line in lines[-10:]:
	print("  " + line)
print()
print("== summary")
names = {"Bo": "bulk OUT", "Bi": "bulk IN", "Co": "control OUT", "Ci": "control IN",
	 "Io": "intr OUT", "Ii": "intr IN", "Zo": "isoc OUT", "Zi": "isoc IN"}
for (kind, ep), v in sorted(seen.items(), key=lambda kv: (kv[0][1], kv[0][0])):
	c = [x for x in v[2:] if x]
	last = c[-1] if c else ("-", "-")
	fst = first.get((kind, ep), ("none", "-", "-"))
	print("  EP 0x%02x %-9s  submitted %d, completed %d, errors %d, first status/length %s/%s, "
	      "last %s/%s"
	      % (ep | (0x80 if kind[1] == "i" else 0), names.get(kind, kind), v[0], v[1],
		 bad.get((kind, ep), 0), fst[0], fst[1], last[0], last[1]))
EOF
echo
echo "full capture: $OUT"
