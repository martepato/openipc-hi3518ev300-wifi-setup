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
| IR-cut filter | two-coil latching solenoid, **GPIO 70 in / GPIO 68 out** | `flash/autoconfig/etc/majestic.yaml`, `usr/sbin/autonight.sh` |
| IR lamp | **GPIO 54** | same |
| Web UI | majestic on port **85** in *that* build's autoconfig; **80** in the generic images this project flashes | README, and `majestic.yaml` in the release |

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
./tools/install-into-openipc.sh ../firmware hi3518ev300_lite mjsxj02hl

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

## Board settings

The installer writes these for you from
`boards/mjsxj02hl/defaults`:

```sh
WIFI_BUTTON_GPIO=0                            # reset button, sysfs numbering
WIFI_BUTTON_ACTIVE_LOW=1                      # 0 = pressed
WIFI_LED_WARN_GPIO=52                         # orange
WIFI_LED_OK_GPIO=53                           # blue
WIFI_LED_ACTIVE_LOW=0
#WIFI_LED_PAUSE_SERVICE=                      # nothing to hand back to; see below
WIFI_PORTAL_STOP_MAJESTIC=1                   # majestic holds port 80; see below
```

## Day/night hardware: the IR-cut filter and the lamp

These are not Wi-Fi, and they are not preferences either — they are which pins
the parts are soldered to, and a camera assembled by `tools/build-image.sh`
has no other way to find out. Until it knows, majestic leaves the day/night
hardware alone: its web UI greys out the IR-cut toggle with
*"nightMode.irCutPin1 is not configured"*, and `/night/on` moves nothing.

| Part | Key | Pin |
|---|---|---|
| IR-cut filter, swing in (day) | `nightMode.irCutPin1` | 70 |
| IR-cut filter, swing out (night) | `nightMode.irCutPin2` | 68 |
| Infrared lamp | `nightMode.backlightPin` | 54 |

The filter is a latching solenoid with two coils — one pulse each way — which
is why there are two pins. `irCutSingleInvert`, already in the stock file and
left alone, is for the cheaper one-pin variant that this camera is not.

They live in `boards/mjsxj02hl/majestic.conf`, and `tools/build-image.sh`
applies them one key at a time to the `majestic.yaml` already in the image
using `tools/majestic-set.sh` — a host-side stand-in for the camera's own
`cli -s`, which is an ARM binary. Nothing else in that file moves; the diff
against OpenIPC's shipped `majestic.yaml` is three added lines.

The device repo's `majestic.yaml` also sets `nightMode.enabled: true` and
`dncDelay`. Those are **not** carried here, and their absence is not an
oversight: that file predates the majestic in current images, whose
`nightMode` section has no `enabled` key at all (`colorToGray`, `irCutPin1`,
`irCutSingleInvert`, `irCutPin2`, `backlightPin`, `drc`, `lightMonitor`,
`lightSensorPin`, `lightSensorInvert`, `monitorDelay`, `minThreshold`,
`maxThreshold`, and no more). The pins alone arm `/night/on`, `/night/ircut`
and `/night/light`.

### On a camera that is already running

A firmware image carries these in the read-only squashfs, so a fresh flash
has them. A camera whose `majestic.yaml` has already been copied up to the
overlay — which happens the first time anything saves a camera setting — keeps
its own copy, and that copy shadows the new one. Set them there directly:

```sh
cli -s .nightMode.irCutPin1 70
cli -s .nightMode.irCutPin2 68
cli -s .nightMode.backlightPin 54
killall -HUP majestic
```

The same three commands are how to apply this on the Buildroot path, where
`majestic.yaml` comes from the majestic package rather than from this builder.

## What the LEDs tell you

Setup used to be silent: between power-on and a phone seeing `OpenIPC-XXXX`
there was nothing to say whether the camera was booting, waiting, or had no
Wi-Fi hardware at all. Now:

| LED | Meaning |
|---|---|
| Solid orange | Booting |
| Orange double-blink, repeating | **No Wi-Fi adapter found** — will not fix itself |
| **Alternating orange/blue** | **Waiting to be set up — join `OpenIPC-XXXX`** |
| White flicker | Testing your password; do not power off |
| Blue blink, slow | Joining the saved network |
| Orange blink, slow | Lost the network, retrying |
| Steady blue ~3 s, then normal | Connected |

After that `wifi-led` turns the LEDs off and stops driving them.

On a stock OpenIPC install the camera's own `S00autoled` would take over here
(orange = majestic stopped, blue = running), and `WIFI_LED_PAUSE_SERVICE`
exists to pause it while setup mode owns the pins. But that daemon is part of
the SD-card autoconfig payload, so an image built by `tools/build-image.sh`
does not have it and the setting is left unset — there is nothing to hand back
to. Dark LEDs on a working camera is the honest result. Point
`WIFI_LED_PAUSE_SERVICE` at an LED daemon if your build ships one.

Check the wiring without provisioning anything:

```sh
wifi-ctl led-test        # walks every pattern once
```

### The button is shared, deliberately

One button, two clearly separated actions:

| When | Effect | Provided by |
|---|---|---|
| Held **while powering on** | Full factory reset — erases the overlay partition | `S00resetbtn` |
| Held **5 s while running** | Erases Wi-Fi settings only, reopens setup mode | `wifi-button-watch` |

`S00resetbtn` reads GPIO 0 once at boot; `wifi-button-watch` polls it during
normal operation and waits for a release before arming, so a boot-time hold is
never also counted as a Wi-Fi reset.

**`S00resetbtn` ships in `boards/mjsxj02hl/rootfs/`, not in OpenIPC.** On a
stock install it reaches the camera through the device's SD-card autoconfig
payload, which a camera flashed from `tools/build-image.sh` never sees — so
before it was added here, the factory reset this camera's documentation
describes did nothing at all, while the runtime Wi-Fi reset worked fine. If
you are integrating this into some other build, carry that file across or the
button will look dead at boot.

It also requires the button to stay held for two seconds rather than sampling
the pin once, so a floating pin at power-on cannot erase the camera by
itself.

## Majestic is on port 80, and that matters

An earlier version of this document said port 85, taken from the OpenIPC
device repo's README. That is true of *that* build, whose autoconfig moves
majestic — but **not** of the generic `hi3518ev300` images this project
flashes, whose `majestic.yaml` says `webPort: 80`.

Getting this wrong had a real consequence on the first hardware test: the
board defaults shipped `WIFI_PORTAL_STOP_MAJESTIC=0`, nothing yielded port
80, and `http://192.168.4.1/` served majestic's own web interface — a
root-password prompt — instead of the setup page. It is now `1`, so majestic
is paused for the duration of setup mode and restarted afterwards.

If the portal still cannot take the port, `wifi-ap.sh` now restores majestic
rather than leaving it stopped, so the camera is always configurable through
one page or the other, and says so loudly in the log instead of failing
quietly.

## Configuring Wi-Fi from the camera's own web interface

OpenIPC's web UI already has a Wi-Fi page. It calls `setnetwork`, which
writes `wlanssid`/`wlanpass` into the U-Boot environment, rewrites
`interfaces.d/wlan0` — and then stops, because the stock design expects a
reboot to pick it up.

`wifi-manager` watches that environment, so credentials set there are adopted
within about ten seconds: tested, committed on success, and the setup AP torn
down, exactly as if they had been typed into the setup page. A wrong password
entered there is no more destructive than a wrong one here.

Two consequences worth knowing:

- **The setup AP stays up until the network is genuinely configured**, by
  whichever page you used. It is not tied to the portal specifically.
- **`setnetwork` overwrites `interfaces.d/wlan0`** with the stock stanza
  every time that page is saved, which would put a second `wpa_supplicant`
  back into the boot path racing ours. The manager notices and puts its own
  stanza back.

### Upgrading a camera whose network page has already been saved

`/etc` is an overlay, and a rootfs-only reflash does not clear it. Once
`setnetwork` has written the stock stanza to
`/etc/network/interfaces.d/wlan0`, that copy lives on the overlay and
**shadows** the one in the new firmware. `S40network` then runs `ifup wlan0`
from it and starts a `wpa_supplicant` of its own — before `wifi-manager` gets
a turn, so repairing the file is too late for that boot, and two supplicants
on one radio means neither works.

So the manager sweeps the interface clear before taking it: any
`wpa_supplicant` or `udhcpc` whose arguments name our interface and which we
did not start is stopped first. Matched on `argv[0]` plus the interface —
never a blanket `killall`, and never a pid from our own pidfiles — so
majestic, hostapd, a second radio and anything on `eth0` are untouched. The
same sweep runs before `hostapd`, which likewise cannot bring up an AP while
a supplicant holds the interface.

The stanza also deliberately contains the word `dhcp` in a comment, because
`fw-network.cgi` reports the addressing mode with

```sh
grep -q dhcp /etc/network/interfaces.d/wlan0
```

and this interface really is DHCP — run by `wifi-manager` rather than by
ifupdown. Without the word the page reported "static" for a camera using
DHCP, which is what made the toggle look like it would not stay on.

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
- The LED patterns were verified against a directory of files standing in for
  sysfs, not against the real GPIOs. The numbers, direction and polarity come
  from `led_control.sh`; confirm on hardware with `wifi-led test`.
