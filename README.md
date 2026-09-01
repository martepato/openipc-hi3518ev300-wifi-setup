# Hi3518EV300 — user-friendly Wi‑Fi setup for OpenIPC

This repository provides a descriptional skeleton and project documentation for building a user-friendly Wi‑Fi provisioning solution targeted at HiSilicon Hi3518EV300-based OpenIPC devices. It intentionally contains documentation only (no code) so maintainers and contributors can plan, design, and integrate a provisioning flow into OpenIPC images.

Goals
-----
- Define clear, device-specific requirements and constraints for Wi‑Fi provisioning on Hi3518EV300 devices.
- Provide onboarding UX options (CLI, minimal web UI, captive-portal AP mode) and security considerations.
- Provide integration notes for OpenIPC image builds and packaging strategies.
- Offer a community-facing roadmap and contribution guidance so integrators can adopt or extend the work.

Why this repo exists
--------------------
OpenIPC deployments using Hi3518EV300 often vary in network stack, init system, and available tooling. A well-documented, chipset-specific plan helps downstream integrators implement a consistent, secure, and user-friendly provisioning flow that can be adapted to different product constraints.

Scope (docs-only)
------------------
- This repository contains only documentation, design notes, issue templates and a roadmap. No device-modifying code is included here.
- Implementation (scripts, packages, image hooks) will be developed in follow-up work and referenced from this repo.

Target audience
---------------
- Firmware maintainers and integrators using Hi3518EV300 SoC in OpenIPC images.
- Community contributors who want a standard onboarding experience across devices.
- QA engineers and security reviewers validating provisioning flows.

Key design considerations
-------------------------
- Minimal runtime footprint: prioritize using system components available on typical OpenIPC images.
- Safety: provisioning operations must be guarded (dry-run, offline approval step) and must never expose credentials over untrusted networks.
- Fail-safe: device must remain reachable after failed provisioning attempts (e.g., keep a fallback AP mode or a timed revert).
- Auditability: configuration changes should be easily reviewable and reversible.

Integration notes
-----------------
- Packaging: consider ipk for OpenIPC builds; provide optional systemd units or init scripts depending on the image.
- Wi‑Fi stack: document expected tools (wpa_supplicant, wpa_cli, iw/iwlist) and fallback strategies for devices without those tools.
- Network naming: note common interface names (wlan0) and how to detect/override them in images.
- Security: TLS for any web UI, CSRF protection, temporary credentials storage with strict file permissions, and optional ephemeral provisioning tokens.

How to use this repo
---------------------
- Read ROADMAP.md to understand planned phases and priorities.
- Open issues for feature requests, device-specific quirks, or packaging help.
- Follow CONTRIBUTING.md before opening PRs.

License
-------
This documentation and any files in this repository are licensed under the MIT License (see LICENSE).
