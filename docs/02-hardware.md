# Hardware: what is confirmed, what is assumed, what is unknown

Everything below was read out of the OpenIPC firmware tree and the OpenIPC
kernel tree, not from memory. Sources are cited so you can check them.

---

## CONFIRMED

Verified by reading the actual files at the paths given.

### SoC target exists in OpenIPC, with two variants

| | |
|---|---|
| Repository | `https://github.com/OpenIPC/firmware` |
| Board configs | `br-ext-chip-hisilicon/configs/hi3518ev300_lite_defconfig`<br>`br-ext-chip-hisilicon/configs/hi3518ev300_ultimate_defconfig` |
| SoC family (shared board dir) | `hi3516ev200` — `BR2_OPENIPC_SOC_FAMILY="hi3516ev200"` |
| Kernel config | `br-ext-chip-hisilicon/board/hi3516ev200/hi3518ev300.generic.config` |
| Flash budget | 8 MB (`lite`), 16 MB (`ultimate`) |
| CPU | ARM Cortex-A7, EABI, NEON-VFPv4, Thumb-2 |
| libc / toolchain | musl, `arm-openipc-linux-musleabi` |
| Build system | Buildroot **2024.02.10** as a `BR2_EXTERNAL` tree (`general/`) |

### Kernel

| | |
|---|---|
| Source | `https://github.com/openipc/linux`, branch `hisilicon-hi3516ev200` |
| Version | 4.9.x (`BR2_TOOLCHAIN_EXTERNAL_HEADERS_4_9=y`) |
| Arch | `CONFIG_ARCH_HISI_BVT=y`, `CONFIG_ARCH_HI3518EV300=y` |
| Device tree | **Appended DTB** — `CONFIG_ARM_APPENDED_DTB=y`, `CONFIG_USE_OF=y` |
| Modules | `CONFIG_MODULES=y`, `CONFIG_MODULE_UNLOAD=y` |

Because the DTB is *appended to the kernel image*, any device-tree change
requires rebuilding the kernel — there is no separate `.dtb` to swap on the
flash.

### SDIO host controller — present and enabled

From `hi3518ev300.generic.config`:

```
CONFIG_MMC=y
CONFIG_MMC_SDHCI=y
CONFIG_MMC_SDHCI_PLTFM=y
CONFIG_MMC_SDHCI_HISI=y          # the HiSilicon SDHCI glue, built in
```

From `arch/arm/boot/dts/hi3518ev300.dtsi` in the OpenIPC kernel:

```
mmc0: sdhci@0x10010000 {         mmc1: sdhci@0x10020000 {
    compatible = "hisi-sdhci";       compatible = "hisi-sdhci";
    interrupts = <0 30 4>;           interrupts = <0 31 4>;
    max-frequency = <150000000>;     max-frequency = <50000000>;
    bus-width = <4>;                 bus-width = <4>;
    mmc-hs200-1_8v;                  cap-sd-highspeed;
    devid = <0>;                     devid = <2>;
    status = "enable";               status = "enable";
};                               };
```

and `hi3518ev300-demb.dts` sets both `&mmc0` and `&mmc1` to `status = "okay"`.

The platform driver binds as **`sdhci-hisi`** (`drivers/mmc/host/sdhci-hisi.c`,
`.name = "sdhci-hisi"`). That name matters for the rescan procedure below.

**So: the SDIO host side needs no work.** The controller is compiled in, both
instances are enabled in the reference DTS, and `mmc1` at `0x10020000` with a
50 MHz ceiling is the instance conventionally wired to an SDIO Wi-Fi module on
this SoC.

### Wireless stack

```
CONFIG_CFG80211=y                # built in
CONFIG_MAC80211=m                # module
CONFIG_WIRELESS_EXT=y            # needed by the Realtek out-of-tree drivers
# CONFIG_RFKILL is not set
# CONFIG_CFG80211_WEXT is not set
```

`CONFIG_RFKILL` being off is fine — nothing here uses it.

### SDIO Wi-Fi drivers OpenIPC already packages

These exist today; none needs to be written or imported.

| Package symbol | Chip | Bus | Module |
|---|---|---|---|
| `BR2_PACKAGE_RTL8189FS_OPENIPC` | Realtek RTL8189FTV | SDIO | `8189fs` |
| `BR2_PACKAGE_RTL8189ES_OPENIPC` | Realtek RTL8189ES | SDIO | `8189es` |
| `BR2_PACKAGE_ATBM_WIFI` / `ATBM60XX` | Altobeam ATBM603x | SDIO | `atbm603x_wifi_sdio` |
| `BR2_PACKAGE_AIC8800_OPENIPC` | AIC AIC8800 | SDIO | `aic8800_fdrv` |
| `BR2_PACKAGE_SSV6X5X` / `SSV635X` | South Silicon Valley | SDIO | `ssv6x5x` |

`hi3518ev300_ultimate_defconfig` **already enables `BR2_PACKAGE_RTL8189FS_OPENIPC`**,
which is a strong hint that RTL8189FTV is the radio most commonly seen on
Hi3518EV300 boards. It is a hint, not a fact about *your* board.

### OpenIPC's existing Wi-Fi bring-up

| Path | Role |
|---|---|
| `general/overlay/etc/wireless/sdio` | Per-board profiles: power/reset GPIO, `modprobe`, module args |
| `general/overlay/etc/wireless/usb` | Same for USB radios |
| `general/overlay/etc/init.d/S40network` | Reads `wlandev` from U-Boot env, calls the above, then `ifup wlan0` |
| `general/overlay/etc/network/interfaces.d/wlan0` | Stock stanza: `wpa_passphrase` from `wlanssid`/`wlanpass`, then `wpa_supplicant -B` |

U-Boot environment variables in play: `wlandev` (board profile name),
`wlanssid`, `wlanpass`, `wlanmac`, `ethaddr`, `netaddr_fallback`.

### Userspace already in the image

| Tool | Status |
|---|---|
| `wpa_supplicant` + `wpa_cli` + `wpa_passphrase` | **Enabled in both hi3518ev300 defconfigs** |
| `hostapd` | Packaged as `rtw-hostapd` (hostapd 2.9, with `nl80211` **and** Realtek `rtw` backends). *Not* enabled by default on `lite` |
| BusyBox `httpd` with CGI | `CONFIG_HTTPD=y`, `CONFIG_FEATURE_HTTPD_CGI=y`, `..._ERROR_PAGES=y`, `..._ACL_IP=y` |
| BusyBox `udhcpd` (server) | `CONFIG_UDHCPD=y` |
| BusyBox `udhcpc` (client) | `CONFIG_UDHCPC=y` |
| BusyBox `dnsd` | **`# CONFIG_DNSD is not set`** — and even when built it has no wildcard, which is the only thing a captive portal needs |
| `dnsmasq` | Not packaged in the OpenIPC tree |
| `iw` | Not in the defconfig (we use `wpa_cli` instead — see `docs/01-architecture.md`) |
| `wireless-tools` (`iwlist`) | Enabled |
| `mdnsd` | Packaged as `mdnsd-openipc`, not enabled by default |
| Root filesystem | squashfs (read-only) + jffs2/ubifs overlay via overlayfs — **`/etc` is writable and persists across reboots** |

The missing wildcard DNS is why this project ships a ~15 KB
`wifi-dnsd` rather than a dependency; see `docs/01-architecture.md`.

---

## ASSUMED

Reasonable defaults chosen so the work could proceed. Each is a one-line
change if wrong, and each is called out where it is set.

1. **The Wi-Fi module is on `mmc1`** (`0x10020000`), the 50 MHz SDIO
   instance, with `mmc0` used for eMMC/SD if anything. This is the
   conventional wiring on this SoC and matches the DTS capability flags.
   *If wrong:* the module simply will not enumerate; see diagnostics below.
2. **The radio is 2.4 GHz only.** The provisioning AP is configured
   `hw_mode=g`, channel 6. Every SDIO radio in OpenIPC's package list is
   2.4 GHz-only. Change `WIFI_AP_CHANNEL` in `/etc/wifi/wifi.defaults` if
   yours is not.
3. **The driver supports AP mode.** Required for the setup hotspot. True for
   RTL8189FS/ES with `rtw-hostapd`, and for the mac80211-based chips. If it
   is not, `hostapd` fails to start, the failure is logged plainly, and the
   camera still boots and still works as a station — the setup page is just
   unavailable. See `docs/07-troubleshooting.md`.
4. **Single virtual interface.** The setup AP and the station cannot run at
   the same time. This drives the whole "test then commit" design in
   `docs/01-architecture.md` §5.
5. **Board profile name.** The examples use `rtl8189fs-generic`, which is a
   real entry in `/etc/wireless/sdio`. Yours may need a new entry.

---

## ANSWERED for one device: Xiaomi MJSXJ02HL

If your camera is a **Xiaomi MJSXJ02HL**, every question in the next section
is already settled — RTL8189FTV on SDIO, no power GPIO, reset button on
GPIO 0 — from OpenIPC's own device repository. The bring-up profile ships
with this project and the installer will add it:

```sh
./tools/install-into-openipc.sh ../firmware hi3518ev300_lite mjsxj02hl
```

See **[docs/10-device-mjsxj02hl.md](10-device-mjsxj02hl.md)**. Note in
particular that the stock `rtl8189fs-generic` profile does *not* work on that
camera, and fails silently.

## UNKNOWN — what I need from you

For any *other* board: the provisioning system is complete and
chip-independent, but what is not determined is which radio your board has
and how it is powered. That gap is deliberately confined to **one file and
one environment variable**, so answering any of the questions below finishes
the job without touching anything else.

Please provide whichever of these you can:

1. **The chip marking.** A photo of the Wi-Fi module, or the silkscreen text.
   Typical markings: `RTL8189FTV`, `RTL8189ES`, `ATBM6032`, `AIC8800`,
   `SSV6051`.
2. **`dmesg` from a boot of the existing (stock or OpenIPC) firmware** —
   specifically the `mmc`/`sdio` lines.
3. **`cat /sys/bus/sdio/devices/*/{vendor,device}`** — the SDIO vendor and
   device IDs identify the chip unambiguously.
4. **Which GPIO powers or resets the module**, if any. From a schematic, or
   from the stock firmware's own init scripts.
5. **The camera model / board marking**, which may already match a known
   OpenIPC profile.

### How to collect it

Over serial console or SSH on a booted camera:

```sh
# 1. Did the SDIO controller find a card at all?
dmesg | grep -iE 'mmc|sdio|sdhci'

# 2. What SDIO functions enumerated? (vendor:device identifies the chip)
ls -l /sys/bus/sdio/devices/
for d in /sys/bus/sdio/devices/*/; do
    echo "$d  vendor=$(cat $d/vendor)  device=$(cat $d/device)  class=$(cat $d/class)"
done

# 3. Which host controllers are bound?
ls -l /sys/bus/platform/drivers/sdhci-hisi/
cat /proc/interrupts | grep -i mmc

# 4. What the board says it is
cat /proc/device-tree/model
cat /proc/device-tree/compatible | tr '\0' '\n'

# 5. What drivers are loaded and available
lsmod
find /lib/modules -name '*.ko' | sort

# 6. The current board profile, if one is set
fw_printenv wlandev wlanssid wlanmac 2>/dev/null

# 7. GPIO state, which can hint at a power-enable line
/usr/sbin/gpio 2>/dev/null || true
```

**If `/sys/bus/sdio/devices/` is empty** the chip is not being powered or
reset correctly, which is the single most common failure on these boards. See
"Forcing an SDIO rescan" below.

### Vendor IDs you are likely to see

| SDIO vendor | Manufacturer | Then look at `device` |
|---|---|---|
| `0x024c` | Realtek | `0xf179` = RTL8189FTV, `0x8179` = RTL8189ES/8188ETV |
| `0x007a` | Altobeam | ATBM603x family |
| `0xc8a1` / `0x5449` | AIC | AIC8800 family |
| `0x3030` | South Silicon Valley | SSV6051/6x5x |

---

## Adding a board profile once you know the chip

This is the *only* chip-specific change. Add an entry to
`general/overlay/etc/wireless/sdio` in your OpenIPC checkout:

```sh
# HI3518EV300 <your board name>
if [ "$1" = "rtl8189fs-hi3518ev300-myboard" ]; then
	set_gpio 57 1          # power-enable, ACTIVE HIGH  -- REPLACE with yours
	sleep 1
	sdio_rescan            # see below
	modprobe 8189fs rtw_power_mgnt=0
	exit 0
fi
```

then on the camera:

```sh
fw_setenv wlandev rtl8189fs-hi3518ev300-myboard
reboot
```

and in your board defconfig, enable the matching driver package, e.g.
`BR2_PACKAGE_RTL8189FS_OPENIPC=y`.

### Forcing an SDIO rescan on HiSilicon

The existing profiles in `/etc/wireless/sdio` call a helper `set_mmc`, which
pokes `/sys/devices/platform/jzmmc_v1.2.N/present`. **That path is Ingenic-only
and does not exist on HiSilicon** — the call is harmless but does nothing here.

The equivalent on this SoC is to make the MMC core re-probe the bus after the
Wi-Fi chip has been powered up, by cycling the platform driver binding:

```sh
sdio_rescan() {
	# 10020000.sdhci is mmc1 on Hi3518EV300; confirm with
	#   ls /sys/bus/platform/drivers/sdhci-hisi/
	dev=$(ls /sys/bus/platform/drivers/sdhci-hisi/ | grep '10020000' | head -1)
	[ -n "$dev" ] || return 1
	echo "$dev" > /sys/bus/platform/drivers/sdhci-hisi/unbind
	sleep 1
	echo "$dev" > /sys/bus/platform/drivers/sdhci-hisi/bind
	sleep 1
}
```

This is needed when the chip's power rail is switched by a GPIO that is off
at boot: the MMC core scans once, finds nothing, and does not look again.
Boards that keep the module powered permanently do not need it.

A board may also expose a controller-level way to re-latch card presence,
which is cheaper than cycling the driver binding. The Xiaomi MJSXJ02HL does
exactly that — a toggle of bit 27 at `mmc1 + 0x28` — and its profile uses it
instead of the unbind/bind dance. See
[docs/10-device-mjsxj02hl.md](10-device-mjsxj02hl.md) for the annotated
sequence; it is a good template for any Hi3518EV300 board whose SDIO pads
need muxing before the radio will enumerate.

> The `10020000.sdhci` device name is **ASSUMED** from the DTS `reg` property.
> Confirm it with the `ls` above before relying on it.
