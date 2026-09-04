# Changelog

Notable changes to this project. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
this project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.1] — 2026-09-04

Fixes for four faults found by running 1.0.0 on a Xiaomi MJSXJ02HL. All four
are confirmed fixed on that camera: the build was flashed and behaved as
expected.

### Fixed

- **The setup SSID did not match the camera's MAC.** The suffix is meant to be
  the last four hex digits so it matches what a router shows, but
  `tail -c 5 | head -c 4` returned digits 9-11 rather than 9-12 — a camera
  whose MAC ended `EE:FF` advertised `OpenIPC-DEEF`. Covered by tests across a
  range of MACs, including short and all-zero identity sources.
- **The signal meter overlapped the network name.** Four block characters in a
  1.4rem box, wider than their container and flat grey. Replaced with a 20×16
  SVG of four bars that fills by strength and follows the theme; secured
  networks show a padlock, and long names ellipsize.
- **The password field read as belonging to the SSID box.** The manual-SSID
  input sat between the network list and the password field. The page is now
  two steps — pick a network, then a screen of its own for the password —
  with hidden networks on a separate screen entirely.

- **Factory reset did nothing.** Holding Reset while powering on is supposed
  to erase the overlay, but `S00resetbtn` reaches a stock camera through the
  device's SD-card autoconfig payload, which an image built by
  `tools/build-image.sh` never sees. The button looked dead at boot while the
  runtime Wi-Fi reset worked normally. It now ships in
  `boards/mjsxj02hl/rootfs/`, and requires a two-second hold so a floating pin
  at power-on cannot wipe the camera on its own.
- `WIFI_LED_PAUSE_SERVICE` pointed at `/etc/init.d/S00autoled`, which is in
  that same payload and so absent from these images. Harmless — the code
  checks before calling it — but the documentation claimed the LEDs were
  handed back to it, which was untrue. Now unset, and the docs say the LEDs
  simply go off once connected.

### Added

- `boards/<name>/rootfs/` — board-specific files that are not part of the
  provisioning package, installed by both `tools/build-image.sh` and
  `tools/install-into-openipc.sh`.

## [1.0.0] — 2026-09-02

First release that has run on hardware: built, flashed and provisioned end to
end on a Xiaomi MJSXJ02HL.

### Added

- Wi‑Fi provisioning state machine (`wifi-manager`) — the single owner of the
  radio, with an explicit `UNCONFIGURED → PROVISIONING → TESTING → CONNECTED`
  progression and a documented fallback policy that does not drop a working
  camera into hotspot mode when the router reboots.
- Setup access point with a captive portal: `hostapd`, `udhcpd`, BusyBox
  `httpd`, and `wifi-dnsd` — a ~5 KB wildcard DNS responder written for this,
  because BusyBox `dnsd` is not in OpenIPC images and has no wildcard, and
  `dnsmasq` is ~300 KB on an 8 MB flash for that one feature.
- Test-before-commit: submitted credentials are proven to associate *and* get a
  DHCP lease before anything is written to `/etc`, so a mistyped password
  cannot lock anyone out.
- Credential store that is hex-encoded, atomically written, mode `0600`, and
  holds a derived PSK rather than the passphrase people reuse.
- `wifi-ctl` command line interface, and an optional hold-to-reset GPIO button.
- LED status indication (`wifi-led`), released back to the board's own
  indicator once connected.
- Adoption of credentials set through OpenIPC's own web UI, so that page and
  the setup portal are equally valid routes and neither needs a reboot.
- Buildroot package plus `tools/install-into-openipc.sh` — a one-line change to
  `general/package/Config.in` and nothing else touched.
- `tools/build-image.sh`, producing a flashable HiTool/HiBurn set by layering
  onto OpenIPC's official release. Kernel and bootloader come out
  byte-identical to upstream, verified against OpenIPC's own checksum.
- Board support for the Xiaomi MJSXJ02HL: RTL8189FTV over SDIO, annotated
  bring-up sequence, reset button on GPIO 0, LEDs on GPIO 52/53.
- 119 host-side tests, including a live assertion that an SSID of
  `$(touch …)` executes nothing.
- Eleven documents covering architecture, hardware, integration, build,
  flashing, the user procedure, troubleshooting, security and testing.

### Fixed during hardware bring-up

- The setup portal lost port 80 to majestic, so `192.168.4.1` served the
  camera's own root-password page instead of the setup page. The board
  defaults had assumed majestic was on port 85, which is true of OpenIPC's
  device-repo build but not of the generic image being flashed.
- The web UI's "Use DHCP" toggle always read off, because it decides the mode
  by grepping the `wlan0` stanza for the word `dhcp` and the replacement
  stanza said `inet manual`.
- Credentials saved from the camera's own web UI were stored but never acted
  on, because `setnetwork` writes them and stops, expecting a reboot.
- `ifup` could leave its own `wpa_supplicant` on `wlan0` before the manager
  ran — certain on an upgrade, since `setnetwork` writes the stock stanza into
  the overlay, which a rootfs reflash does not clear. Two supplicants on one
  radio meant neither worked.
- `hostapd`'s backend was chosen by matching the driver's name, which got
  `8189fs` wrong: that build registers a cfg80211 wiphy and wants `nl80211`,
  not Realtek's `rtw`. Now decided by asking the kernel.
- `start-stop-daemon` returning 0 only means `httpd` forked, not that it could
  bind, so a portal that never came up failed silently.

[1.0.1]: https://github.com/martepato/openipc-hi3518ev300-wifi-setup/releases/tag/v1.0.1
[1.0.0]: https://github.com/martepato/openipc-hi3518ev300-wifi-setup/releases/tag/v1.0.0
