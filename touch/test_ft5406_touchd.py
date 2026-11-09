"""Tests for ft5406_touchd. Run: python3 -m unittest discover -s touch -v"""

import ctypes
import os
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock

import ft5406_touchd as t

ABI_PROBE = r"""
#include <stdio.h>
#include <stddef.h>
#include <linux/i2c.h>
#include <linux/i2c-dev.h>
#include <linux/input.h>
#include <linux/uinput.h>
#define P(x) printf(#x " %ld\n", (long)(x))
int main(void) {
    P(I2C_SLAVE); P(I2C_SMBUS); P(I2C_SMBUS_READ); P(I2C_SMBUS_I2C_BLOCK_DATA);
    P(I2C_SMBUS_BLOCK_MAX);
    P(sizeof(struct i2c_smbus_ioctl_data)); P(offsetof(struct i2c_smbus_ioctl_data, data));
    P(sizeof(union i2c_smbus_data));
    P(UI_DEV_CREATE); P(UI_DEV_DESTROY); P(UI_SET_EVBIT); P(UI_SET_KEYBIT);
    P(UI_SET_ABSBIT); P(UI_SET_PROPBIT);
    P(sizeof(struct input_event)); P(sizeof(struct uinput_user_dev));
    P(EV_SYN); P(EV_KEY); P(EV_ABS); P(SYN_REPORT); P(BTN_TOUCH); P(ABS_X); P(ABS_Y);
    P(ABS_MT_SLOT); P(ABS_MT_POSITION_X); P(ABS_MT_POSITION_Y); P(ABS_MT_TRACKING_ID);
    P(INPUT_PROP_DIRECT); P(BUS_I2C); P(ABS_CNT);
    return 0;
}
"""


@unittest.skipUnless(shutil.which("cc") and os.path.exists("/usr/include/linux/uinput.h"),
                     "needs a C compiler and Linux UAPI headers")
class KernelAbiTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with tempfile.TemporaryDirectory() as d:
            src, exe = os.path.join(d, "abi.c"), os.path.join(d, "abi")
            with open(src, "w") as f:
                f.write(ABI_PROBE)
            subprocess.run(["cc", "-o", exe, src], check=True)
            out = subprocess.run([exe], check=True, capture_output=True, text=True).stdout
        cls.c = {k: int(v) for k, v in (line.rsplit(" ", 1) for line in out.splitlines())}

    def test_constants_match_headers(self):
        for name in ("I2C_SLAVE", "I2C_SMBUS", "I2C_SMBUS_READ", "I2C_SMBUS_I2C_BLOCK_DATA",
                     "I2C_SMBUS_BLOCK_MAX", "UI_DEV_CREATE", "UI_DEV_DESTROY", "UI_SET_EVBIT",
                     "UI_SET_KEYBIT", "UI_SET_ABSBIT", "UI_SET_PROPBIT", "EV_SYN", "EV_KEY",
                     "EV_ABS", "SYN_REPORT", "BTN_TOUCH", "ABS_X", "ABS_Y", "ABS_MT_SLOT",
                     "ABS_MT_POSITION_X", "ABS_MT_POSITION_Y", "ABS_MT_TRACKING_ID",
                     "INPUT_PROP_DIRECT", "BUS_I2C", "ABS_CNT"):
            self.assertEqual(getattr(t, name), self.c[name], name)

    def test_struct_layouts_match_headers(self):
        self.assertEqual(ctypes.sizeof(t._SmbusIoctl), self.c["sizeof(struct i2c_smbus_ioctl_data)"])
        self.assertEqual(t._SmbusIoctl.data.offset, self.c["offsetof(struct i2c_smbus_ioctl_data, data)"])
        self.assertEqual(ctypes.sizeof(t._SmbusData), self.c["sizeof(union i2c_smbus_data)"])
        self.assertEqual(t.INPUT_EVENT.size, self.c["sizeof(struct input_event)"])
        self.assertEqual(t.UINPUT_USER_DEV.size, self.c["sizeof(struct uinput_user_dev)"])


def point(event, touch_id, x, y):
    return bytes([(event << 6) | (x >> 8), x & 0xFF, (touch_id << 4) | (y >> 8), y & 0xFF, 0, 0])


class FakeChip:
    """Register file of an FT5x06; `frames` is a list of (td_status, point bytes)."""

    def __init__(self, frames):
        self.frames = list(frames)
        self.regs = bytearray(0x40)
        self.reads = []

    def read(self, reg, length):
        self.reads.append((reg, length))
        if reg == t.REG_TD_STATUS:
            td_status, points = self.frames.pop(0)
            self.regs[2] = td_status
            self.regs[3:3 + len(points)] = points
        return bytes(self.regs[reg:reg + length])


class ParsePointTest(unittest.TestCase):
    def test_decodes_12_bit_coordinates_event_and_id(self):
        self.assertEqual(t.parse_point(point(2, 7, 0x31F, 0x1DF)), (2, 7, 0x31F, 0x1DF))


class FT5x06Test(unittest.TestCase):
    def test_ignores_stale_frames_until_td_status_changes(self):
        stale = point(2, 0, 100, 100)
        chip = FakeChip([(1, stale), (1, stale), (0, b""), (1, point(0, 0, 10, 20))])
        ft = t.FT5x06(chip, 10)
        self.assertIsNone(ft.read_frame())
        self.assertIsNone(ft.read_frame())
        self.assertEqual(ft.read_frame(), [])
        self.assertEqual(ft.read_frame(), [(0, 0, 10, 20)])

    def test_reads_only_reported_points(self):
        chip = FakeChip([(0, b""), (2, point(0, 0, 1, 2) + point(0, 1, 3, 4))])
        ft = t.FT5x06(chip, 10)
        ft.read_frame()
        self.assertEqual(ft.read_frame(), [(0, 0, 1, 2), (0, 1, 3, 4)])
        self.assertEqual(chip.reads[-1], (t.REG_FIRST_POINT, 12))

    def test_rejects_impossible_point_count(self):
        ft = t.FT5x06(FakeChip([(0, b""), (0x0F, b"")]), 10)
        ft.read_frame()
        self.assertIsNone(ft.read_frame())

    def test_rearm_restores_stale_filter(self):
        chip = FakeChip([(0, b""), (1, point(2, 0, 5, 5)), (1, point(2, 0, 5, 5))])
        ft = t.FT5x06(chip, 10)
        ft.read_frame()
        self.assertEqual(len(ft.read_frame()), 1)
        ft.rearm()
        self.assertIsNone(ft.read_frame())


class TransformTest(unittest.TestCase):
    def test_identity_clamps(self):
        self.assertEqual(t.Transform(800, 480)(900, -1), (799, 0))

    def test_invert_and_swap(self):
        tr = t.Transform(800, 480, swap_xy=True, invert_x=True)
        self.assertEqual(tr(0, 10), (10, 799))
        self.assertEqual(tr.out_size, (480, 800))


class CommandLineTest(unittest.TestCase):
    def test_no_inversion_by_default(self):
        args = t.parse_args([])
        self.assertFalse(args.invert_x)
        self.assertFalse(args.invert_y)

    def test_rotate_180_inverts_both_axes(self):
        args = t.parse_args(["--rotate-180"])
        self.assertTrue(args.invert_x and args.invert_y)
        # a touch in the top-left corner must land in the bottom-right corner
        tr = t.Transform(args.width, args.height, args.swap_xy, args.invert_x, args.invert_y)
        self.assertEqual(tr(0, 0), (799, 479))

    def test_rotate_90_is_clockwise(self):
        args = t.parse_args(["--rotate-90"])
        tr = t.Transform(args.width, args.height, args.swap_xy, args.invert_x, args.invert_y)
        self.assertEqual(tr.out_size, (480, 800))
        # top-left -> top-right, top-right -> bottom-right of the rotated (480x800) space
        self.assertEqual(tr(0, 0), (479, 0))
        self.assertEqual(tr(799, 0), (479, 799))
        # raw +x becomes output +y, raw +y becomes output -x (90 degrees clockwise)
        self.assertEqual(tr(101, 50)[1] - tr(100, 50)[1], 1)
        self.assertEqual(tr(100, 51)[0] - tr(100, 50)[0], -1)

    def test_rotate_270_is_counter_clockwise(self):
        args = t.parse_args(["--rotate-270"])
        tr = t.Transform(args.width, args.height, args.swap_xy, args.invert_x, args.invert_y)
        self.assertEqual(tr.out_size, (480, 800))
        self.assertEqual(tr(0, 0), (0, 799))
        self.assertEqual(tr(101, 50)[1] - tr(100, 50)[1], -1)
        self.assertEqual(tr(100, 51)[0] - tr(100, 50)[0], 1)

    def test_rotations_are_mutually_exclusive(self):
        with self.assertRaises(SystemExit), mock.patch("sys.stderr"):
            t.parse_args(["--rotate-90", "--rotate-180"])

    def test_single_axis_flags(self):
        args = t.parse_args(["--invert-x"])
        self.assertTrue(args.invert_x)
        self.assertFalse(args.invert_y)


A = t.EV_ABS
SYN = (t.EV_SYN, t.SYN_REPORT, 0)


class ContactTrackerTest(unittest.TestCase):
    def setUp(self):
        self.tr = t.ContactTracker(t.Transform(800, 480), 10)

    def test_press_move_release(self):
        self.assertEqual(self.tr.update([(0, 0, 100, 200)]), [
            (A, t.ABS_MT_SLOT, 0), (A, t.ABS_MT_TRACKING_ID, 0),
            (A, t.ABS_MT_POSITION_X, 100), (A, t.ABS_MT_POSITION_Y, 200),
            (t.EV_KEY, t.BTN_TOUCH, 1), (A, t.ABS_X, 100), (A, t.ABS_Y, 200), SYN])
        self.assertEqual(self.tr.update([(2, 0, 100, 200)]), [])
        self.assertEqual(self.tr.update([(2, 0, 110, 200)]), [
            (A, t.ABS_MT_SLOT, 0), (A, t.ABS_MT_POSITION_X, 110), (A, t.ABS_X, 110), SYN])
        self.assertEqual(self.tr.update([(1, 0, 110, 200)]), [
            (A, t.ABS_MT_SLOT, 0), (A, t.ABS_MT_TRACKING_ID, -1), (t.EV_KEY, t.BTN_TOUCH, 0), SYN])

    def test_missed_lift_up_still_releases(self):
        self.tr.update([(0, 3, 1, 1)])
        self.assertEqual(self.tr.update([]), [
            (A, t.ABS_MT_SLOT, 3), (A, t.ABS_MT_TRACKING_ID, -1), (t.EV_KEY, t.BTN_TOUCH, 0), SYN])
        self.assertEqual(self.tr.update([]), [])

    def test_two_fingers_pointer_follows_oldest(self):
        self.tr.update([(0, 0, 10, 10)])
        ev = self.tr.update([(2, 0, 10, 10), (0, 1, 500, 300)])
        self.assertEqual(ev, [(A, t.ABS_MT_SLOT, 1), (A, t.ABS_MT_TRACKING_ID, 1),
                              (A, t.ABS_MT_POSITION_X, 500), (A, t.ABS_MT_POSITION_Y, 300), SYN])
        ev = self.tr.update([(2, 1, 500, 300)])
        self.assertEqual(ev, [(A, t.ABS_MT_SLOT, 0), (A, t.ABS_MT_TRACKING_ID, -1),
                              (A, t.ABS_X, 500), (A, t.ABS_Y, 300), SYN])

    def test_new_contact_gets_new_tracking_id(self):
        self.tr.update([(0, 0, 1, 1)])
        self.tr.update([])
        self.assertIn((A, t.ABS_MT_TRACKING_ID, 1), self.tr.update([(0, 0, 1, 1)]))

    def test_ignores_reserved_events_and_out_of_range_ids(self):
        tr = t.ContactTracker(t.Transform(800, 480), 5)
        self.assertEqual(tr.update([(3, 0, 1, 1), (0, 7, 1, 1)]), [])


class I2CDeviceTest(unittest.TestCase):
    def test_splits_reads_into_smbus_blocks(self):
        regs = bytes(range(0x80))
        calls = []

        def fake_ioctl(fd, req, arg):
            if req == t.I2C_SMBUS:
                n = arg.data.contents.block[0]
                calls.append((arg.command, n))
                for i in range(n):
                    arg.data.contents.block[1 + i] = regs[arg.command + i]

        with mock.patch.object(t.os, "open", return_value=99), \
                mock.patch.object(t.fcntl, "ioctl", side_effect=fake_ioctl):
            dev = t.I2CDevice(1, 0x38)
            self.assertEqual(dev.read(0x03, 60), regs[0x03:0x03 + 60])
        self.assertEqual(calls, [(0x03, 32), (0x23, 28)])


class UInputTest(unittest.TestCase):
    def test_creates_direct_multitouch_device(self):
        ioctls, writes = [], []
        with mock.patch.object(t.os, "open", return_value=5), \
                mock.patch.object(t.os, "write", side_effect=lambda fd, b: writes.append(b)), \
                mock.patch.object(t.fcntl, "ioctl", side_effect=lambda fd, r, a=0: ioctls.append((r, a))):
            dev = t.UInputTouchscreen("ts", 800, 480, 10)
            dev.emit([(t.EV_KEY, t.BTN_TOUCH, 1), SYN])

        self.assertIn((t.UI_SET_PROPBIT, t.INPUT_PROP_DIRECT), ioctls)
        self.assertIn((t.UI_SET_KEYBIT, t.BTN_TOUCH), ioctls)
        self.assertEqual(ioctls[-1][0], t.UI_DEV_CREATE)
        fields = t.UINPUT_USER_DEV.unpack(writes[0])
        absmax = fields[6:6 + t.ABS_CNT]
        self.assertEqual(fields[1], t.BUS_I2C)
        self.assertEqual((absmax[t.ABS_MT_POSITION_X], absmax[t.ABS_MT_POSITION_Y]), (799, 479))
        self.assertEqual(absmax[t.ABS_MT_SLOT], 9)
        self.assertEqual(len(writes[1]), 2 * t.INPUT_EVENT.size)


class RunLoopTest(unittest.TestCase):
    """Drives run() through a controller power cycle with faked hardware."""

    def drive(self, script):
        """Runs run() against a scripted register file and returns the emitted events."""
        class Done(Exception):
            pass

        script = list(script)

        class FakeDev:
            path = "/dev/i2c-fake"

            def __init__(self, bus, addr):
                self.chip = FakeChip([])

            def read(self, reg, length):
                if reg == t.REG_TD_STATUS:
                    if not script:
                        raise Done()
                    step = script.pop(0)
                    if isinstance(step, OSError):
                        raise step
                    self.chip.frames.append(step)
                return self.chip.read(reg, length)

            def close(self):
                pass

        emitted = []

        class FakeUInput:
            def __init__(self, *a):
                pass

            def emit(self, events):
                emitted.extend(events)

            def close(self):
                emitted.append("closed")

        args = mock.Mock(bus=3, address=0x38, width=800, height=480, swap_xy=False,
                         invert_x=False, invert_y=False, max_points=10, interval=1,
                         name="ts")
        with mock.patch.object(t, "I2CDevice", FakeDev), \
                mock.patch.object(t, "UInputTouchscreen", FakeUInput), \
                mock.patch.object(t.time, "sleep"), \
                mock.patch.object(t, "log"):
            with self.assertRaises(Done):
                t.run(args)

        return emitted

    @staticmethod
    def summarize(emitted):
        events = [e for e in emitted if e != "closed"]
        tracking = [v for (_, c, v) in events if c == t.ABS_MT_TRACKING_ID]
        touches = [v for (_, c, v) in events if c == t.BTN_TOUCH]
        return tracking, touches

    def test_releases_on_power_loss_and_recovers(self):
        power_loss = [OSError(121, "Remote I/O error")] * t.READ_RETRIES
        emitted = self.drive([
            (0, b""),                       # first frame: idle, clears the stale filter
            (1, point(0, 0, 100, 100)),     # finger down
            *power_loss,                    # panel turned off, chip unpowered
            (1, point(2, 0, 100, 100)),     # power back: stale frame, ignored
            (1, point(2, 0, 100, 100)),
            (0, b""),                       # idle
            (1, point(0, 0, 300, 200)),     # new touch
        ])
        tracking, touches = self.summarize(emitted)
        self.assertEqual(tracking, [0, -1, 1, -1])
        self.assertEqual(touches, [1, 0, 1, 0])
        self.assertEqual(emitted[-1], "closed")

    def test_transient_read_error_keeps_the_touch(self):
        emitted = self.drive([
            (0, b""),
            (1, point(0, 0, 100, 100)),     # finger down
            OSError(121, "Remote I/O error"),  # one NACK, retried
            (1, point(2, 0, 100, 100)),     # still down: same contact, no release
            (0, b""),                       # lifted
        ])
        tracking, touches = self.summarize(emitted)
        self.assertEqual(tracking, [0, -1])
        self.assertEqual(touches, [1, 0])


if __name__ == "__main__":
    unittest.main()
