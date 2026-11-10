# Tascam US-600 (0644:8035) — USB layout and the official Windows driver

Facts from the device on the bench, from TASCAM's Windows package, and from mainline's driver
for the sibling devices. No macOS kext has been looked at here.

## The device (read on Linux, 2026-11-10)

High Speed, one configuration, 2 vendor-specific interfaces, **no endpoint in alt 0**:

| interface | alt 1 endpoints |
|---|---|
| 0 | `0x02` isoc OUT 156 B int 1, `0x83` bulk IN 512 B, `0x04` bulk OUT 512 B |
| 1 | `0x81` isoc IN 64 B int 4, `0x86` bulk IN 512 B |

`bMaxPower` 480 mA, firmware v1.0.0 (chip ID 0x32), `bcdDevice` 0x0101. A `'I'` (0x49) read of
index 0 gives 0x12 at power-up, 0x32 after the driver's confirm; **a USB port reset does not
clear it**.

What works: `0x02` (isoc OUT), `0x81` (isoc IN), `0x86` (bulk IN, PCM capture).
What fails: `0x04` (bulk OUT) and `0x83` (bulk IN) — with the *driver* streaming they complete
with `-EPROTO`; with the driver unloaded and the port reset, `0x04` takes 9 and 42 bytes
(`ok`) and NAKs anything bigger, and `0x83` never delivers a byte. The `0x04` FIFO holds two
9-byte frames and **never drains**, i.e. the device's MIDI transmitter does not run.

## The Windows package (US-600 v1.03rc1, 2015, Ploytec engine)

`https://www.tascam.eu/sw/us-600/US-600_v103rc1_win.zip` — a 7-Zip SFX (`7z x`), x64 and x86:

| file | what |
|---|---|
| `tus600_u.sys` | the Ploytec engine, class USB, bound to the whole device; owns every USB pipe, exposes sub-devices (control panel, MIDI) |
| `tus600_a.sys` | the audio function driver (MEDIA class) |
| `tus600_m.sys` | the MIDI function driver (MEDIA class), binds **`USB\VID_0644&PID_8035&MI_00`**, i.e. interface 0 — the one with `0x04` / `0x83`; it moves bytes through the engine, no vendor requests of its own |
| `tus600_x64.dll` | the control panel / ASIO side |

RE notes on `tus600_u.sys` (Ghidra-free, `objdump -d -M intel` on the PE; strings carry the
C++ function names):

- **No per-device data table**: `0644:8035` appears only as immediates in 14 places, all of
  them VID/PID membership predicates (`is<family>(vid, pid)` chains: 0x800f, 0x8020, 0x8017,
  0x8030, 0x8034, **0x8035**, 0x8025, 0x801e, Numark, Alesis …). There is no `{vid,pid,...}`
  struct to lift, so anything device-specific is an `if (pid == 0x8035)` inside the code.
- **`'M'` (0x4d, 64-byte routing table) is not part of init**: the only `'M'` sender is the
  *user-client* dispatch (a control-panel command that first copies a 0x200-byte block and then
  a 0x40-byte table out of the request buffer and sends it). So the official driver sends the
  routing table only when the user changes something, not at open. Same for `'B'` (0x42,
  256-byte reverb buffer): both are payload from the panel.
- `'V'` (0x56) reads appear three times (firmware and friends), the vendor-request helper is
  the function that logs `deviceRequest Callresult:...`, and the user-mode path is the
  `PGIOCTL_STD_VENDOR_REQUEST` dispatcher (it fills an 0x88-byte URB by hand).
- Strings worth knowing: `register SubDevice - MIDI`, `USB: Hide MIDI Interface`,
  `rtsProcessBulkOutMIDI` (the *embedded* MIDI path, for the Xone-type devices), `Midi Device`,
  `Create MIDI Device`.

Starting points for a deeper trace: `PGDevice::configurationDone` (string 0xf1074630),
`PGDevice::setSelectors` (0xf10759a0), the `register SubDevice - MIDI` site (0xf1077de0) and
the `USB: Hide MIDI Interface` one (0xf1078b70). `.pdata` gives the function bounds for any
address (`scripts`/notes: parse 12-byte RUNTIME_FUNCTION entries at file offset 0x7a200).

## Mainline's us122l (US-122L 0644:800e, US-144 0644:800f) — the working reference

Same family, same endpoints, GPL-2.0 so facts only:

- `SET_INTERFACE(0,1)` (US-144) then `(1,1)`, then **`'I'` 0x11 then 0x10** (a pulse), then the
  rate by UAC `SET_CUR` on **`0x81`**, then the stream starts; MIDI endpoints created after
  that, MIDI IN URBs only when an app opens the port.
- MIDI transfer size **9 bytes** both ways (`QUIRK_MIDI_US122L`), 4 URBs, **1 MIDI byte per
  transfer at High Speed** padded with 0xFD (so the last byte is 0xFD, **no 0xE0 control byte**),
  input accepted only when a transfer is exactly 9 bytes, trailing 0xFD stripped, no control
  byte either.

## Open

- What starts the US-600's MIDI transmitter (the FIFO that never drains). Candidates: the `'I'`
  index-1 (mixer/chassis config) register that Ozzy never reads, a mixer-mode write, or the
  rate/stream state. `scripts/midi-probe.py -t` measures the FIFO drain after each candidate.
- Whether this unit's MIDI has ever worked (nobody has tested it on Windows/macOS here).
