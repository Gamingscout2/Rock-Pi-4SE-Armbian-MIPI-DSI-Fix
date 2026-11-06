#!/usr/bin/env bash
# TEST 0000: DSI host pattern generator + backlight sanity (no kernel rebuild)
#
# Question: does ANYTHING appear when the DSI host itself generates the picture
# (its built-in video pattern generator, VID_MODE_CFG bit 16, bypasses the VOP)?
#   colour bars  -> host, link, bridge and panel are fine; the problem is the
#                   VOP -> DSI pixel path
#   still black  -> the problem is on the DSI -> bridge -> panel side
#
# Run:  sudo ./tests/0000-host-pattern.sh 2>&1 | tee ~/0000-run.txt
# Needs overlay v8 / v8-pre / v8-vopl and the Build 34 kernel. Reboot undoes everything.

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "$HERE/common.sh"

t_root "$@"
t_prereq
header 0000 "DSI host pattern generator and backlight"
dmesg_mark

ORIG="$(rd $DSI1 0x38)"
cleanup() {
	echo
	echo "--- restoring VID_MODE_CFG ---"
	wr $DSI1 0x38 "$ORIG"
}
trap cleanup EXIT

section "Baseline"
dsi1_regs
dsi1_int
ask_yn "Is the panel currently black with a lit backlight?" || {
	read -r -p "Describe what the panel shows now: " base_desc
	echo "BASELINE | not black | $base_desc"
	RESULTS+=("baseline | not black | $base_desc")
}

section "Step 1: host colour bars (vertical), VPG_EN"
wr $DSI1 0x38 "$(printf '0x%08x' $((ORIG | 0x10000)))"
sleep 4
dsi1_int
ask_change "vpg-colour-bars-vertical"

section "Step 2: host BER pattern, VPG_EN + VPG_MODE"
wr $DSI1 0x38 "$(printf '0x%08x' $((ORIG | 0x10000 | 0x100000)))"
sleep 4
dsi1_int
ask_change "vpg-ber-pattern"

section "Step 3: host colour bars (horizontal), VPG_EN + VPG_HORIZONTAL"
wr $DSI1 0x38 "$(printf '0x%08x' $((ORIG | 0x10000 | 0x1000000)))"
sleep 4
dsi1_int
ask_change "vpg-colour-bars-horizontal"

section "Step 4: pattern off again"
wr $DSI1 0x38 "$ORIG"
sleep 2
ask_change "vpg-off"

section "Step 5: backlight off via the ATTiny (PWM=0)"
act 6
sleep 2
ask_change "backlight-off"

section "Step 6: backlight back on (PWM=0xff)"
act 5
sleep 2
ask_change "backlight-on"

dmesg_new
dsi1_regs
summary
