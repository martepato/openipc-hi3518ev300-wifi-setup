# Building

There are two ways to build, and they have different requirements:

| | What it does | When to use it |
|---|---|---|
| [`tools/build-image.sh`](#a-flashable-image-toolsbuild-imagesh) | Layers the provisioning system onto OpenIPC's official release | You want a flashable image and have not changed the kernel |
| [Buildroot](#a-full-buildroot-build) | Rebuilds the whole firmware from source | You changed the kernel, or you want this in your own OpenIPC build |

## Both paths need Linux on x86-64

Not portability fussiness — a hard constraint with a specific cause. Both
paths use OpenIPC's ARM cross-toolchain, and that toolchain is distributed as
a **glibc x86-64 Linux ELF binary**:

```console
$ file toolchain-wrapper          # what every arm-openipc-*-gcc links to
ELF 64-bit LSB pie executable, x86-64, version 1 (SYSV), dynamically linked,
interpreter /lib64/ld-linux-x86-64.so.2, for GNU/Linux 3.2.0, stripped

$ ldd toolchain-wrapper
    libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6
    /lib64/ld-linux-x86-64.so.2
```

So it cannot run on macOS or Windows at all — a Mach-O host cannot exec an ELF
binary, and no amount of Homebrew fixes that — and on an arm64 Linux host only
under emulation. `tools/build-image.sh` checks this before doing anything and
tells you so, rather than failing halfway through with a confusing error.

### On macOS or Windows: build in a container

From the root of this repository, with Docker Desktop, OrbStack, Podman or
Colima running:

```sh
docker run --rm -it --platform linux/amd64 -v "$PWD:/src" -w /src \
  debian:bookworm bash -c '
    apt-get update -qq &&
    apt-get install -y -qq build-essential coreutils curl file findutils \
      gawk git pkg-config python3 sed squashfs-tools tar u-boot-tools &&
    ./tools/build-image.sh'
```

The images land in `./output/release/` on your own disk — the bind mount means
nothing is trapped inside the container. `--platform linux/amd64` is
load-bearing on Apple Silicon: without it Docker gives you an arm64 image and
the toolchain will not run. Emulation makes it slow — budget 15–30 minutes for
a first build against a few minutes native — but the result is a normal,
complete build, byte-for-byte what a Linux host produces.

Podman is the same command with `podman` in place of `docker`.

## A flashable image: `tools/build-image.sh`

### Requirements

```sh
# Debian / Ubuntu
sudo apt-get install -y build-essential coreutils curl file findutils gawk \
    git pkg-config python3 sed squashfs-tools tar u-boot-tools

# Fedora
sudo dnf install -y make coreutils curl file findutils gawk git \
    pkgconf-pkg-config python3 sed squashfs-tools tar uboot-tools

# Arch
sudo pacman -S --needed base-devel coreutils curl file findutils gawk git \
    pkgconf python sed squashfs-tools tar uboot-tools
```

The two that are not usually already installed, and the ones that actually
bite:

- **`mkenvimage`** (`u-boot-tools`) — writes the U-Boot environment image.
- **`mksquashfs` / `unsquashfs`** (`squashfs-tools`) — unpack and repack the
  root filesystem.

Nothing else has to be installed: the ARM toolchain, the OpenIPC release
images, libnl and hostapd's source are all downloaded by the script into
`output/dl/` and cached there. Expect about 120 MB of downloads on a first
run.

The script checks every tool before it starts and, if any are missing, prints
**all** of them together with the install command for your distribution.
Finding out about one missing package per build is a miserable way to work.

### Running it

```sh
./tools/build-image.sh              # writes ./output/release/
./tools/build-image.sh /some/where  # or somewhere else
```

### The output is reproducible

Two builds of the same commit produce byte-identical files — the whole release
directory, checked file by file:

```console
$ ./tools/build-image.sh /tmp/a && ./tools/build-image.sh /tmp/b
$ for f in $(ls /tmp/a/release); do cmp /tmp/a/release/$f /tmp/b/release/$f; done
$                                       # silence is the result you want
```

That matters because this project ships checksums instead of images. If the
same commit gave a different checksum every run, "the image I built matches
yours" would be indistinguishable from "I built at a different minute", and
the checksums would be decoration.

Only two things ever varied, and both are pinned to `SOURCE_DATE_EPOCH`
(taken from the commit being built, or from the environment if an outer build
system already set it):

- **The mtimes of files this build installs.** Clamped, not flattened:
  anything newer than `SOURCE_DATE_EPOCH` is something this build just wrote
  and gets pinned; anything older is upstream's and keeps the date the release
  tarball gave it. So `/usr/bin/majestic` still shows OpenIPC's date and
  `/usr/sbin/wifi-manager` shows the commit's, rather than everything reading
  1970.
- **The timestamp mksquashfs writes into the superblock**, via `-mkfs-time`.

Everything else was already deterministic: the kernel and bootloader are
copied from the release untouched, and hostapd, libnl and `wifi-dnsd` come out
byte-identical from the pinned toolchain build after build.

To reproduce someone else's image exactly, build the same commit. To pin it
yourself, set `SOURCE_DATE_EPOCH` before running the script.

## A full Buildroot build

### Requirements

Linux on x86-64, as above, plus Buildroot's usual dependencies:

```sh
sudo apt-get install -y build-essential bc bison flex gawk git gperf \
    libncurses-dev libssl-dev python3 rsync unzip wget cpio file whiptail
```

### Build

```sh
git clone https://github.com/OpenIPC/firmware.git
git clone https://github.com/martepato/openipc-hi3518ev300-wifi-setup.git

cd openipc-hi3518ev300-wifi-setup
./tools/install-into-openipc.sh ../firmware hi3518ev300_lite

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
- All 119 checks in `tests/run-tests.sh` pass under `dash`.

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
