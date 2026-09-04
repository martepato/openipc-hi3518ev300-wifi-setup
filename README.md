# Wi‑Fi provisioning for OpenIPC on Hi3518EV300

Power on a new camera, join the `OpenIPC-A1B2` network it broadcasts, pick your
Wi‑Fi from a list, type the password, press Connect. From then on it joins that
network on every boot and reconnects by itself.

No serial console, no SSH, no editing `wpa_supplicant.conf`, no credentials
baked into the firmware image.

**Status: running on hardware.** Built, flashed and provisioned end to end on a
Xiaomi MJSXJ02HL. See [Verified vs. untested](#verified-vs-untested).

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

## Quick start

### A flashable image for a Xiaomi MJSXJ02HL

```sh
git clone https://github.com/martepato/openipc-hi3518ev300-wifi-setup.git
cd openipc-hi3518ev300-wifi-setup
./tools/build-image.sh          # writes ./output/release/
```

Out comes everything HiTool/HiBurn needs: bootloader, U-Boot environment,
kernel, root filesystem and the partition table. Flash it, then set up Wi‑Fi
from your phone — [`docs/11-flashing-mjsxj02hl.md`](docs/11-flashing-mjsxj02hl.md).

The builder layers onto OpenIPC's official release rather than rebuilding
everything, because this project changes neither the kernel nor the
bootloader: both come out byte-identical to upstream, verified against the
checksum OpenIPC publishes. Only the root filesystem differs.

There is deliberately **no prebuilt image to download** — the assembled
firmware contains proprietary components this project cannot redistribute.
[THIRD-PARTY-LICENSES.md](THIRD-PARTY-LICENSES.md) explains exactly why, and
why running the builder is the better answer anyway.

### Into your own OpenIPC build

```sh
git clone https://github.com/OpenIPC/firmware.git
./tools/install-into-openipc.sh ../firmware hi3518ev300_lite mjsxj02hl
cd ../firmware && make BOARD=hi3518ev300_lite
```

Adds one Buildroot package and a one-line change to `general/package/Config.in`.
Full inventory: [`docs/03-openipc-changes.md`](docs/03-openipc-changes.md).

## How it behaves

- **No configuration** → starts `OpenIPC-XXXX` (suffix from the MAC, so two
  cameras are never ambiguous) and serves a setup page at `192.168.4.1`.
- **Credentials submitted** → tested *before* they are saved. If they fail,
  nothing is written and the setup network returns by itself within a minute,
  carrying the reason. A mistyped password cannot lock you out.
- **Connected** → credentials stored atomically, mode `0600`, as a derived PSK
  rather than the plaintext passphrase.
- **Network lost** → retries indefinitely. Deliberately does **not** revert to
  hotspot mode: a router reboot and a wrong password look identical from the
  camera, and a camera that self-resets on every blip has to be set up again
  each time. Reasoning in [`docs/01-architecture.md`](docs/01-architecture.md) §4.
- **Configured from OpenIPC's own web UI instead?** That works too. The manager
  watches the U-Boot environment that page writes to and adopts those
  credentials through the same test-then-commit path, with no reboot.
- **Status on the LEDs**, where the board has them — alternating colours means
  "waiting to be set up". Handed back to the camera's own indicator once
  connected.
- **No Wi‑Fi hardware, or a driver that will not load** → logged clearly, and
  the camera boots and streams normally anyway.
- **Change networks later** → hold the reset button 5 s while running, or
  `wifi-ctl provision`.

## Which Wi‑Fi chip does your board have?

The provisioning system is chip-independent; the one thing it cannot know is
which SDIO radio is fitted and how it is powered. That gap is confined to one
file (`/etc/wireless/sdio`) and one variable (`wlandev`).

**Xiaomi MJSXJ02HL is solved** — RTL8189FTV on SDIO, no power GPIO, reset
button on GPIO 0 — and its profile ships in [`boards/mjsxj02hl/`](boards/mjsxj02hl).
Note that the stock `rtl8189fs-generic` profile does **not** work on that
camera, and fails silently.

For any other board, [`docs/02-hardware.md`](docs/02-hardware.md) separates
what is **confirmed** from **assumed** and **unknown**, and gives the
diagnostic commands to settle it. Nothing about the chip has been invented.

## Documentation

| | |
|---|---|
| [01-architecture.md](docs/01-architecture.md) | Design, state machine, and why each choice was made over the obvious alternative |
| [02-hardware.md](docs/02-hardware.md) | Confirmed / assumed / unknown, with sources; diagnostics; adding a board profile |
| [03-openipc-changes.md](docs/03-openipc-changes.md) | Every file added or modified in an OpenIPC tree |
| [04-build.md](docs/04-build.md) | Building with Buildroot, trimming for 8 MB flash |
| [05-flash-and-recovery.md](docs/05-flash-and-recovery.md) | Flashing, upgrades, recovery |
| [06-user-guide.md](docs/06-user-guide.md) | The end-user setup procedure |
| [07-troubleshooting.md](docs/07-troubleshooting.md) | SDIO, driver, hostapd, DHCP, portal, LEDs |
| [08-security.md](docs/08-security.md) | Injection, credential handling, and the open-AP trade-off |
| [09-testing.md](docs/09-testing.md) | Hardware, provisioning, security and reliability test plan |
| [10-device-mjsxj02hl.md](docs/10-device-mjsxj02hl.md) | Xiaomi MJSXJ02HL specifics |
| [11-flashing-mjsxj02hl.md](docs/11-flashing-mjsxj02hl.md) | Building and flashing with HiTool/HiBurn |

## Footprint

~26 KB (squashfs-xz) of scripts and the setup page, ~5 KB for the DNS
responder on ARM. `hostapd` is the only significant addition at 377 KB;
`wpa_supplicant`, `wpa_cli` and BusyBox `httpd`/`udhcpd`/`udhcpc` are already
in every OpenIPC image. No Python, no Node, no web framework, no
NetworkManager, no systemd.

## Tests

```sh
sh tests/run-tests.sh          # 119 checks, no hardware required
```

Covers the parts where a bug would be a security bug — form decoding,
validation, config generation, credential storage — plus the LED patterns and
the stray-process sweep, driven against stand-in `/proc` and `/sys` trees.
Includes a live assertion that an SSID of `$(touch /tmp/pwned)` creates no such
file.

## Verified vs. untested

Verified on hardware (Xiaomi MJSXJ02HL): boots, RTL8189FTV enumerates on SDIO,
hostapd brings up the setup AP, the LED patterns render, the captive portal is
reachable, provisioning completes, and both resets work — the button held at
power-on erases the overlay, held while running it clears Wi-Fi only.

Not yet exercised: the reliability matrix in
[`docs/09-testing.md`](docs/09-testing.md) — power loss during a credential
save, 30-minute router outages, repeated associate/disassociate cycles — and
every board other than the MJSXJ02HL.

## Contributing

Board profiles for other cameras are the most useful thing to send. See
[CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT — see [LICENSE](LICENSE). Third-party components and the reason there is no
binary release: [THIRD-PARTY-LICENSES.md](THIRD-PARTY-LICENSES.md).

Independent community project. Not endorsed by or affiliated with OpenIPC.
