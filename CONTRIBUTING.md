# Contributing

The most useful contribution is a **board profile for a camera this does not
yet support**. The provisioning system is chip-independent; what it cannot know
is which SDIO radio your board has and how it is powered.

## Adding a board

1. Work out what is fitted, using the diagnostics in
   [`docs/02-hardware.md`](docs/02-hardware.md) — chiefly
   `ls /sys/bus/sdio/devices/*/{vendor,device}` and `dmesg | grep -i sdio`.
2. Create `boards/<name>/profile.sh` with a bring-up block. Copy
   [`boards/mjsxj02hl/profile.sh`](boards/mjsxj02hl/profile.sh) and annotate
   what each register write or GPIO does; a profile nobody can explain is one
   nobody can fix later.
3. Add `boards/<name>/defaults` if the board has a button or LEDs.
4. Add `boards/<name>/majestic.conf` if `tools/build-image.sh` covers your
   board and it has day/night hardware — the IR-cut and lamp pins, which
   majestic cannot discover on its own. Board *wiring* only; see **Scope**.
5. Test with `./tools/install-into-openipc.sh ../firmware <defconfig> <name>`.
6. Say in the PR what you verified on real hardware and what you did not.

Please do not guess register values. A profile that was never run on the
hardware is worse than no profile, because it looks authoritative.

## Running the tests

```sh
sh tests/run-tests.sh
```

160 checks, no hardware needed. They run under `dash`, which is the closest
common shell to the busybox `ash` on the camera — `bash` will hide portability
bugs, so do not test only with it.

Also run shellcheck before sending anything:

```sh
shellcheck -s sh -S warning package/wifi-provision/files/usr/libexec/wifi/*.sh \
                            package/wifi-provision/files/usr/sbin/* tools/*.sh
```

`SC2034` ("appears unused") is expected in `wifi-lib.sh`: it is a library whose
variables are consumed by the scripts that source it.

CI runs both on every push.

## Conventions that are not negotiable

These exist because breaking them has caused real bugs in this codebase:

- **POSIX `sh` only.** The target is busybox `ash`. No bashisms, no `local`, no
  `[[`, no arrays.
- **`printf`, never `echo`, for anything data-bearing.** `echo` in dash and
  busybox `ash` expands backslash escapes, which silently undid passphrase
  escaping here once already.
- **Untrusted text stays hex-encoded** from the moment it is decoded until it
  reaches a consumer that is not a shell. SSIDs and passphrases are never held
  raw in a shell variable and never interpolated into a command line.
- **No `killall`.** Match on `argv[0]` *and* the interface, and never signal a
  pid from our own pidfiles. A camera may carry a second radio and is certainly
  running a streamer.
- **Anything that touches `/proc`, `/sys` or `/etc` goes through the existing
  path variables** (`WIFI_PROC`, `WIFI_GPIO_SYSFS`, `WIFI_ETC_DIR`,
  `WIFI_RUN_DIR`) so it can be tested without hardware. If you add a behaviour
  that cannot be tested, add the indirection that makes it testable.
- **Comments explain *why*, not *what*.** Especially for register writes,
  timing workarounds, and anything that looks redundant but is not.

## Reporting a problem

Include the output of:

```sh
wifi-ctl status
logread | grep -i wifi | tail -60
dmesg | grep -iE 'mmc|sdio|wlan'
fw_printenv wlandev wlanmac 2>/dev/null
```

`wifi-ctl status` never prints a password and the wpa_supplicant log carries no
key material at its default verbosity — but skim before posting publicly.

## Scope

This project does Wi‑Fi provisioning. It is not a place for camera tuning,
streaming features or general OpenIPC changes — those belong upstream at
[OpenIPC/firmware](https://github.com/OpenIPC/firmware).

The one deliberate exception is **board wiring** in `boards/<name>/`: which
pin the reset button, the LEDs, the IR-cut filter and the lamp are soldered
to. Those are facts about the hardware, not preferences, and a camera
assembled by `tools/build-image.sh` has nowhere else to learn them — the
values that would normally arrive with a vendor image are exactly what this
builder does not get. Bitrate, resolution, OSD and the rest are tuning: set
them on the camera with `cli -s`, not here.
