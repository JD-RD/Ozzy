# Tascam US-600 on Linux — findings

Hardware: **TASCAM US-600** (6 in / 4 out USB 2.0 audio + MIDI), USB ID `0644:8035`,
discontinued. Driver under test: this tree (Ozzy, `snd-usb-ozzy`), device row
`TascamUS600` in `common/ozzy_devices.def`, marked `EXPERIMENTAL`.

The bring-up plan (Linux Mint, then Raspberry Pi 3B) is in `plan.md`; this file is the
measurement it starts from.

## USB descriptors (read from `/sys/bus/usb/devices/<dev>/descriptors`)

```
DEVICE  bcdUSB=0200  class=ff sub=ff proto=ff  maxpkt0=64  0644:8035
CONFIG  80 bytes, 2 interfaces, maxPower 256 mA
  IFACE #0 alt=0  nEP=0  class=ff sub=00 proto=00
  IFACE #0 alt=1  nEP=3  class=ff sub=00 proto=00
    EP 0x02  isoc  OUT  wMaxPacketSize=156  bInterval=1
    EP 0x83  bulk  IN   wMaxPacketSize=512  bInterval=4
    EP 0x04  bulk  OUT  wMaxPacketSize=512  bInterval=4
  IFACE #1 alt=0  nEP=0  class=ff sub=00 proto=00
  IFACE #1 alt=1  nEP=2  class=ff sub=00 proto=00
    EP 0x81  isoc  IN   wMaxPacketSize=64   bInterval=4
    EP 0x86  bulk  IN   wMaxPacketSize=512  bInterval=1
```

Both interfaces are vendor-specific and expose **no endpoint in alt 0**; `SET_INTERFACE`
to alt 1 is mandatory before any transfer. This layout is identical to the Akai EIE Pro
noted in `common/devices/ploytec/ploytec_defs.h`, so the by-type endpoint selection in
`PLOYTEC_ISOC_EP_*` resolves to the same pipes:

| role     | endpoint | interface | type |
|----------|----------|-----------|------|
| PCM out  | `0x02`   | 0         | isoc |
| MIDI out | `0x04`   | 0         | bulk |
| MIDI in  | `0x83`   | 0         | bulk |
| PCM in   | `0x86`   | 1         | bulk |
| feedback | `0x81`   | 1         | isoc |

## Test run (2026-11-09)

Environment: Linux `6.14.0-37-generic` x86_64, module built from `e0345d9`.

Module loads cleanly:

```
usb 2-1: [ozzy] build e0345d9 (engine), Tascam US-600 (0644:8035), experimental
[ozzy]   interface 0: EP 0x02 OUT isoc      wMaxPacketSize 156 x1 bInterval 1
[ozzy]   interface 0: EP 0x83 IN  bulk      wMaxPacketSize 512 x1 bInterval 4
[ozzy]   interface 0: EP 0x04 OUT bulk      wMaxPacketSize 512 x1 bInterval 4
[ozzy]   interface 1: EP 0x81 IN  isoc      wMaxPacketSize 64 x1 bInterval 4
[ozzy]   interface 1: EP 0x86 IN  bulk      wMaxPacketSize 512 x1 bInterval 1
[ozzy] isoc out: 1 microframe(s) per packet, up to 13 frames, feedback every 8 microframe(s)
usb 2-1: [ozzy] running at 96000 Hz, 6 in / 4 out
[ozzy] sample rate 96000 -> 48000 Hz
```

ALSA exposes `card 1 [US600]`, `pcm0p`, `pcm0c`, `midi0` (rawmidi `hw:1,0`, `IO`), and
ALSA sequencer client `US-600` with one port. Controls are created (`Clock Source`,
`Capture 1-2/3-4/5-6 Source`, `Output 1-2/3-4 Source`, `IEC958 Playback Mode`).

### Audio: works

- Playback: 24-bit / 48 kHz / 4 channels, 0.5 s of silence -> `rc=0`, no error.
- Capture: 6 channels / 48 kHz / 24-bit, 20 s -> 17 280 044 bytes (864 KB/s, as expected).

### MIDI out: broken

Every 9-byte MIDI-out transfer fails, once per millisecond, for as long as the module is
loaded (idle transfers included):

```
[ploytec] isoc: MIDI output error 0xffffffb9      # -EPROTO, 4706 messages in 4.7 s
```

`/proc/asound/card1/midi0` shows `Tx bytes: 228` accepted from ALSA but nothing leaves the
device. The timer path is `isoc_timer()` -> `ozzy_bus_submit(..., midi_out_addr, ...)`, so
`midi_out_addr` resolves to `0x04` and the device rejects the URB with EPROTO.

### MIDI in: silent

`Rx bytes: 0` while a TR-8 sequencer sent a 4/4 bass drum (note 36) into the DIN MIDI IN,
with audio capture running at the same time. The MIDI-in URBs are submitted (no
"input submission failed" message) but never complete with data.

### Verdict

Audio is usable; **both MIDI directions are non-functional** on this device with the
current row, which is consistent with its `EXPERIMENTAL` status. Endpoint mapping is not
the problem — it matches the Akai EIE Pro of the same family.

## Working hypotheses

1. **Transfer framing/size.** `ploytec_midi_init_xfer()` selects `M4_C1` (9-byte transfers,
   pattern 4,3,3,3,3,3,3,3) for this device. The US-600 may expect another fixed size
   (`NS7` = 42 bytes, or a size derived from `0x2a`/`512`). A wrong size is the simplest
   explanation for a per-URB `-EPROTO`.
2. **Missing vendor initialisation.** The Windows driver (`tus600_u.sys`, Ploytec engine)
   may issue a control request at open that enables the DIN MIDI routing; without it the
   endpoints stay inactive. This would explain the silent MIDI IN as well.
3. **MIDI carried in the PCM stream.** On the Xone family the MIDI slots live inside the
   isochronous PCM packets. If the US-600 does the same, `0x04` is not the MIDI pipe and
   writes to it can only fail. `ploytec_protocol.h` already implements the embedded layout
   for the bulk family, so this would be a matter of selecting that path for this device.

## Next step that settles all three

Capture the official Windows driver with **USBPcap + Wireshark** while sending one note
and receiving one note:

- transfer sizes and byte patterns on `0x04` (out) and `0x83` (in),
- control requests on endpoint 0 during open/close (vendor requests, `bRequest`,
  `wValue`, `wIndex`, payload),
- whether the isochronous `0x02` packets carry MIDI slots.

Then compare with `common/devices/ploytec/ploytec_midi.h` and adjust the device row and/or
the isoc engine.

## Session 2026-11-10 (same machine, kernel 6.14.0-37, module at `345be40`)

After a replug (the device came back as `Bus 002 Device 012`) and a fresh load:

- Handshake as before, card 1 `US600`, `pcm0p` / `pcm0c` / `midi0`, the ten controls
  (`Clock Source`, the three `Capture x-y Source`, two `Output x-y Source`,
  `IEC958 Playback Mode`, `S/PDIF Clock Validity`, `PCM Capture Transfer`, `PCM Capture Queue`)
  and the two CARD bytes controls `Ozzy Info` / `Ozzy Stats`.
- Playback `aplay -D hw:1,0 -f S24_3LE -c 4 -r 48000 -d 1 /dev/zero` -> `rc=0`.
  Capture `arecord -D hw:1,0 -f S24_3LE -c 6 -r 48000 -d 2` -> `rc=0`, 1.73 MB.
  `Ozzy Stats` afterwards: 0 errors both directions, 0 short transfers, `late` 254 and
  max gap ~20 ms on capture (the starts).
- **MIDI out and in both fail at the USB level with `-EPROTO`**, from the very first transfer
  (`usbmon` on bus 2, `scripts/usbmon-midi.sh`, 2 s of capture):
  - `0x04` (bulk OUT): 3170 submissions, 3170 completions, **all status `-71` (`-EPROTO`)**,
    length 0, payload `fd fd fd fd fd fd fd fd e0` or `90 24 64 fd ... e0`.
  - `0x83` (bulk IN): 29 331 submissions in the same 2 s, every completion `-71` and
    resubmitted immediately, so the engine spins at ~15 k submissions/s. Nothing is logged
    for MIDI in.
  - Meanwhile `0x02` (isoc OUT), `0x81` (feedback) and `0x86` (bulk IN, the PCM capture) all
    complete with status 0.
  - `-71` is `EPROTO`, which on xHCI is a **USB transaction error** (an invalid answer from the
    device), not a STALL (`-EPIPE` would be 32) and not a NAK (that would show as a timeout).
- Consequence for the earlier bullet: the driver logs `MIDI output error` ~1000 times/s, which
  fills and wraps the kernel ring buffer. `dmesg | grep -c` therefore stays flat (it even went
  down by 18 during the capture) and `tail` shows old lines: the missing growth is **not**
  evidence that the transfers work. `Tx bytes` in `/proc/asound/card1/midi0` counts what ALSA
  accepted, not what left the host. The rawmidi drain rate (~3.3 KB/s) is the timer popping
  3-4 bytes per millisecond into a transfer that then fails.
- So the loopback (`scripts/midi-loop-test.sh`) shows Tx advancing and Rx at 0 with no *new*
  error count, and that is consistent with total failure of both directions, not with success.
- What is left: the endpoint rejects everything while the other three pipes work, so neither
  the size (9 bytes) nor the endpoint choice is at fault. A missing initialisation that enables
  the MIDI pipes (hypothesis 2) is the leading explanation; the alternative is that the
  device wants those pipes driven differently (transfer type / alt setting / packet size).
  `scripts/midi-probe.py` asks the endpoints directly with the module unloaded to separate the
  two (plan phase 2b).
- Pending: `scripts/midi-probe.py` (needs root) and, if that leaves the question open, the
  Windows capture (plan fallback).

## Session 2026-11-10, `usbfs` without the driver: the MIDI endpoints work at rest

`scripts/midi-probe.py` (module unloaded, `libusb_reset_device`, `SET_CONFIGURATION 1`,
alt 1 on both interfaces). Note that a port reset does **not** reset the 'I' register: it
still reads 0x32, the value the driver wrote.

- **bulk OUT `0x04` is accepted**: 9 bytes -> `ok, moved 9`, 42 bytes -> `ok, moved 42`. No
  0xFD padding, no `0xE0` control byte needed for the device to ACK.
- **512 bytes on `0x04` NAKs** (timeout), and once it has, the following 9-byte writes also
  NAK until the pipe is re-armed (a `SET_CUR` on the PCM endpoints or a fresh
  `SET_CONFIGURATION` brought it back in the next stages). So the device's MIDI FIFO is small,
  and a write larger than it wedges the pipe for a while.
- **bulk IN `0x83` never delivers anything**: 9, 42 and 512-byte reads all time out, with the
  DIN loopback fitted and after the successful OUT writes. So either the device does not
  forward its DIN IN to USB, or it does not forward USB to its DIN OUT (then the loopback
  carries nothing).
- CLEAR_HALT and leaving interface 1 in alt 0 change nothing.
- `SET_CUR` 48000 to `0x86` and `0x02` works here (3 bytes); to `0x81` (mainline's choice) also.
- The 'I' values tried (0x32 vs mainline's 0x11 then 0x10) change nothing for MIDI.

**Consequence:** the device is not refusing these pipes. The driver's `-EPROTO` is a state
that only exists while it streams, i.e. the difference between the probe and the driver is the
PCM traffic (`0x02` isoc out, `0x86` bulk in), not the framing, the alt settings or the handshake.
Two leads, in order:

1. the engine submits the MIDI URBs right after starting the PCM transfers and keeps
   resubmitting a failing MIDI-in URB ~15 000 times/s; mainline's us122l submits MIDI input
   only when an app opens the port, and never in a tight loop;
2. the device may accept MIDI only while nothing streams (unlikely: mainline does both on the
   US-144, and the Windows driver on this very device certainly does).

`scripts/usbmon-midi.sh -m` reloads the module inside the capture to show whether the first
MIDI URBs fail before or after the first PCM completions, which separates the two.

## Session 2026-11-10, later: the device's IN side wedges

After ~40 min of experiments on the same load (audio tests, a rawmidi write flood, the
`usbmon` capture, two loopback tests), the device stopped answering on more than the MIDI
pipes:

- `arecord` on `pcm0c` now fails after the header (`pcm_read: EIO`), and `Ozzy Stats` reads
  **2 574 129 PCM-in transfers, 2 127 856 of them errors**, longest gap between completions
  108 s (`pcm0c` closed, nothing retries once ALSA gave up).
- The MIDI storm continues at ~1000 logged errors/s, so `dmesg | grep -c` sits at whatever the
  ring holds (~4700): a flat or wobbling count means nothing, only the timestamps tell.
- Same shape as the DB4's documented failure (`.claude/re/ploytec_bulk_devices.md`, "the DB4's
  IN side dies when the host stops polling it"): the IN pipe stops completing and the engine's
  restart does not bring it back. Not yet checked whether the US-600 recovers on a module
  reload alone or needs a port reset / replug; `scripts/midi-probe.py` now does
  `libusb_reset_device` first, which is the cheapest way to find out.
- Consequence for the bench: **start every experiment from a fresh device** (reset or replug),
  otherwise a wedged pipe from the previous run is indistinguishable from the bug under test.
  This also matters for the Pi target: a device that wedges after a few minutes of failing
  transfers is not a MIDI interface one can leave running.

## Reference: mainline's us122l on the same family (facts only)

`sound/usb/usx2y/us122l.c` drives the US-122L (`0644:800e`) and US-144 (`0644:800f`) — the same
bulk-in / isoc-out layout, MIDI on `0x04` / `0x83` in alt 1. Its source is GPL-2.0, so these
are the facts of the wire, not code to copy:

- start order: `SET_INTERFACE(0, 1)` on the US-144 then `SET_INTERFACE(1, 1)`, then **two 'I'
  writes with wIndex 0: 0x11, then 0x10** (a pulse: bit 0 set, then cleared), then the rate
  through UAC `SET_CUR` on **endpoint `0x81`**, then the PCM stream starts. The USB-MIDI
  endpoints are created only after that, and the MIDI IN URBs are submitted when an app opens
  the port (`snd_usbmidi_input_start`), not at start.
- MIDI uses mainline's generic driver with `QUIRK_MIDI_US122L` (`sound/usb/midi.c`): out_ep 4,
  in_ep 3, and the transfer size is **forced to 9 bytes** (`ep->max_transfer = 9`, the same as
  Ozzy). 4 URBs; at High Speed **one MIDI byte per transfer**, the rest 0xFD — so the last byte
  is 0xFD, there is **no `0xE0` control byte** on the way out. The input handler accepts only a
  transfer of exactly 9 bytes, strips trailing 0xFD and passes the rest; it knows no control
  byte either.

Where Ozzy differs from it, worth testing one at a time (see `scripts/midi-probe.py`):
| | mainline us122l (works on US-144) | Ozzy on the US-600 |
|---|---|---|
| 'I' writes | 0x11 then 0x10 | the read value OR 0x20 (0x12 -> 0x32) |
| rate `SET_CUR` on | `0x81` | `0x86` |
| bytes per MIDI-out transfer | 1 (HS), no control byte | 3-4, last byte `0xE0` |
| MIDI-out pacing | 4 URBs, resubmit at once, device NAKs | one URB per ms, timer |
| MIDI IN submitted | when the port is opened | at start, always |

The pulse and the `0x10` end state are the interesting part: Ozzy leaves bit 5 (0x20) set,
mainline leaves bit 0 clear, and nobody has checked what the US-600's firmware wants there.

## Session 2026-11-10, the official Windows package and the reference driver

- Downloaded TASCAM's `US-600_v103rc1_win.zip` (v1.03rc1, 2015; the site answers **403**
  without a browser `User-Agent`) and unpacked it (`7z x`, it is a 7-Zip SFX). Layout and what
  each binary is: `.claude/re/tascam_us600.md`. The extracted copy sits outside the repo, in
  `~/src/us600-driver-files/` (proprietary, not committed).
- Three findings there that change the options: `tus600_m.sys` binds **interface 0** (the MIDI
  pipes); `tus600_u.sys` is the Ploytec engine that owns every USB pipe, so the init is in it;
  and there is **no per-device data table** (`0644:8035` appears only as VID/PID membership
  predicates), so nothing can be lifted the way the macOS plist was.
- `'M'` (0x4d, the 64-byte routing table) is **not** part of init: the only sender in
  `tus600_u.sys` is the control-panel dispatch, which forwards a table the user supplied. Same
  for `'B'` (0x42). So "the missing init is the 'M' table" is out.
- **The device is known good**: its MIDI works with this unit under Windows and macOS (owner,
  2026-11-10). Everything that is missing is in the initialisation, not in the hardware.
- Next step: capture the official driver on the Windows 11 machine (plan phase 2c). The local
  leads left are the `'I'` index-1 register (never touched by Ozzy) and the FIFO-drain metric in
  `scripts/midi-probe.py -t`.

## Session 2026-11-10, Windows capture of the official driver (plan 2c)

Four USBPcap captures of the US-600 under the official 1.03rc1 driver on Windows 11, taken from
`0123-4567/us600-captures/` on the SD card and copied to `~/src/us600-captures/` (587 MB, not
committed). Files: `1-start`, `2-idle`, `3-noteout`, `4-note-in`. Device address changes per
replug (24, 25, 33, 34); `usb.idVendor` is only set on the descriptor packets, so the
per-device filter is `usb.device_address` (or the endpoint signature) once the address is known.

What the captures change: nothing in the device, everything in the driver. The MIDI pipes do
**not** error under Windows — every single 9-byte transfer on `0x04` and `0x83` completes with
`USBD_STATUS_SUCCESS`.

### The init sequence (identical in all four captures)

From t≈7.2 s on `1-start` (bus 1, addr 24), everything within ~85 ms:

| # | request | value | window | meaning |
|---|---|---|---|---|
| 1 | `GET_DESCRIPTOR` device / config / string | | | enumeration |
| 2 | `0xc0 'V'` (0x56) read 15 bytes | wValue 0, idx 0 | | returns `31 2e 30 30 …` = "1.00" firmware |
| 3 | `0x00 SET_CONFIGURATION` | 1 | | |
| 4 | `0xc0 'I'` (0x49) read 1 | wValue 0, idx 0 | | returns **0x12** |
| 5 | `0xa2 GET_CUR` bRequest 0x81 | wValue 0x0100, idx 0, 3 B | | returns **`44 ac 00`** = 44100 |
| 6 | `0x22 SET_CUR` bRequest 0x01 | wValue 0x0100, idx **0x86**, 3 B | | data `80 bb 00` = 48000 |
| 7 | `0x22 SET_CUR` bRequest 0x01 | wValue 0x0100, idx **0x02**, 3 B | | data `80 bb 00` = 48000 |
| 8 | `0xc0 'A'` (0x41) read 5 | wValue **0x0d00**, idx **0x0101** | | returns `04 92 00 02 00` |
| 9 | `0x40 'A'` write | wValue **0x0d04**, idx 0x0101 | | no data |
| 10 | `0x40 'A'` write | **0x0e00** | | |
| 11 | `0x40 'A'` write | **0x0f00** | | |
| 12 | `0x40 'A'` write | **0x1002** (3-noteout 2nd init and 4-note-in: **0x1000**) | | varies |
| 13 | `0x40 'A'` write | **0x110b** | | |
| 14 | `0x22 SET_CUR` idx 0x86 (x3), 0x02 (x2) again | | | rate re-sent |
| 15 | `0xa2 GET_CUR` idx 0x86 | | | returns `80 bb 00` = 48000 |
| 16 | `0xc0 'I'` read 1 | | | returns 0x12 |
| 17 | `0x40 'I'` write | wValue **0x0032** | | bit 5 set |

Facts that follow, each one a difference with Ozzy:

- **No `SET_INTERFACE` (bRequest 0x0B, `URB_FUNCTION_SELECT_INTERFACE`) in any capture, ever.**
  Zero occurrences in the four files; there is a single `URB_FUNCTION_SELECT_CONFIGURATION`
  (`SET_CONFIGURATION 1`) per configuration event, and USBPcap does not decode the
  per-interface alternate settings that travel inside that URB. So alt 1 is selected, but in the
  same URB as the configuration — not a difference with Ozzy (on Linux, alt 0 has no endpoint at
  all and usbfs refuses to submit to `0x04`/`0x83` in it, so the two paths are equivalent).
  What the class requests honour is `wIndex` as an *endpoint address*, not an interface number.
- The `'I'` register write is **last**, after the `'A'` block and a rate re-check, and the value
  is a straight `0x32` on a register that reads `0x12` (so Ozzy's "read, OR 0x20, write" lands
  on the same value — but *when* it is written differs).
- The `'A'` block (steps 8-13) is **completely absent from Ozzy** and has never been exercised
  by `scripts/midi-probe.py -t`. It runs once per configuration, immediately before the final
  `'I'` write, with `wIndex 0x0101`. `wValue` looks like `(register << 8) | value`.
- The rate is set on the **endpoints** (class, recipient endpoint), 3 bytes, 48000 = `80 bb 00`,
  after reading 44100 back from endpoint 0. Same shape mainline's us122l uses.
- No `'M'` (0x4d), no `'B'` (0x42), no routing table: the RE reading is confirmed on the wire.
  One configuration = these 20 vendor/class setup requests, nothing else.

### MIDI framing and pacing (what Ozzy must match)

| | Windows (measured) | Ozzy today |
|---|---|---|
| transfer size, both directions | **always exactly 9 bytes**, buffer 512 | 9 B in, 3-4 B per URB out |
| MIDI-out payload | one message, then `0xFD` padding, then **`0xE0`** last | same idea |
| MIDI-in payload | data, `0xFD` padding, **`0x00`** last (not `0xE0`) | ? |
| MIDI-out pacing | **one 9-byte URB per message**, on demand; clock = 20.8 ms median (48/s = 120 BPM × 24 ppqn) | one URB/ms from a timer |
| MIDI-out at idle | **none at all** (0 URBs in 70 s of `2-idle`) | submitted at start |
| MIDI-in submissions | 5 URBs when the port opens, then one resubmission per completion; **3500-4000/nothing**, never a tight loop | tight loop on failure |
| errors | 0. 1405/1405 OUT and 4074/4074 IN complete `SUCCESS` | every transfer `-EPROTO` |

- `3-noteout`: 1405 OUT URBs, payloads `f8 fd×5 e0` (1387, clock), `90 3c 64` (×6), `80 3c 40`
  (×6), `f2 10 00`, `fc`, `fb`, `b0 7b 00`. Note the MIDI clock: Ableton was clock master, so
  most of the volume is 0xF8, not notes.
- `3-noteout` and `4-note-in` both show a fitted **DIN loopback**: everything sent on `0x04`
  comes back on `0x83` (1387 f8 out, 1387 f8 in; the same note bytes on both sides). In
  `4-note-in` the TR-8's `0xFE` active sensing appears on `0x83` (source) *and* on `0x04`
  (Ableton echoing the input), so the TR-8 is audible in the IN stream but not isolated from
  the loopback. A `4-note-in` capture without Ableton is still worth having.
- MIDI-in frames pack freely: `f8 f8 f8 fd…00`, and messages straddle frames
  (`64 99 24 fd…00` / `00 99 24 fd…00`) — the 9-byte framing is a transport, not a message
  delimiter, in both directions.
- USBPcap artifacts to not misread: pending URBs show junk in `USBD_STATUS` (`0x00540055` =
  newline in the IRP's own buffer, `0x00470045`, `0x80000102`), and `0xC0010000` is
  `USBD_STATUS_CANCELED` (device unplugged/reconfigured, not a MIDI error). Real statuses here
  are `0x00000000`; `usb.urb_type` (`S`/`C`) is not filled by the USBPcap dissector, so pairs
  are matched by IRP id.

### Consequence for the next experiment

**Tested 2026-11-10 (`midi-probe.py -t`), the `'A'` block is ruled out.** All three new trials, and
the four old ones, end at `accepted 2/20` then `-7 TIMEOUT (device NAKed)`: the `'A'` block is
accepted (`'A'` read `04 92 00 02 0b`, five writes `ok`) and changes nothing. Two other results
from that run:

- Every init request is **accepted** by the device (the rate GET/SET_CUR, the `'A'` block, the
  `'I'` write): the init is not what the device is refusing.
- `'I'` already reads **0x32** before the probe writes it (a port reset does not clear it, as the
  handoff says), so the probe never sees the 0x12 → 0x32 transition Windows performs. `'M'`
  (64 zero bytes) and `'T'` return `-9 PIPE (STALL)`.

What is left is structural, not a register: **in all four captures, every single successful MIDI
transfer happened while the isochronous engine was streaming** — `tus600_u.sys` runs `0x02`,
`0x81` *and* the bulk `0x86` PCM capture continuously from configuration (12745 iso URBs and 1496
`0x86` URBs in 70 s of `2-idle`, with no application open), and the first `0x04` URB comes 65 s
after streaming started (`3-noteout`, t=6.6 → t=71.27). The FIFO that "takes two frames and never
drains" is what a firmware whose main loop is not running looks like. So the next test is not
another control request:

| run | streams held open | question |
|---|---|---|
| 1 | playback only | (done before: MIDI fails) |
| 2 | **capture only** (`0x86`) | does the PCM-in stream alone start the transmitter? |
| 3 | playback + capture | both, as Windows always has |

Ozzy starts capture only when an application captures, while the official driver streams `0x86`
from configuration: run 2 is the one that would explain everything.

Falling back to control requests only if that fails, the remaining candidates are the `'I'`
transition from a virgin device (unplug while no driver is bound, so the register reads 0x12
again) and the `'A'` 5th/3rd byte state difference (`… 02 00` on Windows, `… 02 0b` here).

If (1) or (2) drains the `0x04` FIFO, the fix is a `TascamUS600`-only quirk in
`common/devices/ploytec/ploytec_handshake.c` plus the device row in `common/ozzy_devices.def`.

### 2026-11-10 18:19 — same driver, same machine: zero errors

`scripts/usbmon-midi.sh -s 3` on a freshly replugged device, with PCM running (both directions
were streaming during the capture: `0x02`/`0x81` at 1045 URBs and `0x86` at 2503 in ~3.5 s):

| endpoint | submitted | completed | errors | payload |
|---|---|---|---|---|
| `0x02` isoc OUT | 1045 | 1045 | **0** | 2304 B of silence |
| `0x81` isoc IN | 1045 | 1045 | **0** | 256 B feedback (`30 30 30 00…`) |
| `0x04` bulk OUT | 4170 | 4170 | **0** | `fd fd fd fd fd fd fd fd e0`, one per **1000 µs** |
| `0x83` bulk IN | 227 | 227 | **0** | `f8 fd…00` ×212, `fe fd…00` ×15 |
| `0x86` bulk IN | 2503 | 2503 | **0** | 5120 B |

- **8994 completions, not one non-zero status, and `MIDI output errors: 0`.** The note itself
  (`90 24 64 fd fd fd fd fd e0`) completes with status 0, 30 µs after submission; the note-off
  too. So the failure this project has been chasing is **not reproducible in this state**: the
  driver's own 1-ms MIDI URBs are accepted and drained.
- **MIDI IN works, and the source is the TR-8**: 212 `0xF8` (MIDI clock, ~60/s) and 15 `0xFE`
  (active sensing) in the 9-byte frames. There is **no DIN loopback cable fitted** on this
  machine — the note sent on `0x04` never comes back on `0x83` — so this run also settles the
  input side on its own.
- **The diagnostic for "engine running"**: with the engine off (`midi-probe.py`, driver unloaded)
  a 9-byte read on `0x83` **NAKs** (libusb `-7`); with the engine running the same read
  **completes with 9 bytes** of `0xFD…0x00`. Same for `0x04`: off = two frames then NAK, on =
  every frame ACKed. That is a cheap, unambiguous state test.
- What is still unknown is the **precondition**. The first guess there — "the PCM engine must be
  running" — was **wrong**, see below.

### 2026-11-10 18:35 — the same device, wedged, with the streams running

Measured on the same boot, same module, ~15 min after the clean run, with nothing holding
`/dev/snd/midiC1D0` open (`fuser -v` empty):

| state | `MIDI output error` rate |
|---|---|
| nothing open | 1992 / 2 s |
| capture open (`pcm0c` `state: RUNNING`, verified) | 1990 / 2 s |
| playback open (`pcm0p` `state: RUNNING`) + capture | 1993 / 2 s |

The log line is `[ploytec] isoc: MIDI output error 0xffffffb9` (0xffffffb9 = -71 = `-EPROTO`), and
it fills the whole ring buffer on its own. So the streams are **not** the gate: the device
transitions from "everything completes with status 0" to "every `0x04` transfer is `-EPROTO`"
on its own, and the four-way `-p`/`-c` matrix that was proposed is moot (the options stay in the
script, they are useful for other questions).

Prime suspect, and it is in our code: **Ozzy submits a 9-byte MIDI OUT every millisecond
forever**, padding-only when nothing is playing, with no port open — `isoc_timer()` in
`engine/devices/ploytec/ploytec_isoc_engine.c` even says "Like the official driver it also sends
idle transfers". The capture says the opposite: the official driver sends **zero** MIDI URBs at
idle, in both directions, over 70 s (`2-idle`), and 5 pending IN URBs when the port opens. 1000
`FD…E0` frames per second into a device the official driver leaves alone at rest is the obvious
candidate for a firmware state machine falling over.

Next measurement: replug, clear `dmesg`, and time how long the driver takes to produce its first
`MIDI output error` with no application running. Minutes → the idle hammering is the trigger and
the fix is to submit on demand only (a new `OZZY_QUIRK_MIDI_IDLE_SILENT` on the `TascamUS600`
row). Hours or never → look at the `0x83` resubmission instead.

Unrelated anomaly worth its own look: `arecord -d 2` on this device returns in 0.14 s after
writing the correct 1.73 MB — the capture substream is not paced to real time.

### 2026-11-10 18:47 — and the state flips back, during a probe run

`sudo scripts/midi-probe.py` (the five default stages) on that wedged device, then the module
reloaded by the script itself:

| moment | `MIDI output error` rate |
|---|---|
| before the probe (18:35) | 1993 / 2 s |
| after the probe, engine suspended | 0 / 2 s |
| after the probe, playback open (`pcm0p` `state: RUNNING`) | **0 / 2 s** |
| after two `amidi` notes (`90 3c 64`, `80 3c 40`) | 0 |

The device went from "every `0x04` transfer `-EPROTO`" to "every transfer accepted" **without a
power cycle**, and the state survived the module reload. What this run has that no earlier one
had is the probe's **last** stage: mainline's us122l handshake — `'I'` write 0x11, `'I'` write
0x10, `SET_CUR` 48000 Hz on **`0x81`** (the feedback endpoint). After it `'I'` reads **0x10**;
the next module load reads 0x32 and writes 0x32 (`status confirmed (read=0x32, wrote
wValue=0x0032)`, `dmesg` 18:47).

The probe output is the same picture from the other side: 9 bytes `ok`, 42 bytes `ok`, 512 bytes
NAK, then (after the 512-byte wedge, the known trap) everything NAKs until a few seconds later —
the FIFO signature of "engine off".

Consequence: there is a **recovery** sequence and it is not a power cycle. `midi-probe.py -R
{both,pulse,rate81}` now applies either half or the whole handshake and nothing else, so the next
two measurements are:

1. does a hard power cycle (external supply **and** USB, 10 s) bring `-EPROTO` back?
2. if yes, which half of the handshake clears it — that half is the missing initialisation, and
the reason the official driver's capture never shows it is that Windows had already left the
   device in that state when it was captured.

Still unexplained: the driver reads `96000 Hz (raw: 00 77 01)` from the rate register at load
(`dmesg` 18:47), although nothing on the Linux side ever set 96000.

### 2026-11-10 19:03 — after a real power cycle (external supply **and** USB)

Bus 2 device 023, module bound on plug, `dmesg` handshake trace:

- `'I'` reads **0x32** at step 2/7, i.e. *before* the driver writes anything. The RE note
  ("0x12 at power-up, 0x32 after the driver's confirm") does not hold for this unit after a
  power cycle: either the value lives in NVM, or the USB side never lost power.
- The rate register reads **96000 Hz (raw `00 77 01`)** at power-up, so Ozzy's `96000 -> 48000`
  line is the device's default, not a leftover from earlier experiments. (Windows reads 44100
  from a *different* register: the UAC `GET_CUR` on endpoint 0, `44 ac 00`.)
- **MIDI is clean**: two engine starts in a row, `0` errors per 2 s window.

So a fresh device works; what is missing is the **decay** — it happened twice (18:19 → 18:35 and
18:47 → ~18:55) without any replug. The soak test (one engine start, one measurement per
minute, nothing else running) is what should give the time. Two named allocations for the fact
table: `0x32` and `96000` at power-on.

### 2026-11-10 19:41-20:10 — the fresh state does not decay

After the power cycle (device 023), with `dmesg -W | grep -c 'MIDI output error'` over 2 s as the
metric (0 = healthy, ~2000 = every `0x04` transfer `-EPROTO`):

| test | result |
|---|---|
| soak: one engine start, one measurement/min for 20 min | `0` all 20 times |
| one note + one note-off through `amidi` (open/write/close) | `0` |
| rawmidi opened and closed with no write | `0` |
| 12 engine start/stop cycles | `0` 12 times |
| `modprobe -r` + `modprobe` (module reload), then 6 cycles | `0` 6 times |
| `midi-probe.py -R pulse` (port reset + `'I'` 0x11/0x10), then 6 cycles | `0` 6 times |
| full `midi-probe.py` (9/42/512-byte writes, `CLEAR_HALT`, alt 0), then module reload | `0` 6 times |

So neither time, nor the engine restart path, nor the rawmidi port lifecycle, nor a module
reload, nor the probe (port reset, `SET_CONFIGURATION`, `SET_INTERFACE`, the 512-byte write)
degrades the device. The two earlier `-EPROTO` states were therefore inherited, not produced:
the session that recorded them ran on a unit whose "replug" left the external supply connected,
and the two bad states seen today (18:35 and ~18:55) both followed long diagnostic runs on that
same never-really-powered-down unit.

Also from this run: `'I'` written to 0x10 **reverts to 0x32 on its own** within ~300 ms (the
probe reads 0x10, the next module load reads 0x32), so 0x10 is not a state that can be kept.

### 2026-11-10 20:55-21:05 — validation with a DIN loopback fitted

Cable OUT → IN fitted on the US-600. `scripts/midi-loop-test.sh` had to be rewritten first: it
never opened the MIDI IN port, and the driver only submits the `0x83` URBs while a client reads,
so `Rx` and `/proc` stayed at zero and the script reported "nothing came back" on a path that
works. It now opens the input for the whole run, compares the returned bytes with what was sent
(dropping `0xF8`/`0xFE`), and judges the error state by whether the **last** `MIDI output error`
timestamp moved (the count is useless, the buffer is always full).

| test | result |
|---|---|
| loopback, 12 s, 18 notes | 108 bytes back, exact order, no new error |
| loopback, 30 s, 36 notes | 216 bytes back, exact order, no new error |
| loopback with **no PCM stream open** | works: both notes come back (the "engine must run" rule only concerns the driver's idle URBs, not real traffic) |
| playback 4 ch, 44.1 / 48 / 88.2 / 96 kHz | `rc=0`, 1.19 s each |
| capture 6 ch, same four rates, alone | `rc=0`, byte-exact (only the 44-byte WAV header extra) |
| playback + capture at 48 and 96 kHz | `rc=0`, byte-exact |

One flake, kept because the Pi phase will hunt exactly this: in a back-to-back rate sweep, the
96 kHz capture returned `pcm_read: Erreur d'entrée/sortie` after 44 bytes, and the same command
was fine in isolation and after a 48 kHz playback. Related: the capture substream is still not
paced to real time (2 s of audio in 0.14 s), so byte counts are meaningful but wall-clock is not.

Still open for phase 3: the TR-8 → SP-404 chain. With the loopback fitted the input contains
exactly the bytes we send and nothing else, so the TR-8 was not sending at all (it was off or
unplugged) — the real chain and the instrument mapping are untested.

Later the same evening, with the loopback replaced by the TR-8 on the DIN IN, `usbmon-midi.sh`
over 4.2 s: `0x04` 4092/4092 and `0x83` 224/224, `errors 0` on every endpoint. The `0x83`
frames carry 208 × `f8` (clock, ~50/s) and 16 × `0xFE` (active sensing), i.e. the TR-8 is on the
input; the one note sent is accepted by the device (status 0) and does **not** come back, which
is expected once the loopback cable has been replaced by the TR-8.

Then 120 s with the TR-8 played by hand, still nothing on the SP-404, and the capture says why:
**the driver does not route MIDI in to out.** `0x83` carried 6065 × `f8`, 422 × `0xFE` and the
notes themselves (`90 35`, `99 25`, `99 27`, `99 33`, `90 47`, `2F 50`, `31 50` … on channels 1
and 10), while `0x04` carried **119 733 idle frames and only the two notes the test script sent
itself**. With `aconnect 20:0 20:0` (the ALSA sequencer subscription that makes the port its own
source, i.e. a thru) the chain works end to end: **TR-8 pad 5 lights bank A pad 7 on the
SP-404MK2**. The cross-mapping is the MK2's fixed note→pad table, which is what `~/src/tr8-remap`
is for; it is not a driver matter.

So both directions are proven on the wire and through real gear. What remains for phase 3:
replug (external supply **and** USB), suspend/resume, and the 36-51 mapping in `tr8-remap`.

## Reproduce

```bash
scripts/probe.sh                 # read-only, no root
scripts/midi-health.sh           # is the MIDI engine healthy right now (no root)
sudo scripts/build-load.sh       # build + reload the module
scripts/midi-loop-test.sh -s 30  # DIN OUT -> IN: every byte back, no errors
sudo scripts/usbmon-midi.sh      # what the device does on 0x04 / 0x83 (sudo)
sudo scripts/midi-probe.py       # ask 0x04 / 0x83 without the driver (sudo, unloads it)
```

The last two are the ones that settle the MIDI question: `usbmon-midi.sh` shows the
completion statuses on the wire, `midi-probe.py` shows whether the endpoints answer at all
when nothing else drives the device.
