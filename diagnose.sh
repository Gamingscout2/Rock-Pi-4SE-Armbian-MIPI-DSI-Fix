#!/usr/bin/env bash
# Read-only health check for the DFR0678 DSI display on a ROCK 4SE.
#
#   sudo ./diagnose.sh
set -uo pipefail

[[ $EUID -eq 0 ]] || exec sudo "$0" "$@"

DT=${DT:-/proc/device-tree}
DSI1=$DT/dsi@ff968000
DSI0=$DT/dsi@ff960000
I2C1=$DT/i2c@ff110000
LCD=$I2C1/lcd@45
MCU=$I2C1/regulator@45
BRIDGE=$DSI1/bridge@0
BRIDGE_OVERLAY=rock-4se-dfr0678-dsi-bridge
TEST_OVERLAY=rock-4se-dfr0678-dsi-bridge-dsi0pll-test
TEST_LANE_OVERLAY=rock-4se-dfr0678-dsi-bridge-test-lane594
TEST_RADXA_OVERLAY=rock-4se-dfr0678-dsi-bridge-test-radxa
TEST_RADXA_VOPL_OVERLAY=rock-4se-dfr0678-dsi-bridge-test-radxa-vopl
TEST_RADXA_VOPL_SIMPLE_OVERLAY=rock-4se-dfr0678-dsi-bridge-test-radxa-vopl-simple
TEST_RADXA_VOPL_SIMPLE_MCU_SEQUENCE_OVERLAY=rock-4se-dfr0678-dsi-bridge-test-radxa-vopl-simple-mcu-sequence-test
LEGACY_OVERLAY=rock-4se-dfr0678-dsi
VOPB_EP=$DSI1/ports/port@0/endpoint@0
VOPL_EP=$DSI1/ports/port@0/endpoint@1
problems=()

section() { printf '\n=== %s ===\n' "$1"; }
dtprop() {
	[[ -f $1 ]] && tr '\0' ' ' < "$1" | sed 's/ $//'
}
kconfig() {
	{ zcat /proc/config.gz 2>/dev/null || cat "/boot/config-$(uname -r)" 2>/dev/null; } \
		| grep -E "^(# )?$1[= ]" | head -n1
}
has_driver() { modinfo -F filename "$1" >/dev/null 2>&1; }

section "System and boot configuration"
uname -a
grep -E '^(PRETTY_NAME|VERSION)=' /etc/os-release 2>/dev/null || echo "OS release: unavailable"
dpkg-query -W -f='${binary:Package} ${Version}\n' 'linux-image*rockchip64' 'linux-dtb*rockchip64' 2>/dev/null || true
if [[ -r /boot/armbianEnv.txt ]]; then
	grep -E '^(overlays|user_overlays|overlay_prefix|fdtfile)=' /boot/armbianEnv.txt || true
	configured_overlays="$(sed -n 's/^user_overlays=//p' /boot/armbianEnv.txt | tail -n1)"
else
	echo "/boot/armbianEnv.txt: unavailable"
	configured_overlays=""
fi
read -r -a configured_overlay_names <<< "$configured_overlays"
selected_dfr_overlays=()
for overlay in "${configured_overlay_names[@]}"; do
	case $overlay in
		"$BRIDGE_OVERLAY"|"$TEST_OVERLAY"|"$TEST_LANE_OVERLAY"|"$TEST_RADXA_OVERLAY"|"$TEST_RADXA_VOPL_OVERLAY"|"$TEST_RADXA_VOPL_SIMPLE_OVERLAY"|"$TEST_RADXA_VOPL_SIMPLE_MCU_SEQUENCE_OVERLAY"|"$LEGACY_OVERLAY")
			selected_dfr_overlays+=("$overlay")
			;;
	esac
done
if [[ ${#selected_dfr_overlays[@]} -gt 1 ]]; then
	problems+=("multiple DFR0678 overlays are selected in user_overlays; keep only one")
fi
for overlay in /boot/overlay-user/*.dtbo; do
	[[ -e $overlay ]] && echo "overlay file: $overlay"
done

section "Live device tree"
echo "DSI1 (ff968000, connector host): $(dtprop "$DSI1/status" || echo missing)"
echo "DSI0 (ff960000, unused display host): $(dtprop "$DSI0/status" || echo missing)"
if [[ -d $MCU || -d $BRIDGE ]]; then
	variant=bridge
	echo "variant: split-driver bridge"
	echo "I2C1 regulator@45 compatible: $(dtprop "$MCU/compatible" || echo missing)"
	echo "DSI1 bridge@0 compatible:     $(dtprop "$BRIDGE/compatible" || echo missing)"
	echo "panel compatible:             $(dtprop "$DT/panel/compatible" || echo missing)"
	vopb_status="$(dtprop "$VOPB_EP/status" || true)"
	vopl_status="$(dtprop "$VOPL_EP/status" || true)"
	[[ -n $vopb_status ]] || vopb_status="okay (implicit)"
	[[ -n $vopl_status ]] || vopl_status="okay (implicit)"
	echo "DSI1 VOPB input endpoint:     $vopb_status"
	echo "DSI1 VOPL input endpoint:     $vopl_status"
	if [[ " $configured_overlays " == *" $TEST_RADXA_VOPL_OVERLAY "* || " $configured_overlays " == *" $TEST_RADXA_VOPL_SIMPLE_OVERLAY "* || " $configured_overlays " == *" $TEST_RADXA_VOPL_SIMPLE_MCU_SEQUENCE_OVERLAY "* ]]; then
		[[ $vopb_status == disabled ]] || problems+=("VOPL test selected, but DSI1 VOPB endpoint is not disabled")
		[[ $vopl_status == okay ]] || problems+=("VOPL test selected, but DSI1 VOPL endpoint is not enabled")
	fi
	if [[ " $configured_overlays " == *" $TEST_RADXA_VOPL_SIMPLE_OVERLAY "* || " $configured_overlays " == *" $TEST_RADXA_VOPL_SIMPLE_MCU_SEQUENCE_OVERLAY "* ]]; then
		[[ "$(dtprop "$DT/panel/compatible")" == powertip,ph800480t013-idf02 ]] \
			|| problems+=("VOPL simple test selected, but the Powertip panel-simple descriptor is not active")
		[[ ! -e $DT/panel/panel-timing ]] \
			|| problems+=("VOPL simple test selected, but an inline panel-timing overrides the descriptor mode")
	fi
	if [[ -e $MCU/radxa,screen-power-sequence ]]; then
		echo "ATTiny Radxa screen power sequence: enabled"
	else
		echo "ATTiny Radxa screen power sequence: absent"
	fi
	if [[ " $configured_overlays " == *" $TEST_RADXA_VOPL_SIMPLE_MCU_SEQUENCE_OVERLAY "* ]]; then
		[[ -e $MCU/radxa,screen-power-sequence ]] \
			|| problems+=("MCU-sequence test selected, but its opt-in device-tree property is absent")
	elif [[ -e $MCU/radxa,screen-power-sequence ]]; then
		problems+=("Radxa MCU power-sequence property is present without its dedicated test overlay")
	fi
	if [[ -f $DSI1/rockchip,dsi-dsi0 ]]; then
		echo "DSI0 PLL test property:       present (experimental kernel required)"
	else
		echo "DSI0 PLL test property:       absent"
	fi
	[[ -d $MCU ]] || problems+=("bridge overlay is incomplete: no regulator@45 under I2C1")
	[[ -d $BRIDGE ]] || problems+=("bridge overlay is incomplete: no bridge@0 under DSI1")
	[[ -d $LCD ]] && problems+=("both overlays claim I2C address 0x45; keep only one in user_overlays")
elif [[ -d $LCD ]]; then
	variant=legacy
	echo "variant: legacy panel-raspberrypi-touchscreen"
	echo "I2C1 lcd@45 compatible: $(dtprop "$LCD/compatible" || echo missing)"
else
	variant=none
	echo "variant: no DFR0678 panel node detected"
	problems+=("no panel node at I2C1 address 0x45: check user_overlays and reboot")
fi
[[ "$(dtprop "$DSI1/status")" == okay ]] || problems+=("DSI1 is not enabled in the live device tree")
if [[ -d $DSI0/ports/port@1 ]] && find "$DSI0/ports/port@1" -name remote-endpoint -print -quit 2>/dev/null | grep -q .; then
	problems+=("DSI0 has a panel endpoint; check for an obsolete overlay attached to the wrong host")
fi

section "Kernel drivers and device binding"
check_driver() {
	local mod="$1" sym="$2" hint="${3:-}"
	if has_driver "$mod"; then
		echo "$mod: $(modinfo -F filename "$mod" 2>/dev/null)"
	else
		local cfg
		cfg="$(kconfig "$sym")"
		echo "$mod: NOT FOUND (${cfg:-$sym: kernel config unavailable})"
		problems+=("kernel lacks $sym (driver $mod)${hint:+; $hint}")
	fi
}
case $variant in
	bridge)
		hint="build a kernel with kernel/dfr0678.config"
		check_driver rpi-panel-attiny-regulator CONFIG_REGULATOR_RASPBERRYPI_TOUCHSCREEN_ATTINY "$hint"
		check_driver tc358762 CONFIG_DRM_TOSHIBA_TC358762 "$hint"
		check_driver panel-simple CONFIG_DRM_PANEL_SIMPLE "$hint"
		;;
	legacy)
		check_driver panel-raspberrypi-touchscreen CONFIG_DRM_PANEL_RASPBERRYPI_TOUCHSCREEN "update the kernel"
		;;
esac
grep -E '^(panel_raspberrypi_touchscreen|rpi_panel_attiny_regulator|tc358762|panel_simple|rockchipdrm) ' /proc/modules \
	| cut -d' ' -f1,3 | sed 's/^/loaded: /' || true

bus=""
for d in /sys/bus/i2c/devices/i2c-*; do
	[[ "$(readlink -f "$d" 2>/dev/null)" == *ff110000.i2c* ]] && bus="${d##*-}"
done
echo "I2C1 (ff110000) adapter: /dev/i2c-${bus:-not found}"
if [[ -n $bus && -e /sys/bus/i2c/devices/$bus-0045 ]]; then
	drv="$(readlink "/sys/bus/i2c/devices/$bus-0045/driver" 2>/dev/null || true)"
	echo "I2C device $bus-0045 driver: ${drv##*/}"
	[[ -n $drv ]] || problems+=("nothing is bound to the panel MCU at $bus-0045")
else
	echo "I2C device at 0x45: not found"
fi
dsidev="$(find /sys/bus/mipi-dsi/devices -maxdepth 1 -name 'ff968000.dsi.*' -print -quit 2>/dev/null)"
if [[ -n $dsidev ]]; then
	ddrv="$(readlink "$dsidev/driver" 2>/dev/null || true)"
	echo "${dsidev##*/} driver: ${ddrv##*/}"
	[[ -n $ddrv ]] || problems+=("no driver is bound to DSI1 peripheral ${dsidev##*/}")
elif [[ $variant != none ]]; then
	echo "DSI1 peripheral: not registered"
	problems+=("DSI1 peripheral was not registered; inspect kernel log and deferred probes")
fi

section "Deferred probes and DRM state"
if [[ -r /sys/kernel/debug/devices_deferred ]]; then
	cat /sys/kernel/debug/devices_deferred
else
	echo "deferred-probe list unavailable (debugfs not mounted or permission denied)"
fi
state_found=0
for state in /sys/kernel/debug/dri/*/state /sys/kernel/debug/dri/display-subsystem/state; do
	[[ -r $state ]] || continue
	state_found=1
	echo "--- $state ---"
	cat "$state"
done
[[ $state_found -eq 1 ]] || echo "DRM debug state unavailable"

echo "DRM connectors (the bridge path may be named DPI-1, not DSI-1):"
found_connector=0
for c in /sys/class/drm/card*-*; do
	[[ -r $c/status ]] || continue
	found_connector=1
	echo "${c##*/}: $(cat "$c/status"), enabled=$(cat "$c/enabled" 2>/dev/null || echo unavailable)"
	[[ ${c##*/} == *DPI-1 ]] && {
		echo "  modes: $(tr '\n' ' ' < "$c/modes" 2>/dev/null || echo unavailable)"
	}
done
[[ $found_connector -eq 1 ]] || echo "no DRM connector status files found"
if [[ $variant == bridge ]] && ! compgen -G '/sys/class/drm/card*-DPI-1/status' >/dev/null; then
	problems+=("expected bridge output DPI-1 is not registered in DRM")
elif [[ $variant == legacy ]] \
	&& ! compgen -G '/sys/class/drm/card*-DPI-1/status' >/dev/null \
	&& ! compgen -G '/sys/class/drm/card*-DSI-1/status' >/dev/null; then
	problems+=("no panel connector (DPI-1 or DSI-1) is registered in DRM")
fi
if command -v modetest >/dev/null 2>&1; then
	modetest -c 2>&1
else
	echo "modetest unavailable (install libdrm-tests for connector/mode details)"
fi

section "DSI clocks and safe read-only registers"
clock_count() {
	local name="$1" file="/sys/kernel/debug/clk/$1/clk_enable_count"
	if [[ -r $file ]]; then
		cat "$file"
	else
		echo unavailable
	fi
}
read_dsi_registers() {
	local label="$1" base="$2" clock="$3" count offset address value
	count="$(clock_count "$clock")"
	echo "$label peripheral clock $clock enable count: $count"
	if [[ ! $count =~ ^[0-9]+$ || $count -lt 1 ]]; then
		echo "  register reads skipped: clock count is unavailable or zero"
		return
	fi
	if ! command -v busybox >/dev/null 2>&1; then
		echo "  register reads unavailable: busybox devmem is not installed"
		return
	fi
	for offset in 0x004 0x008 0x02c 0x034 0x038 0x094 0x0b0; do
		address="$(printf '0x%x' "$((base + offset))")"
		if value="$(busybox devmem "$address" 32 2>&1)"; then
			printf '  %s = %s\n' "$address" "$value"
		else
			printf '  %s = unavailable (%s)\n' "$address" "$value"
		fi
	done
}
read_dsi_registers DSI1 0xff968000 pclk_mipi_dsi1
read_dsi_registers DSI0 0xff960000 pclk_mipi_dsi0
if command -v busybox >/dev/null 2>&1; then
	if value="$(busybox devmem 0xff776250 32 2>&1)"; then
		echo "GRF SOC_CON20 (read-only): $value"
	else
		echo "GRF SOC_CON20 unavailable: $value"
	fi
else
	echo "GRF SOC_CON20 unavailable: busybox devmem is not installed"
fi
echo "Interrupt-status registers are intentionally not read; reads may clear latched status."

section "Panel power, backlight, and touch"
if [[ -n $bus ]] && [[ -e /sys/bus/i2c/devices/$bus-0045/driver ]]; then
	echo "I2C 0x45 probe skipped: a kernel driver owns the address"
elif [[ -n $bus ]] && command -v i2cdetect >/dev/null 2>&1; then
	i2cdetect -y -r "$bus" 0x45 0x45 2>&1
else
	echo "I2C 0x45 probe unavailable (adapter, driver, or i2c-tools missing)"
fi
for bl in /sys/class/backlight/*; do
	[[ -d $bl ]] || continue
	echo "--- backlight ${bl##*/} ---"
	for attr in brightness actual_brightness max_brightness bl_power; do
		[[ -r $bl/$attr ]] && printf '%s=%s\n' "$attr" "$(cat "$bl/$attr")"
	done
done
if [[ -n $bus ]] && command -v i2cdetect >/dev/null 2>&1; then
	touch_scan="$(i2cdetect -y -r "$bus" 0x38 0x38 2>&1)"
	echo "$touch_scan"
	grep -qE '^30:.* (38|UU)' <<<"$touch_scan" \
		|| problems+=("touch controller at 0x38 did not respond")
else
	echo "touch-controller scan unavailable (adapter or i2c-tools missing)"
fi
if command -v systemctl >/dev/null 2>&1 && [[ -f /etc/systemd/system/ft5406-touchd.service ]]; then
	touch_state="$(systemctl is-active ft5406-touchd 2>&1 || true)"
	echo "ft5406-touchd service: $touch_state"
	systemctl is-active -q ft5406-touchd || problems+=("ft5406-touchd service is not running")
	journalctl -u ft5406-touchd -n 8 --no-pager -o cat 2>/dev/null | sed 's/^/  /' || true
else
	echo "ft5406-touchd service: not installed"
fi
if grep -q 'FT5406 touchscreen (polled)' /proc/bus/input/devices 2>/dev/null; then
	grep -A5 'FT5406 touchscreen (polled)' /proc/bus/input/devices | grep -E '^(N|H):'
else
	echo "FT5406 input device: not present"
fi

section "Relevant kernel log"
if log="$(dmesg 2>&1)"; then
	grep -iE 'dsi|panel|rpi|atmel|attiny|tc358|ff968000|0045|rockchip-drm|vop|fifo|deferred|timeout' <<<"$log" \
		| grep -v 'Fixed dependency cycle' | tail -n 80 || true
	fifo="$(grep -c 'failed to write command FIFO\|failed to get available' <<<"$log" || true)"
	if [[ ${fifo:-0} -gt 0 ]]; then
		problems+=("DSI1 logged $fifo command FIFO failure(s); inspect the PHY/host status above and the full dmesg")
	fi
	grep -q 'error initializing bridge' <<<"$log" \
		&& problems+=("TC358762 reported an initialization error; inspect the preceding DSI command/PHY messages")
else
	echo "dmesg unavailable: $log"
fi

section "Summary"
if [[ ${#problems[@]} -eq 0 ]]; then
	echo "No automated faults detected. This does not prove that the panel is displaying an image."
else
	printf ' - %s\n' "${problems[@]}"
fi
