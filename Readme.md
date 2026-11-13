# ROCK 4SE DSI touchscreen

This project configures the Raspberry Pi 7-inch / DFRobot DFR0678 800x480 DSI touchscreen for a Radxa ROCK 4SE running Armbian. The display uses the ROCK 4SE's DSI1 interface and a Toshiba TC358762 bridge. The ATTiny MCU handles panel power and backlight; an FT5406 controller provides touch input.

Based on the Radxa OS implementation, which uses the GPL 2.0 License.
Radxa BSP Kernel for Rock 4 SE: https://github.com/radxa/kernel/tree/linux-6.1-stan-rkr5.1

Armbian also uses the GPL 2.0 license, so this repo uses the GPL 2.0 license.

Radxa, Rock Pi, and Rock 4 SE are registered trademarks of Radxa Computer (Shenzhen) Co., Ltd. (or Radxa Limited) 

Armbian is a registered trademark of Armbian d.o.o.

Please note this software is provided with absolutely no warranty, it is recommended you verify the contents of the patches before building your own kernel. Proceed at your own risk.

## What the display needs

The working `v9` configuration depends on these kernel changes:

- `rk3399-dsi1-dsi0-pll`: use DSI0's shared PLL for the DSI1 link.
- `dsi-lane-rate-override`: select the 696 Mbps/lane DSI rate.
- `dfr0678-radxa-timing`: use the panel's 800x480, 26 MHz timing.
- `tc358762-rpi7-radxa-bringup`: initialize the bridge and ATTiny as required by this panel.
- `rockchip-vop-bsp-parity`: add the VOP `data01_swap` setting needed for the DSI image.

These patch files are in [`userpatches/kernel/archive/rockchip64-6.18/`](userpatches/kernel/archive/rockchip64-6.18/), and the kernel configuration is [`userpatches/linux-rockchip64-current.config`](userpatches/linux-rockchip64-current.config); see [Building](#building). The kernel must include `CONFIG_DRM_TOSHIBA_TC358762`, `CONFIG_REGULATOR_RASPBERRYPI_TOUCHSCREEN_ATTINY`, and `CONFIG_DRM_PANEL_SIMPLE`. The bridge readback patch is optional and only adds diagnostics.

The `v9` overlay, [`overlays/rock-4se-rpi7-radxa-vopl-fix.dts`](overlays/rock-4se-rpi7-radxa-vopl-fix.dts), connects DSI1 through the bridge, uses VOPL, and enables `rockchip,dsi-data01-swap`. VOPL is then unavailable to HDMI while this overlay is active.

## BUILDING

Please see https://docs.armbian.com/build-framework/getting-started/ for more information on building armbian images

[`userpatches/`](userpatches/) has the layout the Armbian build framework expects. Copy its contents into the `userpatches/` folder of the Armbian build checkout:

```bash
cp -r userpatches/. ~/build/userpatches/
```

- `linux-rockchip64-current.config`: kernel configuration for `BRANCH=current` (Linux 6.18).
- `kernel/archive/rockchip64-6.18/`: the kernel patches. Armbian applies them together with its own patches for that kernel.
- `config-enable_v9.conf` and `extensions/rock-4se-dsi-v9.sh`: the optional `enable_v9` build described below.
- `overlay/rock-4se-dsi/`: a copy of `install.sh`, the `v9` overlay and the touch service, which the `enable_v9` build installs into the image.

`general-rtc-pcf8563-pass-driver-data-to-irq-handler.patch` is intentionally empty. An empty user patch makes Armbian skip its own patch of the same name; that patch is already part of Linux 6.18.63, and applying it again stops the build. Framework versions that no longer ship the patch just skip the empty file.

`./compile.sh` builds the patched kernel and image without enabling any overlay; install it on the board as described under [Install](#install).

### Enabling the v9 overlay at build time

```bash
./compile.sh enable_v9
```

This builds the same kernel and image, and also runs `install.sh --variant v9` inside the image. A freshly flashed image then boots with the console on the DSI panel, without running `install.sh`:

- `rock-4se-rpi7-radxa-vopl-fix.dtbo` is in `/boot/overlay-user/` and listed in `user_overlays=` in `/boot/armbianEnv.txt`.
- The FT5406 touch service is installed and enabled, with no touch rotation.
- The panel runs in landscape.
- HDMI shows nothing, because `v9` disables VOPB and gives VOPL to the panel.

`enable_v9` only accepts `BOARD=rock-4se` and a kernel branch that has patches in `userpatches/kernel/archive/` (`BRANCH=current`); otherwise the build stops during configuration. If `install.sh` fails inside the image, the build stops too.

Check the result on the board:

```bash
grep user_overlays /boot/armbianEnv.txt
ls /boot/overlay-user/
systemctl is-enabled ft5406-touchd
```

Running `install.sh --variant v9` again on the board is safe; it does not duplicate the `user_overlays` entry. To switch back to HDMI, run `sudo ./install.sh --uninstall` from a copy of this repository on the board and reboot, or remove `rock-4se-rpi7-radxa-vopl-fix` from `user_overlays=` in `/boot/armbianEnv.txt` and reboot.

When `install.sh`, the `v9` overlay or the touch service change, copy them to `userpatches/overlay/rock-4se-dsi/` as well; [`tools/validate.sh`](tools/validate.sh) reports any difference.

## Install

After booting the ROCK 4SE with the required kernel (an `enable_v9` image already has this done):

```bash
sudo ./install.sh --variant v9
sudo reboot
sudo ./diagnose.sh
```

The installer compiles and installs the overlay, updates `/boot/armbianEnv.txt` (keeping a backup), disables conflicting project overlays, and enables the FT5406 touch service. To install only the display overlay, add `--no-touch`. The installer requires root and `dtc`; it offers to install the device-tree compiler if it is missing.

## Touchscreen

The FT5406 interrupt line is not connected, so [`touch/ft5406_touchd.py`](touch/ft5406_touchd.py) polls the controller and publishes multitouch events through `/dev/uinput`. The installer sets up its systemd service. Use the orientation helper to adjust touch mapping:

```bash
sudo ./touch-orientation.sh status
sudo ./touch-orientation.sh normal
sudo ./touch-orientation.sh 90
sudo ./touch-orientation.sh 180
sudo ./touch-orientation.sh 270
```

## Repository guide

- [`install.sh`](install.sh): install or remove the display overlay and touch service; includes experimental variants.
- [`diagnose.sh`](diagnose.sh): report live device-tree, kernel, overlay, and display configuration. Useful for debugging.
- [`touch-orientation.sh`](touch-orientation.sh): change touch rotation and restart its service.
- [`tests/`](tests/): board-side DSI, bridge, and VOP diagnostic tests. Also helpful in debugging
- [`tools/validate.sh`](tools/validate.sh): compile and check the device-tree overlays on a Linux host, and check that `userpatches/overlay/rock-4se-dsi/` is up to date.
- [`userpatches/`](userpatches/): kernel patches, kernel configuration and the `enable_v9` build option, laid out for the Armbian build framework.

## AI Use Disclosure

AI tools assisted with debugging and source-code comparison during the development of this repository. See ['AI_Disclosure.md'](AI_Disclosure.md) 
