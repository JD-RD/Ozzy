#!/usr/bin/env python3
"""Ask the US-600's MIDI endpoints directly, without the driver (usbfs / libusb).

The module owns the device, so this unloads it first and reloads it at the end
(unless -k). Each stage starts from a fresh SET_CONFIGURATION 1, claims both
interfaces, selects alternate setting 1, and then tries the MIDI endpoints:

  1. as the driver sets it up: bulk OUT 0x04 with 9 / 42 / 512 bytes, then a
     bulk IN 0x83 read of the same size (DIN loopback cable fitted)
  2. after CLEAR_HALT on both MIDI endpoints
  3. with interface 1 left in alt 0 (an alt combination the driver never uses)
  4. after the vendor 'I' write the driver does (read | 0x20)
  5. after the 'I' writes mainline's us122l makes for the US-122L / US-144:
     0x11 then 0x10, and the rate set with SET_CUR on 0x86

Every call prints libusb's return code and the bytes moved, so a STALL (-9), a
timeout (-7, the device NAKed) and a protocol error (-EPROTO, which libusb
reports as -99 OTHER) can be told apart.

Usage: scripts/midi-probe.py [-k] [-n notes]      (needs root for usbfs)
"""
import argparse
import ctypes
import os
import subprocess
import sys
import time

VID, PID = 0x0644, 0x8035
EP_MIDI_OUT, EP_MIDI_IN = 0x04, 0x83
EP_PCM_IN, EP_PCM_OUT = 0x86, 0x02

REQTYPE_IN = 0xC0        # vendor, device, host -> device? no: 0xC0 = in
REQTYPE_OUT = 0x40
REQTYPE_CLASS_EP_OUT = 0x22  # class, endpoint, host -> device
REQ_STATUS = 0x49        # 'I'
REQ_VERSION = 0x56       # 'V'
REQ_SET_CUR = 0x01

NAMES = {
	0: "ok", -1: "IO", -2: "INVALID_PARAM", -3: "ACCESS", -4: "NO_DEVICE",
	-5: "NOT_FOUND", -6: "BUSY", -7: "TIMEOUT (device NAKed)", -8: "OVERFLOW",
	-9: "PIPE (STALL)", -10: "INTERRUPTED", -11: "NO_MEM", -12: "NOT_SUPPORTED",
	-99: "OTHER (usbfs hides EPROTO here)",
}


def name(rc):
	if rc >= 0:   # control transfers: bytes moved
		return "%d ok" % rc
	return "%d %s" % (rc, NAMES.get(rc, "?"))


class Usb:
	def __init__(self):
		self.lib = ctypes.CDLL("libusb-1.0.so.0")
		self.ctx = ctypes.c_void_p()
		self.lib.libusb_init.argtypes = [ctypes.POINTER(ctypes.c_void_p)]
		rc = self.lib.libusb_init(ctypes.byref(self.ctx))
		if rc < 0:
			raise SystemExit("libusb_init failed: %s" % name(rc))
		self.lib.libusb_exit.argtypes = [ctypes.c_void_p]
		self.lib.libusb_close.argtypes = [ctypes.c_void_p]
		self.lib.libusb_bulk_transfer.restype = ctypes.c_int
		self.lib.libusb_control_transfer.restype = ctypes.c_int
		self.handle = None

	def open(self):
		self.lib.libusb_open_device_with_vid_pid.argtypes = [ctypes.c_void_p, ctypes.c_uint16, ctypes.c_uint16]
		self.lib.libusb_open_device_with_vid_pid.restype = ctypes.c_void_p
		self.handle = self.lib.libusb_open_device_with_vid_pid(self.ctx, VID, PID)
		if not self.handle:
			raise SystemExit("cannot open %04x:%04x (permissions? usbfs needs root)" % (VID, PID))
		self.lib.libusb_set_auto_detach_kernel_driver.argtypes = [ctypes.c_void_p, ctypes.c_int]
		self.lib.libusb_set_auto_detach_kernel_driver(self.handle, 1)
		for fn, args in (
			("libusb_set_configuration", [ctypes.c_void_p, ctypes.c_int]),
			("libusb_claim_interface", [ctypes.c_void_p, ctypes.c_int]),
			("libusb_release_interface", [ctypes.c_void_p, ctypes.c_int]),
			("libusb_set_interface_alt_setting", [ctypes.c_void_p, ctypes.c_int, ctypes.c_int]),
			("libusb_clear_halt", [ctypes.c_void_p, ctypes.c_ubyte]),
			("libusb_reset_device", [ctypes.c_void_p]),
			("libusb_bulk_transfer", [ctypes.c_void_p, ctypes.c_ubyte, ctypes.c_char_p,
						  ctypes.c_int, ctypes.POINTER(ctypes.c_int), ctypes.c_uint]),
			("libusb_control_transfer", [ctypes.c_void_p, ctypes.c_uint8, ctypes.c_uint8,
						     ctypes.c_uint16, ctypes.c_uint16, ctypes.POINTER(ctypes.c_ubyte),
						     ctypes.c_uint16, ctypes.c_uint]),
		):
			getattr(self.lib, fn).argtypes = args

	def close(self):
		if self.handle:
			self.lib.libusb_close(self.handle)
			self.handle = None
		self.lib.libusb_exit(self.ctx)

	def config(self):
		return self.lib.libusb_set_configuration(self.handle, 1)

	def claim(self, intf):
		return self.lib.libusb_claim_interface(self.handle, intf)

	def release(self, intf):
		return self.lib.libusb_release_interface(self.handle, intf)

	def alt(self, intf, setting):
		return self.lib.libusb_set_interface_alt_setting(self.handle, intf, setting)

	def clear_halt(self, ep):
		return self.lib.libusb_clear_halt(self.handle, ep)

	def reset(self):
		return self.lib.libusb_reset_device(self.handle)

	def control(self, rtype, request, value, index, length=0, out=None, timeout_ms=500):
		if length:
			buf = ctypes.create_string_buffer(bytes(out) if out else b"", length)
		else:
			buf = ctypes.create_string_buffer(1)
		rc = self.lib.libusb_control_transfer(self.handle, rtype, request, value, index,
						      ctypes.cast(buf, ctypes.POINTER(ctypes.c_uint8)),
						      length, timeout_ms)
		return rc, buf.raw[:length] if rc >= 0 and length else None

	def bulk_out(self, ep, data, timeout_ms=500):
		moved = ctypes.c_int(0)
		rc = self.lib.libusb_bulk_transfer(self.handle, ep, data, len(data), ctypes.byref(moved), timeout_ms)
		return rc, moved.value

	def bulk_in(self, ep, length, timeout_ms=300):
		buf = ctypes.create_string_buffer(length)
		moved = ctypes.c_int(0)
		rc = self.lib.libusb_bulk_transfer(self.handle, ep | 0x80, buf, length, ctypes.byref(moved), timeout_ms)
		return rc, moved.value, buf.raw[:moved.value]


def note_pattern(length):
	"""4,3,3,3,3,3,3,3 MIDI bytes per transfer, 0xFD idle, 0xE0 control byte last."""
	buf = bytearray([0xFD] * length)
	for i, b in enumerate((0x90, 0x24, 0x64)[:max(0, length - 1)]):
		buf[i] = b
	buf[length - 1] = 0xE0
	return bytes(buf)


def module_loaded():
	return "snd_usb_ozzy" in subprocess.run(["lsmod"], capture_output=True, text=True).stdout


def setup(usb, alt_iface1):
	rc = usb.config()
	print("   set_configuration(1): %s" % name(rc))
	for intf in (0, 1):
		print("   claim interface %d: %s" % (intf, name(usb.claim(intf))))
	print("   SET_INTERFACE 0 alt 1: %s" % name(usb.alt(0, 1)))
	print("   SET_INTERFACE 1 alt %d: %s" % (1 if alt_iface1 else 0, name(usb.alt(1, 1 if alt_iface1 else 0))))


def read_status(usb):
	rc, data = usb.control(REQTYPE_IN, REQ_STATUS, 0, 0, 1)
	if rc == 1:
		return data[0]
	print("   'I' read failed: %s" % name(rc))
	return None


def set_rate(usb, ep, rate=48000):
	rc, _ = usb.control(REQTYPE_CLASS_EP_OUT, REQ_SET_CUR, 0x0100, ep,
			    out=bytes([rate & 0xFF, (rate >> 8) & 0xFF, (rate >> 16) & 0xFF]), length=3)
	print("   SET_CUR %d Hz on 0x%02x: %s" % (rate, ep, name(rc)))


def write_status(usb, value):
	rc, _ = usb.control(REQTYPE_OUT, REQ_STATUS, value, 0)
	print("   'I' write 0x%02x: %s" % (value, name(rc)))


def stage(usb, label, sizes, notes, alt_iface1=True, clear_halt=False, handshake="none"):
	print("\n== %s" % label)
	setup(usb, alt_iface1)
	status = read_status(usb)
	print("   'I' reads 0x%02x" % status if status is not None else "   'I' unreadable")

	if handshake == "ozzy":
		set_rate(usb, EP_PCM_IN)
		set_rate(usb, EP_PCM_OUT)
		if status is not None:
			write_status(usb, status | 0x20)
			time.sleep(0.04)
			print("   'I' reads 0x%02x after the confirm" % read_status(usb))
	elif handshake == "mainline":
		write_status(usb, 0x11)
		write_status(usb, 0x10)
		set_rate(usb, 0x81)
		print("   'I' reads 0x%02x after the pulse" % read_status(usb))
	elif handshake != "none":
		raise SystemExit("unknown handshake %r" % handshake)

	if clear_halt:
		for ep in (EP_MIDI_OUT, EP_MIDI_IN):
			print("   CLEAR_HALT 0x%02x: %s" % (ep, name(usb.clear_halt(ep))))

	for size in sizes:
		for i in range(notes):
			rc, moved = usb.bulk_out(EP_MIDI_OUT, note_pattern(size))
			print("   OUT 0x04 %3d bytes -> %s, moved %d" % (size, name(rc), moved))
			if rc == 0 and moved == size:
				break
			time.sleep(0.05)
		rc, moved, got = usb.bulk_in(EP_MIDI_IN, size)
		print("   IN  0x83 %3d bytes -> %s, got %d%s"
		      % (size, name(rc), moved, (" " + got.hex(" ")) if moved else ""))

	for intf in (1, 0):
		usb.release(intf)


def listen(usb, secs, handshake=True):
	"""Read 0x83 for @secs while somebody plays into the DIN IN."""
	print("\n== listening on 0x83 for %ds - play notes into the US-600 MIDI IN" % secs)
	setup(usb, True)
	status = read_status(usb)
	if handshake:
		set_rate(usb, EP_PCM_IN)
		set_rate(usb, EP_PCM_OUT)
		if status is not None:
			write_status(usb, status | 0x20)
			time.sleep(0.04)
	total = 0
	end = time.time() + secs
	while time.time() < end:
		rc, moved, got = usb.bulk_in(EP_MIDI_IN, 9, 500)
		if moved:
			total += moved
			print("   IN %d bytes: %s" % (moved, got.hex(" ")))
		elif rc not in (-7,):
			print("   IN failed: %s" % name(rc))
			break
	print("   %d bytes read" % total)
	for intf in (1, 0):
		usb.release(intf)


def main():
	ap = argparse.ArgumentParser(add_help=True)
	ap.add_argument("-k", "--keep-unloaded", action="store_true", help="do not modprobe the driver again")
	ap.add_argument("-n", "--notes", type=int, default=3, help="writes per size (default 3)")
	ap.add_argument("-l", "--listen", type=int, default=0, metavar="SECS",
			help="only listen on 0x83 for SECS seconds (DIN IN, no loopback needed)")
	args = ap.parse_args()

	if os.geteuid() != 0:
		os.execvp("sudo", ["sudo", "--", sys.executable, os.path.abspath(__file__)] + sys.argv[1:])

	loaded = module_loaded()
	if loaded:
		print("== unloading snd_usb_ozzy (the driver owns the interfaces)")
		subprocess.run(["modprobe", "-r", "snd_usb_ozzy"], check=False)
		time.sleep(0.7)

	usb = Usb()
	try:
		usb.open()
		# A port reset first: the device wedges its IN pipes after a while (see the
		# findings), and a SET_CONFIGURATION alone does not always clear that.
		print("\n== resetting the port")
		print("   libusb_reset_device: %s" % name(usb.reset()))
		time.sleep(0.5)
		if args.listen:
			listen(usb, args.listen)
		else:
			stage(usb, "as the driver sets it up, no handshake", (9, 42, 512), args.notes)
			stage(usb, "after CLEAR_HALT on both MIDI endpoints", (9,), args.notes, clear_halt=True)
			stage(usb, "interface 1 left in alt 0", (9,), args.notes, alt_iface1=False)
			stage(usb, "after the driver's 'I' write (status | 0x20) and SET_CUR", (9,), args.notes,
			      handshake="ozzy")
			stage(usb, "after mainline us122l's 'I' pulse 0x11, 0x10 and SET_CUR", (9,), args.notes,
			      handshake="mainline")
	finally:
		usb.close()

	if loaded and not args.keep_unloaded:
		print("\n== reloading snd_usb_ozzy")
		subprocess.run(["modprobe", "snd-usb-ozzy"], check=False)


if __name__ == "__main__":
	main()
