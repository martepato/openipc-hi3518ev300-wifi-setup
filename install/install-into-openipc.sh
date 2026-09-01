#!/bin/sh
#
# Copyright (c) OpenIPC  https://openipc.org  MIT License
#
# install-into-openipc.sh -- graft the wifi-provision package into an OpenIPC
# firmware checkout.
#
#   git clone https://github.com/OpenIPC/firmware.git
#   ./install/install-into-openipc.sh ../firmware
#   cd ../firmware && make BOARD=hi3518ev300_lite
#
# Idempotent: running it twice makes no further changes. Nothing outside the
# three touched paths is modified, and each is reported.

set -eu

SELF=$(cd "$(dirname "$0")/.." && pwd)
DEST=${1:-}
ENABLE_DEFCONFIG=${2:-}
BOARD_PROFILE=${3:-}

usage() {
	cat <<'USAGE'
Usage: install-into-openipc.sh <path-to-openipc-firmware> [defconfig-name] [board-profile]

  <path-to-openipc-firmware>  A checkout of https://github.com/OpenIPC/firmware
  [defconfig-name]            Optional: also enable the package in this
                              board defconfig, e.g. hi3518ev300_lite
  [board-profile]             Optional: also add a Wi-Fi bring-up profile to
                              general/overlay/etc/wireless/sdio. Available:
                                mjsxj02hl   Xiaomi MJSXJ02HL (RTL8189FTV)

Without a defconfig name the package is installed but left unselected; turn
it on with `make menuconfig` under "External options", or by adding
BR2_PACKAGE_WIFI_PROVISION=y to your board defconfig by hand.
USAGE
}

[ -n "$DEST" ] || { usage >&2; exit 1; }
case "$DEST" in -h|--help) usage; exit 0 ;; esac

[ -d "$DEST" ] || { echo "install: '$DEST' is not a directory" >&2; exit 1; }
[ -d "$DEST/general/package" ] || {
	echo "install: '$DEST' does not look like an OpenIPC firmware checkout" >&2
	echo "         (expected to find general/package/ under it)" >&2
	exit 1
}

PKG_DST=$DEST/general/package/wifi-provision
CONFIG_IN=$DEST/general/package/Config.in

# --------------------------------------------------------------- 1. package --
echo "==> installing package into general/package/wifi-provision"
rm -rf "$PKG_DST"
mkdir -p "$PKG_DST"
cp -R "$SELF/package/wifi-provision/." "$PKG_DST/"
cp "$SELF/LICENSE" "$PKG_DST/LICENSE"
find "$PKG_DST" -name '*.sh' -exec chmod 755 {} +
chmod 755 "$PKG_DST/files/usr/sbin"/* \
          "$PKG_DST/files/etc/init.d"/* \
          "$PKG_DST/files/var/www-wifi/cgi-bin"/*

# ------------------------------------------------------------- 2. Config.in --
SRC_LINE='source "$BR2_EXTERNAL_GENERAL_PATH/package/wifi-provision/Config.in"'
if grep -qF "$SRC_LINE" "$CONFIG_IN"; then
	echo "==> general/package/Config.in already references the package"
else
	echo "==> adding the package to general/package/Config.in"
	# Insert one line in sorted position and leave every other byte alone.
	# Re-sorting the whole file would also work as Kconfig, but the file has
	# a trailing "# Legacy" section whose entries sort in among the main
	# ones -- that turns a one-line diff against upstream into a 150-line
	# one and loses the section structure.
	awk -v new="$SRC_LINE" '
		BEGIN { done = 0 }
		# Stop considering insertion points once the Legacy section starts.
		/^# Legacy/ { stop = 1 }
		{
			if (!done && !stop && /^source /  && $0 > new) {
				print new
				done = 1
			}
			print
		}
		END { if (!done) print new }
	' "$CONFIG_IN" > "$CONFIG_IN.new"
	mv "$CONFIG_IN.new" "$CONFIG_IN"
fi

# ------------------------------------------------------------ 3. defconfig --
if [ -n "$ENABLE_DEFCONFIG" ]; then
	DEFCONFIG=$(find "$DEST"/br-ext-chip-*/configs -name "${ENABLE_DEFCONFIG}_defconfig" 2>/dev/null | head -1)
	if [ -z "$DEFCONFIG" ]; then
		echo "install: no defconfig named '${ENABLE_DEFCONFIG}_defconfig'" >&2
		echo "         available:" >&2
		find "$DEST"/br-ext-chip-*/configs -name '*_defconfig' -exec basename {} _defconfig \; |
			sed 's/^/           /' >&2
		exit 1
	fi
	echo "==> enabling the package in $(basename "$DEFCONFIG")"
	for sym in \
		'BR2_PACKAGE_WIFI_PROVISION=y' \
		'BR2_PACKAGE_WIFI_PROVISION_CAPTIVE_DNS=y' \
		'BR2_PACKAGE_RTW_HOSTAPD=y' \
		'BR2_PACKAGE_RTW_HOSTAPD_DRIVER_NL80211=y' \
		'BR2_PACKAGE_RTW_HOSTAPD_DRIVER_RTW=y' \
		'BR2_PACKAGE_WPA_SUPPLICANT=y' \
		'BR2_PACKAGE_WPA_SUPPLICANT_CLI=y' \
		'BR2_PACKAGE_WPA_SUPPLICANT_PASSPHRASE=y'
	do
		if grep -qxF "$sym" "$DEFCONFIG"; then
			echo "    already set: $sym"
		else
			printf '%s\n' "$sym" >> "$DEFCONFIG"
			echo "    added:       $sym"
		fi
	done
	cat <<WARN

    NOTE: no Wi-Fi *driver* was enabled -- that choice depends on which radio
    is fitted to your board, which this script cannot know. See
    docs/02-hardware.md, then add the matching driver symbol, for example:

        BR2_PACKAGE_RTL8189FS_OPENIPC=y     # Realtek RTL8189FTV, SDIO
        BR2_PACKAGE_RTL8189ES_OPENIPC=y     # Realtek RTL8189ES, SDIO
        BR2_PACKAGE_ATBM_WIFI=y             # Altobeam ATBM603x, SDIO
        BR2_PACKAGE_AIC8800_OPENIPC=y       # AIC AIC8800, SDIO
WARN
fi

# ------------------------------------------------------- 4. board profile --
if [ -n "$BOARD_PROFILE" ]; then
	PROFILE_SRC=$SELF/install/board-profiles/$BOARD_PROFILE.sh
	SDIO_DISPATCH=$DEST/general/overlay/etc/wireless/sdio
	if [ ! -f "$PROFILE_SRC" ]; then
		echo "install: no board profile named '$BOARD_PROFILE'" >&2
		echo "         available:" >&2
		for p in "$SELF"/install/board-profiles/*.sh; do
			[ -e "$p" ] || continue
			b=${p##*/}
			echo "           ${b%.sh}" >&2
		done
		exit 1
	fi
	[ -f "$SDIO_DISPATCH" ] || {
		echo "install: $SDIO_DISPATCH not found" >&2
		exit 1
	}
	# The dispatcher is a chain of `if [ "$1" = ... ]` blocks ending in
	# `exit 1`. A new profile has to land BEFORE that final exit, so insert
	# rather than append.
	PROFILE_TAG=$(sed -n 's/^if \[ "\$1" = "\([^"]*\)" \]; then$/\1/p' "$PROFILE_SRC" | head -1)
	if grep -qF "\"$PROFILE_TAG\"" "$SDIO_DISPATCH"; then
		echo "==> board profile '$PROFILE_TAG' is already in etc/wireless/sdio"
	else
		echo "==> adding board profile '$PROFILE_TAG' to etc/wireless/sdio"
		awk -v prof="$PROFILE_SRC" '
			/^exit 1$/ && !done {
				while ((getline line < prof) > 0) print line
				close(prof)
				print ""
				done = 1
			}
			{ print }
		' "$SDIO_DISPATCH" > "$SDIO_DISPATCH.new"
		mv "$SDIO_DISPATCH.new" "$SDIO_DISPATCH"
		chmod 755 "$SDIO_DISPATCH"
	fi
	echo "    set it on the camera with:  fw_setenv wlandev $PROFILE_TAG"
fi

cat <<'DONE'

==> done.

Next steps:
  1. Enable the driver for your Wi-Fi chip (see docs/02-hardware.md).
  2. Add a board profile to general/overlay/etc/wireless/sdio if your board
     needs a power or reset GPIO before the chip enumerates.
  3. Build:   make BOARD=hi3518ev300_lite
  4. Set the profile on the camera:  fw_setenv wlandev <profile-name>
DONE
