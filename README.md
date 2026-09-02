# Hi3518EV300 — user-friendly Wi‑Fi setup for OpenIPC

Power on a new camera, join the `OpenIPC-A1B2` network it broadcasts, pick
your Wi‑Fi from a list, type the password, press Connect. From then on the
camera joins that network on every boot and reconnects by itself.

No serial console, no SSH, no editing `wpa_supplicant.conf`, no credentials
baked into the firmware image.

```
                    +--------------------------+
                    |       Hi3518EV300        |
                    |  sdhci-hisi (mmc1, SDIO) |
                    +------------+-------------+
                                 |
                    +------------v-------------+
                    |   SDIO Wi-Fi chip        |
                    +------------+-------------+
                                 |
                    +------------v-------------+
                    |          wlan0           |
                    +------------+-------------+
                                 |
             +-------------------+--------------------+
        NORMAL MODE                              SETUP MODE
             |                                        |
      wpa_supplicant                              hostapd
             |                                        |
        udhcpc (client)                    udhcpd + httpd + wifi-dnsd
             |                                        |
        home router                          setup page on 192.168.4.1
```

## Status

This repository previously held design notes only. It now contains a working
implementation: a Buildroot package that drops into an
[OpenIPC/firmware](https://github.com/OpenIPC/firmware) checkout, plus an
installer, a host-side test suite and documentation.

What has actually been verified is listed precisely in
[`docs/04-build.md`](docs/04-build.md#what-was-verified-here-and-what-was-not) —
including what has **not** been: a full cross-compile and anything requiring
the radio both need hardware this was not built on.

## Ready-to-flash image

For a Xiaomi MJSXJ02HL, `tools/build-image.sh` produces a complete set for
HiTool/HiBurn — bootloader, u-boot environment, kernel, root filesystem and
the partition table:

```sh
./tools/build-image.sh          # writes ./output/release/
```

It layers onto OpenIPC's official release rather than rebuilding everything,
because nothing here changes the kernel or the bootloader: both come out
byte-identical to upstream (verified against the release's own `md5sum`
file), so the only thing to review is the root filesystem. It cross-compiles
`hostapd` and `wifi-dnsd` with the OpenIPC toolchain and adds the RTL8189FTV
driver from OpenIPC's own `ultimate` build.

It uses OpenIPC's 16 MB flash layout (`mtdpartsnor16m`) rather than the 8 MB
one the MJSXJ02HL instructions use, because the root filesystem with
provisioning is 5.4 MB and does not fit in a 5120K partition. The camera has
16 MB. See [`docs/11-flashing-mjsxj02hl.md`](docs/11-flashing-mjsxj02hl.md).

## Building from source with Buildroot

```sh
git clone https://github.com/OpenIPC/firmware.git
git clone https://github.com/martepato/openipc-hi3518ev300-wifi-setup.git

cd openipc-hi3518ev300-wifi-setup
./install/install-into-openipc.sh ../firmware hi3518ev300_lite

cd ../firmware
echo 'BR2_PACKAGE_RTL8189FS_OPENIPC=y' >> \
    br-ext-chip-hisilicon/configs/hi3518ev300_lite_defconfig   # your radio
make BOARD=hi3518ev300_lite
```

Then on the camera, once, tell it which radio it has:

```sh
fw_setenv wlandev rtl8189fs-generic
```

Full instructions: [`docs/04-build.md`](docs/04-build.md).

## Which Wi‑Fi chip does your board have?

The provisioning system is chip-independent; the one thing it cannot know is
which SDIO radio is fitted and how it is powered. That gap is confined to one
file (`/etc/wireless/sdio`) and one variable (`wlandev`).

**Xiaomi MJSXJ02HL is already solved** — RTL8189FTV on SDIO, no power GPIO,
reset button on GPIO 0 — and its bring-up profile ships here:

```sh
./install/install-into-openipc.sh ../firmware hi3518ev300_lite mjsxj02hl
fw_setenv wlandev rtl8189fs-hi3518ev300-mjsxj02hl     # on the camera
```

See [`docs/10-device-mjsxj02hl.md`](docs/10-device-mjsxj02hl.md). The stock
`rtl8189fs-generic` profile does **not** work on that camera, and fails
silently.

For any other board, [`docs/02-hardware.md`](docs/02-hardware.md) separates
what is **confirmed** from **assumed** and **unknown**, and gives the
diagnostic commands to settle it. Nothing about the chip has been invented.

## How it behaves

- **No configuration** → starts `OpenIPC-XXXX` (suffix from the MAC, so two
  cameras are never ambiguous) and serves a setup page at `192.168.4.1`.
- **Credentials submitted** → tested *before* they are saved. If they fail,
  nothing is written and the setup network comes back by itself within a
  minute, carrying the reason. A mistyped password cannot lock you out.
- **Connected** → credentials stored atomically, mode `0600`, as a derived
  PSK rather than the plaintext passphrase.
- **Network lost** → retries indefinitely. Deliberately does **not** revert
  to hotspot mode: a router reboot and a wrong password look identical from
  the camera, and a camera that self-resets on every blip has to be set up
  again each time. Reasoning in
  [`docs/01-architecture.md`](docs/01-architecture.md) §4.
- **No Wi‑Fi hardware, or a driver that will not load** → logged clearly, and
  the camera boots and streams normally anyway.
- **Change networks later** → a GPIO button held 5 s, or `wifi-ctl provision`.
- **Configured from OpenIPC's own web UI instead?** That works too — the
  manager watches the U-Boot environment that page writes to, and adopts
  those credentials through the same test-then-commit path, with no reboot.
- **Status on the LEDs**, where the board has them — alternating colours means
  "waiting to be set up", so first-time setup is no longer a silent guess.
  Released back to the camera's own indicator once connected.

## Documentation

| | |
|---|---|
| [01-architecture.md](docs/01-architecture.md) | Design, state machine, and why each choice was made over the obvious alternative |
| [02-hardware.md](docs/02-hardware.md) | Confirmed / assumed / unknown, with sources; diagnostics; adding a board profile |
| [03-openipc-changes.md](docs/03-openipc-changes.md) | Every file added or modified in an OpenIPC tree |
| [04-build.md](docs/04-build.md) | Build, trimming for 8 MB flash, what was verified |
| [05-flash-and-recovery.md](docs/05-flash-and-recovery.md) | Flashing, upgrades, recovery |
| [06-user-guide.md](docs/06-user-guide.md) | The end-user setup procedure |
| [07-troubleshooting.md](docs/07-troubleshooting.md) | SDIO, driver, hostapd, DHCP, portal |
| [08-security.md](docs/08-security.md) | Injection, credential handling, and the open-AP trade-off |
| [09-testing.md](docs/09-testing.md) | Hardware, provisioning, security and reliability test plan |
| [10-device-mjsxj02hl.md](docs/10-device-mjsxj02hl.md) | Xiaomi MJSXJ02HL: confirmed hardware, bring-up profile, shared reset button |
| [11-flashing-mjsxj02hl.md](docs/11-flashing-mjsxj02hl.md) | Building and flashing a ready-to-burn image with HiTool/HiBurn |

## Footprint

~26 KB (squashfs-xz) of scripts and the setup page, ~15 KB for the DNS
responder. `hostapd` is the only significant addition at an estimated
400–450 KB; `wpa_supplicant`, `wpa_cli` and BusyBox `httpd`/`udhcpd`/`udhcpc`
are already in every OpenIPC image. No Python, no Node, no web framework, no
NetworkManager, no systemd.

## Tests

```sh
sh tests/run-tests.sh          # 83 checks, no hardware required
```

Covers the parts where a bug would be a security bug: form decoding,
validation, config generation, credential storage. Includes a live assertion
that an SSID of `$(touch /tmp/pwned)` creates no such file.

## License

MIT — see [LICENSE](LICENSE).
