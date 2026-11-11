#!/usr/bin/env bash
# Send MIDI notes to the US-600 and check the DIN OUT -> IN loopback byte for byte.
#
# Two things the obvious version of this script gets wrong, both measured 2026-11-10:
#  - it never opens the MIDI IN port, and the driver only submits the 0x83 URBs when a client
#    reads, so "Rx bytes" and /proc stay at zero and the result is a false negative;
#  - it counts `MIDI output error` lines, which the ring buffer makes useless (>1000/s fills
#    it in ~5 s). The healthy/unhealthy test is whether the *last* such line moved.
# 0xF8 (clock) and 0xFE (active sensing) from any gear on the DIN IN are ignored when
# comparing, everything else must come back in order.
#
# Usage: midi-loop-test.sh [-d hw:1,0] [-s seconds] [-c card] [-k]
#   -k  keep the raw amidi dump and print its path
set -uo pipefail

DEV=hw:1,0
SECS=20
CARD=1
KEEP=0

while getopts "d:s:c:kh" opt; do
	case $opt in
	d) DEV=$OPTARG ;;
	s) SECS=$OPTARG ;;
	c) CARD=$OPTARG ;;
	k) KEEP=1 ;;
	h) sed -n '2,16p' "$0"; exit 0 ;;
	*) exit 2 ;;
	esac
done

NOTES="24 26 2A 27 2E 31"   # 36 38 42 39 46 49, the TR-8 instrument notes
MIDI0=/proc/asound/card$CARD/midi0
TMP=$(mktemp -d)
EXPECT=$TMP/expect.txt      # one hex byte per line, what we send
IN=$TMP/in.txt              # amidi -d output

last_error() { dmesg 2>/dev/null | grep 'MIDI output error' | tail -1 | sed 's/^\[ *\([0-9.]*\)\].*/\1/'; }

echo "device: $DEV   duration: ${SECS}s"
read -r tx_before rx_before <<<"$(awk '/Tx bytes|Rx bytes/ {gsub(/[^0-9]/, "", $NF); printf "%s ", $NF}' "$MIDI0" 2>/dev/null)"
err_before=$(last_error)
echo "before: Tx=${tx_before:-0} Rx=${rx_before:-0} last-error=${err_before:-none}"

# The input has to be open for the driver to read 0x83 at all.
timeout $((SECS + 3)) amidi -p "$DEV" -d > "$IN" 2>/dev/null &
DUMP=$!
sleep 0.5

: > "$EXPECT"
end=$(( $(date +%s) + SECS ))
sent=0
while [ "$(date +%s)" -lt "$end" ]; do
	for n in $NOTES; do
		if amidi -p "$DEV" -S "90 $n 64" 2>/dev/null; then
			printf '90\n%s\n64\n' "$n" >> "$EXPECT"
			sent=$((sent + 1))
		fi
		sleep 0.2
		if amidi -p "$DEV" -S "80 $n 40" 2>/dev/null; then
			printf '80\n%s\n40\n' "$n" >> "$EXPECT"
		fi
		sleep 0.4
	done
done

sleep 0.5
kill $DUMP 2>/dev/null
wait $DUMP 2>/dev/null

read -r tx_after rx_after <<<"$(awk '/Tx bytes|Rx bytes/ {gsub(/[^0-9]/, "", $NF); printf "%s ", $NF}' "$MIDI0" 2>/dev/null)"
err_after=$(last_error)

# amidi -d prints "90 3C 64" style text; keep the hex pairs, drop clock and active sensing.
bytes() { tr -s ' \n' '\n' < "$1" | grep -E '^[0-9A-Fa-f]{2}$' | tr 'a-f' 'A-F'; }
got_n=$(bytes "$IN" | wc -l)
got_real_n=$(bytes "$IN" | grep -vcE '^(F8|FE)$')
WANT=$(tr -d '\n' < "$EXPECT")
GOT=$(bytes "$IN" | grep -vE '^(F8|FE)$' | tr -d '\n')

echo "after:  Tx=${tx_after:-0} Rx=${rx_after:-0} last-error=${err_after:-none}"
echo "notes sent: $sent   bytes received: $got_n (${got_real_n} outside 0xF8/0xFE)"
[ "$err_after" != "$err_before" ] && echo "MIDI OUT transfers failed during the run (new 'MIDI output error' lines)"

case "$GOT" in
*"$WANT"*)
	echo "RESULT: MIDI loopback OK - every byte came back in order"
	rc=0
	;;
*)
	echo "RESULT: no exact match"
	if [ "${got_real_n:-0}" -eq 0 ]; then
		echo "        nothing came back: cable fitted? DIN OUT -> DIN IN on the US-600"
		[ "$err_after" != "$err_before" ] && echo "        and MIDI OUT is failing, see dmesg"
	else
		echo "        got   ${GOT:0:120}"
		echo "        want  ${WANT:0:120}"
	fi
	rc=1
	;;
esac

if [ "$KEEP" -eq 1 ]; then
	echo "raw dump: $IN"
else
	rm -rf "$TMP"
fi
exit $rc
