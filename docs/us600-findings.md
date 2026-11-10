# Tascam US-600 on Linux — findings

Hardware: **TASCAM US-600** (6 in / 4 out USB 2.0 audio + MIDI), USB ID `0644:8035`,
discontinued. Driver under test: this tree (Ozzy, `snd-usb-ozzy`), device row
`TascamUS600` in `common/ozzy_devices.def`, marked `EXPERIMENTAL`.

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

## Reproduce

```bash
scripts/probe.sh                 # read-only, no root
sudo scripts/build-load.sh       # build + reload the module
scripts/midi-loop-test.sh -s 30  # send notes, report Tx/Rx and dmesg errors
```
