# Xiaomi MJSXJ02HL

The hardware questions left open in `docs/02-hardware.md` are **answered** for
this camera. Everything below was read out of
[OpenIPC/device-mjsxj02hl](https://github.com/OpenIPC/device-mjsxj02hl)
(commit `bb2aa27`), not inferred.

## Confirmed hardware

| | | Source |
|---|---|---|
| SoC | Hi3518EV300 | `usb-burn.xml`, README |
| Wi-Fi chip | **Realtek RTL8189FTV, SDIO** | `flash/autoconfig/lib/modules/4.9.37/external/8189fs.ko` |
| Kernel | 4.9.37 | module `vermagic=4.9.37 mod_unload ARMv7 p2v8` |
| Driver | `8189fs`, **built with `CONFIG_IOCTL_CFG80211`** | 111 undefined `cfg80211_*` symbols in the `.ko`; stock config drives it with `wpa_supplicant -D nl80211` |
| Power-enable GPIO | **none** — pin mux + a card-detect poke instead | `etc/network/interfaces.d/wlan0` |
| Reset button | **GPIO 0, active low** (`0` = pressed) | `etc/init.d/S00resetbtn` |
| LEDs | orange GPIO 52, blue GPIO 53, sysfs, active high | `usr/sbin/led_control.sh` |
| Flash | 16 MB NOR: 256K fastboot, 64K env, 2048K kernel, 5120K rootfs, 8896K rootfs_data | `usb-burn.xml` |
| Web UI | majestic on port **85**, not 80 | README |

That the driver speaks nl80211 is the detail that mattered most here. Whether
a Realtek out-of-tree driver exposes cfg80211 is a *build-time* option, not a
property of the chip — so `wifi_ap_driver()` no longer guesses from the
driver's name (an "8189 means Realtek `rtw`" guess would have been wrong on
exactly this camera). It now checks whether `/sys/class/net/wlan0/phy80211`
exists, which is true if and only if a wiphy was registered — the same
condition nl80211 needs.

## Install

```sh
cd openipc-hi3518ev300-wifi-setup
./install/install-into-openipc.sh ../firmware hi3518ev300_lite mjsxj02hl

cd ../firmware
echo 'BR2_PACKAGE_RTL8189FS_OPENIPC=y' >> \
    br-ext-chip-hisilicon/configs/hi3518ev300_lite_defconfig
make BOARD=hi3518ev300_lite
```

The third argument inserts the bring-up profile into
`general/overlay/etc/wireless/sdio`. Then, on the camera:

```sh
fw_setenv wlandev rtl8189fs-hi3518ev300-mjsxj02hl
reboot
```

`nor-lite` is the right variant — it is what the device README flashes.

## The bring-up profile, annotated

Transcribed from the camera's stock `interfaces.d/wlan0`:

```sh
devmem 0x112C0048 32 0x1D54     # IOCFG: SDIO1 clock pin
devmem 0x112C004C 32 0x1174     # IOCFG: SDIO1 cmd + data0..3
devmem 0x112C0064 32 0x1174
devmem 0x112C0060 32 0x1174
devmem 0x112C005C 32 0x1174
devmem 0x112C0058 32 0x1174
devmem 0x10020028 32 0x28000000 # mmc1 (0x10020000) + 0x28: re-latch
devmem 0x10020028 32 0x20000000 # card presence (bit 27 toggled)
modprobe cfg80211
sleep 2
modprobe 8189fs
```

There is no power rail to switch. The reason the module still will not appear
without this is the last pair of writes: the MMC core scans once at boot,
finds nothing because the pads are not yet muxed to SDIO, and never looks
again. Toggling that bit makes the controller re-latch card presence — this
SoC's equivalent of the Ingenic `set_mmc` "INSERT" poke.

**The stock `rtl8189fs-generic` profile does not work on this camera.** It
calls `set_mmc`, which pokes `/sys/devices/platform/jzmmc_v1.2.N/present` — an
Ingenic path that does not exist on HiSilicon — and it does no pin muxing. It
fails silently: nothing errors, and `wlan0` simply never appears.

## Recommended `/etc/wifi/wifi.defaults`

```sh
# Xiaomi MJSXJ02HL
WIFI_BUTTON_GPIO=0              # the reset button, sysfs numbering
WIFI_BUTTON_ACTIVE_LOW=1        # 0 = pressed
WIFI_AP_DRIVER=nl80211          # optional: the probe already gets this right
```

### The button is shared, deliberately

`S00resetbtn` reads the same GPIO 0 **once at boot** and, if it is held then,
wipes the whole overlay partition. `wifi-button-watch` polls it **during
normal operation**. So one button gives two clearly separated actions:

| When | Effect |
|---|---|
| Held **while powering on** | Full factory reset — wipes `/dev/mtd4` (`S00resetbtn`) |
| Held **5 s while running** | Erases Wi-Fi settings only, reopens setup mode |

The watcher waits for the button to be released before arming, so a boot-time
hold is never also counted as a Wi-Fi reset.

## Port 85, not 80

Majestic's web UI is on **85** on this device, so it does not contend with the
setup portal on port 80. `WIFI_PORTAL_STOP_MAJESTIC` can therefore be left at
its default and will simply never trigger — the manager only pauses majestic
if it actually finds it holding the portal's port. Nothing to configure; worth
knowing when reading `docs/03-openipc-changes.md`, which describes the
contention case that applies to other boards.

## What this replaces

The stock flow asks the owner to edit `interfaces.d/wlan0` on an SD card in
Notepad++ to set `myssid` / `mypassword`, format two VFAT partitions, and
reboot twice. After this change the camera broadcasts `OpenIPC-XXXX` on first
boot and is configured from a phone. The SD-card route still works and is
still the recovery path if Wi-Fi is misconfigured beyond reach.

## Still unverified

Everything above is read from the device repository; none of it has been run
on the camera. Untested specifically:

- **AP mode on the RTL8189FTV.** The driver exposes cfg80211, and hostapd's
  nl80211 backend is built in, but whether this particular build advertises AP
  as a supported interface mode has not been confirmed. Check on hardware with
  `iw list | grep -A10 'Supported interface modes'`. If AP is missing, the
  camera still works as a station and provisioning falls back to
  `wifi-ctl configure` — see `docs/04-build.md` on dropping the AP.
- The `0x10020028` write is described here from the SDHCI register map and the
  behaviour it produces; the bit is not documented in a public datasheet I can
  cite. It is transcribed verbatim from the working stock configuration.
- The GPIO 52/53 LEDs are not wired to provisioning state. Showing setup mode
  on the LED would be a genuine improvement on a device with no screen, and
  `led_control.sh` makes it a few lines — but it is not implemented, because
  nothing in scope asked for it.
