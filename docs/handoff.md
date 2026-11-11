# Handoff — US-600 on Linux (Mint, then Raspberry Pi 3B)

Rewritten 2026-11-10 at the end of the session that closed the MIDI question. Read this first,
then `docs/plan.md` (the plan) and `docs/us600-findings.md` (the measurements, with dates).
Delete or rewrite this file when it no longer matches reality — a stale handoff is worse than
none.

## Where we are, in one paragraph

Audio and **both MIDI directions work** with this tree's `snd-usb-ozzy` on Linux Mint. On a
device that has been through a **real power cycle** (external supply *and* USB unplugged — see
the trap below), measured 2026-11-10: 20 minutes of continuous streaming with zero
`MIDI output error`, 12 engine start/stop cycles with zero, a note out and back through the
rawmidi port with zero, a module reload with zero, and the full `usbfs` probe (9/42/512-byte
writes, `CLEAR_HALT`, alt combinations) with zero afterwards. Under `usbmon` the transfers are
the right shape and complete cleanly: 4170/4170 on `0x04` and 227/227 on `0x83`, all
`USBD_STATUS_SUCCESS`, the note completing 30 µs after submission.

The `-EPROTO` failure this project was built around is **a state of the device, not a driver
bug**: it was seen twice, both times on a unit that had *never been really power-cycled* (the
earlier session's "replug" was USB-only with the external supply still connected, which does not
reset the firmware). No sequence we can execute deliberately — module reload, port reset, the
full probe including the 512-byte writes, engine start/stop, rawmidi open/close — reproduces it
once the device is properly power-cycled.

## The one open question

> What puts the device into the `-EPROTO` state, and can a driver avoid it?

It matters because a user who ends up in that state sees both MIDI directions dead until they
power-cycle the hardware. Two observations to start from:

- `scripts/midi-health.sh` is the one-number test: it opens playback (the driver submits no MIDI
  URB at all without a running PCM substream, so "0 errors" at rest proves nothing), counts
  `[ploytec] isoc: MIDI output error` for 2 s, and prints `healthy` / `unhealthy`.
- The recovery that is known to work is a real power cycle. A module reload and a USB-only
  unplug do **not** necessarily clear it. `scripts/midi-probe.py -R pulse` cleared it once, from
  a state created by the probe itself; don't count on it.

## Next steps, in order

1. **Raspberry Pi 3B (plan phase 4)**, now the next thing: build on the Pi, powered hub if it
   browns out, `tr8-remap.service` from boot, an hour of the real chain and watch for xruns.
   The two carry-overs are already patched on the other side, in `~/src/tr8-remap` (no git there):
   `remap.py` now waits up to 30 s for its MIDI port instead of exiting (which made systemd
   restart-loop and fill the journal), a `systemd-sleep/tr8-remap` hook restarts the service after
   a resume (the ALSA sequencer subscription does not survive it, and `Restart=always` never sees
   the silent stop), and the unit carries both `ExecStart` variants with the **US-600** one active.
   The remaining risk is the 6-channel capture not being paced to real time here: xruns are the
   thing to look for first.
2. **The instrument mapping (notes 36-51)** in `~/src/tr8-remap`, on the bench:  `pip install
   --user mido python-rtmidi`, then `--in US-600 --out US-600` (the same port is both, so the
   substring matches are not ambiguous — each is looked up in its own list).
3. **Upstream (plan phase 5)** — the US-600 row can arguably leave `EXPERIMENTAL`: the captures
   and the measurements say the device is not the problem. Report with the init table and the
   framing, and say plainly that the `-EPROTO` state is a device state we could not reproduce.

## Bench state (as of the end of 2026-11-10)

- Host: Linux Mint 22.2, kernel `6.14.0-37-generic`, `sudo` needs a password (no NOPASSWD).
- Device: `0644:8035` on bus 2 (device number changes per plug; was 024 at 2:24), card 1 `US600`
  (`pcm0p`, `pcm0c`, `midi0`, ten controls + `Ozzy Info` / `Ozzy Stats`), firmware v1.0.0,
  chip ID 0x32. **It has an external power supply** and still declares itself bus-powered
  (`bmAttributes 0x80`, `bMaxPower` 240 mA in the descriptor, 480 mA in sysfs) — relevant for
  the Pi's power budget and for every "reset" in this document.
- Branch `us600-midi` (ahead of `upstream/main`, `e0345d9`). The Windows captures are in
  `~/src/us600-captures/` (587 MB, **not** committed); the TASCAM package (proprietary) in
  `~/src/us600-driver-files/`; the reverse-engineering notes in `.claude/re/tascam_us600.md`.

## Tools (all in `scripts/`)

| script | needs root | what it does |
|---|---|---|
| `midi-health.sh` | no | **start here.** Opens playback, counts `MIDI output error` for 2 s: `0` = healthy, ~2000 = the bad state |
| `probe.sh` | no | descriptors, ALSA cards, recent `dmesg` |
| `build-load.sh` | yes | build, install, `modprobe`, print state |
| `midi-loop-test.sh` | no | notes out, report `Tx`/`Rx` deltas and error count |
| `usbmon-midi.sh` | yes | capture the bus while sending a note; `-m` reloads the module inside the capture, `-p`/`-c` hold playback/capture open, prints per-endpoint submitted/completed/**errors** |
| `midi-probe.py` | yes | module unloaded, `libusb_reset_device`, talks to `0x04`/`0x83` directly; `-l SECS` listens, `-t` replays candidate inits, `-R {both,pulse,rate81}` applies the us122l handshake only, `-N` skips the port reset |

## Facts already established (do not re-derive)

- Endpoint map: `0x02` isoc OUT (156 B, int 1), `0x04` bulk OUT (MIDI), `0x83` bulk IN (MIDI),
  `0x81` isoc IN (feedback, 64 B), `0x86` bulk IN (PCM); alt 1 mandatory, alt 0 has no endpoint.
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

## Traps this bench paid for (do not rediscover them)

- **A USB-only replug is not a reset**: the external supply keeps the firmware alive. Full power
  cycle = external supply **and** USB, ~10 s. Every "I replugged it" in the earlier notes is
  suspect for this reason.
- **"0 errors" proves nothing without a running PCM substream.** The driver submits no MIDI URB
  at all when the engine is suspended. `midi-health.sh` opens playback for exactly that reason.
- **`dmesg` lies about the error rate.** `MIDI output error` at 1000/s fills the ring buffer in
  ~5 s: `grep -c` plateaus, `tail` shows old lines, and the history of what happened just
  before is *gone*. Use `dmesg -W` (new lines only) and timestamps.
- `Tx bytes` in `/proc/asound/card1/midi0` counts what ALSA accepted, not what left the host.
- **512-byte writes to `0x04` wedge the pipe for a few seconds** (the FIFO is small). Use 9-byte
  writes; `midi-probe.py` is a diagnostic, not something to leave running.
- **The PCM capture is not paced to real time**: `arecord -d 2` returns in ~0.14 s after writing
  the correct 1.73 MB. Harmless for MIDI work, worth owning before the Pi/xrun tests.
- USBPcap artefacts, if the captures are re-read: pending URBs show junk in `USBD_STATUS`
  (`0x00540055`, `0x00470045`), `0xC0010000` is `USBD_STATUS_CANCELED`, and `usb.idVendor` is
  only set on the descriptor packets — filter by `usb.device_address` once you know it. `usbmon`
  prints endpoint *numbers*, so `0x86` appears as `Bi:…:06` and `0x83` as `Bi:…:03`.

## Conventions

- MIT only; the TASCAM/GPL sources are facts-only references, no code copied.
- One commit per thing, on `us600-midi`; `upstream` is read-only.
- Measurements → `docs/us600-findings.md` (dated sections); protocol facts →
  `.claude/re/tascam_us600.md`; plan/state → `docs/plan.md`.
