#!/usr/bin/env bash
# Build the mainline ROCK 4SE base DTB, apply each overlay with fdtoverlay and
# check the resulting DSI graph. Runs on any Linux host; no board needed.
# Also checks that userpatches/overlay/rock-4se-dsi/ matches the files it copies.
#
#   tools/validate.sh [path-to-linux-source]
#
# Without an argument, a sparse shallow clone of mainline is made in .cache/.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
build="$repo_root/.cache/build"
linux="${1:-$repo_root/.cache/linux}"

for tool in dtc fdtoverlay fdtget cpp git; do
	command -v "$tool" >/dev/null || { echo "missing tool: $tool (apt install device-tree-compiler cpp git)"; exit 1; }
done

if [[ ! -f "$linux/arch/arm64/boot/dts/rockchip/rk3399-rock-4se.dts" ]]; then
	echo ">> fetching mainline device tree sources into $linux"
	rm -rf "$linux"
	git clone --quiet --depth 1 --filter=blob:none --sparse https://github.com/torvalds/linux.git "$linux"
	git -C "$linux" sparse-checkout set --no-cone \
		'/arch/arm64/boot/dts/rockchip/' '/include/dt-bindings/' '/scripts/dtc/include-prefixes/' \
		'/include/uapi/linux/input-event-codes.h'
fi

mkdir -p "$build"
base_dtb="$build/rk3399-rock-4se.dtb"

echo ">> building base DTB (with __symbols__, like Armbian)"
cpp -nostdinc -undef -D__DTS__ -x assembler-with-cpp \
	-I "$linux/include" -I "$linux/arch/arm64/boot/dts" -I "$linux/scripts/dtc/include-prefixes" \
	"$linux/arch/arm64/boot/dts/rockchip/rk3399-rock-4se.dts" \
	| dtc -q -@ -I dts -O dtb -o "$base_dtb" -

fail=0
expect() {
	local desc="$1" want="$2" got="$3"
	if [[ "$got" == "$want" ]]; then
		echo "   ok   $desc = $got"
	else
		echo "   FAIL $desc: want '$want', got '$got'"
		fail=1
	fi
}

# apply NAME: compiles overlays/NAME.dts and applies it; sets $merged.
apply() {
	local name="$1" dtbo="$build/$1.dtbo"
	merged="$build/rk3399-rock-4se+$1.dtb"
	echo
	echo ">> $name: compiling and applying"
	dtc -@ -Wno-unit_address_vs_reg -I dts -O dtb -o "$dtbo" "$repo_root/overlays/$name.dts"
	fdtoverlay -i "$base_dtb" -o "$merged" "$dtbo"
}

# points FROM PROP TO: FROM's PROP holds TO's phandle.
points() {
	expect "$1 $2 -> $3" "$(fdtget "$merged" "$3" phandle 2>&1)" "$(fdtget "$merged" "$1" "$2" 2>&1)"
}

# link A B: graph endpoints A and B point at each other.
link() {
	points "$1" remote-endpoint "$2"
	points "$2" remote-endpoint "$1"
}

dsi1=/dsi@ff968000
common_checks() {
	expect "$dsi1 status" okay "$(fdtget -t s "$merged" $dsi1 status)"
	expect "/dsi@ff960000 status (unused DSI0)" disabled "$(fdtget -t s "$merged" /dsi@ff960000 status)"
	expect "/i2c@ff110000 status" okay "$(fdtget -t s "$merged" /i2c@ff110000 status)"
	expect "audio codec still on i2c1" everest,es8316 "$(fdtget -t s "$merged" /i2c@ff110000/codec@11 compatible)"
	expect "DSI1 port@0 still fed by VOPs" "endpoint@0 endpoint@1" "$(fdtget -l "$merged" $dsi1/ports/port@0 | xargs)"
}

apply rock-4se-dfr0678-dsi
lcd=/i2c@ff110000/lcd@45
common_checks
expect "$lcd compatible" raspberrypi,7inch-touchscreen-panel "$(fdtget -t s "$merged" $lcd compatible)"
expect "$lcd reg" 69 "$(fdtget "$merged" $lcd reg)"
link $dsi1/ports/port@1/endpoint $lcd/port/endpoint

apply rock-4se-dfr0678-dsi-bridge
mcu=/i2c@ff110000/regulator@45
bridge=$dsi1/bridge@0
common_checks
expect "$mcu compatible" raspberrypi,7inch-touchscreen-panel-regulator "$(fdtget -t s "$merged" $mcu compatible)"
expect "$mcu reg" 69 "$(fdtget "$merged" $mcu reg)"
expect "no legacy lcd@45" "" "$(fdtget -l "$merged" /i2c@ff110000 | grep -x lcd@45 || true)"
expect "$bridge compatible" toshiba,tc358762 "$(fdtget -t s "$merged" $bridge compatible)"
expect "$bridge reg (DSI virtual channel)" 0 "$(fdtget "$merged" $bridge reg)"
expect "$dsi1 #address-cells" 1 "$(fdtget "$merged" $dsi1 '#address-cells')"
expect "/panel compatible" powertip,ph800480t013-idf02 "$(fdtget -t s "$merged" /panel compatible)"
points $bridge vddc-supply $mcu
points /panel power-supply $mcu
points /panel backlight $mcu
link $dsi1/ports/port@1/endpoint $bridge/ports/port@0/endpoint
link $bridge/ports/port@1/endpoint /panel/port/endpoint

apply rock-4se-dfr0678-dsi-bridge-dsi0pll-test
common_checks
mcu=/i2c@ff110000/regulator@45
bridge=$dsi1/bridge@0
expect "$mcu compatible" raspberrypi,7inch-touchscreen-panel-regulator "$(fdtget -t s "$merged" $mcu compatible)"
expect "$mcu reg" 69 "$(fdtget "$merged" $mcu reg)"
expect "no legacy lcd@45" "" "$(fdtget -l "$merged" /i2c@ff110000 | grep -x lcd@45 || true)"
expect "$bridge compatible" toshiba,tc358762 "$(fdtget -t s "$merged" $bridge compatible)"
points "$dsi1" rockchip,dsi-dsi0 /dsi@ff960000
expect "DSI0 display host remains disabled" disabled "$(fdtget -t s "$merged" /dsi@ff960000 status)"

apply rock-4se-dfr0678-dsi-bridge-test-lane594
common_checks
expect "$bridge compatible" toshiba,tc358762 "$(fdtget -t s "$merged" $bridge compatible)"
expect "/panel compatible" powertip,ph800480t013-idf02 "$(fdtget -t s "$merged" /panel compatible)"
points "$dsi1" rockchip,dsi-dsi0 /dsi@ff960000
expect "$dsi1 rockchip,lane-rate" 594 "$(fdtget "$merged" $dsi1 rockchip,lane-rate)"
link $dsi1/ports/port@1/endpoint $bridge/ports/port@0/endpoint
link $bridge/ports/port@1/endpoint /panel/port/endpoint

apply rock-4se-dfr0678-dsi-bridge-test-radxa
common_checks
expect "$bridge compatible" toshiba,tc358762 "$(fdtget -t s "$merged" $bridge compatible)"
expect "$bridge toshiba,radxa-init" "toshiba,radxa-init" "$(fdtget -p "$merged" $bridge | grep -x toshiba,radxa-init || true)"
expect "/panel compatible" panel-dpi "$(fdtget -t s "$merged" /panel compatible)"
expect "/panel pixel clock" 26000000 "$(fdtget "$merged" /panel/panel-timing clock-frequency)"
points "$dsi1" rockchip,dsi-dsi0 /dsi@ff960000
expect "$dsi1 rockchip,lane-rate" 696 "$(fdtget "$merged" $dsi1 rockchip,lane-rate)"
points $bridge vddc-supply $mcu
points /panel power-supply $mcu
points /panel backlight $mcu
link $dsi1/ports/port@1/endpoint $bridge/ports/port@0/endpoint
link $bridge/ports/port@1/endpoint /panel/port/endpoint

apply rock-4se-dfr0678-dsi-bridge-test-radxa-vopl
common_checks
mcu=/i2c@ff110000/regulator@45
bridge=$dsi1/bridge@0
expect "$bridge compatible" toshiba,tc358762 "$(fdtget -t s "$merged" $bridge compatible)"
expect "$bridge toshiba,radxa-init" "toshiba,radxa-init" "$(fdtget -p "$merged" $bridge | grep -x toshiba,radxa-init || true)"
expect "/panel compatible" panel-dpi "$(fdtget -t s "$merged" /panel compatible)"
expect "/panel pixel clock" 26000000 "$(fdtget "$merged" /panel/panel-timing clock-frequency)"
expect "DSI1 VOPB input endpoint disabled" disabled "$(fdtget -t s "$merged" $dsi1/ports/port@0/endpoint@0 status)"
expect "DSI1 VOPL input endpoint enabled" okay "$(fdtget -t s "$merged" $dsi1/ports/port@0/endpoint@1 status)"
points "$dsi1" rockchip,dsi-dsi0 /dsi@ff960000
expect "$dsi1 rockchip,lane-rate" 696 "$(fdtget "$merged" $dsi1 rockchip,lane-rate)"
points $bridge vddc-supply $mcu
points /panel power-supply $mcu
points /panel backlight $mcu
link $dsi1/ports/port@1/endpoint $bridge/ports/port@0/endpoint
link $bridge/ports/port@1/endpoint /panel/port/endpoint

apply rock-4se-dfr0678-dsi-bridge-test-radxa-vopl-simple
common_checks
mcu=/i2c@ff110000/regulator@45
bridge=$dsi1/bridge@0
expect "$bridge compatible" toshiba,tc358762 "$(fdtget -t s "$merged" $bridge compatible)"
expect "$bridge toshiba,radxa-init" "toshiba,radxa-init" "$(fdtget -p "$merged" $bridge | grep -x toshiba,radxa-init || true)"
expect "/panel compatible" powertip,ph800480t013-idf02 "$(fdtget -t s "$merged" /panel compatible)"
expect "/panel has no inline panel-timing" "" "$(fdtget -l "$merged" /panel | grep -x panel-timing || true)"
expect "DSI1 VOPB input endpoint disabled" disabled "$(fdtget -t s "$merged" $dsi1/ports/port@0/endpoint@0 status)"
expect "DSI1 VOPL input endpoint enabled" okay "$(fdtget -t s "$merged" $dsi1/ports/port@0/endpoint@1 status)"
expect "$mcu compatible" raspberrypi,7inch-touchscreen-panel-regulator "$(fdtget -t s "$merged" $mcu compatible)"
expect "$mcu reg" 69 "$(fdtget "$merged" $mcu reg)"
expect "$mcu has no opt-in power sequence" "" "$(fdtget -p "$merged" "$mcu" | grep -x radxa,screen-power-sequence || true)"
points "$dsi1" rockchip,dsi-dsi0 /dsi@ff960000
expect "$dsi1 rockchip,lane-rate" 696 "$(fdtget "$merged" $dsi1 rockchip,lane-rate)"
points $bridge vddc-supply $mcu
points /panel power-supply $mcu
points /panel backlight $mcu
link $dsi1/ports/port@1/endpoint $bridge/ports/port@0/endpoint
link $bridge/ports/port@1/endpoint /panel/port/endpoint

apply rock-4se-dfr0678-dsi-bridge-test-radxa-vopl-simple-mcu-sequence-test
common_checks
mcu=/i2c@ff110000/regulator@45
bridge=$dsi1/bridge@0
expect "$bridge compatible" toshiba,tc358762 "$(fdtget -t s "$merged" $bridge compatible)"
expect "$bridge toshiba,radxa-init" "toshiba,radxa-init" "$(fdtget -p "$merged" $bridge | grep -x toshiba,radxa-init || true)"
expect "/panel compatible" powertip,ph800480t013-idf02 "$(fdtget -t s "$merged" /panel compatible)"
expect "/panel has no inline panel-timing" "" "$(fdtget -l "$merged" /panel | grep -x panel-timing || true)"
expect "DSI1 VOPB input endpoint disabled" disabled "$(fdtget -t s "$merged" $dsi1/ports/port@0/endpoint@0 status)"
expect "DSI1 VOPL input endpoint enabled" okay "$(fdtget -t s "$merged" $dsi1/ports/port@0/endpoint@1 status)"
expect "$mcu compatible" raspberrypi,7inch-touchscreen-panel-regulator "$(fdtget -t s "$merged" $mcu compatible)"
expect "$mcu opt-in power sequence" radxa,screen-power-sequence "$(fdtget -p "$merged" "$mcu" | grep -x radxa,screen-power-sequence || true)"
points "$dsi1" rockchip,dsi-dsi0 /dsi@ff960000
expect "$dsi1 rockchip,lane-rate" 696 "$(fdtget "$merged" $dsi1 rockchip,lane-rate)"
points $bridge vddc-supply $mcu
points /panel power-supply $mcu
points /panel backlight $mcu
link $dsi1/ports/port@1/endpoint $bridge/ports/port@0/endpoint
link $bridge/ports/port@1/endpoint /panel/port/endpoint

echo
echo ">> userpatches/overlay/rock-4se-dsi: the copy that ./compile.sh enable_v9 installs"
for f in install.sh overlays/rock-4se-rpi7-radxa-vopl-fix.dts touch/ft5406_touchd.py touch/ft5406-touchd.service; do
	if diff -q --strip-trailing-cr "$repo_root/$f" "$repo_root/userpatches/overlay/rock-4se-dsi/$f" >/dev/null; then
		echo "   ok   $f"
	else
		echo "   FAIL $f differs from userpatches/overlay/rock-4se-dsi/$f"
		fail=1
	fi
done

echo
if [[ $fail -eq 0 ]]; then
	echo ">> PASS: all eight overlays apply cleanly to mainline rk3399-rock-4se.dtb"
	ls "$build"/*.dtbo | sed 's/^/   /'
else
	echo ">> FAILED"
	exit 1
fi
