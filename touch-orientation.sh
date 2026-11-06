#!/usr/bin/env bash
# Switch touch orientation for ft5406-touchd without editing files by hand.
#
#   sudo ./touch-orientation.sh 180      invert both axes (touch landed in the opposite quadrant)
#   sudo ./touch-orientation.sh 90       rotate touch 90 deg clockwise (drag left = cursor down,
#                                        drag right = up, drag up = left, drag down = right)
#   sudo ./touch-orientation.sh 270      rotate touch 90 deg counter-clockwise (the opposite of 90)
#   sudo ./touch-orientation.sh normal   no transform
#   sudo ./touch-orientation.sh toggle   flip between normal and 180 (anything else -> normal)
#   ./touch-orientation.sh status        show the current setting
#
# Edits FT5406_TOUCHD_ARGS in /etc/default/ft5406-touchd (only the --rotate-90,
# --rotate-180, --rotate-270, --swap-xy, --invert-x and --invert-y words; other
# options are kept) and restarts the service.

set -euo pipefail

DEFAULTS_FILE=${DEFAULTS_FILE:-/etc/default/ft5406-touchd}
SERVICE=${SERVICE:-ft5406-touchd.service}
SYSTEMCTL=${SYSTEMCTL:-systemctl}

current_args() {
	[[ -f $DEFAULTS_FILE ]] || { echo ""; return; }
	sed -n 's/^FT5406_TOUCHD_ARGS=//p' "$DEFAULTS_FILE" | tail -n 1 | sed 's/^"\(.*\)"$/\1/; s/^'"'"'\(.*\)'"'"'$/\1/'
}

has_word() {
	[[ " $1 " == *" $2 "* ]]
}

current_mode() {
	if has_word "$1" --rotate-90; then echo 90
	elif has_word "$1" --rotate-270; then echo 270
	elif has_word "$1" --rotate-180; then echo 180
	elif has_word "$1" --swap-xy && has_word "$1" --invert-y && ! has_word "$1" --invert-x; then echo 90
	elif has_word "$1" --swap-xy && has_word "$1" --invert-x && ! has_word "$1" --invert-y; then echo 270
	elif has_word "$1" --invert-x && has_word "$1" --invert-y && ! has_word "$1" --swap-xy; then echo 180
	else echo normal
	fi
}

strip_orientation() {
	local out="" w
	for w in $1; do
		case $w in
			--rotate-90|--rotate-180|--rotate-270|--swap-xy|--invert-x|--invert-y) ;;
			*) out+="${out:+ }$w" ;;
		esac
	done
	echo "$out"
}

args="$(current_args)"
mode="${1:-status}"

if [[ $mode == status ]]; then
	echo "touch orientation: $(current_mode "$args") (args: ${args:-none})"
	exit 0
fi

[[ $EUID -eq 0 ]] || exec sudo "$0" "$@"

if [[ $mode == toggle ]]; then
	if [[ $(current_mode "$args") == normal ]]; then mode=180; else mode=normal; fi
fi

base="$(strip_orientation "$args")"
case "$mode" in
	90|180|270) new="${base:+$base }--rotate-$mode" ;;
	normal) new="$base" ;;
	*) echo "usage: $0 90|180|270|normal|toggle|status"; exit 2 ;;
esac

if [[ -f $DEFAULTS_FILE ]] && grep -q '^FT5406_TOUCHD_ARGS=' "$DEFAULTS_FILE"; then
	sed -i "s|^FT5406_TOUCHD_ARGS=.*|FT5406_TOUCHD_ARGS=\"$new\"|" "$DEFAULTS_FILE"
else
	echo "FT5406_TOUCHD_ARGS=\"$new\"" >> "$DEFAULTS_FILE"
fi
echo "FT5406_TOUCHD_ARGS=\"$new\""
$SYSTEMCTL restart "$SERVICE"
echo "touch orientation set to $mode"
