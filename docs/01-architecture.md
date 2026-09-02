# Architecture

## The shape of it

```
                    +--------------------------+
                    |       Hi3518EV300        |
                    |  sdhci-hisi  (mmc1,      |
                    |   0x10020000, 4-bit)     |
                    +------------+-------------+
                                 | SDIO
                    +------------v-------------+
                    |   Wi-Fi chip (see        |
                    |   docs/02-hardware.md)   |
                    +------------+-------------+
                                 | vendor .ko, loaded by
                                 | /etc/wireless/sdio "$wlandev"
                    +------------v-------------+
                    |          wlan0           |
                    +------------+-------------+
                                 |
             +-------------------+--------------------+
             |                                        |
        NORMAL MODE                              SETUP MODE
             |                                        |
      wpa_supplicant  (-D nl80211,wext)          hostapd  (-D rtw | nl80211)
             |                                        |
        udhcpc (client)                          udhcpd  192.168.4.100-.150
             |                                   busybox httpd -> 192.168.4.1:80
        home router                              wifi-dnsd  (wildcard A record)
             |                                        |
      camera has an address                    phone shows the setup page
```

Only one of the two columns runs at a time. A single-vif SDIO radio cannot
beacon and associate simultaneously; §5 explains what that means for the user
and how the design keeps it from mattering.

## 1. Where this sits in OpenIPC

OpenIPC already has a Wi-Fi path. It works like this:

```
S40network  ->  fw_printenv wlandev
            ->  /etc/wireless/sdio "$wlandev"    # power GPIO + modprobe
            ->  ifup wlan0
                 -> interfaces.d/wlan0 stanza:
                    wpa_passphrase "$(fw_printenv -n wlanssid)" \
                                   "$(fw_printenv -n wlanpass)" > /tmp/...
                    wpa_supplicant -B ...
```

That gets a camera onto Wi-Fi, but the credentials come from the U-Boot
environment, so setting them needs a serial console or an already-working
network. There is nothing to extend for first-time setup — there is no
first-time setup.

This project **keeps the half that is genuinely board-specific and replaces
the half that is not**:

| Layer | What happens to it |
|---|---|
| `/etc/wireless/sdio` board profiles | **Kept unchanged.** Power rails, reset GPIOs, module names and module parameters stay exactly where OpenIPC maintainers already put them. `wifi-manager` calls the same dispatcher with the same `wlandev` variable. |
| `S40network` | **Kept unchanged.** |
| `interfaces.d/wlan0` | **Replaced** with `iface wlan0 inet manual`. The original is preserved as `wlan0.stock`. |
| Credential source | **Replaced.** `/etc/wifi/wifi.conf` on the writable overlay, filled in from the setup page. Existing `wlanssid`/`wlanpass` are imported once on first boot, so an already-configured camera keeps working. |

Replacing the `wlan0` stanza is not optional: if it stayed, `ifup wlan0` would
start a second `wpa_supplicant` from the U-Boot environment and race the one
`wifi-manager` starts. Whichever won, it would not reliably be the credentials
the user just typed in.

## 2. Processes and who owns what

```
  /etc/init.d/S41wifi
        |
        +--> wifi-manager                    (the only process that touches the radio)
        |       |
        |       +-- /etc/wireless/sdio       driver load
        |       +-- wpa_supplicant, udhcpc   station mode
        |       +-- hostapd, udhcpd          setup mode
        |       +-- busybox httpd            the setup page
        |       +-- wifi-dnsd                captive DNS
        |
        +--> wifi-button-watch               optional, GPIO hold-to-reset
        |
        +--> wifi-led                        optional, shows state on the LEDs
```

`wifi-led` is a *reader*, not a client: it follows `/tmp/wifi/state`, which
the manager already writes on every transition, so there is no second channel
to keep in sync and killing it cannot affect provisioning. It claims the LEDs
only while the camera needs attention and hands them back — pausing and
restarting the board's own LED daemon — once connected.

Everything else is a *client* of the manager:

```
  browser  ->  httpd  ->  /var/www-wifi/cgi-bin/wifi   (CGI: validate only)
                                    |
                            writes /tmp/wifi/cmd       (the command channel)
                                    |
  ssh      ->  wifi-ctl  ------------+
                                    v
                              wifi-manager acts
                                    |
                            writes /tmp/wifi/result
                                    |
                       CGI reads it back for the browser to poll
```

The CGI runs no network command at all. Its entire authority is "write a file
of hex digits into a root-owned directory". That is what makes the injection
surface analysable: see §7.

This is also the layered configuration API asked for — `wifi_scan`,
`wifi_get_status`, `wifi_configure`, `wifi_test`, `wifi_enter_provisioning`,
`wifi_reset` map onto `wifi-ctl scan|status|configure|provision|forget` and the
CGI's `action=` verbs, both of which go through the same command channel.

## 3. The state machine

```
                    INIT
                      |
          driver loads, wlan0 appears?
             no  /                \  yes
      NO_HARDWARE                  |
    (log it, exit 0,       credentials stored?
     camera boots on)       no /          \ yes
                             /             \
                    UNCONFIGURED          CONNECTING
                          |                 /      \
                          v          success        failure
                    PROVISIONING        |               |
                     (AP + portal)      |        verified before?
                          |             |         no /      \ yes
                    user submits        |           /        \
                          |             |     PROVISIONING  RECONNECTING
                          v             |                       |
                       TESTING          |                  (retry forever)
                       /      \         |                       |
                 failure      success   |                    success
                    |            \      |                       |
              back to             +---> CONNECTED <-------------+
              PROVISIONING              |        |
              with a reason         healthy   lost
                                        |        |
                                     (stay)   RECONNECTING
```

`NO_HARDWARE` is a deliberate terminal state, not an error path: a camera
whose Wi-Fi did not come up is still a camera. The manager logs a diagnostic
and exits 0 so the sensor, encoder and RTSP server boot normally.

## 4. Fallback policy — and why it is conservative

`wifi_should_fallback()` in `wifi-manager` decides whether a camera that
cannot reach its network should reopen the setup AP.

- **Credentials that have never worked → yes, fall back.** They are probably
  wrong, and the AP is the only way for the owner to fix them.
- **Credentials that have worked at least once → no.** Retry forever.

The `verified` flag in `/etc/wifi/wifi.conf` is set only after an association
*and* a DHCP lease. From the camera's point of view a router reboot, an ISP
outage, a power cut at the far end and a changed password are
indistinguishable. A camera that turns itself into an open access point every
time the network blinks has to be re-provisioned by hand each time — for a
device mounted under an eave, that is worse than being briefly offline.

`WIFI_FALLBACK_AFTER` (default `0`, meaning never) can relax this for
integrators who want it. Deliberate re-provisioning is always available: the
button, `wifi-ctl provision`, or `wifi-ctl forget`.

## 4b. Credentials set outside the portal

The portal is not the only way Wi-Fi gets configured. OpenIPC's own web UI
has a Wi-Fi page that calls `setnetwork`, which writes `wlanssid`/`wlanpass`
into the U-Boot environment and rewrites `interfaces.d/wlan0`, then stops —
the stock design expects a reboot.

Rather than duplicate that page or fight it, the manager watches the
environment (`wifi_env_changed`) and adopts anything set there, running it
through the same test-then-commit path as a portal submission. So:

- either page configures the camera, with no reboot;
- the setup AP stays up until the network is *actually* configured, by
  whichever route;
- if the portal cannot start at all, the camera is still configurable — the
  manager restores majestic's UI and picks up whatever is set there.

A fingerprint of what was last acted on is kept in tmpfs so a value we wrote
ourselves, or one already adopted, does not re-trigger — and so credentials
that turn out to be wrong are tried once rather than every ten seconds. The
fingerprint is a hash; the passphrase is never written to that file.

Because `setnetwork` replaces the `wlan0` stanza with one that starts its own
`wpa_supplicant`, the manager also re-asserts its own stanza when it sees
that happen. Two supplicants on one radio is the race described in §1.

## 5. Test before commit — what is actually guaranteed

The requirement is that a mistyped password must never leave the camera
unreachable. The obvious reading — keep the setup AP running while testing —
is not physically available on a single-vif radio: the chip cannot beacon on
channel 6 and associate on channel 11 at the same time.

What is implemented instead gives the same guarantee:

```
 1. CGI validates the input.                      AP still up
 2. CGI writes /tmp/wifi/candidate  (tmpfs)       AP still up
    -- /etc/wifi/wifi.conf is NOT touched
 3. Manager stops the AP.                         AP down
 4. Manager associates using the candidate.
 5. Manager requests a DHCP lease.
 6a. Both succeed  -> candidate is committed to /etc atomically,
                      state = CONNECTED, done.
 6b. Either fails  -> candidate is discarded, the reason is recorded,
                      the AP comes back up automatically (~30-60 s).
```

So the committed configuration is never modified by a failed attempt, and the
way back in restores itself without a power cycle. The user-visible cost is
that the setup network disappears for under a minute; the setup page says so
before it happens, and shows the specific reason ("Wrong Wi-Fi password") once
the phone reconnects.

If a chip ever proves to support reliable concurrent AP+STA, step 3 can be
dropped without changing anything else. It is not assumed, because on these
radios it is frequently claimed and rarely stable.

## 6. Credential storage

`/etc/wifi/wifi.conf`, mode `0600`, on the writable overlay:

```
version=1
ssid=4d7920486f6d6520322e3447      # hex
key_type=psk                       # open | psk | passphrase
key=30313233...                    # hex of the 64-hex PSK, or of the passphrase
hidden=0
verified=1
```

Four decisions worth naming:

- **Everything is hex.** Nothing that reads this file has to think about
  quoting, and a value can never introduce a newline, a quote or a shell
  metacharacter. The file is *parsed*, never `source`d.
- **The PSK is stored, not the passphrase**, whenever `wpa_passphrase` can
  derive it (any 8–63 character passphrase). The plaintext the owner typed —
  which people reuse — never reaches flash. `key_type=passphrase` is the
  fallback, used only when WPA3-SAE is enabled, since SAE derives from the
  passphrase itself.
- **Writes are atomic**: temp file in the same directory, `sync`, `rename`.
  `rename(2)` is atomic on jffs2, ubifs and overlayfs, so a power cut leaves
  either the old credentials or the new ones — never half a file. A file that
  is short a required key fails to load rather than half-loading.
- **Flash wear is bounded**: the file is written once per successful
  provisioning and once when `verified` flips, not on any periodic path.

The U-Boot environment is *read* once to migrate an existing configuration,
and written only if `WIFI_MIRROR_UBOOT_ENV=1`. It is not the primary store:
`fw_setenv` rewrites a raw flash sector, which is a poor place to put
something the user changes interactively.

## 7. Why the injection surface is small

An SSID of `$(reboot)` or `"; rm -rf / #` is a hostile *value*, and the
defence is to make sure it is never in a position where it could be anything
else:

1. **Form decoding happens inside `awk` and emits hex.** No branch of the CGI
   ever holds a raw form value in a shell variable. `$(reboot)` leaves the
   decoder as the nine bytes `242872656 26f6f7429`.
2. **The command channel carries only hex**, and the manager re-validates it
   with `wifi_is_hex` before use.
3. **The SSID enters `wpa_supplicant.conf` as bare hex** (`ssid=4d79...`),
   which the config parser accepts and which has no string to terminate and no
   comment to start. The one value that must sometimes be a quoted string — a
   passphrase that could not be pre-hashed — is escaped for `\` and `"`.
4. **Values are passed as argv**, never interpolated into a command line.
5. **Every generated config line is written with `printf`, never `echo`** —
   the `echo` built-in in dash and busybox ash expands backslash escapes and
   would silently undo (3)'s escaping.

`tests/run-tests.sh` asserts all of this, including a live check that feeding
`$(touch /tmp/pwned)` through the decoder and the config generator creates no
such file.

## 8. Choices made against the obvious alternative

| Instead of | We use | Why |
|---|---|---|
| `iw` for scanning | `wpa_cli scan` / `scan_results` | `wpa_supplicant` is already in every OpenIPC Wi-Fi image, and works over both nl80211 and wext — so the Realtek out-of-tree drivers are covered with no second code path. `iw` would be a new package for the same answer, and would not work on wext-only drivers. |
| `dnsmasq` for captive DNS | `wifi-dnsd`, ~15 KB, in this repo | BusyBox `dnsd` is not compiled into OpenIPC images and has no wildcard, which is the only feature a captive portal needs. `dnsmasq` is ~300 KB on an 8 MB flash for that one feature. |
| A web framework, or any CGI in Python/Lua | BusyBox `httpd` + one shell CGI | `httpd` with CGI is already enabled in OpenIPC's BusyBox config. Nothing new is added to the image for the web tier. |
| `wpa_supplicant`'s own AP mode | `hostapd` (`rtw-hostapd`) | Already packaged, and it is the only one with the Realtek `rtw` backend those SDIO drivers need. `BR2_PACKAGE_WPA_SUPPLICANT_AP_SUPPORT` is off in the OpenIPC defconfig anyway. |
| A `wifi.conf` that is `source`d | A parsed hex key/value file | Sourcing a file containing user-supplied text is arbitrary code execution with extra steps. |
| Storing the passphrase | Storing the derived PSK | People reuse Wi-Fi passwords. The PSK is enough to join the network and no more. |

## 9. Footprint

Measured from the actual install into a staging tree (`docs/04-build.md`
explains how to reproduce):

| Item | Size |
|---|---|
| Scripts, CGI and setup page | 83 KB uncompressed / **~26 KB in squashfs-xz** |
| `wifi-dnsd` | ~15 KB stripped |
| `hostapd` (`rtw-hostapd`, internal TLS, no EAP/WPS) | **~400–450 KB stripped — estimated, not measured**; this is the only significant addition |
| `wpa_supplicant`, `wpa_cli`, BusyBox `httpd`/`udhcpd`/`udhcpc` | 0 — already in the image |

Runtime: one `sh` process asleep on a 10-second poll; `hostapd`, `udhcpd`,
`httpd` and `wifi-dnsd` exist only while setup mode is active. Boot impact is
one driver load plus the association attempt, which the stock path also pays.

`hostapd` is the cost worth weighing on an 8 MB `lite` build. Everything else
is rounding error. If it does not fit, `docs/04-build.md` covers dropping the
AP and keeping the rest.
