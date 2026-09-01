Roadmap
=======

Phase 1 — Design & safety
- [x] Specify goals and constraints for Hi3518EV300 provisioning
- [x] Document the expected Wi‑Fi stack and tool dependencies
- [x] Define security requirements and fail-safe behaviour

Phase 2 — Reference implementation
- [x] Determine the real OpenIPC target, kernel, SDIO host and existing Wi‑Fi path
      (`docs/02-hardware.md`)
- [x] Provisioning state machine with test-before-commit (`usr/sbin/wifi-manager`)
- [x] Persistent, atomic, hex-encoded credential store; PSK stored rather than
      the passphrase
- [x] Automatic reconnection, with a fallback policy that survives a router outage
- [x] CLI for scanning, status and configuration (`wifi-ctl`)
- [x] Minimal local-only web UI, bound to the provisioning interface
- [x] Host-side test suite, including injection tests

Phase 3 — Packaging & integration
- [x] Buildroot package and OpenIPC installer (`install/install-into-openipc.sh`)
- [x] SysV init integration (`S41wifi`), ordered before majestic
- [x] Kconfig and package makefile validated against Buildroot 2024.02.10
- [ ] Full cross-compile on a host with the OpenIPC toolchain available
- [ ] CI: run `tests/run-tests.sh` and `shellcheck` on push

Phase 4 — Captive portal & discovery
- [x] Captive-portal AP provisioning mode
- [x] Wildcard DNS responder (`wifi-dnsd`) for portal auto-open
- [ ] Confirm portal auto-open behaviour on current iOS, Android and Windows
- [ ] mDNS announcement wired up by default (`openipc-xxxx.local`)

Phase 5 — Hardware validation
- [ ] Confirm the SDIO chip and power/reset GPIO on a real board
      (see the UNKNOWN section of `docs/02-hardware.md`)
- [ ] Work through the hardware, provisioning, security and reliability
      matrices in `docs/09-testing.md`
- [ ] Measure the real image-size delta and boot-time impact

Phase 6 — Later
- [ ] WPA3-SAE once a driver that supports it is confirmed
- [ ] Concurrent AP+STA, if it proves stable on a given chip — it would remove
      the setup network's brief disappearance during a connection test
- [ ] WPA2-Enterprise (EAP) provisioning
- [ ] QR / token-based setup for products that can print a label
