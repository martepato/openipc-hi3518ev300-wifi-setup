# Xiaomi MJSXJ02HL (Hi3518EV300 + Realtek RTL8189FTV on SDIO)
#
# Derived from the device's own bring-up sequence in
# https://github.com/OpenIPC/device-mjsxj02hl
#   -> flash/autoconfig/etc/network/interfaces.d/wlan0
#
# There is no power-enable GPIO on this board. What the register writes do:
#
#   0x112C0048..0x112C0064   IOCFG (pin mux) for the SDIO1 pin group -- mux
#                            the pads to their SDIO function and set drive
#                            strength/pull. 0x1D54 is the clock pin, which
#                            wants a different setting from the five
#                            data/cmd pins at 0x1174.
#   0x10020028               mmc1 (SDHCI base 0x10020000) + 0x28. Toggling
#                            bit 27 makes the controller re-latch card
#                            presence, which is this SoC's equivalent of the
#                            Ingenic "INSERT" poke that set_mmc() does --
#                            without it the MMC core scans once at boot,
#                            finds nothing, and never looks again.
#
# cfg80211 is loaded first and given a moment to settle before 8189fs, which
# is what the stock configuration does; the driver is built with
# CONFIG_IOCTL_CFG80211 and registers a wiphy, so wpa_supplicant and hostapd
# both drive it through nl80211.
if [ "$1" = "rtl8189fs-hi3518ev300-mjsxj02hl" ]; then
	devmem 0x112C0048 32 0x1D54
	devmem 0x112C004C 32 0x1174
	devmem 0x112C0064 32 0x1174
	devmem 0x112C0060 32 0x1174
	devmem 0x112C005C 32 0x1174
	devmem 0x112C0058 32 0x1174
	devmem 0x10020028 32 0x28000000
	devmem 0x10020028 32 0x20000000
	modprobe cfg80211
	sleep 2
	modprobe 8189fs
	exit 0
fi
