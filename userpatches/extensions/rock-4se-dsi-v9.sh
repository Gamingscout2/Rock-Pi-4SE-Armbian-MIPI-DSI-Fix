#!/usr/bin/env bash
# Enables the v9 DSI panel overlay and the FT5406 touch service in the image.
# Enabled by config-enable_v9.conf:  ./compile.sh enable_v9
#
# The kernel, its patches and its config are the same as without enable_v9. This runs
# install.sh --variant v9 from overlay/rock-4se-dsi/ in the image chroot, the same way it
# is run on a booted board.

declare -g ROCK_4SE_DSI_SRC="${USERPATCHES_PATH}/overlay/rock-4se-dsi"
declare -g ROCK_4SE_DSI_OVERLAY="rock-4se-rpi7-radxa-vopl-fix"

function extension_prepare_config__rock_4se_dsi_v9() {
	[[ "${BOARD}" == "rock-4se" ]] || exit_with_error "enable_v9 is for the ROCK 4SE only" "BOARD=${BOARD}"

	# v9 needs the patched kernel; with a stock kernel the panel stays dark
	declare patch_dir="${USERPATCHES_PATH}/kernel/archive/${LINUXFAMILY}-${KERNEL_MAJOR_MINOR}"
	compgen -G "${patch_dir}/*tc358762-rpi7-radxa-bringup.patch" > /dev/null ||
		exit_with_error "enable_v9: no DSI kernel patches for Linux ${KERNEL_MAJOR_MINOR} (BRANCH=${BRANCH})" "${patch_dir}"

	declare file
	for file in install.sh "overlays/${ROCK_4SE_DSI_OVERLAY}.dts" touch/ft5406_touchd.py touch/ft5406-touchd.service; do
		[[ -f "${ROCK_4SE_DSI_SRC}/${file}" ]] || exit_with_error "enable_v9: file missing" "${ROCK_4SE_DSI_SRC}/${file}"
	done
}

function post_customize_image__rock_4se_dsi_v9() {
	declare work="/tmp/rock-4se-dsi" kernel_version
	kernel_version="$(ls -1 "${SDCARD}/lib/modules" | sort -V | tail -n 1)"
	[[ -n "${kernel_version}" ]] || exit_with_error "enable_v9: no kernel modules in the image" "${SDCARD}/lib/modules"

	# install.sh would apt-get these itself
	declare -a packages=()
	[[ -x "${SDCARD}/usr/bin/dtc" ]] || packages+=(device-tree-compiler)
	[[ -x "${SDCARD}/usr/bin/python3" ]] || packages+=(python3)
	[[ ${#packages[@]} -eq 0 ]] || chroot_sdcard_apt_get_install "${packages[@]}"

	rm -rf "${SDCARD}${work}"
	cp -r "${ROCK_4SE_DSI_SRC}" "${SDCARD}${work}"
	# No systemd runs in the chroot and install.sh uses "set -euo pipefail", so daemon-reload
	# must not fail. "systemctl enable" works offline in a chroot and is passed through.
	printf '#!/bin/sh\n[ "$1" = daemon-reload ] && exit 0\nexec systemctl "$@"\n' > "${SDCARD}${work}/systemctl"
	chmod +x "${SDCARD}${work}/systemctl"

	# MODINFO: check the image's kernel for the panel drivers, not the build host's
	chroot_sdcard "SYSTEMCTL=${work}/systemctl MODINFO='modinfo -k ${kernel_version}' bash ${work}/install.sh --variant v9" ||
		exit_with_error "enable_v9: install.sh --variant v9 failed in the image"

	rm -rf "${SDCARD}${work}"
	rm -f "${SDCARD}"/boot/armbianEnv.txt.bak-*
	display_alert "DSI panel enabled" "$(grep '^user_overlays=' "${SDCARD}/boot/armbianEnv.txt")" "info"
}

function image_specific_armbian_env_ready__rock_4se_dsi_v9() {
	grep -Eq "^user_overlays=(.* )?${ROCK_4SE_DSI_OVERLAY}( |$)" "${SDCARD}/boot/armbianEnv.txt" ||
		exit_with_error "enable_v9: ${ROCK_4SE_DSI_OVERLAY} is missing from user_overlays" "${SDCARD}/boot/armbianEnv.txt"
}
