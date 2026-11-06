#!/usr/bin/env bash
# TEST 0006: which VOP DSI setting combination gives the best picture? (live, no rebuild)
#
# Result of test 0005 (session 18): setting VOP SYS_CTRL bit 17 (data01_swap) makes the
# console appear; step A5-1 (DSP_CTRL1 = 0x1000e400: dclk_pol 0, mipi_pin_pol 1) gave a
# sharp, correct console; B5 (DSP_CTRL1 = 0x0000e400, pin_pol 0) also worked; A4 (with the
# BSP's lut/dither bits 0/1/6, 0xe443) was washed out. This test:
#
#   - keeps the windows ON (normal operation), clears the screen, prints text lines on tty1
#     and draws 8 colour bars on /dev/fb0 (white yellow cyan green magenta red blue black)
#   - applies every combination of data01_swap=1 with dclk_pol {0,1} and pin_pol {0..3}
#   - for each one asks if the picture is good (sharp, correct colours, correct orientation)
#   - also checks swap=0 for reference
#
# Pick the best combination, put those two numbers in the overlay
# (overlays/rock-4se-rpi7-radxa-vopl-fix.dts: rockchip,dsi-dclk-pol / rockchip,dsi-pin-pol).
# All registers are restored on exit.
#
# Run:  sudo ./tests/0006-vop-fix-variants.sh 2>&1 | tee ~/0006-run.txt
# Needs python3, busybox, overlay v8-vopl or v9 (v9 already applies the fix; then the "reference"
# lines below show the unfixed picture instead).

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "$HERE/common.sh"

# Fallbacks for an older tests/common.sh on the board.
if ! declare -F fb_bars >/dev/null; then
	fb_bars() {
		echo "+ draw 8 vertical colour bars on /dev/fb0"
		python3 - <<'PY'
import struct
cols = [(255,255,255),(255,255,0),(0,255,255),(0,255,0),(255,0,255),(255,0,0),(0,0,255),(0,0,0)]
row = b''.join(struct.pack('<BBBB', b, g, r, 0) * 100 for (r, g, b) in cols)
open('/dev/fb0', 'wb').write(row * 480)
PY
	}
fi

t_root "$@"
t_prereq
header 0006 "VOP DSI fix variants"
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 is missing"; exit 1; }

CON20="$(busybox devmem $GRF_CON20 32)"
if (((CON20 >> 4) & 1)); then VOP=0xff8f0000; VOPN=VOPL; else VOP=0xff900000; VOPN=VOPB; fi
echo "DSI1 is fed by $VOPN at $VOP"

O_SYS="$(rd $VOP 0x08)"
O_D1="$(rd $VOP 0x14)"
echo "Originals: SYS_CTRL=$O_SYS DSP_CTRL1=$O_D1"

vop_apply() {
	while (($# >= 2)); do
		wr $VOP "$1" "$2"
		shift 2
	done
	wr $VOP 0x00 0x00000001
}

cleanup() {
	echo
	echo "--- restoring VOP registers ---"
	vop_apply 0x08 "$O_SYS" 0x14 "$O_D1"
}
trap cleanup EXIT

hx() { printf '0x%08x' "$1"; }

# draw <label>: black screen, text lines, colour bars
draw() {
	python3 - <<'PY'
open('/dev/fb0', 'wb').write(b'\x00' * (800 * 480 * 4))
PY
	command -v chvt >/dev/null 2>&1 && chvt 1
	for i in 1 2 3 4 5 6; do
		echo "VOP FIX TEST LINE $i  $(date +%T)  0123456789 abcdefghijklmnopqrstuvwxyz" > /dev/tty1
	done
	fb_bars
}

# variant <label> <swap 0|1> <dclk_pol 0|1> <pin_pol 0..7>
variant() {
	local label="$1" swap="$2" dclk="$3" pin="$4" sys d1 good desc
	sys=$((swap ? (O_SYS | 0x20000) : (O_SYS & ~0x20000)))
	d1=$(((O_D1 & 0x0000ffff) | (dclk << 31) | (pin << 28)))
	section "Variant $label: data01_swap=$swap dclk_pol=$dclk pin_pol=$pin (SYS_CTRL=$(hx $sys) DSP_CTRL1=$(hx $d1))"
	vop_apply 0x08 "$(hx $sys)" 0x14 "$(hx $d1)"
	draw "$label"
	sleep 2
	dsi1_int
	echo "Expect: 6 text lines at the top that are sharp, 8 colour bars (white yellow cyan green"
	echo "magenta red blue black, left to right), nothing shifted, flickering or washed out."
	if ask_yn "[$label] Is the picture GOOD (sharp text, bars correct)?"; then
		RESULTS+=("$label | good")
		echo "RESULT | $label | good"
	else
		read -r -p "[$label] Describe what is wrong (black / washed out / shifted / colours wrong ...): " desc
		RESULTS+=("$label | bad | $desc")
		echo "RESULT | $label | bad | $desc"
	fi
}

variant "V0-reference-no-swap-dclk1-pin0" 0 1 0
variant "V1-swap-dclk0-pin1" 1 0 1
variant "V2-swap-dclk0-pin0" 1 0 0
variant "V3-swap-dclk1-pin0" 1 1 0
variant "V4-swap-dclk1-pin1" 1 1 1
variant "V5-swap-dclk0-pin2" 1 0 2
variant "V6-swap-dclk0-pin3" 1 0 3
variant "V7-swap-dclk0-pin4" 1 0 4

echo
echo "Done. Put the dclk_pol / pin_pol of the best GOOD variant into the overlay."
summary
