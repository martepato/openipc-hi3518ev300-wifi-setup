# Building

## Prerequisites

A Linux host with the usual Buildroot dependencies:

```sh
sudo apt-get install -y build-essential bc bison flex gawk git gperf \
    libncurses-dev libssl-dev python3 rsync unzip wget cpio file whiptail
```

## Build

```sh
git clone https://github.com/OpenIPC/firmware.git
git clone https://github.com/martepato/openipc-hi3518ev300-wifi-setup.git

cd openipc-hi3518ev300-wifi-setup
./install/install-into-openipc.sh ../firmware hi3518ev300_lite

cd ../firmware
# Enable the driver for YOUR radio -- see docs/02-hardware.md
echo 'BR2_PACKAGE_RTL8189FS_OPENIPC=y' >> br-ext-chip-hisilicon/configs/hi3518ev300_lite_defconfig

make BOARD=hi3518ev300_lite
```

Substitute `hi3518ev300_ultimate` for the 16 MB variant, which already has
`BR2_PACKAGE_RTL8189FS_OPENIPC=y`.

Output lands in `firmware/output/images/`:

```
uImage.hi3518ev300                 kernel + appended DTB
rootfs.squashfs.hi3518ev300        root filesystem
```

Expect 30–90 minutes for a first build (it fetches the toolchain and builds
everything); minutes for a rebuild.

Useful targets:

```sh
make BOARD=hi3518ev300_lite defconfig          # generate .config only
make BOARD=hi3518ev300_lite br-menuconfig      # browse/adjust the config
make BOARD=hi3518ev300_lite br-wifi-provision-rebuild
make BOARD=hi3518ev300_lite br-wifi-provision-reinstall
```

## What was verified here, and what was not

Being precise, because "it builds" is a claim worth qualifying:

**Verified by actually running it** against a fresh `OpenIPC/firmware`
checkout with Buildroot 2024.02.10:

- `install-into-openipc.sh` produces a **one-line** diff in
  `general/package/Config.in`, in sorted position, leaving the `# Legacy`
  section intact — and is idempotent.
- `make BOARD=hi3518ev300_lite defconfig` **succeeds** with the package
  enabled, and the resulting `.config` resolves
  `BR2_PACKAGE_WIFI_PROVISION=y`, `BR2_PACKAGE_RTW_HOSTAPD=y` with both the
  `nl80211` and `rtw` backends, and `wpa_supplicant` with `_CLI`,
  `_PASSPHRASE`, `_NL80211` and `_WEXT`.
- Buildroot **parses `wifi-provision.mk`** and resolves
  `WIFI_PROVISION_BUILD_CMDS` to the real
  `arm-openipc-linux-musleabi-gcc ... -Os` invocation, with dependencies
  `wpa_supplicant rtw-hostapd busybox toolchain`.
- The package's `INSTALL_TARGET_CMDS` were **executed** against a staging
  tree: all 13 files install with the right modes, and the stock `wlan0`
  stanza is preserved as `wlan0.stock`.
- `wifi-dnsd.c` compiles clean under `-Wall -Wextra -Werror`, and was
  **run and exercised** with real DNS queries — A, AAAA, MX, truncated
  headers, multi-question packets and compression pointers in the QNAME.
- All 83 checks in `tests/run-tests.sh` pass under `dash`.

**Not verified here**, and honestly out of reach in this environment:

- A full cross-compile. The OpenIPC toolchain is fetched from a GitHub
  release, which the sandbox's egress proxy blocks. Everything up to and
  including the compiler invocation was validated; the compile itself was not
  run.
- Anything requiring the radio: association, DHCP, `hostapd` on a real chip.
  `docs/09-testing.md` is the plan for that, and it needs hardware.

## Trimming for an 8 MB flash

`hostapd` is the only meaningful addition (~400–450 KB estimated). Check what
your build actually costs:

```sh
make BOARD=hi3518ev300_lite br-graph-size
ls -la output/images/rootfs.squashfs.hi3518ev300
```

If it does not fit, in order of what you lose least:

1. **Drop the captive DNS** (~15 KB): `BR2_PACKAGE_WIFI_PROVISION_CAPTIVE_DNS=n`.
   The setup page still works; the phone no longer opens it automatically, so
   the user types `http://192.168.4.1/`.
2. **Trim hostapd**: leave `_EAP`, `_WPS`, `_WPA3` and `_VLAN` off (the
   installer already does), and drop `BR2_PACKAGE_RTW_HOSTAPD_DRIVER_HOSTAP`
   and `_DRIVER_WIRED` if your chip needs neither.
3. **Drop the setup AP entirely** — `BR2_PACKAGE_RTW_HOSTAPD=n`. You keep
   persistent credentials, automatic reconnection, the state machine and
   `wifi-ctl`; you lose first-time setup over the air, so provisioning goes
   back to `wifi-ctl configure` over serial or Ethernet. This is the priority
   order in the brief: reliable Wi-Fi first, UX second.
4. Use `general/scripts/excludes/hi3518ev300_lite.list` to prune sensor blobs
   you do not ship.

## Running the tests

```sh
sh tests/run-tests.sh
```

Runs on the build host with no target hardware. It covers the parts where a
bug would be a security bug: hex encoding, input validation, config-file
generation, form decoding, the command channel and credential storage. It
does not cover the radio.
