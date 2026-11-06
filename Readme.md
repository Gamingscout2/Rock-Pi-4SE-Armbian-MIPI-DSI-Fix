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

These patch files are in [`kernel/patches/`](kernel/patches/). Use [`kernel/linux-rockchip64-current.config`](kernel/linux-rockchip64-current.config) as the kernel configuration reference and follow [`kernel/patch_dir.md`](kernel/patch_dir.md) for where the Armbian build tree expects the files. The kernel must include `CONFIG_DRM_TOSHIBA_TC358762`, `CONFIG_REGULATOR_RASPBERRYPI_TOUCHSCREEN_ATTINY`, and `CONFIG_DRM_PANEL_SIMPLE`. The bridge readback patch is optional and only adds diagnostics.

The `v9` overlay, [`overlays/rock-4se-rpi7-radxa-vopl-fix.dts`](overlays/rock-4se-rpi7-radxa-vopl-fix.dts), connects DSI1 through the bridge, uses VOPL, and enables `rockchip,dsi-data01-swap`. VOPL is then unavailable to HDMI while this overlay is active.

## BUILDING

Please see https://docs.armbian.com/build-framework/getting-started/ for more information on building armbian images

## Install

After booting the ROCK 4SE with the required kernel:

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
- [`tools/validate.sh`](tools/validate.sh): compile and check the device-tree overlays on a Linux host.

## AI Use Disclosure

AI tools assisted with debugging and source-code comparison during the development of this repository. The tools used were Cursor and Claude Sonnet 5.5.
