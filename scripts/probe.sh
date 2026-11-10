#!/usr/bin/env bash
# Read-only probe of a Tascam US-600 (0644:8035). No root required.
# Prints USB descriptors, ALSA ports, card state and recent driver messages.
set -uo pipefail

VID=${VID:-0644}
PID=${PID:-8035}
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

echo "== device: $DEV"
for a in busnum devnum speed version manufacturer product serial bNumInterfaces bMaxPower; do
	[ -r "$DEV/$a" ] && printf '%-16s %s\n' "$a:" "$(cat "$DEV/$a")"
done

echo
echo "== active interfaces"
for i in "$DEV"/*:*; do
	[ -d "$i" ] || continue
	driver=NONE
	[ -e "$i/driver" ] && driver=$(basename "$(readlink -f "$i/driver")")
	printf '%s class=%s sub=%s proto=%s driver=%s\n' \
		"$(basename "$i")" "$(cat "$i/bInterfaceClass")" \
		"$(cat "$i/bInterfaceSubClass")" "$(cat "$i/bInterfaceProtocol")" "$driver"
done

echo
echo "== full configuration descriptor"
python3 - "$DEV/descriptors" <<'PY'
import sys

data = open(sys.argv[1], "rb").read()
i = 0
while i < len(data):
    ln = data[i]
    if ln == 0:
        break
    seg = data[i:i + ln]
    typ = seg[1]
    if typ == 0x01:
        print("DEVICE  bcdUSB=%04x class=%02x sub=%02x proto=%02x vid=%04x pid=%04x" % (
            seg[2] | seg[3] << 8, seg[4], seg[5], seg[6],
            seg[8] | seg[9] << 8, seg[10] | seg[11] << 8))
    elif typ == 0x02:
        print("CONFIG  nIfaces=%d maxPower=%dmA" % (seg[4], seg[7] * 2))
    elif typ == 0x04:
        print("  IFACE #%d alt=%d nEP=%d class=%02x sub=%02x proto=%02x" % (
            seg[2], seg[3], seg[4], seg[5], seg[6], seg[7]))
    elif typ == 0x05:
        attr = seg[3]
        kind = ["ctrl", "isoc", "bulk", "int"][attr & 3]
        print("    EP 0x%02x %-4s %s maxpkt=%d interval=%d" % (
            seg[2], kind, "IN " if seg[2] & 0x80 else "OUT",
            seg[4] | seg[5] << 8, seg[6]))
    i += ln
PY

echo
echo "== ALSA"
cat /proc/asound/cards 2>/dev/null || echo "(no /proc/asound)"
echo
amidi -l 2>/dev/null || echo "(amidi: no rawmidi device)"
echo
aconnect -l 2>/dev/null | grep -i -A1 'US-600' || echo "(aconnect: no US-600 client)"

for m in /proc/asound/card*/midi0; do
	[ -r "$m" ] || continue
	echo
	echo "== $m"
	cat "$m"
done

echo
echo "== recent kernel messages"
dmesg 2>/dev/null | grep -i -E 'ozzy|ploytec|usb.*8035' | grep -v 'MIDI output error' | tail -15
echo
echo "MIDI output errors since boot: $(dmesg 2>/dev/null | grep -c 'MIDI output error')"
