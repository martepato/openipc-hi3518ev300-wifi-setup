#!/bin/bash
#
# Copyright (c) OpenIPC  https://openipc.org  MIT License
#
# build-image.sh -- produce a flashable OpenIPC image with Wi-Fi provisioning
# for the Xiaomi MJSXJ02HL (Hi3518EV300), ready for HiTool / HiBurn.
#
#   ./tools/build-image.sh [output-dir]
#
# This layers onto OpenIPC's official release rather than running Buildroot
# from source, because nothing here changes the kernel or the bootloader --
# only the root filesystem. The kernel and u-boot come out byte-identical to
# the official release (verified against the release's own md5sum file), so
# the diff a reviewer has to trust is exactly the rootfs.
#
# A full `make BOARD=hi3518ev300_lite` in an OpenIPC checkout is still the
# right thing when you HAVE changed the kernel; see docs/04-build.md.
#
# Needs: curl, squashfs-tools (mksquashfs/unsquashfs), u-boot-tools
#        (mkenvimage), and a host compiler for nothing at all -- the ARM
#        toolchain is downloaded.

set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:-$REPO/output}
WORK=$OUT/work
DL=$OUT/dl
REL=$OUT/release

UPSTREAM=https://github.com/openipc/firmware/releases/download
TOOLCHAIN_URL=$UPSTREAM/toolchain/toolchain.hisilicon-hi3516ev200.tgz
LITE_URL=$UPSTREAM/latest/openipc.hi3518ev300-nor-lite.tgz
ULTIMATE_URL=$UPSTREAM/latest/openipc.hi3518ev300-nor-ultimate.tgz
UBOOT_URL=$UPSTREAM/latest/u-boot-hi3518ev300-universal.bin
LIBNL_URL=https://github.com/thom311/libnl/releases/download/libnl3_9_0/libnl-3.9.0.tar.gz
HOSTAPD_REPO=https://github.com/lwfinger/rtl8188eu.git
# The commit OpenIPC pins for its rtw-hostapd package.
HOSTAPD_COMMIT=a69d6361ef0185aa7d2e4c774bc2de36fe83d81e

say() { printf '\n==> %s\n' "$*"; }

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing tool: $1" >&2; exit 1; }; }
for t in curl tar git make mksquashfs unsquashfs mkenvimage md5sum sha256sum; do need "$t"; done

mkdir -p "$DL" "$WORK" "$REL"

# ---------------------------------------------------------------- fetch --
fetch() { # url dest
    [ -s "$2" ] && { echo "    cached $(basename "$2")"; return; }
    curl -sSL --retry 3 -o "$2" "$1"
}
say "Fetching upstream artefacts"
fetch "$TOOLCHAIN_URL" "$DL/toolchain.tgz"
fetch "$LITE_URL"      "$DL/openipc-nor-lite.tgz"
fetch "$ULTIMATE_URL"  "$DL/openipc-nor-ultimate.tgz"
fetch "$UBOOT_URL"     "$DL/u-boot-hi3518ev300-universal.bin"
fetch "$LIBNL_URL"     "$DL/libnl-3.9.0.tar.gz"

say "Unpacking official images"
for v in lite ultimate; do
    rm -rf "$WORK/$v"; mkdir -p "$WORK/$v"
    tar xzf "$DL/openipc-nor-$v.tgz" -C "$WORK/$v"
    rm -rf "$WORK/$v/rootfs"
    unsquashfs -d "$WORK/$v/rootfs" -q "$WORK/$v/rootfs.squashfs.hi3518ev300" >/dev/null
done
# The official release ships its own md5sum; check it rather than trusting
# the download.
( cd "$WORK/lite" && md5sum -c uImage.hi3518ev300.md5sum >/dev/null \
    && echo "    kernel md5 verified against the release's own checksum" )

say "Unpacking toolchain"
rm -rf "$WORK/toolchain"; mkdir -p "$WORK/toolchain"
tar xzf "$DL/toolchain.tgz" -C "$WORK/toolchain"
TCDIR=$(dirname "$(dirname "$(find "$WORK/toolchain" -name 'arm-openipc-linux-musleabi-gcc' | head -1)")")
export PATH=$TCDIR/bin:$PATH
CROSS=arm-openipc-linux-musleabi
echo "    $($CROSS-gcc --version | head -1)"

# ------------------------------------------------------------- libnl ----
# Only needed to LINK hostapd. The image already ships libnl-3.so.200 /
# libnl-genl-3.so.200 (used by its wpa_supplicant), and this build produces
# the same soname, so nothing has to be installed onto the camera.
say "Cross-compiling libnl (link-time only)"
STAGE=$WORK/stage-libnl
if [ ! -e "$STAGE/lib/libnl-3.so" ]; then
    rm -rf "$WORK/libnl-3.9.0"
    tar xzf "$DL/libnl-3.9.0.tar.gz" -C "$WORK"
    ( cd "$WORK/libnl-3.9.0"
      ./configure --host=$CROSS --prefix="$STAGE" --disable-cli --disable-static \
          CC=$CROSS-gcc CFLAGS="-Os" >/dev/null
      make -j"$(nproc)" >/dev/null && make install >/dev/null )
fi
echo "    soname: $($CROSS-readelf -d "$STAGE/lib/libnl-3.so" | sed -n 's/.*soname: \[\(.*\)\]/\1/p')"

# ------------------------------------------------------------ hostapd ---
say "Cross-compiling hostapd (OpenIPC's pinned source)"
HAPD=$WORK/rtw-hostapd-src/hostapd-2.9/hostapd
if [ ! -x "$HAPD/hostapd" ]; then
    [ -d "$WORK/rtw-hostapd-src" ] || git clone -q --filter=blob:none --no-checkout "$HOSTAPD_REPO" "$WORK/rtw-hostapd-src"
    ( cd "$WORK/rtw-hostapd-src" && git checkout -q "$HOSTAPD_COMMIT" )
    cat > "$HAPD/.config" <<EOF
# Only what a temporary WPA2-PSK / open setup AP needs. No EAP, RADIUS, WPS
# or VLAN: dead weight on NOR flash and extra attack surface on an access
# point that exists for two minutes.
CONFIG_DRIVER_NL80211=y
CONFIG_DRIVER_RTW=y
CONFIG_LIBNL32=y
CONFIG_IEEE80211N=y
CONFIG_TLS=internal
CONFIG_INTERNAL_LIBTOMMATH=y
CONFIG_NO_RADIUS=y
CONFIG_NO_ACCOUNTING=y
CONFIG_NO_VLAN=y
CONFIG_NO_DUMP_STATE=y
CONFIG_ELOOP=eloop
# Appended, never set on the make command line: the Makefile adds its own
# -I../src and a command-line CFLAGS= would replace that wholesale.
CFLAGS += -Os -I$STAGE/include/libnl3 -Wno-error -Wno-implicit-function-declaration
LIBS += -L$STAGE/lib
EOF
    ( cd "$HAPD"
      PKG_CONFIG_LIBDIR=$STAGE/lib/pkgconfig PKG_CONFIG_PATH=$STAGE/lib/pkgconfig \
        make -j"$(nproc)" CC=$CROSS-gcc >/dev/null
      $CROSS-strip hostapd hostapd_cli )
fi
echo "    hostapd $(stat -c%s "$HAPD/hostapd") bytes; needs:" \
     "$($CROSS-readelf -d "$HAPD/hostapd" | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p' | tr '\n' ' ')"

# ----------------------------------------------------------- wifi-dnsd --
say "Cross-compiling wifi-dnsd"
$CROSS-gcc -Os -Wall -Wextra -Werror -o "$WORK/wifi-dnsd" "$REPO/package/wifi-provision/src/wifi-dnsd.c"
$CROSS-strip "$WORK/wifi-dnsd"
echo "    $(stat -c%s "$WORK/wifi-dnsd") bytes"

# ------------------------------------------------------------- rootfs ---
say "Building root filesystem"
R=$WORK/rootfs
rm -rf "$R"; cp -a "$WORK/lite/rootfs" "$R"
P=$REPO/package/wifi-provision/files

install -d -m 755 "$R/usr/libexec/wifi"
install -m 644 "$P"/usr/libexec/wifi/*.sh "$R/usr/libexec/wifi/"
for b in wifi-manager wifi-ctl wifi-button-watch wifi-led; do
    install -m 755 "$P/usr/sbin/$b" "$R/usr/sbin/$b"
done
install -m 755 "$P/etc/init.d/S41wifi" "$R/etc/init.d/S41wifi"
install -d -m 755 "$R/var/www-wifi/cgi-bin"
install -m 644 "$P/var/www-wifi/index.html"   "$R/var/www-wifi/index.html"
install -m 755 "$P/var/www-wifi/cgi-bin/wifi" "$R/var/www-wifi/cgi-bin/wifi"
install -m 644 -D "$REPO/install/board-profiles/mjsxj02hl.defaults" "$R/etc/wifi/wifi.defaults"
install -m 755 "$WORK/wifi-dnsd"      "$R/usr/sbin/wifi-dnsd"
install -m 755 "$HAPD/hostapd"        "$R/usr/sbin/hostapd"
install -m 755 "$HAPD/hostapd_cli"    "$R/usr/bin/hostapd_cli"

# The RTL8189FTV driver, from OpenIPC's own "ultimate" release -- nor-lite
# does not carry it. Safe to move between the two: CONFIG_MODVERSIONS is off,
# vermagic is identical, and mac80211.ko is byte-for-byte the same in both,
# so they are the same kernel build. Asserted, not assumed:
KV=$(ls "$R/lib/modules" | head -1)
a=$(md5sum "$WORK/lite/rootfs/lib/modules/$KV/kernel/net/mac80211/mac80211.ko" | cut -d' ' -f1)
b=$(md5sum "$WORK/ultimate/rootfs/lib/modules/$KV/kernel/net/mac80211/mac80211.ko" | cut -d' ' -f1)
[ "$a" = "$b" ] || { echo "ABORT: lite and ultimate kernels differ; 8189fs.ko is not portable" >&2; exit 1; }
echo "    kernel builds match ($a) -- 8189fs.ko is portable"
MODDIR=$R/lib/modules/$KV
install -m 644 -D "$WORK/ultimate/rootfs/lib/modules/$KV/extra/8189fs.ko" "$MODDIR/extra/8189fs.ko"
# modprobe here is busybox: it reads the TEXT modules.dep/modules.alias and
# ignores the .bin indexes, so the index is maintained by appending the two
# lines the driver needs. depmod is in neither the image nor (necessarily)
# the build host. 8189fs has no dependencies, hence the empty RHS.
grep -q '^extra/8189fs\.ko:' "$MODDIR/modules.dep" || echo 'extra/8189fs.ko:' >> "$MODDIR/modules.dep"
grep -h '8189fs' "$WORK/ultimate/rootfs/lib/modules/$KV/modules.alias" | while read -r al; do
    grep -qxF "$al" "$MODDIR/modules.alias" || echo "$al" >> "$MODDIR/modules.alias"
done

# ifup must not start a second wpa_supplicant against wifi-manager's.
[ -f "$R/etc/network/interfaces.d/wlan0.stock" ] || \
    mv "$R/etc/network/interfaces.d/wlan0" "$R/etc/network/interfaces.d/wlan0.stock"
install -m 644 "$P/etc/network/interfaces.d/wlan0" "$R/etc/network/interfaces.d/wlan0"

grep -q 'rtl8189fs-hi3518ev300-mjsxj02hl' "$R/etc/wireless/sdio" || {
    awk -v prof="$REPO/install/board-profiles/mjsxj02hl.sh" '
        /^exit 1$/ && !d { while ((getline l < prof) > 0) print l; close(prof); print ""; d=1 }
        { print }' "$R/etc/wireless/sdio" > "$R/etc/wireless/sdio.new"
    mv "$R/etc/wireless/sdio.new" "$R/etc/wireless/sdio"
    chmod 755 "$R/etc/wireless/sdio"
}

# Match the stock image and the kernel's config: xz, 128K blocks, no xattrs
# (CONFIG_SQUASHFS_XATTR is off), BCJ ARM filter (CONFIG_XZ_DEC_ARM=y).
mksquashfs "$R" "$REL/rootfs.squashfs.hi3518ev300" \
    -comp xz -Xbcj arm -b 131072 -no-xattrs -all-root -noappend -quiet

# ---------------------------------------------------------------- env ---
say "Building u-boot environment"
# Starts from the bootloader's OWN default environment, extracted from the
# gzip payload inside the u-boot binary, so nothing is invented and nothing
# unrelated is lost.
python3 - "$DL/u-boot-hi3518ev300-universal.bin" "$REL/uboot-env.txt" <<'PY'
import sys, re, gzip
raw = open(sys.argv[1],'rb').read()
off = raw.find(b'\x1f\x8b\x08')
blob = gzip.decompress(raw[off:])
i = blob.find(b'bootargs=mem=')
win = blob[max(0,i-3000): i+6000]
env, order = {}, []
for p in win.split(b'\x00'):
    s = p.decode('latin1')
    if re.match(r'^[A-Za-z_][A-Za-z0-9_]*=', s) and len(s) < 400:
        k, v = s.split('=', 1)
        if k not in env: order.append(k)
        env[k] = v
# The only deviations from stock, each with a reason:
#  1. u-boot's own mtdpartsnor16m -- the 5120k default cannot hold a rootfs
#     with provisioning (5.4 MB). Identical to what `run setnor16m` stores.
env['mtdparts'] = 'hi_sfc:256k(boot),64k(env),3072k(kernel),10240k(rootfs),-(rootfs_data)'
#  2. bootargs already ends in ${extras}, so the allocator goes there and
#     bootargs itself stays byte-identical to the default.
env['extras']   = 'mmz_allocator=hisi'
#  3. Memory split for this camera, from OpenIPC/device-mjsxj02hl autoconfig.
env['osmem']    = '35M'
env['totalmem'] = '64M'
#  4. Wi-Fi board profile, so the radio is up on the first boot with nothing
#     for the owner to type.
env['wlandev']  = 'rtl8189fs-hi3518ev300-mjsxj02hl'
for k in ('extras','totalmem','wlandev'):
    if k not in order: order.append(k)
open(sys.argv[2],'w').write('\n'.join(f'{k}={env[k]}' for k in order) + '\n')
print(f"    {len(order)} variables")
PY
mkenvimage -s 0x10000 -o "$REL/env.bin" "$REL/uboot-env.txt"
python3 - "$REL/env.bin" <<'PY'
import sys, binascii
d = open(sys.argv[1],'rb').read()
assert len(d) == 0x10000, len(d)
assert int.from_bytes(d[:4],'little') == (binascii.crc32(d[4:]) & 0xffffffff), "env CRC mismatch"
print("    env.bin 64K, CRC verified")
PY

# ------------------------------------------------------------ package ---
say "Packaging"
cp "$DL/u-boot-hi3518ev300-universal.bin" "$REL/"
cp "$WORK/lite/uImage.hi3518ev300"        "$REL/"
python3 - "$REL" <<'PY'
import sys, os
REL = sys.argv[1]
parts = [("fastboot",0,256,"u-boot-hi3518ev300-universal.bin"),
         ("env",256,64,"env.bin"),
         ("kernel",320,3072,"uImage.hi3518ev300"),
         ("rootfs",3392,10240,"rootfs.squashfs.hi3518ev300"),
         ("rootfs_data",13632,2752,"")]
assert sum(p[2] for p in parts) == 16384
for i in range(1,len(parts)):
    assert parts[i][1] == parts[i-1][1]+parts[i-1][2], "partition gap"
x = ['<?xml version="1.0" encoding="GB2312" ?>','<Partition_Info ProgrammerFile="">']
for n,s,l,f in parts:
    if f:
        sz = os.path.getsize(f"{REL}/{f}")
        assert sz <= l*1024, f"{f} is {sz} bytes, larger than {n} ({l}K)"
        print(f"    {n:<12} {s:>6}K {l:>6}K  {sz:>9,} bytes  ({100*sz/(l*1024):.0f}% full)")
    x.append(f'<Part Sel="1" PartitionName="{n}" FlashType="spi" FileSystem="none" '
             f'Start="{s}K" Length="{l}K" SelectFile="{f}"/>')
x.append('</Partition_Info>')
open(f"{REL}/usb-burn.xml","w").write('\n'.join(x)+'\n')
PY
cp "$REPO/docs/11-flashing-mjsxj02hl.md" "$REL/README-FLASHING.md" 2>/dev/null || true
( cd "$REL"
  md5sum    u-boot-hi3518ev300-universal.bin env.bin uImage.hi3518ev300 rootfs.squashfs.hi3518ev300 > md5sums.txt
  sha256sum u-boot-hi3518ev300-universal.bin env.bin uImage.hi3518ev300 rootfs.squashfs.hi3518ev300 > sha256sums.txt )

say "Done -- $REL"
ls -la "$REL"
