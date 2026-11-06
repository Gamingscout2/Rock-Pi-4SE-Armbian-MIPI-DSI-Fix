#!/usr/bin/env bash
# Shared helpers for tests/NNNN-*.sh (sourced, never run directly).
#
# Conventions for every test script:
#   - tests are numbered with 4-digit hex in creation order: 0000, 0001, ... 000f, 0010
#   - run as: sudo ./tests/NNNN-name.sh 2>&1 | tee ~/NNNN-run.txt
#   - everything is printed to the terminal; copy the output into docs/phaedra/
#   - after every visible change the script asks "Did the display state change? (y/n)";
#     a description is only requested when the answer is y
#   - the last block of the output ("SUMMARY") repeats every answer
#
# Needs: busybox (devmem), debugfs, a kernel with the tc358762 debugfs "action"
# file (Build 34+) and one of the v8 overlays (v8, v8-pre, v8-vopl).

DSI0=0xff960000
DSI1=0xff968000
GRF_CON20=0xff776250
ACTION=/sys/kernel/debug/tc358762/action
RESULTS=()
MARK=0

t_root() {
	[[ $EUID -eq 0 ]] || exec sudo -E bash "$0" "$@"
}

t_prereq() {
	if ! command -v busybox >/dev/null 2>&1; then
		echo "FATAL: busybox (devmem) is missing: sudo apt install busybox"
		exit 1
	fi
	mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug 2>/dev/null
	if [[ ! -w $ACTION ]]; then
		echo "FATAL: $ACTION not found. Boot the Build 34 (or newer) kernel with a v8 overlay."
		exit 1
	fi
	if ! dmesg | grep -q 'using Radxa RPi 7" init (mcu: yes'; then
		echo "FATAL: the bridge has no MCU access (needs overlay v8, v8-pre or v8-vopl)."
		exit 1
	fi
	local count
	count="$(cat /sys/kernel/debug/clk/pclk_mipi_dsi1/clk_enable_count 2>/dev/null || true)"
	if [[ ! $count =~ ^[0-9]+$ || $count -lt 1 ]]; then
		echo "FATAL: pclk_mipi_dsi1 is not enabled (count '$count'): the DSI1 host is not active."
		exit 1
	fi
}

rd() { busybox devmem "$(printf '0x%x' $(($1 + $2)))" 32; }

wr() {
	echo "+ devmem $(printf '0x%x' $(($1 + $2))) <- $3"
	busybox devmem "$(printf '0x%x' $(($1 + $2)))" 32 "$3"
}

# action <code>: write a code to /sys/kernel/debug/tc358762/action
#   1 reprogram bridge, 2 MCU power cycle, 3 MCU power cycle + reprogram,
#   4 log ATTiny registers, 5 backlight on, 6 backlight off
act() {
	echo "+ echo $1 > $ACTION"
	echo "$1" > "$ACTION" || echo "  (action $1 returned an error)"
}

# poke <addr> <data>: write one TC358762 register through the debugfs file
poke() {
	local v
	v="$(printf '0x0002%04x%08x' "$1" "$2")"
	echo "+ bridge reg $(printf '0x%04x' "$1") <- $(printf '0x%08x' "$2")"
	echo "$v" > "$ACTION" || echo "  (poke failed)"
}

section() { printf '\n===== %s =====\n' "$*"; }

header() {
	section "TEST $1: $2"
	date -Is
	uname -a
	grep '^user_overlays=' /boot/armbianEnv.txt
	dmesg | grep -E 'using Radxa RPi 7" init' | tail -n 1
	echo "GRF SOC_CON20 = $(busybox devmem $GRF_CON20 32)   (0x249 = DSI1 on VOPB, 0x259 = VOPL)"
	echo "DSI1 VID_MODE_CFG = $(rd $DSI1 0x38)   PWR_UP = $(rd $DSI1 0x04)   MODE_CFG = $(rd $DSI1 0x34)"
}

dmesg_mark() { MARK="$(dmesg | wc -l)"; }

dmesg_new() {
	echo "--- new kernel messages ---"
	dmesg | tail -n +$((MARK + 1)) | grep -E 'tc358762|dw-mipi-dsi|MCU|drm|vop' || echo "(none)"
}

# INT_ST0/1 clear on read: read twice, one second apart
dsi1_int() {
	local i
	echo "--- DSI1 INT_ST0 / INT_ST1 (read twice, clear-on-read) ---"
	for i in 1 2; do
		echo "INT_ST0=$(rd $DSI1 0xbc) INT_ST1=$(rd $DSI1 0xc0)"
		[[ $i -eq 1 ]] && sleep 1
	done
}

dsi1_regs() {
	local off
	echo "--- DSI1 registers ---"
	for off in 0x04 0x08 0x2c 0x34 0x38 0x48 0x4c 0x50 0x78 0x94 0x98 0x9c 0xa4 0xb0; do
		printf '  DSI1+%-5s = %s\n' "$off" "$(rd $DSI1 $off)"
	done
}

# ask_yn <question>: returns 0 for y, 1 for n
ask_yn() {
	local ans
	while true; do
		read -r -p "$1 (y/n): " ans
		ans="${ans,,}"
		[[ $ans == y ]] && return 0
		[[ $ans == n ]] && return 1
	done
}

# ask_change <label>: "Did the display state change?"; description only if yes
ask_change() {
	local label="$1" ans desc="-"
	while true; do
		read -r -p "[$label] Did the display state change? (y/n): " ans
		ans="${ans,,}"
		[[ $ans == y || $ans == n ]] && break
	done
	if [[ $ans == y ]]; then
		read -r -p "[$label] Describe what changed: " desc
	fi
	echo "RESULT | $label | changed=$ans | $desc"
	RESULTS+=("$label | changed=$ans | $desc")
}

summary() {
	section "SUMMARY"
	printf '%s\n' "${RESULTS[@]}"
}

# host_apply <offset> <value> [<offset> <value> ...]: write DSI1 registers with PWR_UP held low
# (same order the driver uses: reset, configure, power up)
host_apply() {
	wr $DSI1 0x04 0x00000000
	while (($# >= 2)); do
		wr $DSI1 "$1" "$2"
		shift 2
	done
	wr $DSI1 0x04 0x00000001
}

# fb_info: geometry of /dev/fb0
fb_info() {
	echo "--- /dev/fb0 ---"
	local f
	for f in name bits_per_pixel virtual_size stride; do
		printf '  %s = %s\n' "$f" "$(cat /sys/class/graphics/fb0/$f 2>/dev/null || echo '?')"
	done
}

# fb_fill <R> <G> <B>: fill /dev/fb0 (XR24, 800x480, 32 bpp) with one colour
fb_fill() {
	echo "+ fill /dev/fb0 with RGB($1,$2,$3)"
	python3 - "$1" "$2" "$3" <<'PY'
import struct, sys
r, g, b = (int(x) for x in sys.argv[1:4])
open('/dev/fb0', 'wb').write(struct.pack('<BBBB', b, g, r, 0) * (800 * 480))
PY
}

# fb_bars: eight vertical bars (white yellow cyan green magenta red blue black) on /dev/fb0
fb_bars() {
	echo "+ draw 8 vertical colour bars on /dev/fb0"
	python3 - <<'PY'
import struct
cols = [(255,255,255),(255,255,0),(0,255,255),(0,255,0),(255,0,255),(255,0,0),(0,0,255),(0,0,0)]
row = b''.join(struct.pack('<BBBB', b, g, r, 0) * 100 for (r, g, b) in cols)
open('/dev/fb0', 'wb').write(row * 480)
PY
}

# Optional: VPG=1 turns the DSI host's own colour-bar generator on for the whole test,
# so the VOP/framebuffer path is out of the picture while the bridge is being tested.
VPG_ORIG=""
vpg_on() {
	VPG_ORIG="$(rd $DSI1 0x38)"
	wr $DSI1 0x38 "$(printf '0x%08x' $((VPG_ORIG | 0x10000)))"
}
vpg_off() {
	[[ -n $VPG_ORIG ]] && wr $DSI1 0x38 "$VPG_ORIG"
	VPG_ORIG=""
}
