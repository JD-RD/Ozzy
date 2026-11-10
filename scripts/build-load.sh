#!/usr/bin/env bash
# Build the Linux module from this tree and (re)load it.
# Usage: [sudo] scripts/build-load.sh [-n]   (-n = build only, do not reload)
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
KDIR=${KDIR:-/lib/modules/$(uname -r)/build}
RELOAD=1

[ "${1:-}" = "-n" ] && RELOAD=0

if [ ! -d "$KDIR" ]; then
	echo "Kernel headers not found: $KDIR" >&2
	echo "Raspberry Pi OS: sudo apt install linux-headers-\$(uname -r)" >&2
	echo "Debian/Ubuntu:  sudo apt install linux-headers-\$(uname -r)" >&2
	exit 1
fi

echo "== building against $(uname -r)"
make -C "$ROOT/linux" KERNELDIR="$KDIR" -j"$(nproc)" || exit 1

[ "$RELOAD" -eq 1 ] || exit 0

SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo"

$SUDO make -C "$ROOT/linux" KERNELDIR="$KDIR" modules_install || exit 1
$SUDO depmod -a

if lsmod | grep -q '^snd_usb_ozzy'; then
	$SUDO rmmod snd_usb_ozzy || exit 1
fi

$SUDO modprobe snd-usb-ozzy || exit 1
sleep 1

echo
echo "== driver state"
lsmod | grep '^snd_usb_ozzy' || echo "(module not loaded)"
for f in /proc/asound/cards /proc/asound/card*/midi0; do
	[ -r "$f" ] && { echo "--- $f"; cat "$f"; }
done
echo
echo "== messages"
dmesg | grep -i -E 'ozzy|ploytec' | grep -v 'MIDI output error' | tail -12
echo "MIDI output errors: $(dmesg | grep -c 'MIDI output error')"
