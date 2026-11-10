# Handoff — US-600 on Linux (Mint, then Raspberry Pi 3B)

Written 2026-11-10 at the end of a bench session. Read this first, then
`docs/plan.md` (the plan) and `docs/us600-findings.md` (the measurements). Delete or
rewrite this file when it no longer matches reality — a stale handoff is worse than none.

## Where we are, in one paragraph

Audio works on Linux Mint with this tree's `snd-usb-ozzy`. **Both MIDI directions do not**: with
the driver streaming, every transfer on `0x04` (MIDI out) and `0x83` (MIDI in) completes with
`-EPROTO`, in both directions, thousands per second, while the PCM pipes (`0x02`, `0x81`,
`0x86`) are clean. With the driver unloaded and the port reset, `0x04` **accepts** 9 and 42-byte
writes and NAKs 512; `0x83` never delivers a byte; the `0x04` FIFO takes two 9-byte frames and
**never drains**, i.e. the device's MIDI transmitter is not running. The device itself is fine:
**its MIDI works with this unit under Windows and macOS** (owner, confirmed). So the missing
piece is an initialisation (or a driver behaviour) we have not reproduced yet.

## The one open question

> What starts the US-600's MIDI transmitter, and what does the official driver send that Ozzy
> does not?

Ranked leads:

1. **The official Windows driver's traffic** — the shortest path now that we have the package
   and a Windows 11 machine (phase 2c).
2. **`'I'` index 1** — the mixer/chassis register the official driver reads for every `0644:…`
   device and Ozzy never touches. `scripts/midi-probe.py -t` measures the FIFO drain after it.
3. Some state only present while streaming. Weak: mainline's `us122l` streams and does MIDI at
   the same time on the US-144, and Windows does both on this very device.

## Next steps, in order

1. **Windows capture** (decisive, ~15 min of human time) — plan phase 2c:
   - package: `~/src/us600-driver-files/TASCAM_US600_1.03rc1.exe` (also
     `https://www.tascam.eu/sw/us-600/US-600_v103rc1_win.zip`, which answers **403** without a
     browser `User-Agent`); install x64, reboot;
   - Wireshark with the USBPcap component, filter `usb.idVendor == 0x0644 && usb.idProduct ==
     0x8035`;
   - four captures: `1-start` (capture running, replug, 10 s), `2-idle` (10 s, nothing
     happening), `3-note-out` (one note, ideally with audio playing), `4-note-in` (one note from
     the TR-8 into the DIN IN);
   - drop them in `~/src/us600-captures/` on this machine. `tshark` is **not** installed here
     (`sudo apt install -y tshark` if that is easy, otherwise the USBPcap link type can be
     parsed by hand).
2. If the capture is not available yet, run `sudo scripts/midi-probe.py -t` (loopback cable
   fitted) and read the FIFO-drain counts.
3. Then implement behind a per-device quirk (`common/ozzy_quirks.h`, asserted in the
   `TascamUS600` row of `common/ozzy_devices.def`), with a unit test in `tests/`, and validate on
   Mint (DIN loopback) before touching the Raspberry Pi 3B part (plan phase 4).

## Bench state (as of this handoff)

- Host: Linux Mint 22.2, kernel `6.14.0-37-generic`, `sudo` needs a password (no NOPASSWD), so
  anything root goes through the user.
- Device: `0644:8035` on bus 2, card 1 `US600` (`pcm0p`, `pcm0c`, `midi0`, ten controls +
  `Ozzy Info` / `Ozzy Stats`), 480 mA, firmware v1.0.0.
- Branch `us600-midi` (everything ahead of `upstream/main`, which is `e0345d9`), working
  tree clean. `git log --oneline upstream/main..us600-midi` lists the work done so far.
- The TASCAM package is **not** in the repo (proprietary); it lives in
  `~/src/us600-driver-files/`. The reverse-engineering notes are in `.claude/re/tascam_us600.md`.

## Tools (all in `scripts/`)

| script | needs root | what it does |
|---|---|---|
| `probe.sh` | no | descriptors, ALSA cards, recent `dmesg` |
| `build-load.sh` | yes | build, install, `modprobe`, print state |
| `midi-loop-test.sh` | no | notes out, report `Tx`/`Rx` deltas and error count |
| `usbmon-midi.sh` | yes | capture the device's bus while sending a note; `-m` reloads the module inside the capture; prints per-endpoint first/last completion |
| `midi-probe.py` | yes | module unloaded, `libusb_reset_device`, talks to `0x04`/`0x83` directly; `-l SECS` listens (writes a burst too), `-t` measures how many writes each candidate init lets through |

## Traps this session paid for (do not rediscover them)

- **`dmesg` lies about the error rate.** The driver logs `MIDI output error` ~1000×/s, which
  fills and wraps the ring buffer: `grep -c` plateaus (it once *dropped* by 18) and `tail` shows
  old lines. A flat counter is not proof of success. Only timestamps, or `usbmon`, tell.
- **`Tx bytes` in `/proc/asound/card1/midi0` counts what ALSA accepted**, not what left the host.
- **The device wedges.** After ~40 min of failing MIDI traffic, PCM capture died too:
  `arecord` → `EIO`, `Ozzy Stats` showed 2.1 M PCM-in errors and a 108 s gap. Replug (or a port
  reset) recovers it; an engine restart does not. Start each experiment from a fresh device.
- **`SET_CONFIGURATION` does not reliably re-arm the MIDI FIFO**; a `SET_CUR` on the PCM
  endpoints or a port reset does.
- **A USB port reset does not clear the `'I'` register** (it still reads what the driver wrote).
- **512-byte writes to `0x04` wedge the pipe** for a while: the FIFO is small. Use 9-byte writes.
- Counters to trust: `scripts/usbmon-midi.sh`'s per-endpoint status summary, and
  `midi-probe.py -t`'s "accepted N/20 writes".

## Facts already established (do not re-derive)

- Endpoint map: `0x02` isoc OUT, `0x04` bulk OUT (MIDI), `0x83` bulk IN (MIDI), `0x81` isoc IN
  (feedback), `0x86` bulk IN (PCM); alt 1 mandatory on both interfaces.
- **9-byte MIDI transfers are correct** for this family: the official Tascam kext uses
  `kInACR 3` / `inACR_M4_C1`, and mainline's `us122l` forces `max_transfer = 9` for the US-144.
- `'M'` (0x4d, 64-byte routing table) and `'B'` (0x42, reverb) are **control-panel payloads** in
  `tus600_u.sys`, not initialisation. The "send the 'M' table at open" idea is dead.
- There is **no per-device data table** in the Windows driver (`0644:8035` only appears in
  VID/PID predicates), so nothing can be lifted like the macOS plist; it has to be traced.
- `tus600_m.sys` (MIDI) binds `…&MI_00`, i.e. interface 0; `tus600_u.sys` owns every USB pipe.
- mainline's `us122l` (US-144) reference: `SET_INTERFACE(0,1)` then `(1,1)`, **`'I'` 0x11 then
  0x10**, rate by `SET_CUR` on `0x81`, MIDI created after streaming starts, MIDI IN submitted
  only when a port is opened, **1 MIDI byte per transfer at High Speed** padded with 0xFD and
  **no `0xE0` control byte** out, input accepted only when a transfer is exactly 9 bytes.
- Ozzy's differences worth testing one at a time: `'I'` = read OR 0x20 (0x12 → 0x32), `SET_CUR`
  on `0x86`/`0x02`, 3-4 MIDI bytes per transfer with `0xE0` last, one URB per ms from a timer,
  MIDI IN submitted at start and resubmitted in a tight loop when it fails.

## Conventions

- MIT only; the TASCAM/GPL sources are facts-only references, no code copied.
- One commit per thing, on `us600-midi`; `upstream` is read-only.
- Measurements → `docs/us600-findings.md` (dated sections); protocol facts →
  `.claude/re/tascam_us600.md`; plan/state → `docs/plan.md`.
