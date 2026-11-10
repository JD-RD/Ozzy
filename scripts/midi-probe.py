#!/usr/bin/env python3
"""Ask the US-600's MIDI endpoints directly, without the driver (usbfs / libusb).

The module owns the device, so this unloads it first and reloads it at the end
(unless -k). It then does what Ozzy does - configuration 1, alternate setting 1
on interfaces 0 and 1 - and tries the MIDI endpoints in several ways:

  * bulk OUT 0x04, 9 / 42 / 512 bytes: does any size leave the host?
  * bulk IN  0x83, 9 / 42 / 512 bytes, after the OUT writes: does the DIN
    loopback come back?
  * the same after CLEAR_HALT on both endpoints
  * the same with only interface 0 in alt 1 (interface 1 left in alt 0)

Every call prints libusb's return code and the bytes moved, so a STALL (-9),
a timeout (-7, the device NAKed) and a protocol error (-99 or 0 with no data)
can be told apart.

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

NAMES = {
	0: "ok", -1: "IO", -2: "INVALID_PARAM", -3: "ACCESS", -4: "NO_DEVICE",
	-5: "NOT_FOUND", -6: "BUSY", -7: "TIMEOUT (device NAKed)", -8: "OVERFLOW",
	-9: "PIPE (STALL)", -10: "INTERRUPTED", -11: "NO_MEM", -12: "NOT_SUPPORTED",
	-99: "OTHER (see usbfs: EPROTO shows up here)",
}


def name(rc):
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
		self.handle = None

	def open(self):
		self.lib.libusb_open_device_with_vid_pid.argtypes = [ctypes.c_void_p, ctypes.c_uint16, ctypes.c_uint16]
		self.lib.libusb_open_device_with_vid_pid.restype = ctypes.c_void_p
		self.handle = self.lib.libusb_open_device_with_vid_pid(self.ctx, VID, PID)
		if not self.handle:
			raise SystemExit("cannot open %04x:%04x (permissions? /dev/bus/usb needs root)" % (VID, PID))
		self.lib.libusb_set_auto_detach_kernel_driver.argtypes = [ctypes.c_void_p, ctypes.c_int]
		self.lib.libusb_set_auto_detach_kernel_driver(self.handle, 1)
		self.lib.libusb_set_configuration.argtypes = [ctypes.c_void_p, ctypes.c_int]
		self.lib.libusb_claim_interface.argtypes = [ctypes.c_void_p, ctypes.c_int]
		self.lib.libusb_release_interface.argtypes = [ctypes.c_void_p, ctypes.c_int]
		self.lib.libusb_set_interface_alt_setting.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int]
		self.lib.libusb_clear_halt.argtypes = [ctypes.c_void_p, ctypes.c_ubyte]
		self.lib.libusb_bulk_transfer.argtypes = [
			ctypes.c_void_p, ctypes.c_ubyte, ctypes.c_char_p,
			ctypes.c_int, ctypes.POINTER(ctypes.c_int), ctypes.c_uint]
		self.lib.libusb_bulk_transfer.restype = ctypes.c_int

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

	def bulk_out(self, ep, data, timeout_ms=200):
		moved = ctypes.c_int(0)
		rc = self.lib.libusb_bulk_transfer(self.handle, ep, data, len(data), ctypes.byref(moved), timeout_ms)
		return rc, moved.value

	def bulk_in(self, ep, length, timeout_ms=200):
		buf = ctypes.create_string_buffer(length)
		moved = ctypes.c_int(0)
		rc = self.lib.libusb_bulk_transfer(self.handle, ep | 0x80, buf, length, ctypes.byref(moved), timeout_ms)
		return rc, moved.value, buf.raw[:moved.value]


def note_pattern(length):
	"""4,3,3,3,3,3,3,3 MIDI bytes per transfer, 0xFD idle, 0xE0 control byte last."""
	msg = [0x90, 0x24, 0x64]
	buf = bytearray([0xFD] * length)
	for i, b in enumerate(msg[:max(0, length - 1)]):
		buf[i] = b
	buf[length - 1] = 0xE0
	return bytes(buf)


def module_loaded():
	return subprocess.run(["lsmod"], capture_output=True, text=True).stdout.find("snd_usb_ozzy") >= 0


def run(usb, label, sizes, alt_iface1, clear_halt_first, notes):
	print("\n== %s" % label)
	rc = usb.config()
	print("   set_configuration(1): %s" % name(rc))
	for intf in (0, 1):
		rc = usb.claim(intf)
		print("   claim interface %d: %s" % (intf, name(rc)))
	rc = usb.alt(0, 1)
	print("   SET_INTERFACE 0 alt 1: %s" % name(rc))
	rc = usb.alt(1, 1 if alt_iface1 else 0)
	print("   SET_INTERFACE 1 alt %d: %s" % (1 if alt_iface1 else 0, name(rc)))
	if clear_halt_first:
		for ep in (EP_MIDI_OUT, EP_MIDI_IN):
			print("   CLEAR_HALT 0x%02x: %s" % (ep, name(usb.clear_halt(ep))))

	for size in sizes:
		for i in range(notes):
			data = note_pattern(size)
			rc, moved = usb.bulk_out(EP_MIDI_OUT, data, 500)
			print("   OUT 0x04 %3d bytes -> %s, moved %d" % (size, name(rc), moved))
			if rc == 0 and moved == size:
				break
			time.sleep(0.05)
		rc, moved, got = usb.bulk_in(EP_MIDI_IN, size, 300)
		print("   IN  0x83 %3d bytes -> %s, got %d%s"
		      % (size, name(rc), moved, (" " + got.hex(" ")) if moved else ""))

	for intf in (1, 0):
		usb.release(intf)


def main():
	ap = argparse.ArgumentParser(add_help=True)
	ap.add_argument("-k", "--keep-unloaded", action="store_true", help="do not modprobe the driver again")
	ap.add_argument("-n", "--notes", type=int, default=3, help="writes per size (default 3)")
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
		run(usb, "as the driver sets it up (both interfaces alt 1)",
		    (9, 42, 512), alt_iface1=True, clear_halt_first=False, notes=args.notes)
		run(usb, "after CLEAR_HALT on both MIDI endpoints",
		    (9,), alt_iface1=True, clear_halt_first=True, notes=args.notes)
		run(usb, "interface 1 left in alt 0",
		    (9,), alt_iface1=False, clear_halt_first=False, notes=args.notes)
	finally:
		usb.close()

	if loaded and not args.keep_unloaded:
		print("\n== reloading snd_usb_ozzy")
		subprocess.run(["modprobe", "snd-usb-ozzy"], check=False)


if __name__ == "__main__":
	main()
