#!/usr/bin/env python3
"""Polling touchscreen driver for FT5x06 controllers that have no IRQ line.

The DFRobot DFR0678 (and the original Raspberry Pi 7" display) wire the
FT5406 touch controller to the DSI connector's I2C bus but leave its
interrupt pin unconnected. Mainline's edt-ft5x06 driver requires an IRQ, so
this daemon polls the controller through /dev/i2c-N and republishes the
contacts as a multitouch (protocol B) input device through /dev/uinput.

Only the Python standard library is used.
"""

import argparse
import ctypes
import fcntl
import glob
import os
import signal
import struct
import sys
import time

# <linux/i2c-dev.h>, <linux/i2c.h>
I2C_SLAVE = 0x0703
I2C_SMBUS = 0x0720
I2C_SMBUS_READ = 1
I2C_SMBUS_I2C_BLOCK_DATA = 8
I2C_SMBUS_BLOCK_MAX = 32

# <linux/input-event-codes.h>
EV_SYN, EV_KEY, EV_ABS = 0x00, 0x01, 0x03
SYN_REPORT = 0
BTN_TOUCH = 0x14A
ABS_X, ABS_Y = 0x00, 0x01
ABS_MT_SLOT = 0x2F
ABS_MT_POSITION_X, ABS_MT_POSITION_Y = 0x35, 0x36
ABS_MT_TRACKING_ID = 0x39
INPUT_PROP_DIRECT = 0x01
BUS_I2C = 0x18
ABS_CNT = 0x40


def _iow(nr, size=4):
    return (1 << 30) | (size << 16) | (ord("U") << 8) | nr


# <linux/uinput.h>
UI_DEV_CREATE = (ord("U") << 8) | 1
UI_DEV_DESTROY = (ord("U") << 8) | 2
UI_SET_EVBIT = _iow(100)
UI_SET_KEYBIT = _iow(101)
UI_SET_ABSBIT = _iow(103)
UI_SET_PROPBIT = _iow(110)

INPUT_EVENT = struct.Struct("llHHi")
UINPUT_USER_DEV = struct.Struct("=80s4HI%di" % (4 * ABS_CNT))

# FT5x06 register map (work mode)
REG_TD_STATUS = 0x02
REG_FIRST_POINT = 0x03
POINT_LEN = 6
EVENT_UP, EVENT_RESERVED = 1, 3

# A polled controller with no IRQ line occasionally NACKs a read while it is busy
# scanning. That is not a power loss, so a failed read is retried a few times before
# the controller is treated as gone (which drops every contact and re-arms the stale filter).
READ_RETRIES = 3
READ_RETRY_DELAY = 0.003


class _SmbusData(ctypes.Union):
    _fields_ = [("byte", ctypes.c_uint8), ("word", ctypes.c_uint16),
                ("block", ctypes.c_uint8 * (I2C_SMBUS_BLOCK_MAX + 2))]


class _SmbusIoctl(ctypes.Structure):
    _fields_ = [("read_write", ctypes.c_uint8), ("command", ctypes.c_uint8),
                ("size", ctypes.c_uint32), ("data", ctypes.POINTER(_SmbusData))]


class I2CDevice:
    """One I2C slave on /dev/i2c-N, read with SMBus I2C-block transfers."""

    def __init__(self, bus, addr):
        self.path = "/dev/i2c-%d" % bus
        self.fd = os.open(self.path, os.O_RDWR)
        fcntl.ioctl(self.fd, I2C_SLAVE, addr)

    def read(self, reg, length):
        out = bytearray()
        while length > 0:
            chunk = min(length, I2C_SMBUS_BLOCK_MAX)
            data = _SmbusData()
            data.block[0] = chunk
            req = _SmbusIoctl(I2C_SMBUS_READ, reg, I2C_SMBUS_I2C_BLOCK_DATA,
                              ctypes.pointer(data))
            fcntl.ioctl(self.fd, I2C_SMBUS, req)
            out += bytes(data.block[1:1 + data.block[0]])
            reg += chunk
            length -= chunk
        return bytes(out)

    def close(self):
        os.close(self.fd)


class FT5x06:
    """Reads contact frames: lists of (event, touch_id, x, y)."""

    def __init__(self, dev, max_points):
        self.dev = dev
        self.max_points = max_points
        self.rearm()

    def rearm(self):
        # After power-up the point registers can hold stale data; ignore
        # frames until TD_STATUS changes for the first time (or reads 0),
        # as the Raspberry Pi kernel's polling mode does.
        self.init_td_status = -1

    def read_frame(self):
        """Returns a list of contacts, or None if the frame must be ignored."""
        td_status = self.dev.read(REG_TD_STATUS, 1)[0]
        num = td_status & 0x0F
        if num > self.max_points:
            return None

        if self.init_td_status is not None:
            if self.init_td_status < 0:
                self.init_td_status = td_status
            if num and td_status == self.init_td_status:
                return None
            self.init_td_status = None

        if num == 0:
            return []
        raw = self.dev.read(REG_FIRST_POINT, POINT_LEN * num)
        return [parse_point(raw[i:i + POINT_LEN]) for i in range(0, len(raw), POINT_LEN)]


def parse_point(p):
    event = p[0] >> 6
    x = ((p[0] & 0x0F) << 8) | p[1]
    touch_id = p[2] >> 4
    y = ((p[2] & 0x0F) << 8) | p[3]
    return event, touch_id, x, y


class Transform:
    def __init__(self, width, height, swap_xy=False, invert_x=False, invert_y=False):
        self.width, self.height = width, height
        self.swap_xy, self.invert_x, self.invert_y = swap_xy, invert_x, invert_y

    @property
    def out_size(self):
        return (self.height, self.width) if self.swap_xy else (self.width, self.height)

    def __call__(self, x, y):
        x = min(max(x, 0), self.width - 1)
        y = min(max(y, 0), self.height - 1)
        if self.invert_x:
            x = self.width - 1 - x
        if self.invert_y:
            y = self.height - 1 - y
        return (y, x) if self.swap_xy else (x, y)


class ContactTracker:
    """Turns contact frames into multitouch protocol B events.

    A contact missing from a frame is released even without an explicit
    lift-up event, because polling can miss the lift-up entirely.
    """

    def __init__(self, transform, max_points):
        self.transform = transform
        self.max_points = max_points
        self.slots = {}          # touch_id -> (tracking_id, x, y)
        self.next_tracking_id = 0
        self.touching = False
        self.pointer = None

    def update(self, contacts):
        current = {}
        for event, touch_id, x, y in contacts:
            if event in (EVENT_UP, EVENT_RESERVED) or touch_id >= self.max_points:
                continue
            current[touch_id] = self.transform(x, y)

        events = []
        for touch_id in sorted(set(self.slots) - set(current)):
            events += [(EV_ABS, ABS_MT_SLOT, touch_id), (EV_ABS, ABS_MT_TRACKING_ID, -1)]
            del self.slots[touch_id]

        for touch_id in sorted(current):
            x, y = current[touch_id]
            prev = self.slots.get(touch_id)
            if prev is None:
                tracking_id = self.next_tracking_id
                self.next_tracking_id = (self.next_tracking_id + 1) & 0xFFFF
                events += [(EV_ABS, ABS_MT_SLOT, touch_id),
                           (EV_ABS, ABS_MT_TRACKING_ID, tracking_id),
                           (EV_ABS, ABS_MT_POSITION_X, x),
                           (EV_ABS, ABS_MT_POSITION_Y, y)]
            else:
                tracking_id = prev[0]
                if (x, y) != prev[1:]:
                    events += [(EV_ABS, ABS_MT_SLOT, touch_id)]
                    if x != prev[1]:
                        events.append((EV_ABS, ABS_MT_POSITION_X, x))
                    if y != prev[2]:
                        events.append((EV_ABS, ABS_MT_POSITION_Y, y))
            self.slots[touch_id] = (tracking_id, x, y)

        # Single-touch emulation follows the oldest contact, like the kernel's
        # input_mt_report_pointer_emulation().
        touching = bool(self.slots)
        if touching != self.touching:
            events.append((EV_KEY, BTN_TOUCH, int(touching)))
            self.touching = touching
        if touching:
            oldest = min(self.slots.values(), key=lambda s: (s[0] - self.next_tracking_id) & 0xFFFF)
            pointer = oldest[1:]
            if pointer != self.pointer:
                if self.pointer is None or pointer[0] != self.pointer[0]:
                    events.append((EV_ABS, ABS_X, pointer[0]))
                if self.pointer is None or pointer[1] != self.pointer[1]:
                    events.append((EV_ABS, ABS_Y, pointer[1]))
                self.pointer = pointer
        else:
            self.pointer = None

        if events:
            events.append((EV_SYN, SYN_REPORT, 0))
        return events


class UInputTouchscreen:
    def __init__(self, name, width, height, max_points):
        self.fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
        for ev in (EV_SYN, EV_KEY, EV_ABS):
            fcntl.ioctl(self.fd, UI_SET_EVBIT, ev)
        fcntl.ioctl(self.fd, UI_SET_KEYBIT, BTN_TOUCH)
        fcntl.ioctl(self.fd, UI_SET_PROPBIT, INPUT_PROP_DIRECT)

        absmax = [0] * ABS_CNT
        ranges = {ABS_X: width - 1, ABS_Y: height - 1,
                  ABS_MT_POSITION_X: width - 1, ABS_MT_POSITION_Y: height - 1,
                  ABS_MT_SLOT: max_points - 1, ABS_MT_TRACKING_ID: 0xFFFF}
        for code, maximum in ranges.items():
            fcntl.ioctl(self.fd, UI_SET_ABSBIT, code)
            absmax[code] = maximum

        zeros = [0] * ABS_CNT
        os.write(self.fd, UINPUT_USER_DEV.pack(name.encode()[:79], BUS_I2C, 0, 0, 1, 0,
                                               *(absmax + zeros + zeros + zeros)))
        fcntl.ioctl(self.fd, UI_DEV_CREATE)

    def emit(self, events):
        if events:
            os.write(self.fd, b"".join(INPUT_EVENT.pack(0, 0, t, c, v) for t, c, v in events))

    def close(self):
        fcntl.ioctl(self.fd, UI_DEV_DESTROY)
        os.close(self.fd)


def find_bus(adapter):
    for path in glob.glob("/sys/bus/i2c/devices/i2c-*"):
        if adapter in os.path.realpath(path):
            return int(path.rsplit("-", 1)[1])
    raise SystemExit("no I2C adapter matching %r (use --bus N)" % adapter)


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def read_frame_with_retry(chip):
    for attempt in range(READ_RETRIES):
        try:
            return chip.read_frame()
        except OSError:
            if attempt == READ_RETRIES - 1:
                raise
            time.sleep(READ_RETRY_DELAY)


def run(args):
    bus = args.bus if args.bus is not None else find_bus(args.adapter)
    dev = I2CDevice(bus, args.address)
    chip = FT5x06(dev, args.max_points)
    transform = Transform(args.width, args.height, args.swap_xy, args.invert_x, args.invert_y)
    tracker = ContactTracker(transform, args.max_points)
    out_w, out_h = transform.out_size
    uinput = UInputTouchscreen(args.name, out_w, out_h, args.max_points)
    log("polling FT5x06 at %s addr 0x%02x every %d ms, reporting %dx%d"
        % (dev.path, args.address, args.interval, out_w, out_h))

    stop = []
    signal.signal(signal.SIGTERM, lambda *_: stop.append(1))
    signal.signal(signal.SIGINT, lambda *_: stop.append(1))

    online = None
    period = args.interval / 1000.0
    next_poll = time.monotonic()
    try:
        while not stop:
            try:
                frame = read_frame_with_retry(chip)
                if online is not True:
                    log("touch controller is responding")
                    online = True
            except OSError as e:
                # The controller loses power whenever the panel driver turns
                # the display off (boot, modeset, screen blanking).
                if online is not False:
                    log("touch controller not responding (%s); retrying" % e.strerror)
                    online = False
                uinput.emit(tracker.update([]))
                chip.rearm()
                time.sleep(0.5)
                next_poll = time.monotonic()
                continue

            if frame is not None:
                uinput.emit(tracker.update(frame))

            next_poll += period
            delay = next_poll - time.monotonic()
            if delay > 0:
                time.sleep(delay)
            else:
                next_poll = time.monotonic()
    finally:
        uinput.emit(tracker.update([]))
        uinput.close()
        dev.close()


def build_parser():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--adapter", default="ff110000.i2c",
                   help="sysfs name of the I2C controller (default: ROCK 4 DSI connector, i2c1)")
    p.add_argument("--bus", type=int, help="use /dev/i2c-N directly instead of --adapter")
    p.add_argument("--address", type=lambda s: int(s, 0), default=0x38)
    p.add_argument("--width", type=int, default=800, help="touch X range before transforms")
    p.add_argument("--height", type=int, default=480, help="touch Y range before transforms")
    p.add_argument("--swap-xy", action="store_true")
    p.add_argument("--invert-x", action="store_true", help="mirror the X axis")
    p.add_argument("--invert-y", action="store_true", help="mirror the Y axis")
    rot = p.add_mutually_exclusive_group()
    rot.add_argument("--rotate-180", action="store_true",
                     help="shortcut for --invert-x --invert-y (touch lands in the opposite quadrant)")
    rot.add_argument("--rotate-90", action="store_true",
                     help="rotate touch 90 degrees clockwise (shortcut for --swap-xy --invert-y); "
                          "fixes drag left=cursor down, drag up=cursor left")
    rot.add_argument("--rotate-270", action="store_true",
                     help="rotate touch 90 degrees counter-clockwise (shortcut for --swap-xy --invert-x); "
                          "fixes drag left=cursor up, drag up=cursor right")
    p.add_argument("--max-points", type=int, default=10, choices=range(1, 11), metavar="1-10")
    p.add_argument("--interval", type=int, default=17, help="poll period in ms (default 17, ~60 Hz)")
    p.add_argument("--name", default="FT5406 touchscreen (polled)")
    return p


def parse_args(argv=None):
    args = build_parser().parse_args(argv)
    if args.rotate_180:
        args.invert_x = args.invert_y = True
    elif args.rotate_90:
        args.swap_xy, args.invert_x, args.invert_y = True, False, True
    elif args.rotate_270:
        args.swap_xy, args.invert_x, args.invert_y = True, True, False
    return args


def main(argv=None):
    run(parse_args(argv))


if __name__ == "__main__":
    main()
