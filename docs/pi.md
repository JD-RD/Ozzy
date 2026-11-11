# Raspberry Pi 3B — the card, the first boot, the install

Everything below was executed on 2026-11-10 for the bench that runs TR-8 → US-600 →
SP-404MK2. The image was written, the card configured, but **the first boot itself has not
been observed yet** (no Pi was available): treat the last two sections as the plan to follow,
not as measurements.

## 1. The image

| | |
|---|---|
| file | `2026-10-06-raspios-trixie-arm64-lite.img.xz` (Debian 13, kernel 6.12, 64-bit, no desktop) |
| from | `https://downloads.raspberrypi.org/raspios_lite_arm64/images/raspios_lite_arm64-2026-10-06/` |
| sha256 of the `.xz` | `483db18a48da399b5b7022ffae9a07bc6d99daab30e593aedac09b69ff422843` (550 466 056 B) |
| uncompressed size | 3 078 619 136 B = 734 blocks of 4 MiB exactly |
| sha256 of the `.img` | `b8a393dc1c3701450b5fffbfe74368a98fb6eab7415ce456cc0cead886ea8780` |

Why Lite and not the desktop: no PipeWire, no PulseAudio. On the desktop image the
sound server takes over the ALSA sequencer and MIDI routing becomes someone else's problem;
with Lite, `aconnect`/`mido` see the raw ports directly.

Why 64-bit: the 3B is ARMv8 and 1 GB of RAM is plenty for Lite; the driver is plain C, so the
arch is not a factor either way.

**Writing it.** `rpi-imager` 1.8.5 (the version in Ubuntu noble, and what `apt install`
gives on Mint) has two behaviours that cost time:

- it does **not** elevate itself (no polkit code in the binary) — run it with `sudo`;
- its `--sha256` is checked against the **decompressed** stream, not the `.xz`: pass the
  `.img` hash above, otherwise it stops with `Download corrupt. Hash does not match`.

```bash
sudo umount /dev/sdc1
sudo rpi-imager --cli --sha256 b8a393dc1c3701450b5fffbfe74368a98fb6eab7415ce456cc0cead886ea8780 \
  ~/Downloads/2026-10-06-raspios-trixie-arm64-lite.img.xz /dev/sdc
```

It writes, re-reads the card to verify, then **ejects it** — the device drops to 0 B and comes
back on re-plug. Equivalent manual path, with the same verification:

```bash
xzcat ~/Downloads/2026-10-06-raspios-trixie-arm64-lite.img.xz |
  sudo dd of=/dev/sdc bs=4M iflag=fullblock oflag=direct conv=fsync status=progress
sync
sudo dd if=/dev/sdc bs=4M count=734 iflag=direct | sha256sum   # b8a393dc…
```

After the write: `sdc1` = `bootfs`, FAT32, 512 MiB; `sdc2` = `rootfs`, ext4, 2.4 GiB and
expanded to the card on first boot (`resize` is in `cmdline.txt`).

## 2. How this image wants to be configured: cloud-init

Trixie images ship **cloud-init**, not the older `firstrun.sh` mechanism. `bootfs` contains
`meta-data` (`dsmode: local`, `instance_id: rpios-image`), `user-data` (a commented template)
and `network-config` (netplan v2 examples). `rpi-imager` 1.8.5 detects that and would write
cloud-init data itself if it were asked to customise; its `--cli` cannot (the
`--hostname`/`--wifi-ssid` flags only exist upstream from 1.9).

So the configuration is written by `scripts/pi-card-setup.sh`, which fills three templates from
`scripts/pi-card/`:

```bash
scripts/pi-card-setup.sh /media/$USER/bootfs          # -s SSID, -n HOSTNAME, -k PUBKEY
```

What it writes, and why:

| key | value | note |
|---|---|---|
| `hostname` | `us600` | plus `manage_etc_hosts` |
| user | `pi`, in `adm,dialout,…,spi`, `sudo: ALL=(ALL) ALL` | unlocked only by the injected hash |
| `ssh_authorized_keys` | the dev machine's `~/.ssh/id_ed25519.pub` | key login is what actually gets you in |
| `ssh_pwauth` | `true` | so `sudo` can ask for a password once injected |
| locale / tz / keyboard / wifi country | via `raspi-config nonint` in `runcmd` | cloud-init's own `locale:` does not run `locale-gen`; `raspi-config` does |
| packages | `python3-mido python3-rtmidi alsa-utils build-essential git rsync avahi-daemon`, then `linux-headers-$(uname -r)` | three apt attempts, the WiFi may take a few seconds |
| `runcmd` | extract both `git archive` tarballs into `/home/pi` | so nothing has to be copied over the network |
| `network-config` | `wlan0` → `"Yum Kaax"`, `regulatory-domain: CA`, `optional: true`, plus DHCP on `eth0` | `optional: true` so a wrong PSK cannot hang the boot |

`us600-setup/` on the card then carries `us600-linux.tar.gz` (this tree), `tr8-remap.tar.gz`,
`install.sh` and `README.txt`.

**The two secrets are never written by the script or committed.** `user-data` keeps
`__PI_PASSWORD_HASH__` and `network-config` keeps `__WIFI_PSK__`; the script prints the snippet
that fills them with `openssl passwd -6 -stdin` (no argument visible in `ps`) and `getpass` (no
shell history), then re-validates the YAML.

## 3. First boot (to be observed)

Expected: 2 to 5 minutes of resize + cloud-init. Then, from the dev machine:

```bash
ssh pi@us600.local        # avahi is installed; otherwise the router's DHCP list
sudo sh /boot/firmware/us600-setup/install.sh
```

`install.sh` is idempotent: it extracts the trees if cloud-init did not, installs the packages,
builds the module with `scripts/build-load.sh` (which wants `linux-headers-$(uname -r)`),
installs `tr8-remap.service` and the `systemd-sleep` hook, enables the service, then prints the
cards, the playback devices, and the ALSA sequencer ports.

If cloud-init did something unexpected: `/var/log/cloud-init-output.log`, and the file that
drove it is still on the card (`bootfs/user-data`).

## 4. What to check on the Pi, in this order

```bash
uname -r                                  # headers must exist for exactly this
cat /proc/asound/cards                    # US600 should be card 1 (onboard audio is card 0)
~/us600-linux/scripts/midi-health.sh      # 0 / healthy
~/us600-linux/scripts/midi-loop-test.sh -s 30   # with the DIN loopback fitted
aconnect -l | sed -n '/US-600/,+2p'       # client number: 20 here, not guaranteed
systemctl start tr8-remap && journalctl -u tr8-remap -f
```

Then the real chain for an hour: TR-8 pads → SP-404MK2, watching
`/proc/asound/card*/pcm*/sub*/status` and `dmesg` for xruns.

## 5. Traps, from the bench and from this card

- **The 3B's WiFi is 2.4 GHz only.** If the SSID is 5 GHz-only, use Ethernet.
- **Power**: the 3B shares about 1.2 A across its ports. The US-600 declares itself bus-powered
  (`bAttributes 0x80`, 240 mA in the descriptor, 480 mA in sysfs) but has an external supply;
  if it drops off the bus, use a powered hub and check `dmesg` for over-current first.
- **A USB unplug is not a reset** on this device: the external supply keeps the firmware alive.
  The known cure for the `-EPROTO` state is external supply **and** USB off for ~10 s.
- **The ALSA sequencer subscription does not survive a suspend**; the sleep hook installed by
  `install.sh` restarts the service, which is what re-subscribes.
- **The 6-channel capture is not paced to real time** on the Mint bench (2 s of audio in
  0.14 s) and one 96 kHz capture returned `EIO` in a back-to-back rate sweep. If the Pi shows
  xruns, that is where to look, with `ozzy-cli set pcm-capture-transfer` /
  `pcm-capture-queue` as the knobs.
- Re-running `scripts/pi-card-setup.sh` on an already-injected card **resets the two
  placeholders** — inject after the last run, or mount the card and redo it.
