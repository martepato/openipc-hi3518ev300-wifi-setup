# Roadmap

## Done

Provisioning works end to end on hardware — a Xiaomi MJSXJ02HL boots, brings up
the setup AP, serves the portal, tests credentials and joins the network.

- Provisioning state machine with test-before-commit and a fallback policy that
  survives a router outage
- Setup AP, captive portal, wildcard DNS responder
- Persistent, atomic, hex-encoded credential store holding a derived PSK
- Automatic reconnection; adoption of credentials set through OpenIPC's own UI
- `wifi-ctl`, optional reset button, LED status indication
- Buildroot package, OpenIPC installer, flashable-image builder
- Board support: Xiaomi MJSXJ02HL (RTL8189FTV / SDIO)
- 119 host-side tests; CI running tests, shellcheck and the installer

## Next

**More boards.** The single most useful contribution — see
[CONTRIBUTING.md](CONTRIBUTING.md). Every other Hi3518EV300 camera needs a
profile, and the candidates OpenIPC already packages drivers for are ATBM603x,
AIC8800, SSV6x5x and RTL8189ES.

**Finish the reliability matrix** in [`docs/09-testing.md`](docs/09-testing.md).
Untested so far, and worth doing properly:

- power loss during a credential save, repeated (the whole justification for
  the atomic-write design)
- router unavailable for 30 minutes, then restored
- 50 associate/disassociate cycles, checking for leaked processes
- overlay filesystem full

**Confirm captive-portal auto-open** on current iOS, Android and Windows, and
record which of them actually pop the sign-in sheet.

## Later

- mDNS announcement wired up by default (`openipc-xxxx.local`)
- WPA3-SAE, once a driver that supports it is confirmed on this class of radio
- Concurrent AP+STA where a chip supports it reliably — it would remove the
  brief disappearance of the setup network during a connection test
- WPA2-Enterprise (EAP) provisioning
- A per-device setup password with a printed label or QR code, which would let
  the setup AP default to WPA2 instead of open — see
  [`docs/08-security.md`](docs/08-security.md)
