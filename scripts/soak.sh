#!/bin/sh
# Échantillonne la chaîne TR-8 -> US-600 -> SP-404MK2 pendant la tenue (phase 4, item 5).
# Usage: scripts/soak.sh [secondes] [pas], journal dans ~/soak-<date>.log
#
# La tenue de la phase 4 (docs/plan.md, item 5) : une ligne par minute avec l'état du service,
# les compteurs du port rawmidi, les -EPROTO, les avertissements dwc_otg et les compteurs du
# moteur décodés. C'est ce journal qui a daté la bascule en -EPROTO du 2026-11-11 (15:43).
DUR=${1:-3600}
STEP=${2:-60}
LOG=/home/pi/soak-$(date +%Y%m%d-%H%M).log
end=$(( $(date +%s) + DUR ))
echo "# tenue $(date -Is), ${DUR}s, pas ${STEP}s, noyau $(uname -r)" > "$LOG"
while [ "$(date +%s)" -lt "$end" ]; do
	rx=$(awk '/Rx bytes/{print $4}' /proc/asound/card0/midi0 2>/dev/null)
	tx=$(awk '/Tx bytes/{print $4}' /proc/asound/card0/midi0 2>/dev/null)
	ov=$(awk '/Overruns/{print $3}' /proc/asound/card0/midi0 2>/dev/null)
	proto=$(journalctl -k -b --no-pager 2>/dev/null | grep -c 'MIDI output error')
	fsm=$(dmesg 2>/dev/null | grep -c 'Timed out waiting for FSM')
	stats=$(amixer -c 0 cget iface=CARD,name='Ozzy Stats' 2>/dev/null | python3 -c '
import re, struct, sys
m = re.search(r"^\s*: values=(.*)$", sys.stdin.read(), re.M)
if not m: print("?"); raise SystemExit
b = bytes(int(x, 16) for x in m.group(1).split(","))
out = struct.unpack_from("<QIIII", b, 16); inp = struct.unpack_from("<QIIII", b, 40)
print(f"out={out[0]}/{out[1]}/{out[3]}/{out[4]}us in={inp[0]}/{inp[1]}/{inp[3]}/{inp[4]}us")')
	svc=$(systemctl is-active tr8-remap)
	echo "$(date -Is) svc=$svc rx=$rx tx=$tx overruns=$ov proto=$proto fsm=$fsm $stats" >> "$LOG"
	sleep "$STEP"
done
echo "$(date -Is) fin" >> "$LOG"
