# Changelog

Notable changes to this project. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
this project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

[1.0.0]: https://github.com/martepato/openipc-hi3518ev300-wifi-setup/releases/tag/v1.0.0
