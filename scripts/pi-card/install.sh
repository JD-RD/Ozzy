#!/bin/sh
# Installation sur le Raspberry Pi 3B, après le premier démarrage (SSH).
#
# Prérequis : ce dossier est sur la carte, monté sur le Pi en /boot/firmware/us600-setup,
# et cloud-init a déjà extrait les deux dépôts dans /home/pi (voir user-data).
#
#   sudo sh /boot/firmware/us600-setup/install.sh
#
# Idempotent : peut être relancé après une mise à jour de l'un des dépôts.
set -eu

SETUP=$(cd "$(dirname "$0")" && pwd)
PI=${PI:-pi}
HOME_PI=/home/$PI

say() { printf '\n== %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || { echo "à lancer avec sudo" >&2; exit 1; }

# Les dépôts sont extraits par cloud-init ; s'ils manquent (premier démarrage
# qui n'a pas abouti), on les extrait depuis la carte.
say "dépôts"
for name in us600-linux tr8-remap; do
	if [ ! -d "$HOME_PI/$name" ]; then
		echo "  extraction de $name depuis $SETUP"
		mkdir -p "$HOME_PI/$name"
		tar -xzf "$SETUP/$name.tar.gz" -C "$HOME_PI"
		chown -R "$PI:$PI" "$HOME_PI/$name"
	fi
	echo "  $HOME_PI/$name ok"
done

say "paquets"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
	python3-mido python3-rtmidi alsa-utils build-essential git rsync
apt-get install -y "linux-headers-$(uname -r)" || {
	echo "pas de paquet linux-headers-$(uname -r) ; essayer raspberrypi-kernel-headers" >&2
	apt-get install -y raspberrypi-kernel-headers || true
}

say "module snd-usb-ozzy"
"$HOME_PI/us600-linux/scripts/build-load.sh"

say "service tr8-remap"
install -m 644 "$HOME_PI/tr8-remap/tr8-remap.service" /etc/systemd/system/tr8-remap.service
# Le répertoire des hooks de veille n'existe pas sur l'image Trixie nue :
# sans ce mkdir, `install` échoue et `set -e` coupe le script juste avant
# `systemctl enable` (constaté au premier passage sur le 3B, 2026-11-11).
install -d /usr/lib/systemd/system-sleep
install -m 755 "$HOME_PI/tr8-remap/systemd-sleep/tr8-remap" /usr/lib/systemd/system-sleep/tr8-remap
systemctl daemon-reload
systemctl enable tr8-remap.service

say "cartes et ports"
cat /proc/asound/cards
aplay -l | sed -n '/US-600/,$p' | head -4
aconnect -l | sed -n "/US-600/,+2p"

cat <<'EOF'

== terminé. Pour démarrer le remap :

   systemctl start tr8-remap        # ou: python3 ~/tr8-remap/remap.py --in US-600 --out US-600 --monitor

Vérifications utiles :

   ~/us600-linux/scripts/midi-health.sh          # 0 = sain
   systemctl status tr8-remap
   journalctl -u tr8-remap -f

Si le US-600 n'est pas exposé sous le nom « US-600 », `remap.py --list` donne les
noms réels ; l'unité et cette commande prennent alors le même.
EOF
