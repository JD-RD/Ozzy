#!/usr/bin/env bash
# Send MIDI notes to the US-600 and report what comes back.
#
# With a DIN cable from MIDI OUT to MIDI IN, every byte must return: this is the
# end-to-end check of the MIDI path (out and in) without any other gear.
#
# Usage: midi-loop-test.sh [-d hw:1,0] [-s seconds] [-c card]
set -uo pipefail

DEV=hw:1,0
SECS=20
CARD=1

while getopts "d:s:c:h" opt; do
	case $opt in
	d) DEV=$OPTARG ;;
	s) SECS=$OPTARG ;;
	c) CARD=$OPTARG ;;
	h) sed -n '2,8p' "$0"; exit 0 ;;
	*) exit 2 ;;
	esac
done

NOTES="24 26 2A 27 2E 31"   # 36 38 42 39 46 49, the TR-8 instrument notes
MIDI0=/proc/asound/card$CARD/midi0

errors_before=0
dmesg -r >/dev/null 2>&1 || true
errors_before=$(dmesg 2>/dev/null | grep -c 'MIDI output error')

echo "device: $DEV   duration: ${SECS}s"
read -r tx_before rx_before <<<"$(awk '/Tx bytes|Rx bytes/ {gsub(/[^0-9]/, "", $NF); printf "%s ", $NF}' "$MIDI0" 2>/dev/null)"
echo "before: Tx=${tx_before:-0} Rx=${rx_before:-0} errors=$errors_before"

end=$(( $(date +%s) + SECS ))
sent=0
while [ "$(date +%s)" -lt "$end" ]; do
	for n in $NOTES; do
		amidi -p "$DEV" -S "90 $n 64" 2>/dev/null && sent=$((sent + 1))
		sleep 0.2
		amidi -p "$DEV" -S "80 $n 40" 2>/dev/null
		sleep 0.8
	done
done

sleep 0.5
read -r tx_after rx_after <<<"$(awk '/Tx bytes|Rx bytes/ {gsub(/[^0-9]/, "", $NF); printf "%s ", $NF}' "$MIDI0" 2>/dev/null)"
errors_after=$(dmesg 2>/dev/null | grep -c 'MIDI output error')

echo "after:  Tx=${tx_after:-0} Rx=${rx_after:-0} errors=$errors_after"
echo "notes sent: $sent"
echo "delta:  Tx=$(( ${tx_after:-0} - ${tx_before:-0} )) Rx=$(( ${rx_after:-0} - ${rx_before:-0} )) errors=$(( errors_after - errors_before ))"

if [ $(( ${rx_after:-0} - ${rx_before:-0} )) -gt 0 ]; then
	echo "RESULT: MIDI loopback OK"
else
	echo "RESULT: nothing came back on MIDI IN"
	[ $(( errors_after - errors_before )) -gt 0 ] && echo "        MIDI OUT transfers are failing (see dmesg)"
fi
