#!/usr/bin/env bash
# Write the first-boot configuration for the US-600 bench onto an already-written
# Raspberry Pi OS Lite card (the bootfs partition has to be mounted).
#
# The image has to be one that ships cloud-init — the 2026-10-06 Trixie images do:
# bootfs then contains meta-data (dsmode: local), network-config and user-data.
# This script fills those, and drops scripts/pi-card/{install.sh,README.txt} plus a
# git archive of this tree and of tr8-remap in us600-setup/.
#
# Usage: scripts/pi-card-setup.sh BOOTFS [-s SSID] [-n HOSTNAME] [-k SSH_PUBKEY]
#   BOOTFS        mount point of the card's FAT partition, e.g. /media/$USER/bootfs
#   -s SSID       WiFi network to join (default: Yum Kaax); the PSK is left as a
#                 marker and injected afterwards, never written by this script
#   -n HOSTNAME   hostname (default: us600)
#   -k FILE       SSH public key to authorise (default: ~/.ssh/id_ed25519.pub)
#
# Neither the WiFi PSK nor the user's password is handled here: user-data carries
# __PI_PASSWORD_HASH__ and network-config carries __WIFI_PSK__, and the script
# prints the snippet that fills them (openssl passwd -stdin, getpass).
#
# Writing the image itself is not done here — rpi-imager 1.8.5 needs root and its
# --sha256 is the hash of the *decompressed* image; see docs/pi.md.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEMPLATES="$ROOT/scripts/pi-card"
REMAP_DIR=${REMAP_DIR:-$HOME/src/tr8-remap}

SSID="Yum Kaax"
HOSTNAME_=us600
SSH_KEY=$HOME/.ssh/id_ed25519.pub

usage() { sed -n '2,24p' "$0"; exit "${1:-0}"; }

BOOTFS=""
while getopts "s:n:k:h" opt; do
	case $opt in
	s) SSID=$OPTARG ;;
	n) HOSTNAME_=$OPTARG ;;
	k) SSH_KEY=$OPTARG ;;
	h) usage 0 ;;
	*) usage 2 ;;
	esac
done
shift $((OPTIND - 1))
BOOTFS=${1:-}
[ -n "$BOOTFS" ] || usage 2

die() { echo "$*" >&2; exit 1; }

# --- the target has to be the bootfs of a cloud-init image -------------------
[ -d "$BOOTFS" ] || die "$BOOTFS: pas un répertoire"
[ -f "$BOOTFS/cmdline.txt" ] || die "$BOOTFS: pas une bootfs Raspberry Pi (cmdline.txt absent)"
[ -f "$BOOTFS/user-data" ] || die "$BOOTFS: pas d'image cloud-init (user-data absent) — rpi-imager 1.8.5 écrit firstrun.sh sur les anciennes images, ce script ne les couvre pas"
[ -f "$SSH_KEY" ] || die "$SSH_KEY: clé publique introuvable (option -k)"
KEY=$(tr -d '\n' < "$SSH_KEY")

# --- the sources --------------------------------------------------------------
[ -d "$ROOT/linux" ] || die "$ROOT: dépôt us600-linux introuvable"
[ -d "$REMAP_DIR/.git" ] || die "$REMAP_DIR: dépôt tr8-remap introuvable (REMAP_DIR=...)"
git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 || die "$ROOT: pas un dépôt git"

# --- what we are about to write ----------------------------------------------
echo "== cible : $BOOTFS"
echo "   hostname   : $HOSTNAME_"
echo "   wifi       : $SSID (PSK laissée en marqueur)"
echo "   clé ssh    : $SSH_KEY"
echo "   dépôts     : $ROOT ($(git -C "$ROOT" rev-parse --short HEAD))," \
     "$REMAP_DIR ($(git -C "$REMAP_DIR" rev-parse --short HEAD))"

# --- templates ---------------------------------------------------------------
for f in user-data network-config; do
	sed -e "s|@HOSTNAME@|$HOSTNAME_|g" \
	    -e "s|@SSID@|$SSID|g" \
	    -e "s|@SSH_KEY@|$KEY|g" \
	    "$TEMPLATES/$f" > "$BOOTFS/$f.new" || die "écriture de $f impossible"
	mv "$BOOTFS/$f.new" "$BOOTFS/$f"
	echo "   écrit $f"
done
grep -q '__PI_PASSWORD_HASH__' "$BOOTFS/user-data" || die "user-data: marqueur de mot de passe perdu"
grep -q '__WIFI_PSK__' "$BOOTFS/network-config" || die "network-config: marqueur de PSK perdu"

# --- the two trees, as clean archives, plus the install script ---------------
mkdir -p "$BOOTFS/us600-setup"
git -C "$ROOT" archive --format=tar.gz --prefix=us600-linux/ \
	-o "$BOOTFS/us600-setup/us600-linux.tar.gz" HEAD || die "git archive (us600-linux)"
git -C "$REMAP_DIR" archive --format=tar.gz --prefix=tr8-remap/ \
	-o "$BOOTFS/us600-setup/tr8-remap.tar.gz" HEAD || die "git archive (tr8-remap)"
cp "$TEMPLATES/install.sh" "$TEMPLATES/README.txt" "$BOOTFS/us600-setup/"
echo "   écrit us600-setup/ ($(du -sh "$BOOTFS/us600-setup" | cut -f1))"

# --- YAML sanity, the Pi fails silently otherwise ---------------------------
if python3 -c 'import yaml' 2>/dev/null; then
	python3 - "$BOOTFS" <<-'PY' || die "YAML invalide"
		import sys, pathlib, yaml
		b = pathlib.Path(sys.argv[1])
		for f in ("user-data", "network-config"):
		    yaml.safe_load((b / f).read_text())
		print("   YAML : valide")
	PY
else
	echo "   YAML : pyyaml absent, contrôle sauté"
fi

sync
cat <<EOF

== prêt. Il reste deux secrets à injecter sur $BOOTFS (ils ne passent ni par ce
   script ni par un dépôt) :

python3 - <<'PY'
import getpass, pathlib, subprocess, yaml
b = pathlib.Path("$BOOTFS")
pw = getpass.getpass("mot de passe du Pi (utilisateur pi) : ")
h = subprocess.run(["openssl", "passwd", "-6", "-stdin"], input=pw + "\\n",
                   capture_output=True, text=True, check=True).stdout.strip()
u = b / "user-data"
u.write_text(u.read_text().replace('"__PI_PASSWORD_HASH__"', f'"{h}"'))
psk = getpass.getpass("PSK WiFi « $SSID » : ")
n = b / "network-config"
n.write_text(n.read_text().replace("__WIFI_PSK__", psk))
for f in (u, n):
    yaml.safe_load(open(f))
print("ok")
PY

   puis démonter la carte et démarrer le Pi. Sur le Pi :

     ssh pi@$HOSTNAME_.local
     sudo sh /boot/firmware/us600-setup/install.sh
EOF
