# US-600 bring-up plan — Linux Mint, then Raspberry Pi 3B

Goal: make the TASCAM US-600 (`0644:8035`, 6 in / 4 out, DIN MIDI both ways) fully usable
with `snd-usb-ozzy`, first on the Linux Mint desktop this tree is developed on, then on a
Raspberry Pi 3B where the device is the MIDI interface of the TR-8 -> SP-404MK2 remapper
(`~/src/tr8-remap`). Audio must keep working throughout; nothing may change for other
devices.

"Works" means, on both hosts:

- playback and capture at every rate the row lists (44.1 / 48 / 88.2 / 96 kHz), 6 in / 4 out,
- DIN MIDI out and in, byte-exact, including a hardware loopback (OUT -> IN cable),
- survives unplug/replug and suspend,
- on the Pi: the same via `tr8-remap.service` from boot, no xrun over an hour.

## Current state (2026-11-10, this Mint machine)

Hardware: `Bus 002 Device 012: ID 0644:8035 TEAC Corp. US-600`, High Speed (480 Mb/s),
2 vendor-specific interfaces, both with endpoints only in alt 1.

```
IFACE #0 alt=1   EP 0x02 isoc OUT 156 B int 1   EP 0x83 bulk IN 512 B   EP 0x04 bulk OUT 512 B
IFACE #1 alt=1   EP 0x81 isoc IN   64 B int 4   EP 0x86 bulk IN 512 B
```

| role     | endpoint | interface | type |
|----------|----------|-----------|------|
| PCM out  | `0x02`   | 0         | isoc |
| MIDI out | `0x04`   | 0         | bulk |
| MIDI in  | `0x83`   | 0         | bulk |
| PCM in   | `0x86`   | 1         | bulk |
| feedback | `0x81`   | 1         | isoc |

- The module builds and loads on `6.14.0-37-generic`; card 1 `US600` with `pcm0p` / `pcm0c` /
  `midi0` and the ten controls. Playback and 6-channel capture work (`rc=0`).
- **Both MIDI directions fail at the USB level while the driver streams**: every completion on
  `0x04` and `0x83` is `-EPROTO` (`scripts/usbmon-midi.sh`: 3170/3170 OUT, 29 331/29 331 IN in
  two seconds), while `0x02`, `0x81` and `0x86` all complete with status 0.
- With the driver unloaded and the port reset (`scripts/midi-probe.py`), `0x04` **accepts** 9 and
  42 bytes and only NAKs 512; `0x83` never delivers a byte; the `0x04` FIFO holds two 9-byte
  frames and **never drains**. So the device is not refusing the pipes, and its MIDI
  transmitter is not running.
- The device is known good: **its MIDI works with this unit on Windows and macOS** (owner,
  2026-11-10). Whatever is missing is in the init, not in the hardware.
- Power: the configuration descriptor says 256 mA, sysfs reports 480 mA. Relevant on the Pi.

See `us600-findings.md` for the measurements and `.claude/re/tascam_us600.md` for the device and
the official driver (who binds what, why `'M'` is not the gate, mainline's us122l as reference).

## Phase 0 — Baseline (done)

Build, load, log the failure mode with evidence. Scripts: `scripts/probe.sh` (read-only),
`scripts/build-load.sh` (build + install + reload), `scripts/midi-loop-test.sh` (notes out,
report Tx/Rx and `MIDI output error` count).

## Phase 1 — Mint: audio baseline

1. `sudo scripts/build-load.sh` — install, `depmod`, `modprobe`, then check
   `/proc/asound/cards`, `card*/midi0`, `dmesg | grep -iE 'ozzy|ploytec'`.
2. `amixer -c US600` — list the controls the row creates (Clock Source,
   Capture 1-2/3-4/5-6 Source, Output 1-2/3-4 Source, IEC958 Playback Mode).
3. Playback 24-bit / 48 kHz / 4 ch and capture 6 ch (`speaker-test`, `arecord`), then repeat
   at 44.1 / 88.2 / 96 kHz. Record what fails, if anything.
4. `ozzy-cli show` (build `apps/cli` if needed) to capture the driver's own view: firmware,
   rates, transfer sizes, endpoints, latency.

Exit criterion: the same result as `us600-findings.md` §Audio, on this kernel, with the log
kept in `docs/logs/` (`*.log` is gitignored, so the directory has to be created).

## Phase 2 — Mint: MIDI

2a and 2b are done and narrowed it to "the device's MIDI engine is not running, and our driver
however is what makes it visible as `-EPROTO`". The official driver's behaviour on the same
device is now the shortest path to the missing initialisation: see 2c.

### 2a. See what the device actually does (`usbmon`)

Tool: `scripts/usbmon-midi.sh` (re-runs itself with sudo). It captures this device's bus,
sends one note on/off, and prints the endpoint lines plus a per-endpoint summary
(submitted / completed / last status). Full capture kept in `/tmp/`.

```bash
scripts/usbmon-midi.sh            # 2 s after the note; -s/-b/-o to change that
```

```bash
sudo modprobe usbmon
lsusb -d 0644:8035            # the bus in "Bus 002 Device 012" is the one to watch
sudo cat /sys/kernel/debug/usb/usbmon/2u > /tmp/us600-midi.txt   # bus 2 today
# play one note into DIN IN, send one note from an app, stop the capture
```

Look at: the exact URB length and payload on `0x04`, whether the completion is a STALL
(`-EPIPE`) or a protocol error (`-EPROTO`), whether anything is ever submitted/completed on
`0x83`, and what the control pipe does around start/stop (vendor `'I'`, `'V'`, `'A'`,
SET_CUR on `0x86`).

**Done (2026-11-10):** every completion on `0x04` and `0x83` is `-EPROTO` while the driver
streams; `0x02` / `0x81` / `0x86` are clean. Numbers in `us600-findings.md`.

### 2b. Ask the device directly (`usbfs`, no rebuild)

Tool: `scripts/midi-probe.py` (ctypes + libusb-1.0.so.0, no headers, no pip). It unloads the
module (the driver owns the interfaces), does `SET_CONFIGURATION 1` + `SET_INTERFACE` alt 1,
then tries `0x04` / `0x83` with 9, 42 and 512 bytes, after `CLEAR_HALT`, and with
interface 1 left in alt 0, then reloads the module. Every call prints the libusb code, so
STALL, NAK-timeout and protocol error are distinguishable.

```bash
scripts/midi-probe.py             # -k: leave the driver unloaded afterwards
```

What the probe covers (and what each result would mean):

| variant | what it tests |
|---|---|
| bulk OUT `0x04`, 9 bytes, `4,3,3,3,3,3,3,3` pattern | today's path (expect `-EPROTO`) |
| bulk OUT `0x04`, 42 bytes / 512 bytes | another framing, endpoint-sized transfer |
| `CLEAR_HALT 0x04` / `0x83` before the writes | endpoint left halted |
| interface 1 left in alt 0 | an alt-setting combination the driver does not use |
| vendor requests `'I'` / `'A'` / `'M'` / `'T'` before the writes (not in the tool yet) | missing initialisation |
| MIDI inside PCM out `0x02`, Xone layout (not in the tool yet) | hypothesis 3: DIN MIDI fed by the PCM stream |
| bulk IN `0x83` 9 / 42 / 512 bytes, DIN loopback fitted | which size makes MIDI in flow |

**Done (2026-11-10):** with the driver unloaded, `0x04` accepts 9 and 42 bytes and NAKs 512;
`0x83` never delivers; `CLEAR_HALT`, the alt combinations and both `'I'` variants change
nothing; the `0x04` FIFO holds two frames and never drains. Measurements in
`us600-findings.md`.

Every run prints the return code / errno and the bytes read. This distinguishes "wrong size"
from "endpoint not enabled" from "MIDI is elsewhere" without touching the driver, and gives
us the exact list of requests to add if initialisation is missing.

### 2c. Capture the official driver (next step, needs the Windows 11 machine)

The device's MIDI works under Windows and macOS with this unit, so the answers are in the
official driver's traffic. Capture it with USBPcap, four short sessions:

| file | what to do |
|---|---|
| `1-start.pcapng` | start the capture, then replug the US-600, wait ~10 s: the init requests and their order relative to streaming |
| `2-idle.pcapng` | 10 s idle: whether Windows sends MIDI at rest, of what size, and how the device answers |
| `3-note-out.pcapng` | one note from a MIDI app, ideally with audio playing: sizes and byte patterns on `0x04` |
| `4-note-in.pcapng` | one note from the TR-8 into the DIN IN: sizes on `0x83` |

- Driver package: `https://www.tascam.eu/sw/us-600/US-600_v103rc1_win.zip` (403 without a
  browser `User-Agent`); the downloaded and extracted copy for this bench lives outside the
  repo, in `~/src/us600-driver-files/` (proprietary, nothing to commit). Its layout is in
  `.claude/re/tascam_us600.md`.
- Wireshark + the USBPcap component, display filter `usb.idVendor == 0x0644 && usb.idProduct ==
  0x8035`, then *File > Export Specified Packets > Displayed*.
- Deliverables: `docs/captures/*.pcapng` plus the table of transfers (endpoint, size, payload,
  interval) and control requests (`bmRequestType`, `bRequest`, `wValue`, `wIndex`, `wLength`).
  Facts go to `.claude/re/tascam_us600.md`, the measurements to `us600-findings.md`.

What the capture settles: whether the MIDI pipes are driven with 9-byte frames (and how often),
whether the device stalls/NAKs/errors them, whether MIDI coexists with PCM streaming, and the
one or two vendor requests the official driver sends that Ozzy does not — the answer to "what
starts the transmitter".

### 2d. Decide, then implement behind a quirk

| finding in 2a/2b | change |
|---|---|
| another transfer size works | framing choice for `TascamUS600` in `common/ozzy_devices.def` (`OZZY_QUIRK_MIDI_NS7` or a new size/pattern), `common/devices/ploytec/ploytec_midi.h` |
| only after a control request | `common/devices/ploytec/ploytec_handshake.c`, new flag in `common/ozzy_quirks.h`, asserted in the device row |
| MIDI rides in the PCM stream | route the device through the embedded path (`ploytec_protocol.h`) instead of the dedicated bulk pipe, `engine/devices/ploytec/ploytec_isoc_engine.c` |
| endpoint was simply halted | clear halt on the MIDI endpoint at start (and only for this device, `xone_host_ops` deliberately has no `clear_halt`) |

Unit tests in `tests/` (fake bus, golden files): `test_midi_queue.c`, `test_running_status.c`,
plus one for the selected framing. Every change stays behind a per-device quirk so no other
Ploytec device changes behaviour.

Known trap to keep in mind while testing MIDI out: ALSA's sequencer bridge
(`sound/core/seq/seq_midi.c`) sends running status, and at least one Ploytec firmware
(Reloop Digital Jockey 2 ME, `200c:1009`) drops messages that use it (`.claude/re/open_questions.md`).
If MIDI out starts working on the wire but notes are missing, test with full status bytes
before blaming the driver.

## Phase 3 — Validation on Mint

- `scripts/midi-loop-test.sh -s 30` with a DIN OUT -> IN cable: every byte comes back, the
  `MIDI output error` counter stays at zero.
- Real intent: TR-8 MIDI OUT -> US-600 IN, US-600 OUT -> SP-404MK2 IN, notes 36-51, one pad
  per instrument.
- Audio regression at the four rates, plus unplug/replug and suspend/resume.

## Phase 4 — Raspberry Pi 3B

1. OS and headers: Raspberry Pi OS (64-bit or 32-bit — both fine, the module is plain C),
   `sudo apt install linux-headers-$(uname -r)` (or `raspberrypi-kernel-headers` on older
   images).
2. Build on the Pi from this tree: `make -C linux KERNELDIR=/lib/modules/$(uname -r)/build`,
   then `sudo make modules_install && sudo depmod -a && sudo modprobe snd-usb-ozzy`.
   `scripts/build-load.sh` does all of it.
3. Power: the 3B shares 1.2 A across its ports and the US-600 claims up to 480 mA (more with
   the 48 V phantom supply). Use a powered hub if the device resets, capture babbles or the
   card disappears under load — check `dmesg` for over-current / disconnect first.
4. Confirm the transports on the 3B's host controller: PCM out is isochronous (`0x02`, 156 B,
   interval 1) and PCM in is bulk (`0x86`) — watch for `-EOVERFLOW` on capture and for
   `xrun`s.
5. Run the real chain and `tr8-remap.service` from boot; leave it an hour and check both
   `/proc/asound/card*/pcm*/sub*/status` and the counters.
6. If the 3B struggles (xruns, late completions), reduce what the host asks for: on this
   isochronous family only the capture side is a setting, e.g.
   `ozzy-cli set pcm-capture-transfer 8-frames pcm-capture-queue 2-transfers`
   (smaller transfer, fewer in flight). The defaults are a starting point, not a rule.

## Phase 5 — Upstream

Report on `mischa85/Ozzy` (issue with `dmesg`, descriptors, usbmon/usbfs evidence) so the
US-600 row can move from `EXPERIMENTAL` to `SUPPORTED`, or so the maintainer can point at
what is missing. If the fix is small and generic, prepare a PR: device row + quirk + test,
no unrelated reformatting.

## Conventions

- `upstream` = `https://github.com/mischa85/Ozzy` (read-only). Work happens on `us600-midi`;
  rebase on `upstream/main` before sending anything.
- Never push experiment commits to `upstream`. Keep each commit about one thing.
- Build artifacts are already gitignored (`*.ko`, `*.o`, `*.mod`, `modules.order`, ...).
- Code style of the tree: C in `common/` and `engine/`, MIT only, `/* */` for function docs,
  structs and enums over `#define`s.
- Record what each experiment showed: findings go to `us600-findings.md`, protocol facts to
  `.claude/re/` (a `tascam_us600.md` once there is enough to be worth a file).
