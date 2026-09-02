# Exactly what changes in an OpenIPC tree

Run `./tools/install-into-openipc.sh <firmware-checkout> hi3518ev300_lite`
and this is the complete set of changes. Nothing else in the tree is touched.

## Files added

```
general/package/wifi-provision/
├── Config.in                                  Kconfig entry
├── wifi-provision.mk                          Buildroot package
├── LICENSE
├── src/
│   └── wifi-dnsd.c                            captive-portal DNS responder
└── files/
    ├── etc/
    │   ├── init.d/S41wifi                     starts the manager
    │   ├── network/interfaces.d/wlan0         replacement stanza (see below)
    │   └── wifi/wifi.defaults                 integrator settings
    ├── usr/
    │   ├── libexec/wifi/
    │   │   ├── wifi-lib.sh                    encoding, validation, storage
    │   │   ├── wifi-sta.sh                    association + DHCP
    │   │   ├── wifi-ap.sh                     hostapd, DHCP server, portal
    │   │   └── wifi-scan.sh                   neighbour scan via wpa_cli
    │   └── sbin/
    │       ├── wifi-manager                   the state machine
    │       ├── wifi-ctl                       CLI / config API
    │       └── wifi-button-watch              optional GPIO reset button
    └── var/www-wifi/
        ├── index.html                         the setup page
        └── cgi-bin/wifi                       JSON backend
```

## Files modified

### 1. `general/package/Config.in` — one line

```diff
 source "$BR2_EXTERNAL_GENERAL_PATH/package/webrtc-audio-processing-openipc/Config.in"
+source "$BR2_EXTERNAL_GENERAL_PATH/package/wifi-provision/Config.in"
 source "$BR2_EXTERNAL_GENERAL_PATH/package/wifibroadcast-ng/Config.in"
```

Inserted in sorted position, before the trailing `# Legacy` section. Verified
to be a one-line `diff` against upstream.

### 2. Your board defconfig — five lines

`br-ext-chip-hisilicon/configs/hi3518ev300_lite_defconfig`:

```diff
+BR2_PACKAGE_WIFI_PROVISION=y
+BR2_PACKAGE_WIFI_PROVISION_CAPTIVE_DNS=y
+BR2_PACKAGE_RTW_HOSTAPD=y
+BR2_PACKAGE_RTW_HOSTAPD_DRIVER_NL80211=y
+BR2_PACKAGE_RTW_HOSTAPD_DRIVER_RTW=y
```

`BR2_PACKAGE_WPA_SUPPLICANT`, `_CLI` and `_PASSPHRASE` are already set in both
hi3518ev300 defconfigs, so the installer reports them as "already set".

`hi3518ev300_ultimate_defconfig` additionally already has
`BR2_PACKAGE_RTL8189FS_OPENIPC=y`.

### 3. `/etc/network/interfaces.d/wlan0` — replaced at install time

Done by the package's install step, not by editing the overlay, so the
overlay in the OpenIPC tree stays pristine. The original is preserved
alongside as `wlan0.stock`.

Before (OpenIPC stock):

```
iface wlan0 inet dhcp
    pre-up wpa_passphrase "$(fw_printenv -n wlanssid)" "$(fw_printenv -n wlanpass)" > /tmp/wpa_supplicant.conf
    pre-up sed -i 's/#psk.*/scan_ssid=1/g' /tmp/wpa_supplicant.conf
    pre-up wpa_supplicant -B -i wlan0 -D nl80211,wext -c /tmp/wpa_supplicant.conf
    post-down killall -q wpa_supplicant
```

After:

```
iface wlan0 inet manual
    pre-up ip link set dev wlan0 up
```

Why: `S40network` calls `ifup wlan0`. If the stock stanza stayed, it would
start a second `wpa_supplicant` from the U-Boot environment and race the one
`wifi-manager` starts. See `docs/01-architecture.md` §1.

To revert: `mv wlan0.stock wlan0` on the camera and disable `S41wifi`.

## Files you must edit yourself

### `general/overlay/etc/wireless/sdio` — add your board profile

The one genuinely chip-specific change, and the reason it is yours to make is
that only you know which radio is fitted and how it is powered. Template and
GPIO/rescan guidance: `docs/02-hardware.md`.

### Your board defconfig — enable the driver

One of:

```
BR2_PACKAGE_RTL8189FS_OPENIPC=y     # Realtek RTL8189FTV (SDIO)
BR2_PACKAGE_RTL8189ES_OPENIPC=y     # Realtek RTL8189ES  (SDIO)
BR2_PACKAGE_ATBM_WIFI=y             # Altobeam ATBM603x  (SDIO)
BR2_PACKAGE_AIC8800_OPENIPC=y       # AIC AIC8800        (SDIO)
```

The installer deliberately does not guess this.

## What is NOT changed

- **The kernel config** — the SDIO host (`CONFIG_MMC_SDHCI_HISI`), `cfg80211`
  and `mac80211` are already enabled. Nothing here needs a kernel rebuild.
- **The device tree** — `mmc0` and `mmc1` are already `okay` in
  `hi3518ev300-demb.dts`. A DTS change is only needed if your board wires the
  radio somewhere non-standard, and since the DTB is appended to the kernel
  image that would mean a kernel rebuild.
- `S40network`, `S30customizer`, `rcS`, `inittab`, `mdev.conf`
- `/etc/wireless/sdio` and `/etc/wireless/usb` dispatch logic (only *entries*
  are added)
- BusyBox config — `httpd`, CGI, `udhcpd` and `udhcpc` are already enabled
- majestic, its web UI, or any camera-side configuration

## Interaction with majestic

Majestic serves its own web UI on port 80 across all addresses, so it and the
setup portal cannot both hold that port. Setup mode is temporary and
exclusive, so for its duration the manager pauses majestic and restarts it on
the way out. `WIFI_PORTAL_STOP_MAJESTIC=0` plus a different
`WIFI_PORTAL_PORT` avoids this entirely if you would rather the streamer
never stop; the cost is that captive-portal auto-open stops working, since
phones probe port 80.
