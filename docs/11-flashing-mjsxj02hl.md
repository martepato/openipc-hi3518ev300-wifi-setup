# Flashing: Xiaomi MJSXJ02HL

Produced by `tools/build-image.sh`, which layers the provisioning system onto
OpenIPC's official `hi3518ev300` release. The kernel and bootloader come out
byte-identical to that release (checked against its own `md5sum` file), so the
only thing to review is the root filesystem.

Run it with:

```sh
./tools/build-image.sh          # writes ./output/release/
```

The text below is shipped verbatim as `README-FLASHING.txt` alongside the
images.

```
OpenIPC + Wi-Fi provisioning for Xiaomi MJSXJ02HL (Hi3518EV300)
================================================================

Flash these five files with HiTool / HiBurn, then set up Wi-Fi from your
phone. No serial console is required.

  u-boot-hi3518ev300-universal.bin   bootloader   STOCK, unmodified
  env.bin                            boot config  NEW  (see "Divergence")
  uImage.hi3518ev300                 kernel       STOCK, unmodified
  rootfs.squashfs.hi3518ev300        filesystem   MODIFIED
  usb-burn.xml                       partition table for HiBurn

  uboot-env.txt                      the env in readable form (reference)
  md5sums.txt / sha256sums.txt       checksums


WHAT DIVERGES FROM STOCK OPENIPC
--------------------------------
Two things, both deliberate and both explained below.

1. THE PARTITION LAYOUT IS OPENIPC'S 16 MB ONE, NOT ITS 8 MB ONE.

   This camera has 16 MB of flash but the published MJSXJ02HL instructions
   use the 8 MB layout, which gives the root filesystem 5120K and leaves
   ~11 MB of the chip unused. The root filesystem here is about 5.7 MB --
   it does not fit in 5120K.

   The layout used is u-boot's own built-in "mtdpartsnor16m", byte for byte:

     hi_sfc:256k(boot),64k(env),3072k(kernel),10240k(rootfs),-(rootfs_data)

   Nothing invented. It is what the shipped bootloader's `setnor16m` command
   would set, and usb-burn.xml matches it exactly:

     fastboot         0K   256K
     env            256K    64K
     kernel         320K  3072K
     rootfs        3392K 10240K   (5.7 MB used, 4.3 MB free)
     rootfs_data  13632K  2752K   (settings, wiped by factory reset)

2. env.bin PRE-SETS THAT LAYOUT SO NO SERIAL CONSOLE IS NEEDED.

   The kernel finds its root filesystem via "mtdparts" in the u-boot
   environment. Flashing a bigger rootfs without also setting mtdparts gives
   a kernel panic at boot. env.bin is the stock default environment with
   four changes:

     mtdparts = ...16 MB layout as above...
     osmem    = 35M                        (this camera; from the OpenIPC
     totalmem = 64M                         device-mjsxj02hl autoconfig)
     extras   = mmz_allocator=hisi         (bootargs already ends in ${extras})
     wlandev  = rtl8189fs-hi3518ev300-mjsxj02hl

   The last one means the Wi-Fi driver is loaded on the very first boot with
   nothing for you to type. Everything else -- bootcmd, bootargs, baudrate,
   the whole rest -- is unchanged from the bootloader's own defaults.

The kernel and bootloader are byte-identical to the official OpenIPC release
(hi3518ev300 nor-lite / latest). Only the root filesystem is modified.


WHAT WAS ADDED TO THE ROOT FILESYSTEM
-------------------------------------
Base: official openipc.hi3518ev300-nor-lite.tgz. Added:

  extra/8189fs.ko       RTL8189FTV SDIO driver, 1,240,228 bytes. Taken from
                        OpenIPC's own hi3518ev300 "ultimate" release; the
                        nor-lite image does not carry it. Safe to move
                        between them: CONFIG_MODVERSIONS is off, vermagic is
                        identical, and mac80211.ko is byte-for-byte the same
                        in both images, so they are the same kernel build.
                        Registered in modules.dep and modules.alias
                        (sdio:c*v024CdF179* = RTL8189FTV).

  /usr/sbin/hostapd     377,212 bytes, built from the exact source OpenIPC
  /usr/bin/hostapd_cli  pins for rtw-hostapd (lwfinger/rtl8188eu @ a69d636,
                        hostapd 2.9), cross-compiled with the OpenIPC
                        toolchain. nl80211 + rtw backends; no EAP, RADIUS,
                        WPS or VLAN. Links only against libnl-3/libnl-genl-3
                        and libc, all already present in the image.

  /usr/sbin/wifi-dnsd   5,424 bytes. Wildcard DNS so the setup page opens by
                        itself on a phone.

  the provisioning system itself (wifi-manager, wifi-ctl, wifi-led,
  wifi-button-watch, the setup page and its CGI, the board profile in
  /etc/wireless/sdio, and /etc/wifi/wifi.defaults for this camera).

  /etc/network/interfaces.d/wlan0 is replaced with an "inet manual" stanza so
  ifup does not race the provisioning manager. The original is kept next to
  it as wlan0.stock.

  /etc/majestic.yaml gains three lines, and loses nothing:

      nightMode:
        irCutPin1: 70        IR-cut filter, swing in  (daylight)
        irCutPin2: 68        IR-cut filter, swing out (night)
        backlightPin: 54     infrared lamp

  This camera's day/night wiring, from OpenIPC/device-mjsxj02hl. Without it
  majestic leaves that hardware alone -- the web UI's IR-cut toggle stays
  greyed out and night mode moves nothing. Every other setting in that file
  is OpenIPC's.


FLASHING
--------
Same procedure as the OpenIPC MJSXJ02HL instructions; only the files and the
partition table differ.

 1. Install Zadig, enable Options -> List All Devices.
 2. Hold the camera's Reset button and plug it into USB (a data cable -- the
    bundled one is power-only). As soon as "HiUSBBurn" appears, select it and
    install the libusbK driver. You usually need a few attempts; the device
    disappears after a couple of seconds.
 3. Open HiTool, choose chip Hi3518EV300, open HiBurn.
 4. Load usb-burn.xml from this directory. Check that all five rows point at
    the files here (rootfs_data is intentionally blank -- it gets erased).
 5. Press Burn, accept the erase warning, then hold Reset and connect USB.
    Flashing takes about a minute.

VERIFY BEFORE YOU BURN: the checksums in md5sums.txt.


FIRST BOOT
----------
Watch the front LED:

  solid orange               booting
  alternating orange/blue    ready for setup   <-- expected within ~40 s
  orange double-blink        no Wi-Fi adapter found (see TROUBLESHOOTING)

When it alternates:

 1. On your phone, join the Wi-Fi network "OpenIPC-XXXX" (XXXX comes from the
    camera's MAC, so two cameras are never ambiguous).
 2. The setup page should open by itself. If not, browse to
    http://192.168.4.1/
 3. Pick your Wi-Fi, enter the password, press Connect.
 4. The setup network disappears for up to a minute while the camera tests
    the password. White flicker = testing.
      - Success: steady blue for about three seconds, then both LEDs go
        out. That is the finished state, not a fault: the daemon that
        would otherwise show the streamer's state on them is part of the
        SD-card autoconfig payload, which this image does not include.
      - Wrong password: the setup network comes back by itself and the page
        tells you what was wrong. Nothing was saved; just try again.

Afterwards the camera joins that network on every boot. Its web UI is on
port 80 (http://camera-ip/) -- the OpenIPC MJSXJ02HL instructions say 85,
which is true of that build's autoconfig but not of the generic images this
one is built from. SSH as root with no password until you set one.


CHANGING THE WI-FI LATER
------------------------
  Hold Reset for 5 seconds while the camera is running
        -> erases Wi-Fi settings only, reopens setup mode.
  Hold Reset while powering on
        -> full factory reset (wipes the whole overlay). Unchanged stock
           behaviour, handled by S00resetbtn.

Or over SSH: `wifi-ctl provision`, `wifi-ctl forget`, `wifi-ctl status`.


TROUBLESHOOTING
---------------
Kernel panic / "unable to mount root" after flashing
    env.bin did not take. Confirm the env partition really was written. With
    a serial console (115200 8N1), interrupt u-boot and run:
        run setnor16m
    which sets the same layout from the bootloader's own built-in command and
    reboots. Then reflash the rootfs if needed.

LED double-blinks orange (no adapter)
    The SDIO chip did not enumerate. Over SSH or serial:
        ls /sys/bus/sdio/devices/      # expect one entry
        dmesg | grep -iE 'mmc|sdio'
        fw_printenv wlandev            # expect rtl8189fs-hi3518ev300-mjsxj02hl
    The bring-up sequence lives in /etc/wireless/sdio.

No LED activity at all
    wifi-ctl led-test          # walks every pattern
    wifi-ctl status

Setup network appears but the page will not load
    Browse to http://192.168.4.1/ directly. Check:
        logread | grep -iE 'wifi|httpd'

Going back to stock OpenIPC
    Flash the official openipc.hi3518ev300-nor-lite.tgz with the original
    5120K partition table from OpenIPC/device-mjsxj02hl, and blank the env
    partition so the bootloader falls back to its 8 MB defaults.


WHAT HAS AND HAS NOT BEEN TESTED
--------------------------------
Verified on the build host: hostapd, wifi-dnsd and libnl cross-compile and
link only against libraries present in the image; the kernel module's
vermagic matches and its image is byte-identical between the two OpenIPC
releases; the squashfs is xz/128K with no xattrs, matching the stock image
and the kernel's CONFIG_SQUASHFS_XZ / no-XATTR / XZ_DEC_ARM settings;
env.bin is 64K with a correct CRC32 and parses back to 40 variables;
every partition fits with room to spare and the table covers exactly 16 MB;
119 automated tests of the provisioning logic pass.

NOT verified, because it needs the camera: that it boots, that the RTL8189FTV
enumerates on SDIO, that hostapd can actually bring up an AP on this driver
build, and that the LED GPIOs are the polarity the datasheet-free device
repo implies. Flash with a serial console to hand the first time if you can.
```
