#!/usr/bin/env bash
# Install the DFR0678 DSI overlay and the polling touch service on an
# Armbian ROCK 4SE / ROCK Pi 4.
#
#   sudo ./install.sh                      install, and disable the old
#                                          "rockchip-raspi-7inch" overlay
#   sudo ./install.sh --variant bridge     force the split-driver overlay
#   sudo ./install.sh --variant test       use the experimental DSI0-PLL overlay
#   sudo ./install.sh --test               alias for --variant test
#   sudo ./install.sh --variant test-lane594  DSI0-PLL + lane rate 594 (experimental)
#   sudo ./install.sh --variant test-radxa    DSI0-PLL + Radxa bridge setup (experimental)
#   sudo ./install.sh --variant test-radxa-vopl  test-radxa with Radxa's VOPL route
#   sudo ./install.sh --variant test-radxa-vopl-simple  VOPL route with Powertip panel descriptor
#   sudo ./install.sh --variant test-radxa-vopl-simple-mcu-sequence  opt-in MCU power-sequence test
#   sudo ./install.sh --variant v7         RPi 7" with Radxa register values + mainline ATTiny driver
#   sudo ./install.sh --variant v8         Radxa-style bring-up, MCU power-cycled in bridge enable (recommended)
#   sudo ./install.sh --variant v8-pre     same, but in bridge pre_enable (DSI host in command mode)
#   sudo ./install.sh --variant v8-vopl    like v8 but with DSI1 on the little VOP (VOPL), like Radxa
#   sudo ./install.sh --variant v8-gpio    mainline ATTiny driver + bridge reset GPIO + Radxa register values
#   sudo ./install.sh --variant v9         v8-vopl + VOP DSI fix (data01_swap, dclk/pin polarity): console and X11 on the DSI panel
#   sudo ./install.sh --variant legacy     force the panel-raspberrypi-touchscreen overlay
#   sudo ./install.sh --also-remove NAME   disable another old user overlay too
#   sudo ./install.sh --no-touch           skip the touchscreen service
#   sudo ./install.sh --uninstall          undo everything this script did
set -euo pipefail

LEGACY=rock-4se-dfr0678-dsi
BRIDGE=rock-4se-dfr0678-dsi-bridge
TEST_BRIDGE=rock-4se-dfr0678-dsi-bridge-dsi0pll-test
TEST_LANE=rock-4se-dfr0678-dsi-bridge-test-lane594
TEST_RADXA=rock-4se-dfr0678-dsi-bridge-test-radxa
TEST_RADXA_VOPL=rock-4se-dfr0678-dsi-bridge-test-radxa-vopl
TEST_RADXA_VOPL_SIMPLE=rock-4se-dfr0678-dsi-bridge-test-radxa-vopl-simple
TEST_RADXA_VOPL_SIMPLE_MCU_SEQUENCE=rock-4se-dfr0678-dsi-bridge-test-radxa-vopl-simple-mcu-sequence-test
RPi7_FIXED=rock-4se-rpi7-touchscreen-radxa
RPi7_MCU=rock-4se-rpi7-radxa-mcu
RPi7_MCU_PRE=rock-4se-rpi7-radxa-mcu-pre
RPi7_MCU_VOPL=rock-4se-rpi7-radxa-mcu-vopl
RPi7_FIX=rock-4se-rpi7-radxa-vopl-fix
RPi7_GPIO=rock-4se-rpi7-attiny-gpio
ALL_OVERLAYS=("$BRIDGE" "$TEST_BRIDGE" "$TEST_LANE" "$TEST_RADXA" "$TEST_RADXA_VOPL" "$TEST_RADXA_VOPL_SIMPLE" "$TEST_RADXA_VOPL_SIMPLE_MCU_SEQUENCE" "$RPi7_FIXED" "$RPi7_MCU" "$RPi7_MCU_PRE" "$RPi7_MCU_VOPL" "$RPi7_FIX" "$RPi7_GPIO" "$LEGACY")
TOUCH=ft5406-touchd
OLD_OVERLAYS=(rockchip-raspi-7inch)
ENV_FILE=${ENV_FILE:-/boot/armbianEnv.txt}
OVERLAY_DIR=${OVERLAY_DIR:-/boot/overlay-user}
MODULES_CONF=${MODULES_CONF:-/etc/modules-load.d/rock-4se-dfr0678-dsi.conf}
BIN_DIR=${BIN_DIR:-/usr/local/sbin}
UNIT_DIR=${UNIT_DIR:-/etc/systemd/system}
DEFAULTS_FILE=${DEFAULTS_FILE:-/etc/default/$TOUCH}
SYSTEMCTL=${SYSTEMCTL:-systemctl}
MODINFO=${MODINFO:-modinfo}
HERE="$(cd "$(dirname "$0")" && pwd)"

BRIDGE_MODULES=(rpi-panel-attiny-regulator tc358762 panel-simple)
BRIDGE_CONFIGS=(CONFIG_REGULATOR_RASPBERRYPI_TOUCHSCREEN_ATTINY CONFIG_DRM_TOSHIBA_TC358762 CONFIG_DRM_PANEL_SIMPLE)
LEGACY_MODULES=(panel-raspberrypi-touchscreen)

[[ $EUID -eq 0 ]] || exec sudo "$0" "$@"

uninstall=0
touch=1
variant=auto
while [[ $# -gt 0 ]]; do
	case "$1" in
		--uninstall) uninstall=1 ;;
		--no-touch) touch=0 ;;
		--test) variant=test ;;
		--variant)
			[[ $# -ge 2 ]] || { echo "--variant needs auto, bridge, test, test-lane594, test-radxa, test-radxa-vopl, test-radxa-vopl-simple, 			test-radxa-vopl-simple-mcu-sequence, v7, v8, v8-pre, v8-vopl, v8-gpio, v9, or legacy"; exit 2; }
			if [[ $2 == --test ]]; then variant=test; else variant=$2; fi
			shift
			;;
		--also-remove) OLD_OVERLAYS+=("${2:?--also-remove needs an overlay name}"); shift ;;
		*) echo "unknown option: $1"; exit 2 ;;
	esac
	shift
done
[[ $variant == @(auto|bridge|test|test-lane594|test-radxa|test-radxa-vopl|test-radxa-vopl-simple|test-radxa-vopl-simple-mcu-sequence|v7|v8|v8-pre|v8-vopl|v8-gpio|v9|legacy) ]] || { echo "--variant must be auto, bridge, test, test-lane594, test-radxa, test-radxa-vopl, test-radxa-vopl-simple, test-radxa-vopl-simple-mcu-sequence, v7, v8, v8-pre, v8-vopl, v8-gpio, v9, or legacy"; exit 2; }

if [[ ! -f $ENV_FILE ]]; then
	cat <<-EOF
	$ENV_FILE not found, so this does not look like Armbian.
	On Radxa's official image, use: sudo rsetup -> Overlays -> Manage overlays ->
	"Enable Raspberry Pi 7-inch Touchscreen", then reboot.
	EOF
	exit 1
fi

current="$(sed -n 's/^user_overlays=//p' "$ENV_FILE" | tail -n1)"

set_user_overlays() {
	local value="$1"
	cp -a "$ENV_FILE" "$ENV_FILE.bak-$(date +%Y%m%d-%H%M%S)"
	if grep -q '^user_overlays=' "$ENV_FILE"; then
		if [[ -n $value ]]; then
			sed -i "s/^user_overlays=.*/user_overlays=$value/" "$ENV_FILE"
		else
			sed -i '/^user_overlays=/d' "$ENV_FILE"
		fi
	elif [[ -n $value ]]; then
		echo "user_overlays=$value" >> "$ENV_FILE"
	fi
	echo "user_overlays is now: '${value}'"
}

without() {
	local drop=" $* " out=()
	for o in $current; do
		[[ $drop == *" $o "* ]] || out+=("$o")
	done
	echo "${out[*]}"
}

# Prints the modules from "$@" that the running kernel has neither as a
# module nor built in (modinfo reports built-in drivers too).
missing_modules() {
	local m
	for m in "$@"; do
		$MODINFO -F filename "$m" >/dev/null 2>&1 || echo "$m"
	done
}

remove_touch() {
	if [[ -f $UNIT_DIR/$TOUCH.service ]]; then
		$SYSTEMCTL disable --now "$TOUCH.service" || true
		rm -f "$UNIT_DIR/$TOUCH.service"
		$SYSTEMCTL daemon-reload || true
	fi
	rm -f "$BIN_DIR/$TOUCH"
}

if [[ $uninstall -eq 1 ]]; then
	set_user_overlays "$(without "${ALL_OVERLAYS[@]}")"
	for o in "${ALL_OVERLAYS[@]}"; do rm -f "$OVERLAY_DIR/$o.dtbo"; done
	rm -f "$MODULES_CONF"
	remove_touch
	echo "Removed ($DEFAULTS_FILE kept if you edited it). Reboot to apply."
	exit 0
fi

missing_bridge="$(missing_modules "${BRIDGE_MODULES[@]}")"
missing_legacy="$(missing_modules "${LEGACY_MODULES[@]}")"
if [[ $variant == auto ]]; then
	if [[ -z $missing_bridge || -n $missing_legacy ]]; then
		variant=bridge
	else
		variant=legacy
	fi
fi

if [[ $variant == bridge ]]; then
	NAME=$BRIDGE OTHER=$LEGACY MODULES=("${BRIDGE_MODULES[@]}")
	if [[ -n $missing_bridge ]]; then
		cat <<-EOF
		WARNING: kernel $(uname -r) lacks: $(echo $missing_bridge)
		The overlay will install, but the screen cannot work until the kernel has:
		  ${BRIDGE_CONFIGS[*]}
		Armbian's stock rockchip64 kernels don't enable the first two. Build a kernel
		with kernel/dfr0678.config (see README), then hold it: sudo apt-mark hold <kernel packages>
		EOF
	fi
elif [[ $variant == test* ]]; then
	case $variant in
		test) NAME=$TEST_BRIDGE patches="rk3399-dsi1-dsi0-pll" ;;
		test-lane594) NAME=$TEST_LANE patches="rk3399-dsi1-dsi0-pll dsi-lane-rate-override" ;;
		test-radxa) NAME=$TEST_RADXA patches="rk3399-dsi1-dsi0-pll dsi-lane-rate-override tc358762-radxa-init" ;;
		test-radxa-vopl) NAME=$TEST_RADXA_VOPL patches="rk3399-dsi1-dsi0-pll dsi-lane-rate-override tc358762-radxa-init" ;;
		test-radxa-vopl-simple) NAME=$TEST_RADXA_VOPL_SIMPLE patches="rk3399-dsi1-dsi0-pll dsi-lane-rate-override tc358762-radxa-init dfr0678-radxa-timing" ;;
		test-radxa-vopl-simple-mcu-sequence) NAME=$TEST_RADXA_VOPL_SIMPLE_MCU_SEQUENCE patches="rk3399-dsi1-dsi0-pll dsi-lane-rate-override tc358762-radxa-init dfr0678-radxa-timing attiny-radxa-screen-power-sequence" ;;
	esac
	OTHER=$BRIDGE MODULES=("${BRIDGE_MODULES[@]}")
	cat <<-EOF
	WARNING: $NAME is experimental. It needs a kernel built with these
	patches from kernel/: $patches
	This test is not a production configuration.
	EOF
	if [[ -n $missing_bridge ]]; then
		cat <<-EOF
		WARNING: kernel $(uname -r) lacks: $(echo $missing_bridge)
		The overlay will install, but the screen cannot work until the kernel has:
		  ${BRIDGE_CONFIGS[*]}
		Armbian's stock rockchip64 kernels don't enable the first two. Build a kernel
		with kernel/dfr0678.config (see README), then hold it: sudo apt-mark hold <kernel packages>
		EOF
	fi
elif [[ $variant == v7 ]]; then
	NAME=$RPi7_FIXED OTHER=$BRIDGE MODULES=("${BRIDGE_MODULES[@]}")
	echo "INFO: Installing $NAME (production configuration for RPi 7\" touchscreen)"
	echo "This variant requires a kernel built with these patches from kernel/:"
	echo "  rk3399-dsi1-dsi0-pll"
	echo "  dsi-lane-rate-override"
	echo "  dfr0678-radxa-timing"
	echo "  tc358762-rpi7-touchscreen-radxa  (obsolete: use v8 and tc358762-rpi7-radxa-bringup instead)"
	if [[ -n $missing_bridge ]]; then
		cat <<-EOF
		WARNING: kernel $(uname -r) lacks: $(echo $missing_bridge)
		The overlay will install, but the screen cannot work until the kernel has:
		  ${BRIDGE_CONFIGS[*]}
		Build a kernel with the patches listed above and CONFIG_DRM_TOSHIBA_TC358762 enabled.
		EOF
	fi
elif [[ $variant == v8* || $variant == v9 ]]; then
	case $variant in
		v8) NAME=$RPi7_MCU ;;
		v8-pre) NAME=$RPi7_MCU_PRE ;;
		v8-vopl) NAME=$RPi7_MCU_VOPL ;;
		v8-gpio) NAME=$RPi7_GPIO ;;
		v9) NAME=$RPi7_FIX ;;
	esac
	OTHER=$BRIDGE MODULES=("${BRIDGE_MODULES[@]}")
	cat <<-EOF
	INFO: Installing $NAME (Radxa-compatible RPi 7" bring-up)
	This variant requires a kernel built with these patches from kernel/:
	  rk3399-dsi1-dsi0-pll
	  dsi-lane-rate-override
	  dfr0678-radxa-timing
	  tc358762-rpi7-radxa-bringup
	  tc358762-rpi7-radxa-readback (debug only, optional)
	  rockchip-vop-dsi-bsp-parity (required for v9: the VOP DSI fix)
	(and NOT tc358762-radxa-init or tc358762-rpi7-touchscreen-radxa)
	EOF
	if [[ -n $missing_bridge ]]; then
		cat <<-EOF
		WARNING: kernel $(uname -r) lacks: $(echo $missing_bridge)
		The overlay will install, but the screen cannot work until the kernel has:
		  ${BRIDGE_CONFIGS[*]}
		EOF
	fi
else
	NAME=$LEGACY OTHER=$BRIDGE MODULES=("${LEGACY_MODULES[@]}")
	[[ -n $missing_legacy ]] && echo "WARNING: kernel $(uname -r) lacks panel-raspberrypi-touchscreen."
	cat <<-EOF
	NOTE: installing the legacy overlay. On Armbian 6.18 it lights the backlight
	but shows no image ("failed to write command FIFO"). The bridge variant needs
	a kernel built with kernel/dfr0678.config.
	EOF
fi
echo "Variant: $variant ($NAME)"

if ! command -v dtc >/dev/null; then
	apt-get install -y device-tree-compiler
fi

mkdir -p "$OVERLAY_DIR" "$OVERLAY_DIR/disabled"
dtc -q -@ -I dts -O dtb -o "$OVERLAY_DIR/$NAME.dtbo" "$HERE/overlays/$NAME.dts"
echo "Installed $OVERLAY_DIR/$NAME.dtbo"

for other in "${ALL_OVERLAYS[@]}"; do
	[[ $other == "$NAME" ]] || rm -f "$OVERLAY_DIR/$other.dtbo"
done
for old in "${OLD_OVERLAYS[@]}"; do
	if [[ -f $OVERLAY_DIR/$old.dtbo ]]; then
		mv "$OVERLAY_DIR/$old.dtbo" "$OVERLAY_DIR/disabled/"
		echo "Moved old overlay $old.dtbo to $OVERLAY_DIR/disabled/"
	fi
done

current="$(without "${OLD_OVERLAYS[@]}" "${ALL_OVERLAYS[@]}")"
set_user_overlays "${current:+$current }$NAME"

printf '%s\n' "${MODULES[@]}" uinput > "$MODULES_CONF"

if [[ $touch -eq 1 ]]; then
	command -v python3 >/dev/null || apt-get install -y python3
	install -D -m 0755 "$HERE/touch/ft5406_touchd.py" "$BIN_DIR/$TOUCH"
	install -D -m 0644 "$HERE/touch/$TOUCH.service" "$UNIT_DIR/$TOUCH.service"
	if [[ ! -f $DEFAULTS_FILE ]]; then
		install -D -m 0644 /dev/null "$DEFAULTS_FILE"
		cat > "$DEFAULTS_FILE" <<-'EOF'
		# Extra options for ft5406-touchd (see: ft5406-touchd --help). If touches land in
		# the opposite quadrant, invert both axes (or run ./touch-orientation.sh 180).
		# If the axes are swapped (drag left moves the cursor down), use --rotate-90 or
		# --rotate-270 (or ./touch-orientation.sh 90|270):
		#   FT5406_TOUCHD_ARGS="--rotate-180"
		FT5406_TOUCHD_ARGS=""
		EOF
	fi
	$SYSTEMCTL daemon-reload
	$SYSTEMCTL enable "$TOUCH.service"
	echo "Installed touch service $TOUCH (starts on boot; options in $DEFAULTS_FILE)"
else
	remove_touch
fi

echo
echo "Done. Reboot, then run ./diagnose.sh to check the result."
