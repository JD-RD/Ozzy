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

## Reproduce

```bash
scripts/probe.sh                 # read-only, no root
sudo scripts/build-load.sh       # build + reload the module
scripts/midi-loop-test.sh -s 30  # send notes, report Tx/Rx and dmesg errors
scripts/usbmon-midi.sh           # what the device does on 0x04 / 0x83 (sudo)
scripts/midi-probe.py            # ask 0x04 / 0x83 without the driver (sudo, unloads it)
```

The last two are the ones that settle the MIDI question: `usbmon-midi.sh` shows the
completion statuses on the wire, `midi-probe.py` shows whether the endpoints answer at all
when nothing else drives the device.
