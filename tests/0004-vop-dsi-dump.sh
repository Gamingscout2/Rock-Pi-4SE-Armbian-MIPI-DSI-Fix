#!/usr/bin/env bash
# TEST 0004: read-only dump of VOP, DSI0/DSI1 and GRF registers (Armbian AND Radxa OS)
#
# Purpose: compare the VOP -> DSI configuration of the working Radxa OS with Armbian.
# Nothing is written. Run it twice and keep both outputs:
#
#   Radxa OS (picture visible):  sudo ./tests/0004-vop-dsi-dump.sh 2>&1 | tee ~/0004-radxa.txt
#   Armbian  (v8-vopl overlay):  sudo ./tests/0004-vop-dsi-dump.sh 2>&1 | tee ~/0004-armbian.txt
#
# Only VOPs whose clocks are enabled are read (reading a clock-gated block can hang the
# board). If the debugfs clock files do not exist (Radxa), set FORCE_VOPL=1 or FORCE_VOPB=1:
#   sudo FORCE_VOPL=1 ./tests/0004-vop-dsi-dump.sh
# Radxa routes DSI1 from VOPL (ff8f0000), so FORCE_VOPL=1 is the one to use there.
#
# Needs busybox (devmem). No test-specific debugfs files are needed.

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "$HERE/common.sh"

t_root "$@"
command -v busybox >/dev/null 2>&1 || { echo "FATAL: busybox missing: sudo apt install busybox"; exit 1; }
mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug 2>/dev/null

section "TEST 0004: VOP / DSI / GRF register dump (read-only)"
date -Is
hostname
uname -a
cat /proc/cmdline
grep '^user_overlays=' /boot/armbianEnv.txt 2>/dev/null
grep -E '^(fdtoverlays|label|menu label)' /boot/extlinux/extlinux.conf 2>/dev/null | head -n 4

clk_count() {
	cat "/sys/kernel/debug/clk/$1/clk_enable_count" 2>/dev/null || echo "?"
}

section "Clock enable counts"
for c in aclk_vop0 hclk_vop0 dclk_vop0 aclk_vop1 hclk_vop1 dclk_vop1 pclk_mipi_dsi0 pclk_mipi_dsi1; do
	printf '  %-16s %s\n' "$c" "$(clk_count $c)"
done
echo "--- clk_summary (VOP / DSI related) ---"
grep -E 'dclk_vop|aclk_vop|hclk_vop|pclk_mipi_dsi|mipidphy' /sys/kernel/debug/clk/clk_summary 2>/dev/null

section "GRF (base 0xff770000)"
for off in 0x6250 0x6254 0x6258 0x625c 0x6260; do
	printf '  GRF+%s = %s\n' "$off" "$(rd 0xff770000 $off)"
done
echo "  (SOC_CON20 at +0x6250: 0x249 = DSI1 on VOPB, 0x259 = VOPL)"

section "Interrupt counts (two samples, 2 s apart: VOP frame interrupts must increase)"
grep -iE 'vop|dsi' /proc/interrupts
sleep 2
grep -iE 'vop|dsi' /proc/interrupts

# dump_block <name> <base> <first> <last>
dump_block() {
	local name="$1" base="$2" off
	echo "--- $name @ $base ---"
	for ((off = $3; off <= $4; off += 4)); do
		printf '%s+0x%03x = %s\n' "$name" "$off" "$(rd "$base" "$off")"
	done
}

section "VOP registers"
vop_dump() {
	local name="$1" base="$2" force="$3" a h
	a="$(clk_count "aclk_$4")"
	h="$(clk_count "hclk_$4")"
	if [[ $force == 1 || ( $a =~ ^[0-9]+$ && $a -ge 1 && $h =~ ^[0-9]+$ && $h -ge 1 ) ]]; then
		dump_block "$name" "$base" 0 764
	else
		echo "$name skipped (aclk=$a hclk=$h; set FORCE_${name}=1 to read it anyway)"
	fi
}
vop_dump VOPL 0xff8f0000 "${FORCE_VOPL:-0}" vop1
vop_dump VOPB 0xff900000 "${FORCE_VOPB:-0}" vop0

section "DSI host registers (INT_ST0/1 at 0xbc/0xc0 are not read: they clear on read)"
dsi_dump() {
	local name="$1" base="$2" c
	c="$(clk_count "$3")"
	if [[ $c =~ ^[0-9]+$ && $c -ge 1 ]] || [[ ${FORCE_DSI:-0} == 1 ]]; then
		local off
		echo "--- $name @ $base ---"
		for ((off = 0; off <= 0xb8; off += 4)); do
			printf '%s+0x%02x = %s\n' "$name" "$off" "$(rd "$base" "$off")"
		done
		printf '%s+0xc4 = %s\n' "$name" "$(rd "$base" 0xc4)"
	else
		echo "$name skipped (pclk enable count '$c'; set FORCE_DSI=1 to read anyway)"
	fi
}
dsi_dump DSI0 0xff960000 pclk_mipi_dsi0
dsi_dump DSI1 0xff968000 pclk_mipi_dsi1

section "DRM state (CRTC / connector lines)"
grep -E 'crtc\[|mode:|connector\[|enable=|active=' /sys/kernel/debug/dri/0/state 2>/dev/null | head -n 30

section "DONE (nothing was written)"
