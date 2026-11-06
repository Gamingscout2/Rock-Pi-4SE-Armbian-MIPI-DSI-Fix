#!/usr/bin/env bash
# TEST 0003: what does the VOP -> DSI pixel path deliver? (no kernel rebuild)
#
# Background (test 0000): with the DSI host's own pattern generator the panel shows colour
# bars, so DSI host -> TC358762 -> panel works. With pattern off the panel stays black
# although DSI1 INT_ST1 is 0 (pixels are being drained from the DPI FIFO).
# This test makes the framebuffer content impossible to miss, then varies the DPI side.
#
#   F0  print text lines on tty1 (is the text console drawn at all?)
#   F1  fill /dev/fb0 with white         (black panel = no VOP pixels arrive/shown at all)
#   F2  draw 8 colour bars on /dev/fb0   (colours wrong/swapped = format problem)
#   F3  modetest SMPTE pattern (fresh DRM modeset, not fbcon)
#   P*  DSI1 DPI_CFG_POL variants (sync/DE polarity seen by the host)
#   M*  DSI1 video type: non-burst sync pulses / sync events instead of burst
#   T1  Radxa's line timing (HBP 0x86, HLINE_TIME 0xb0f instead of 0x87 / 0xb22)
#
# Each DSI1 change is applied with PWR_UP held low and reverted before the next one.
#
# Run:  sudo ./tests/0003-vop-pixel-path.sh 2>&1 | tee ~/0003-run.txt
# Needs python3 (fb drawing) and overlay v8 / v8-pre / v8-vopl with the Build 34 kernel.

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "$HERE/common.sh"

# Fallbacks so this script still works when an older tests/common.sh was copied to the board
# (the first run failed with "fb_info/fb_fill/fb_bars/host_apply: command not found").
if ! declare -F host_apply >/dev/null; then
	host_apply() {
		wr $DSI1 0x04 0x00000000
		while (($# >= 2)); do
			wr $DSI1 "$1" "$2"
			shift 2
		done
		wr $DSI1 0x04 0x00000001
	}
fi
if ! declare -F fb_info >/dev/null; then
	fb_info() {
		echo "--- /dev/fb0 ---"
		local f
		for f in name bits_per_pixel virtual_size stride; do
			printf '  %s = %s\n' "$f" "$(cat /sys/class/graphics/fb0/$f 2>/dev/null || echo '?')"
		done
	}
fi
if ! declare -F fb_fill >/dev/null; then
	fb_fill() {
		echo "+ fill /dev/fb0 with RGB($1,$2,$3)"
		python3 - "$1" "$2" "$3" <<'PY'
import struct, sys
r, g, b = (int(x) for x in sys.argv[1:4])
open('/dev/fb0', 'wb').write(struct.pack('<BBBB', b, g, r, 0) * (800 * 480))
PY
	}
fi
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
header 0003 "VOP pixel path"
fb_info
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 is missing"; exit 1; }

O_POL="$(rd $DSI1 0x14)"
O_VID="$(rd $DSI1 0x38)"
O_HBP="$(rd $DSI1 0x4c)"
O_HLINE="$(rd $DSI1 0x50)"
echo "Originals: DPI_CFG_POL=$O_POL VID_MODE_CFG=$O_VID HBP=$O_HBP HLINE=$O_HLINE"
echo "DPI_VCID=$(rd $DSI1 0x0c) DPI_COLOR_CODING=$(rd $DSI1 0x10) DPI_LP_CMD_TIM=$(rd $DSI1 0x18)"

restore_regs() {
	host_apply 0x14 "$O_POL" 0x38 "$O_VID" 0x4c "$O_HBP" 0x50 "$O_HLINE"
}
cleanup() {
	echo
	echo "--- restoring DSI1 registers and framebuffer ---"
	restore_regs
	fb_fill 0 0 0
}
trap cleanup EXIT

section "Baseline"
dsi1_int
ask_yn "Is the panel currently black with a lit backlight?" || {
	read -r -p "Describe what the panel shows now: " base_desc
	RESULTS+=("baseline | not black | $base_desc")
}

section "F0: text console state, then print a line on tty1"
echo "--- /proc/consoles ---"
cat /proc/consoles
echo "--- vtconsole ---"
for v in /sys/class/vtconsole/vtcon*; do
	printf '  %s name=%s bind=%s\n' "$v" "$(cat "$v/name" 2>/dev/null)" "$(cat "$v/bind" 2>/dev/null)"
done
echo "consoleblank = $(cat /sys/module/kernel/parameters/consoleblank 2>/dev/null)   cmdline: $(cat /proc/cmdline)"
command -v chvt >/dev/null 2>&1 && chvt 1
for i in 1 2 3 4 5; do echo "FBCON TEST LINE $i  $(date +%T)  ################################" > /dev/tty1; done
sleep 3
ask_change "F0-tty1-text"

section "F1: fill the framebuffer with white"
fb_fill 255 255 255
sleep 3
dsi1_int
ask_change "F1-fb-white"

section "F2: eight colour bars in the framebuffer"
fb_bars
sleep 3
dsi1_int
ask_change "F2-fb-colour-bars"

section "F3: modetest SMPTE pattern (a fresh DRM modeset)"
if ! command -v modetest >/dev/null 2>&1; then
	echo "modetest not found, trying: apt-get install -y libdrm-tests"
	apt-get install -y libdrm-tests >/dev/null 2>&1 || echo "(install failed, skipping F3)"
fi
if command -v modetest >/dev/null 2>&1; then
	CONN="$(modetest -M rockchip -c 2>/dev/null | awk '$3=="connected" && ($4 ~ /DPI|DSI/) {print $1; exit}')"
	CRTC="$(modetest -M rockchip -p 2>/dev/null | awk '/^CRTCs:/{f=1;next} f && /^[0-9]+[ \t]/{print $1; exit}')"
	echo "connector=$CONN crtc=$CRTC"
	if [[ -n $CONN && -n $CRTC ]]; then
		dmesg_mark
		(sleep 25) | modetest -M rockchip -s "${CONN}@${CRTC}:800x480" >/tmp/modetest-0003.log 2>&1 &
		MT=$!
		sleep 8
		dsi1_int
		ask_change "F3-modetest-smpte"
		wait "$MT" 2>/dev/null
		tail -n 5 /tmp/modetest-0003.log
		dmesg_new
	else
		echo "could not determine connector/crtc, skipping F3"
		modetest -M rockchip -c 2>&1 | head -n 20
	fi
else
	echo "modetest unavailable, skipping F3"
fi

# leave the colour bars in the framebuffer for the register variants
fb_bars

# variant <label> <offset value ...>
variant() {
	local label="$1"
	shift
	section "Variant $label"
	host_apply "$@"
	sleep 3
	dsi1_regs
	dsi1_int
	ask_change "$label"
	restore_regs
	sleep 2
}

variant "P0-dpi-pol-0x00" 0x14 0x00000000
variant "P1-dpi-pol-0x07" 0x14 0x00000007
variant "P2-dpi-pol-0x01" 0x14 0x00000001
variant "P3-dpi-pol-0x02" 0x14 0x00000002
variant "P4-dpi-pol-0x04" 0x14 0x00000004
variant "M1-non-burst-sync-pulses" 0x38 0x0000bf00
variant "M2-non-burst-sync-events" 0x38 0x0000bf01
variant "T1-radxa-line-timing" 0x4c 0x00000086 0x50 0x00000b0f

summary
