# Raspberry Pi 3B — the card, the first boot, the install

Everything below was executed for the bench that runs TR-8 → US-600 → SP-404MK2: the image on
2026-11-10, the first boot on **2026-11-11**. Sections 3 to 5 are now measurements.

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

## 3. First boot (observed 2026-11-11)

It takes 2 to 5 minutes of resize + cloud-init. Then, from the dev machine:

```bash
ssh pi@192.168.0.142      # mDNS does not resolve on this WiFi, see the traps
sudo sh /boot/firmware/us600-setup/install.sh
```

What the boot did, measured: cloud-init `done` (its only complaint is a `cc_netplan_nm_patch`
module this cloud-init version does not have — no effect), `linux-headers-6.18.50+rpt-rpi-v8`
already present and matching `uname -r`, both trees extracted to `/home/pi`, `us600-setup/`
readable. The device was not plugged in, so `/proc/asound/cards` only showed the onboard two.

**`install.sh` stopped half-way** on the first run: `/usr/lib/systemd/system-sleep/` does not
exist on this image, so `install -m 755 … /usr/lib/systemd/system-sleep/tr8-remap` failed and
`set -eu` ended the script *before* `systemctl enable`. The unit was installed, the module was
built and loaded, the sleep hook and the enable were not. Fixed in `scripts/pi-card/install.sh`
(`install -d` first); if you meet a unit that is installed but `disabled`, that is the trace.

`install.sh` is idempotent: it extracts the trees if cloud-init did not, installs the packages,
writes `/etc/modules-load.d/us600-ozzy.conf`, builds the module with `scripts/build-load.sh`
(which wants `linux-headers-$(uname -r)`), adds `dwc_otg.fiq_fsm_enable=0` to `cmdline.txt` on
a `dwc_otg` host (the 3B), installs `tr8-remap.service` and the `systemd-sleep` hook, enables
the service, then prints the cards, the playback devices, and the ALSA sequencer ports.

**Then reboot once**: the `cmdline.txt` change is read at boot, and until it is, the bulk pipes
wedge on the first stream that needs them (see §5). After the reboot the module is already
loaded, the card is up, and `tr8-remap.service` is `active` on its own.

If cloud-init did something unexpected: `/var/log/cloud-init-output.log`, and the file that
drove it is still on the card (`bootfs/user-data`).

## 4. What to check on the Pi, in this order

```bash
uname -r                                  # headers must exist for exactly this
cat /proc/asound/cards                    # US600 is card 0 (module loads before the onboard cards)
~/us600-linux/scripts/midi-health.sh      # 0 / healthy
~/us600-linux/scripts/pi-bench.sh -c      # the whole transport matrix, ~45 s, table + counters
~/us600-linux/scripts/midi-loop-test.sh -s 30   # with the DIN loopback fitted
aconnect -l | sed -n '/US-600/,+2p'       # client number: 16 after this boot, not guaranteed
systemctl status tr8-remap               # active, started at boot
```

`scripts/pi-bench.sh` is the one to run before and after any change: it walks the rates, opens
playback and capture in the orders that have broken here, and prints per step the exit status,
the `MIDI output error` delta and the decoded `Ozzy Stats` (transfers / errors / short / late /
longest gap, per direction) — so two runs compare, which `dmesg` scrolling does not.

Then the real chain for an hour: TR-8 pads → SP-404MK2, watching
`/proc/asound/card*/pcm*/sub*/status` and `journalctl -k` for xruns.

## 5. Traps, from the bench and from this card

- **`dwc_otg`'s FIQ FSM wedges the non-periodic transfers** (the 3B's only USB controller).
  Symptom: `WARN::dwc_otg_hcd_urb_dequeue:639: Timed out waiting for FSM NP transfer to
  complete` in `dmesg`, then `aplay`/`arecord` fail with `EIO` (`Erreur d'entrée/sortie`) on
  any rate, the engine's counters stop moving, and nothing in the driver logs it. On the first
  boot it also produced a 30 s storm of `[ploytec] isoc: MIDI output error 0xffffffb9`
  (29 654 lines) that ended with `restart failed, resetting the device`. Cure, measured:
  `dwc_otg.fiq_fsm_enable=0` in `/boot/firmware/cmdline.txt` (a reboot), after which 14/14
  bench steps pass twice in a row, `0` `-EPROTO`, `0` FSM warnings. `install.sh` now adds it.
- **The module is not loaded at boot** unless `/etc/modules-load.d/us600-ozzy.conf` exists:
  `tr8-remap.service` is `enabled`, starts with the system, waits 30 s for its MIDI port, exits,
  and `Restart=always` loops every 5 s. `install.sh` now writes that file.
- **mDNS does not work in either direction on this WiFi** (5353 filtered or AP isolation):
  `us600.local` times out from the dev machine, and the Pi has no `avahi-utils` to ask back.
  Use the IP and an `~/.ssh/config` alias, and reserve a DHCP lease for `b8:27:eb:e2:84:6f`.
- **The 3B's WiFi is 2.4 GHz only.** If the SSID is 5 GHz-only, use Ethernet.
- **Power**: the 3B shares about 1.2 A across its ports. The US-600 declares itself bus-powered
  (`bAttributes 0x80`, 240 mA in the descriptor, 480 mA in sysfs) but has an external supply;
  if it drops off the bus, use a powered hub and check `dmesg` for over-current first. Not
  needed with the fix above: it has run 22 000 transfers and a concurrent playback+capture
  without a reset.
- **A USB unplug is not a reset** on this device: the external supply keeps the firmware alive.
  The known cure for the `-EPROTO` state is external supply **and** USB off for ~10 s.
- **The ALSA sequencer subscription does not survive a suspend**; the sleep hook installed by
  `install.sh` restarts the service, which is what re-subscribes.
- **The 6-channel capture is paced on the Pi** (`arecord -d 2` takes 2.0 s), unlike the Mint
  bench, where the same command returned in ~0.14 s. If the Pi shows xruns, the knobs are
  `PCM Capture Transfer` / `PCM Capture Queue` (ALSA controls; `amixer -c 0 sset` works, no
  `ozzy-cli` needed) — `pi-bench.sh -t 8 -q 2` measures a pair.
- Re-running `scripts/pi-card-setup.sh` on an already-injected card **resets the two
  placeholders** — inject after the last run, or mount the card and redo it.
