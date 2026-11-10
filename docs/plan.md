# US-600 MIDI bring-up plan

Goal: make the Tascam US-600's DIN MIDI (both directions) work through `snd-usb-ozzy`, so the
device can serve as the MIDI interface of the TR-8 -> SP-404MK2 remapper and be reported
upstream as tested.

Baseline (current): audio works, MIDI out returns `-EPROTO` on every transfer, MIDI in is
silent. See `us600-findings.md`.

## M0 — Baseline (done)

- Build and load the module on a recent kernel, capture the descriptors, log the failure
  mode with evidence.
- Scripts: `scripts/probe.sh`, `scripts/build-load.sh`, `scripts/midi-loop-test.sh`.

## M1 — Windows capture (blocking for M2)

Needs a Windows host with the official TASCAM driver (`US-600_v103rc1_win.zip`, Ploytec
engine) and USBPcap + Wireshark.

Capture three sessions, each with a note marker in the file name:

1. **Plug-in only** — driver install/load, interface open, any idle traffic. Shows the
   vendor control requests issued at open and the size of idle MIDI-out transfers.
2. **One note out** — play one note from a MIDI app to the US-600 MIDI OUT (DIN).
3. **One note in** — send one note from a MIDI device into the US-600 MIDI IN.

Deliverables in `docs/captures/`: `*.pcapng` plus a short table of the transfers observed
(endpoint, size, payload, interval) and of the control requests (`bmRequestType`,
`bRequest`, `wValue`, `wIndex`, `wLength`).

## M2 — Protocol adjustment

Depending on M1:

- **Framing only** -> change the framing selection for `TascamUS600` (e.g.
  `OZZY_QUIRK_MIDI_NS7`, or add a new size/pattern) in `common/ozzy_devices.def` and
  `ploytec_midi.h`. Unit-test it in `tests/` (the tree already has `test_midi_queue.c`,
  `test_running_status.c`, a fake bus and golden files).
- **Missing init request** -> add the control request to `ploytec_handshake.c` behind a
  quirk flag, and assert the flag in the device row.
- **Embedded MIDI** -> route the device through the PCM-slot encoder in
  `ploytec_protocol.h` instead of the dedicated bulk pipe.

Keep every change behind a per-device quirk so no other Ploytec device changes behaviour.

## M3 — Validation

- `scripts/midi-loop-test.sh` with a physical DIN loopback (OUT -> IN): bytes out must come
  back in, and the `MIDI output error` counter must stay at zero.
- Real chain: TR-8 MIDI OUT -> US-600 MIDI IN, US-600 MIDI OUT -> SP-404MK2 MIDI IN, with
  `~/src/tr8-remap` running: 11 instruments, one pad each, notes 36-51.
- Audio regression: playback 24/48/4ch and capture 6ch must still pass, and the device must
  still survive unplug/replug and suspend.
- ARM64 build on a Raspberry Pi 3B (target host of the remapper).

## M4 — Upstream

- Report the result on `mischa85/Ozzy` (issue with `dmesg`, descriptors, capture) so the
  US-600 row can move from `EXPERIMENTAL` to `SUPPORTED`, or so the maintainer can point
  at what is missing.
- If the fix is small and generic, prepare a PR: device row + quirk + test, no unrelated
  reformatting.

## Conventions

- `upstream` = `https://github.com/mischa85/Ozzy` (read-only). Work happens on
  `us600-midi`; rebase on `upstream/main` before sending anything.
- Never push experiment commits to `upstream`. Keep each commit about one thing.
- Build artifacts are already gitignored (`*.ko`, `*.o`, `*.mod`, `modules.order`, ...).
