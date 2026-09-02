# Licensing

This repository's own contents are MIT — see [LICENSE](LICENSE).

That covers everything *authored here*: the provisioning scripts, the setup
page and its CGI, `wifi-dnsd.c`, the board profile, the Buildroot package, the
installer and the image builder.

It does **not** cover the firmware those tools assemble, which is why there is
no flashable image attached to any release. The reasoning is below, because
"just attach the .tgz" is the obvious thing to want and it is worth being
explicit about why this project does not.

## Why no binary firmware release

`tools/build-image.sh` produces a flashable image by layering this project
onto OpenIPC's official `hi3518ev300` release. The result contains software
this project has no right to redistribute:

| Component | License | Redistributable by us? |
|---|---|---|
| **majestic** (`/usr/bin/majestic`, 946 KB) | Proprietary, OpenIPC EULA | **No** — see below |
| **HiSilicon vendor SDK** (`libmpi.so`, `libisp.so`, `libive.so`, `libVoiceEngine.so`, 32 `open_*.ko`) | Proprietary HiSilicon | **No** |
| Linux kernel (`uImage`), U-Boot, BusyBox, `8189fs.ko` | GPL-2.0 | Yes, with a corresponding-source offer |
| wpa_supplicant, hostapd | BSD-3-Clause | Yes, with the notice retained |
| libnl | LGPL-2.1 | Yes |
| musl libc | MIT | Yes |
| Everything from this repository | MIT | Yes |

The majestic EULA is the binding constraint. Section 5 permits redistributing
**unmodified official** OpenIPC firmware images for noncommercial purposes.
The image this project builds is a *modified* image — that is the entire point
of it — so Section 5 does not apply to it, and no other clause grants a
redistribution right. Section 1 grants installation and use, not distribution.

The HiSilicon vendor blobs are a second, independent blocker with no
noncommercial carve-out at all.

None of this restricts **you**. The EULA grants free personal and
noncommercial use, so building the image and flashing it onto a camera you own
is squarely permitted. What is not granted is *us* publishing the assembled
result for download.

## What this means in practice

Run the builder. It fetches the official release straight from OpenIPC,
verifies the kernel against the checksum OpenIPC publishes with it, and
assembles the image locally:

```sh
./tools/build-image.sh          # writes ./output/release/
```

This is better practice regardless of licensing. Nobody should flash a
firmware binary offered by a third-party repository when one command
reproduces it from the vendor's own artefacts, and the kernel and bootloader
come out byte-identical to OpenIPC's release so there is nothing to take on
trust.

## GPL corresponding source

The build consumes prebuilt GPL binaries — the kernel, U-Boot and BusyBox —
exactly as OpenIPC publishes them. Their corresponding source is:

- Firmware and build system: <https://github.com/OpenIPC/firmware>
- Kernel: <https://github.com/openipc/linux>, branch `hisilicon-hi3516ev200`
- U-Boot: published by OpenIPC with the firmware releases

`hostapd` is built from source during the build, from the commit OpenIPC pins
for its `rtw-hostapd` package: <https://github.com/lwfinger/rtl8188eu> at
`a69d6361ef0185aa7d2e4c774bc2de36fe83d81e` (hostapd 2.9, BSD-3-Clause).
`libnl` 3.9.0 (LGPL-2.1) is built only to link against; the runtime copy is
the one already in the OpenIPC image.

## Trademarks

The majestic EULA Section 6 grants no rights to the OpenIPC name or logos.
This project is an independent community contribution. It is not endorsed by,
certified by, or affiliated with OpenIPC, and nothing here should be read as
claiming otherwise.
