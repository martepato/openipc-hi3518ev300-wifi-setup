Roadmap
=======

Phase 1 — Design & safety (Docs-only)
- [x] Specify goals and constraints for Hi3518EV300 provisioning
- [x] Document expected Wi‑Fi stack and tool dependencies
- [x] Define security requirements and fail-safe behavior

Phase 2 — Reference implementation (follow-up)
- [ ] Minimal CLI utility for scanning and generating wpa_supplicant config
- [ ] Minimal local-only web UI for onboarding (HTTPS or constrained to local network)
- [ ] Dry-run and audit features; reversible configuration changes

Phase 3 — Packaging & integration
- [ ] ipk package and OpenIPC image hooks
- [ ] systemd/init support examples for common OpenIPC builds
- [ ] Tests and CI for linting and basic config generation

Phase 4 — Advanced features
- [ ] Captive-portal AP provisioning mode for zero-touch onboarding
- [ ] WPA2-Enterprise (EAP) provisioning workflows
- [ ] Mobile provisioning (QR or temporary token flows)

Notes
-----
- Implementation tasks will be added as issues with device-specific labels and checklists. This doc serves to prioritise and coordinate work.