#!/usr/bin/env bash
# TEST 0001: TC358762 initialisation variants, applied live (no kernel rebuild)
#
# Question: is the bridge's register sequence, value set or timing the problem?
# Each variant power-cycles the bridge through the ATTiny (like Radxa does), then
# programs the bridge register by register through the tc358762 debugfs file,
# with the DSI host already in video mode (same stage as Radxa's BSP).
#
#   A  control: Radxa's exact values and order, no delays (what the kernel does)
#   B  Radxa's values with the 100 ms pauses the mainline/Pi driver uses
#   C  mainline (Raspberry Pi) values: CLRSIPOCOUNT 5, LPTXTIMECNT 3, SPICMR 0,
#      LCDCTRL 0x1a0150, no LCD timing registers
#   D  C with Radxa's PPI timing (CLRSIPOCOUNT 0x0c, LPTXTIMECNT 0x15)
#   E  B after a 3 s settle time following the MCU power cycle
#
# Run:  sudo ./tests/0001-bridge-init-variants.sh 2>&1 | tee ~/0001-run.txt
# Optional: VPG=1 sudo -E ./tests/0001-bridge-init-variants.sh ...   (host colour bars as the
# video source, use it if test 0000 showed nothing)

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "$HERE/common.sh"

t_root "$@"
t_prereq
header 0001 "bridge initialisation variants (VPG=${VPG:-0})"

cleanup() {
	echo
	echo "--- restoring: normal MCU power-up and bridge init ---"
	vpg_off
	act 3
}
trap cleanup EXIT

[[ ${VPG:-0} == 1 ]] && vpg_on

# Radxa values, Radxa order. $1 = pause between SYSCTRL, STARTPPI/STARTDSI
init_radxa() {
	poke 0x210 0x3
	poke 0x164 0x0c
	poke 0x168 0x0c
	poke 0x144 0
	poke 0x148 0
	poke 0x114 0x15
	poke 0x450 0x60
	poke 0x420 0x00100152
	poke 0x424 0x001a0014
	poke 0x428 0x00690320
	poke 0x42c 0x00150002
	poke 0x430 0x000701e0
	poke 0x434 1
	poke 0x464 0x040f
	sleep "$1"
	poke 0x104 1
	poke 0x204 1
	sleep "$1"
	poke 0x410 3
}

# mainline / Raspberry Pi values (800x480, NHSYNC|NVSYNC)
init_mainline() {
	poke 0x210 0x3
	poke 0x164 5
	poke 0x168 5
	poke 0x144 0
	poke 0x148 0
	poke 0x114 3
	poke 0x450 0
	poke 0x420 0x001a0150
	poke 0x464 0x040f
	sleep "$1"
	poke 0x104 1
	poke 0x204 1
	sleep "$1"
}

# mainline values with Radxa's PPI timing
init_hybrid() {
	poke 0x210 0x3
	poke 0x164 0x0c
	poke 0x168 0x0c
	poke 0x144 0
	poke 0x148 0
	poke 0x114 0x15
	poke 0x450 0
	poke 0x420 0x001a0150
	poke 0x464 0x040f
	sleep "$1"
	poke 0x104 1
	poke 0x204 1
	sleep "$1"
}

# run_variant <name> <settle seconds after MCU cycle> <function> <pause arg>
run_variant() {
	local name="$1" settle="$2"
	shift 2
	section "Variant $name"
	dmesg_mark
	act 2
	sleep "$settle"
	ask_change "$name: after MCU power cycle only"
	"$@"
	sleep 3
	dsi1_int
	ask_change "$name: after bridge programming"
	dmesg_new
}

run_variant "A-radxa-control-no-delays" 1 init_radxa 0
run_variant "B-radxa-values-100ms-delays" 1 init_radxa 0.1
run_variant "C-mainline-values" 1 init_mainline 0.1
run_variant "D-mainline-with-radxa-ppi-timing" 1 init_hybrid 0.1
run_variant "E-radxa-values-3s-settle" 3 init_radxa 0.1

section "Final: normal kernel bring-up (action 3)"
trap - EXIT
vpg_off
act 3
sleep 3
ask_change "final-normal-bringup"
dsi1_int
summary
