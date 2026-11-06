#!/usr/bin/env bash
# TEST 0005: VOP side, live (no kernel rebuild): background colour, DCLK polarity, Radxa-style VOP regs
#
# Why: test 0004 (Radxa vs Armbian, both DSI1 <- VOPL) showed the DSI host registers are at
# parity, but the VOPL registers differ:
#
#   reg            Armbian        Radxa (works)   meaning
#   +0x14          0x8000E400     0x0000E443      DSP_CTRL1: bit31 = mipi_dclk_pol (mainline sets 1 for DSI), 0 on Radxa;
#                                                 bits 0,1,6 only set by the BSP
#   +0x08          0x20809800     0x20829800      SYS_CTRL: bit 17 only set by the BSP
#   +0x40          0x00000000     0x0030a000      WIN0_YRGB_MST: framebuffer (IO)VA; 0 on Armbian
#   +0x60          0x00000000     0x00ff0000      WIN0_SRC_ALPHA_CTRL
#   +0xb0          0x00000001     0x00000000      WIN2_CTRL0: win2 enabled on Armbian, off on Radxa
#
# Stage A (windows OFF, only the VOP background colour is shown; no memory fetch at all):
#   A1 white background. White panel -> the VOP -> DSI -> panel output path WORKS and the
#      fault is the framebuffer fetch (window/IOMMU/format). Black -> the output path itself
#      (dclk polarity, pins, mipi enable) is wrong, continue with A2-A6.
# Stage B (windows restored, framebuffer white): cumulative Radxa-style register changes.
#
# VOP registers are shadowed: each change is followed by REG_CFG_DONE (write 1 to +0x00),
# exactly like the driver. Every touched register is restored on exit.
#
# Run:  sudo ./tests/0005-vop-bg-and-pol.sh 2>&1 | tee ~/0005-run.txt
# Needs python3 and busybox, overlay v8-vopl (or v8/v8-pre: the VOP in use is detected).

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "$HERE/common.sh"

# Fallbacks so this script still works with an older common.sh on the board.
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

t_root "$@"
t_prereq
header 0005 "VOP background, DCLK polarity, Radxa-style VOP registers"
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 is missing"; exit 1; }

CON20="$(busybox devmem $GRF_CON20 32)"
if (((CON20 >> 4) & 1)); then
	VOP=0xff8f0000
	VOPN=VOPL
else
	VOP=0xff900000
	VOPN=VOPB
fi
MMU=$(printf '0x%x' $((VOP + 0x3f00)))
echo "DSI1 is fed by $VOPN at $VOP (SOC_CON20=$CON20), its IOMMU is at $MMU"

O_SYS="$(rd $VOP 0x08)"
O_D1="$(rd $VOP 0x14)"
O_BG="$(rd $VOP 0x18)"
O_W0="$(rd $VOP 0x30)"
O_A0="$(rd $VOP 0x60)"
O_W2="$(rd $VOP 0xb0)"
echo "Originals: SYS_CTRL=$O_SYS DSP_CTRL1=$O_D1 DSP_BG=$O_BG WIN0_CTRL0=$O_W0 WIN0_ALPHA=$O_A0 WIN2_CTRL0=$O_W2"

# vop_apply <offset> <value> [...]: write VOP registers, then REG_CFG_DONE
vop_apply() {
	while (($# >= 2)); do
		wr $VOP "$1" "$2"
		shift 2
	done
	wr $VOP 0x00 0x00000001
}

restore_vop() {
	vop_apply 0x08 "$O_SYS" 0x14 "$O_D1" 0x18 "$O_BG" 0x30 "$O_W0" 0x60 "$O_A0" 0xb0 "$O_W2"
}

cleanup() {
	echo
	echo "--- restoring VOP registers and framebuffer ---"
	restore_vop
	fb_fill 0 0 0
}
trap cleanup EXIT

hx() { printf '0x%08x' "$1"; }
last_changed() { [[ ${RESULTS[-1]:-} == *"changed=y"* ]]; }

section "S0: IOMMU, DRM plane state and kernel messages (read-only)"
echo "--- $VOPN IOMMU registers (0 DTE_ADDR, 4 STATUS bit0=paging, c PAGE_FAULT_ADDR, 14 RAWSTAT, 20 STATUS) ---"
for off in 0x00 0x04 0x0c 0x14 0x1c 0x20 0x24; do
	printf '  MMU+%-5s = %s\n' "$off" "$(rd $MMU $off)"
done
echo "--- kernel messages about iommu / faults / vop / drm ---"
dmesg | grep -iE 'iommu|page fault|rockchip-drm|rockchipdrm|vop|drm' | tail -n 40
echo "--- first 16 bytes of /dev/fb0 (after a white fill) ---"
fb_fill 255 255 255
head -c 16 /dev/fb0 | od -An -tx1
echo "--- /sys/kernel/debug/dri/0/state (planes) ---"
head -n 160 /sys/kernel/debug/dri/0/state 2>/dev/null || echo "(not readable)"

section "Baseline"
ask_yn "Is the panel currently black with a lit backlight?" || {
	read -r -p "Describe what the panel shows now: " base_desc
	RESULTS+=("baseline | not black | $base_desc")
}

section "Stage A: windows OFF, only the VOP background colour (no memory fetch)"
echo "A1: DSP_BG = white, WIN0 and WIN2 disabled."
vop_apply 0x18 0x3fffffff 0x30 "$(hx $((O_W0 & ~1)))" 0xb0 "$(hx $((O_W2 & ~1)))"
sleep 3
dsi1_int
ask_change "A1-bg-white-windows-off"
A_WORKS=0
last_changed && A_WORKS=1

if ((A_WORKS)); then
	echo
	echo ">>> The VOP output path works (white background reached the panel)."
	echo ">>> The fault is the window / framebuffer fetch. Skipping A2-A6, going to stage B."
else
	echo "A2: DCLK polarity bit (DSP_CTRL1 bit31) cleared, as on Radxa."
	vop_apply 0x14 "$(hx $((O_D1 & ~0x80000000)))"
	sleep 3
	ask_change "A2-dclk-pol-0"

	echo "A3: DSP_CTRL1 = Radxa value 0x0000e443."
	vop_apply 0x14 0x0000e443
	sleep 3
	ask_change "A3-dsp-ctrl1-radxa"

	echo "A4: A3 plus SYS_CTRL bit17 (set on Radxa only)."
	vop_apply 0x08 "$(hx $((O_SYS | 0x20000)))"
	sleep 3
	ask_change "A4-sys-ctrl-bit17"

	for nib in 1 2 3 4 7 8 f; do
		v=$(((O_D1 & 0x0fffffff) | (0x$nib << 28)))
		echo "A5-$nib: DSP_CTRL1 top nibble 0x$nib ($(hx $v)), SYS_CTRL bit17 set."
		vop_apply 0x14 "$(hx $v)"
		sleep 3
		ask_change "A5-dsp-ctrl1-top-nibble-$nib"
		last_changed && break
	done
fi

section "Stage B: windows back on, framebuffer white, cumulative Radxa-style VOP registers"
fb_fill 255 255 255
restore_vop
sleep 3
dsi1_int
ask_change "B1-all-restored-fb-white"

stage_b() {
	local label="$1"
	shift
	echo "$label"
	vop_apply "$@"
	sleep 3
	dsi1_int
	ask_change "$label"
}

stage_b "B2-dclk-pol-0" 0x14 "$(hx $((O_D1 & ~0x80000000)))"
last_changed || stage_b "B3-plus-win0-alpha-00ff0000" 0x60 0x00ff0000
last_changed || stage_b "B4-plus-win2-off" 0xb0 "$(hx $((O_W2 & ~1)))"
last_changed || stage_b "B5-plus-sys-ctrl-bit17" 0x08 "$(hx $((O_SYS | 0x20000)))"
last_changed || stage_b "B6-plus-dsp-ctrl1-radxa-e443" 0x14 0x0000e443

if last_changed; then
	echo
	echo ">>> The last step made the panel change. The registers are restored on exit, so report"
	echo ">>> the label above and its description; it identifies the kernel patch to write."
fi

section "S1: registers at the end (before restore)"
for off in 0x08 0x0c 0x14 0x18 0x30 0x40 0x60 0xb0; do
	printf '  %s+%-5s = %s\n' "$VOPN" "$off" "$(rd $VOP $off)"
done

summary
