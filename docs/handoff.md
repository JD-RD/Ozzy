# Handoff — US-600 on Linux (Mint bench, and the Pi 3B now runs the chain)

Rewritten 2026-11-11, at the end of the session that booted the Raspberry Pi 3B for the first
time and found out why it could not stream. Read this first, then `docs/plan.md` (the plan) and
`docs/us600-findings.md` (the measurements, with dates). Delete or rewrite this file when it no
longer matches reality — a stale handoff is worse than none.

## Where we are, in one paragraph

**The bench is a Raspberry Pi 3B now, not the Mint box.** First boot observed, module built on
the Pi (aarch64, kernel `6.18.50+rpt-rpi-v8`), US-600 on `card 0`, both MIDI directions healthy,
and `tr8-remap.service` **active since boot** with the ALSA sequencer port subscribed. The
transport matrix passes 14/14 twice in a row (`scripts/pi-bench.sh -c`): four rates of playback,
six-channel capture at three rates, and playback+capture at once, with **0** `MIDI output
error`, 0 engine errors, 0 late completions (out: 18 isochronous short transfers in ~22 800,
longest gap 5.6 ms; in: none, longest gap 1.9 ms).

Getting there cost one finding, and it is **not** the device and **not** the driver: the 3B's
only USB controller is `dwc_otg`, and its FIQ state machine stops completing **non-periodic**
transfers (bulk `0x04` MIDI out, `0x83` MIDI in, `0x86` PCM in) while the isochronous side keeps
submitting. The visible symptom is `aplay`/`arecord` failing with `EIO` at whatever rate comes
next, engine counters frozen, nothing in the driver log — and, once, a 30 s storm of 29 654
`[ploytec] isoc: MIDI output error 0xffffffb9` that ended in `restart failed, resetting the
device`. The trace is `WARN::dwc_otg_hcd_urb_dequeue:639: Timed out waiting for FSM NP transfer
to complete`. `dwc_otg.fiq_fsm_enable=0` in `/boot/firmware/cmdline.txt` (plus a reboot) removes
it; `install.sh` now writes it, and also `/etc/modules-load.d/us600-ozzy.conf` (without that the
enabled service starts before its port exists and loops every 5 s).

So: the 2026-11-10 conclusions about the Mint bench still stand (audio, both MIDI directions, the
`-EPROTO` state is a state of the device), and the Pi adds a host-side failure mode that has
nothing to do with either.

## The one open question

> What puts the device into the `-EPROTO` state, and can a driver avoid it?

**2026-11-11 gave it a trigger and a clock.** On the Pi, with the TR-8 looping into the US-600,
the device went from healthy to `-EPROTO` on its own **after ~8 minutes**: every bulk transfer
(`0x04`, `0x83`, `0x86`) completed `-71` with length 0, `Rx`/`Tx` froze, `Ozzy Stats` reached
35 M errors on the `in` direction and a 494 s gap, and the isochronous direction stayed clean.
`dmesg` had no `dwc_otg` warning — the device, not the host controller (which had its own,
section above). It was cured by the usual external-supply **and** USB off, 10 s, and the same
load then ran healthy again. So the next run has something to bisect: does it come back after
~8 minutes every time, and does it follow the MIDI-in traffic (clock? notes? both?), or the
isochronous playback that keeps running because a rate was set?

On Mint it was never reproduced this way; there the state only appeared on a device that had
never had a real power cycle. Two things to remember:

- `scripts/midi-health.sh` is the one-number test: it opens playback (the driver submits no MIDI
  URB at all without a running PCM substream, so "0 errors" at rest proves nothing), counts
  `[ploytec] isoc: MIDI output error` for 2 s, and prints `healthy` / `unhealthy`. The caveat
  only holds with no stream open: with the chain running, MIDI URBs are being submitted.
- On a `dwc_otg` host, "unhealthy" can also mean the FIQ FSM (§above). Check
  `dmesg | grep 'FSM NP transfer'` before blaming the device: with it, the FSM warnings are
  there and the isochronous side follows; with the device state, only bulk fails and `dmesg` is
  silent.

## Next steps, in order

1. **The one-hour soak (plan phase 4, item 5) — running since 2026-11-11 17:24**, on the real
   chain (TR-8 pads 1-11 -> US-600 -> SP-404MK2 pads 1-11), with `scripts/soak.sh` sampling every
   minute into `/home/pi/soak-<date>.log` — the only thing left of Phase 4. Chain plugged
   in (TR-8 into the US-600's MIDI in, SP-404MK2 out), `tr8-remap.service` already running from
   boot; play for an hour, then check `systemctl status tr8-remap`,
   `~/us600-linux/scripts/pi-bench.sh -c`, `/proc/asound/card*/pcm*/sub*/status` and
   `journalctl -k` for xruns. The service re-subscribes after a resume thanks to the
   `systemd-sleep` hook, and waits up to 30 s for its MIDI port at boot.
2. ~~The instrument mapping~~ Done, measured, not guessed: `--in-channel 10 --channel 10
   --base-note 44` (the TR-8 double-sends on channel 1, the MK2 listens on 10, its bank C
   starts at 44). Commits `e756a1b`, `d8ecabe`, `a5eb975` in `~/src/tr8-remap`. If the bank
   changes on the MK2, `--base-note` follows (36 A, 40 B, 44 C).
3. **Upstream (plan phase 5)** — the US-600 row can arguably leave `EXPERIMENTAL`: the captures
   and the measurements say the device is not the problem. Report with the init table and the
   framing, say plainly that the `-EPROTO` state is a device state we could not reproduce, and
   keep the Pi's `dwc_otg` story out of it (host workaround, not a driver matter).

## Bench state (as of the end of 2026-11-11)

- **Pi 3B**: `pi@192.168.0.142` (host `us600`), Raspberry Pi OS Lite 64-bit Trixie, kernel
  `6.18.50+rpt-rpi-v8`, card `0 [US600]`, ALSA client `16` this boot (not guaranteed), WiFi
  only (mDNS does not resolve on this network — use the IP, alias in `~/.ssh/config`). `sudo`
  is **passwordless** for `pi` (`/etc/sudoers.d/010_pi-nopasswd`, the stock Raspberry Pi OS
  file cloud-init had not written). `cmdline.txt` carries `dwc_otg.fiq_fsm_enable=0`.
  `/home/pi/us600-linux` and `/home/pi/tr8-remap` are tarball extracts of the commits
  `32cb1fc`+`86ecc6a` and `41009b2`; `scripts/pi-bench.sh` was copied by hand and lives only
  there until the next card is built, so **re-copy it after editing the repo**.
- **Mint box** (the old bench): Linux Mint 22.2, kernel `6.14.0-37-generic`, the US-600 unplugged
  since 2026-11-11. Its card numbering was 1; on the Pi it is 0. Anything measured on one host
  should be re-measured before it is asserted for the other: the capture pacing already differs.
- **Device**: `0644:8035`, firmware v1.0.0, chip ID 0x32, external supply, declares itself
  bus-powered (`bmAttributes 0x80`, 240 mA in the descriptor, 480 mA in sysfs). Driver build
  `8ac988b`.
- Branch `us600-midi` (ahead of `upstream/main`, `e0345d9`). The Windows captures are in
  `~/src/us600-captures/` (587 MB, **not** committed); the TASCAM package (proprietary) in
  `~/src/us600-driver-files/`; the reverse-engineering notes in `.claude/re/tascam_us600.md`.
- The Pi's card is written and reproducible: `scripts/pi-card-setup.sh` plus the templates in
  `scripts/pi-card/`. The two secrets are injected by hand after the last run of that script
  (it resets the placeholders).
- Host names: the bench machine is `onzep`, the Pi is `us600`.

## Tools (all in `scripts/`)

| script | needs root | what it does |
|---|---|---|
| `midi-health.sh` | no | **start here.** Opens playback, counts `MIDI output error` for 2 s: `0` = healthy, ~1000/s = bad |
| `pi-bench.sh` | no (`-r` needs it) | **the Pi's matrix**: rates, capture, concurrency; per step: status, duration, `-EPROTO` delta, decoded `Ozzy Stats`. `-c` concurrency, `-r` reload, `-t`/`-q` capture transfer/queue, `-j` JSON |
| `probe.sh` | no | descriptors, ALSA cards, recent `dmesg` |
| `build-load.sh` | yes | build, install, `modprobe`, print state |
| `midi-loop-test.sh` | no | notes out, report `Tx`/`Rx` deltas and error count |
| `usbmon-midi.sh` | yes | capture the bus while sending a note; `-m` reloads the module inside the capture, `-p`/`-c` hold playback/capture open, prints per-endpoint submitted/completed/**errors** |
| `midi-probe.py` | yes | module unloaded, `libusb_reset_device`, talks to `0x04`/`0x83` directly; `-l SECS` listens, `-t` replays candidate inits, `-R {both,pulse,rate81}` applies the us122l handshake only, `-N` skips the port reset |
| `pi-card-setup.sh` | no | fills `user-data` / `network-config` on a mounted Pi `bootfs`, builds the two `git archive` tarballs, drops `us600-setup/`; see `docs/pi.md` |

`/etc/modules-load.d/us600-ozzy.conf` and the `cmdline.txt` line are written by
`scripts/pi-card/install.sh`, not by hand.

## Facts already established (do not re-derive)

- Endpoint map: `0x02` isoc OUT (156 B, int 1), `0x04` bulk OUT (MIDI), `0x83` bulk IN (MIDI),
  `0x81` isoc IN (feedback, 64 B), `0x86` bulk IN (PCM); alt 1 mandatory, alt 0 has no endpoint.
  Same on the Pi's `dwc_otg` as on Mint's xHCI.
- **MIDI framing, measured on Windows and matched on Linux**: 9-byte transfers, buffer 512, one
  message per URB out, `0xFD` padding, **`0xE0` last out**, **`0x00` last in**; messages straddle
  IN frames freely. The device answers an empty IN read with 9 bytes of `0xFD…0x00` while its
  engine runs, and NAKs while it doesn't — that is the cheapest state test without `dmesg`.
- The official driver's per-configuration init (20 requests, ~85 ms, `1-start`): `'V'` read 15,
  `'I'` read (0x12), UAC `GET_CUR` endpoint 0 (44100), `SET_CUR` 48000 on `0x86` and `0x02`,
  the `'A'` block (read 0x0d00, writes 0x0d04/0x0e00/0x0f00/0x1002/0x110b at `wIndex 0x0101`),
  the rate re-sent, then **`'I'` write 0x32 last**. No `SET_INTERFACE` of its own (it rides in
  the configuration URB), no `'M'`, no `'B'`, no routing table.
- On our unit `'I'` reads **0x32** after a real power cycle (the 0x12 in the RE notes does not
  hold here), writing 0x10 reverts to 0x32 by itself, and the rate register reads **96000** at
  power-on, which is the `96000 -> 48000` line in `dmesg`, not a leftover.
- Ozzy's `'A'` block absence is **not** the problem: `midi-probe.py -t` replayed the whole
  official sequence, `'A'` included, and the FIFO behaviour did not change.
- `Ozzy Stats` (ALSA bytes control `iface=CARD,name='Ozzy Stats'`, `engine/shared/ozzy_stats.h`)
  is the only place the engine counts: otherwise a stalled pipe looks like silence. The knobs
  `PCM Capture Transfer` / `PCM Capture Queue` are plain ALSA enum controls — `amixer -c 0 sset`
  is enough, `ozzy-cli` is not needed on the Pi.

## Traps this bench paid for (do not rediscover them)

- **`dwc_otg`'s FIQ FSM** (Pi 3B): see the top. `EIO` on every rate is the controller, not the
  driver, and the driver logs nothing — the evidence is `dmesg | grep 'FSM NP transfer'`.
- **A USB-only replug is not a reset**: the external supply keeps the firmware alive. Full power
  cycle = external supply **and** USB, ~10 s. Every "I replugged it" in the earlier notes is
  suspect for this reason.
- **"0 errors" proves nothing without a running PCM substream.** The driver submits no MIDI URB
  at all when the engine is suspended. `midi-health.sh` opens playback for exactly that reason.
- **`dmesg` lies about the error rate.** `MIDI output error` at 1000/s fills the ring buffer in
  ~5 s: `grep -c` plateaus, `tail` shows old lines, and the history of what happened just
  before is *gone*. Use `journalctl -k` (it keeps 29 654 lines a ring buffer throws away),
  `dmesg -W` for new lines, and timestamps.
- **`install.sh` stopping half-way** leaves the unit installed but `disabled` and no sleep hook:
  the first Trixie boot has no `/usr/lib/systemd/system-sleep/`, so `install` fails there and
  `set -eu` ends the script. If the module works but the service is `disabled`, this is why.
- **`sudo` needs a password out of the box** on this card (cloud-init did not write the stock
  `010_pi-nopasswd`): every remote `ssh -t … sudo` prompt is one more thing to get wrong in a
  quoted `sh -c` (it cost one wasted round trip). Fixed.
- `Tx bytes` in `/proc/asound/card*/midi0` counts what ALSA accepted, not what left the host.
- **512-byte writes to `0x04` wedge the pipe for a few seconds** (the FIFO is small). Use 9-byte
  writes; `midi-probe.py` is a diagnostic, not something to leave running.
- **Capture pacing differs by host**: on Mint `arecord -d 2 … -c 6` returns in ~0.14 s after
  writing the correct 1.73 MB; on the Pi the same command takes 2.0 s. Do not carry one host's
  timing conclusions to the other.
- USBPcap artefacts, if the captures are re-read: pending URBs show junk in `USBD_STATUS`
  (`0x00540055`, `0x00470045`), `0xC0010000` is `USBD_STATUS_CANCELED`, and `usb.idVendor` is
  only set on the descriptor packets — filter by `usb.device_address` once you know it. `usbmon`
  prints endpoint *numbers*, so `0x86` appears as `Bi:…:06` and `0x83` as `Bi:…:03`.

## Conventions

- MIT only; the TASCAM/GPL sources are facts-only references, no code copied.
- One commit per thing, on `us600-midi`; `upstream` is read-only.
- Measurements → `docs/us600-findings.md` (dated sections); protocol facts →
  `.claude/re/tascam_us600.md`; plan/state → `docs/plan.md`.
- After changing anything in `scripts/`, re-copy the file to the Pi: its tree is a tarball
  extract, not a checkout.
