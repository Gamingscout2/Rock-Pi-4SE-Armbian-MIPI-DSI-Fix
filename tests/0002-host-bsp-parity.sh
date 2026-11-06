#!/usr/bin/env bash
# TEST 0002: DSI host parity with Radxa's BSP, applied live to DSI1 (no kernel rebuild)
#
# Question: do the remaining host-side register differences matter for the bridge?
# Radxa (BSP, working) vs Armbian (mainline) on DSI1:
#   CLKMGR_CFG (0x08)         0x00000a05   vs 0x00000005   (TO_CLK_DIVISION 10 vs 0)
#   TO_CNT_CFG (0x78)         0x03e803e8   vs 0x00000000   (HS/LP timeouts 1000 vs off)
#   BTA_TO_CNT (0x8c)         0x00000d00   (same)
#   PHY_TMR_LPCLK_CFG (0x98)  0x00400040   vs 0x0028005f
#   PHY_TMR_CFG (0x9c)        0x14102710   vs 0x1c4d2710
# Source: docs/phaedra/other-debug/old/RADXA-phase3b-20261029-173032/dsi-registers-radxa.txt
#
# Steps are cumulative. After each one the bridge is power-cycled and reprogrammed
# (action 3) so it sees the new link. Originals are restored at the end.
# The DSI1 host is put in reset (PWR_UP=0) only while those registers are written.
#
# Run:  sudo ./tests/0002-host-bsp-parity.sh 2>&1 | tee ~/0002-run.txt
# Optional: VPG=1 sudo -E ./tests/0002-host-bsp-parity.sh ...   (host colour bars as source)

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "$HERE/common.sh"

t_root "$@"
t_prereq
header 0002 "DSI host parity with Radxa BSP (VPG=${VPG:-0})"

O_CLK="$(rd $DSI1 0x08)"
O_TO="$(rd $DSI1 0x78)"
O_BTA="$(rd $DSI1 0x8c)"
O_TMRL="$(rd $DSI1 0x98)"
O_TMR="$(rd $DSI1 0x9c)"
echo "Originals: CLKMGR=$O_CLK TO_CNT=$O_TO BTA_TO=$O_BTA PHY_TMR_LPCLK=$O_TMRL PHY_TMR=$O_TMR"

# apply_host <offset> <value> [<offset> <value> ...]: write with PWR_UP held low
apply_host() {
	wr $DSI1 0x04 0x00000000
	while (($# >= 2)); do
		wr $DSI1 "$1" "$2"
		shift 2
	done
	wr $DSI1 0x04 0x00000001
}

restore_host() {
	echo
	echo "--- restoring original DSI1 host values ---"
	apply_host 0x08 "$O_CLK" 0x78 "$O_TO" 0x8c "$O_BTA" 0x98 "$O_TMRL" 0x9c "$O_TMR"
	vpg_off
	act 3
}
trap restore_host EXIT

[[ ${VPG:-0} == 1 ]] && vpg_on

# step <label> <offset value ...>
step() {
	local label="$1"
	shift
	section "Step $label"
	dmesg_mark
	apply_host "$@"
	sleep 2
	dsi1_regs
	dsi1_int
	ask_change "$label: after host change"
	act 3
	sleep 3
	dsi1_int
	ask_change "$label: after MCU power cycle + bridge reprogram"
	dmesg_new
}

step "S1-clkmgr-0a05" 0x08 0x00000a05
step "S2-plus-timeouts" 0x08 0x00000a05 0x78 0x03e803e8 0x8c 0x00000d00
step "S3-plus-phy-timing" 0x08 0x00000a05 0x78 0x03e803e8 0x8c 0x00000d00 \
	0x98 0x00400040 0x9c 0x14102710

if [[ -f $HERE/../dsi0-mirror.sh ]]; then
	section "Step S4: S3 plus the DSI0 host mirrored from Radxa (dsi0-mirror.sh)"
	dmesg_mark
	bash "$HERE/../dsi0-mirror.sh"
	sleep 2
	ask_change "S4-dsi0-mirror: after DSI0 change"
	act 3
	sleep 3
	dsi1_int
	ask_change "S4-dsi0-mirror: after MCU power cycle + bridge reprogram"
	dmesg_new
	bash "$HERE/../dsi0-mirror.sh" --undo
fi

section "Final: originals restored, normal bring-up"
trap - EXIT
restore_host
sleep 3
ask_change "final-restored"
dsi1_regs
summary
