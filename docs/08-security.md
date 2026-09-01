# Security

## The one trade-off you should decide deliberately

**The setup access point is open by default.** This is the weakest point in
the design and it is a choice, not an oversight.

While the setup network is up, anyone in radio range can join it and reach
the setup page, and could capture the home Wi-Fi password as it is submitted.

It is the default because the alternative is worse in the common case. A WPA2
setup AP needs a password the owner can obtain *before* they can connect —
which means a printed label, a QR code, or a sticker applied in the factory.
A camera whose setup password nobody can look up is a camera that cannot be
set up at all, and the requirement this project is built to is "no serial
console, no SSH, no config files".

What limits the exposure:

- The AP exists only while the camera is unconfigured, or right after a
  deliberate reset. Successful setup shuts it down immediately.
- If credentials are already saved, the AP times out after
  `WIFI_AP_IDLE_TIMEOUT` (default 15 min) and retries the saved network.
- `httpd` is bound to `192.168.4.1:80` — not `0.0.0.0` — and additionally
  ACL-limited to the provisioning subnet, so it is not reachable from the LAN
  once the camera is on it.
- Nothing else is published on that interface: no SSH, no RTSP, no majestic
  UI, no routing to any other network.

**If your product can print a per-device password, use it.** In
`/etc/wifi/wifi.defaults`:

```sh
WIFI_AP_SECURITY=wpa2
WIFI_AP_PASSPHRASE=<per-device, 8-63 chars>
```

The passphrase is hashed into `wpa_psk` before it reaches `hostapd.conf` and
is never echoed or logged. Derive it per device (from the MAC, or a factory
secret) — a constant across a product line is barely better than open, since
the first person to read the label knows every unit's.

## Injection: SSIDs and passwords as data

The stated test cases — an SSID of `$(reboot)`, `` `reboot` ``,
`"; rm -rf / #`, and the same in a password field — are handled structurally
rather than by filtering:

1. **Form decoding happens entirely inside `awk` and emits hex.** No branch of
   the CGI ever holds a raw form value in a shell variable, so there is
   nothing for the shell to re-interpret.
2. **The command channel carries only hex**, re-validated with `wifi_is_hex`
   before the manager uses it. A hand-written command file containing
   `ssid=; reboot` has that field dropped, not executed.
3. **The SSID enters `wpa_supplicant.conf` as bare hex** — `ssid=4d79...` —
   which the parser accepts and which has no string to terminate and no
   comment to start. A quote in an SSID cannot escape anything because the
   SSID is never quoted.
4. **The one value that must sometimes be a quoted string** (a passphrase
   that could not be pre-hashed) is escaped for `\` and `"`.
5. **Every generated config line is written with `printf`, never `echo`.**
   The `echo` built-in in dash and busybox ash expands backslash escapes and
   would silently undo (4). This was a real bug during development, caught by
   the test suite.
6. **Values are passed as argv**, never interpolated into a command line.
7. **Form field names are restricted to `[A-Za-z0-9_]`** and dropped
   otherwise, so a crafted name cannot become a path or an option.

`tests/run-tests.sh` asserts each of these, including a live check that
feeding `$(touch <path>)` through the decoder and the config generator creates
no such file.

## Credential handling

- **The derived PSK is stored, not the passphrase**, whenever
  `wpa_passphrase` can derive it. People reuse Wi-Fi passwords; the PSK joins
  that one network and is useless elsewhere. `key_type=passphrase` is the
  fallback, used only when WPA3-SAE is enabled, because SAE derives from the
  passphrase itself.
- **`/etc/wifi/wifi.conf` is mode `0600`**, written under `umask 077`,
  asserted by the tests.
- **No endpoint returns a stored key.** `api_status` returns the SSID, state
  and address; there is no code path that reads the key field into a response.
  The tests assert that neither the CGI nor `wifi-ctl` so much as references
  `WIFI_CFG_KEY`. There is no `wifi-ctl show-password`.
- **Credentials never appear in a URL.** Submission is `POST` only; `connect`
  rejects `GET` with 405.
- **Nothing is logged.** `wifi_log` is only ever called with descriptions, and
  `wifi_redact()` exists for tool output we do not control. The
  `wpa_supplicant` log is at default verbosity, which carries association
  events but no key material, and is mode `0600`.
- **The passphrase is not in `ps`.** `wifi-ctl` reads `WIFI_PASSWORD` from the
  environment; the web path passes hex through a file.
- **Writes are atomic** (temp + `sync` + `rename`), so a power cut during save
  leaves the old credentials or the new ones, never a corrupt file. A file
  missing a required key fails to load rather than half-loading.

## Attack surface while in setup mode

| Listener | Bound to | Notes |
|---|---|---|
| `hostapd` | `wlan0` | open or WPA2 per config |
| `udhcpd` | `wlan0` | 20 leases max, 10-minute lease |
| `httpd` | `192.168.4.1:80` | ACL-limited to the provisioning subnet; CGI + one static page |
| `wifi-dnsd` | `192.168.4.1:53` | answers A with one fixed address; never forwards, never recurses — not an open resolver |

The CGI caps request bodies at 4 KB and rejects a non-numeric
`Content-Length`.

`wifi-dnsd` was written narrow on purpose and fuzzed by hand against
truncated headers, `qdcount != 1`, compression pointers in the QNAME (rejected
— a query has nothing to point back to) and non-A query types. It parses no
name into a buffer; it only walks label lengths with bounds checks and replies
with a compression pointer to the question it was sent.

## Re-provisioning is authenticated by physical access

There is deliberately **no unauthenticated HTTP endpoint on the LAN** that
drops the camera off the network. Re-entering setup mode requires:

- the physical button (`WIFI_BUTTON_GPIO`), or
- `wifi-ctl provision` / `wifi-ctl forget` over SSH.

An `http://camera/reset-wifi` reachable from the LAN would let anything on the
network — a compromised IoT device, a guest, a browser following a link —
knock the camera offline and open an access point next to it. If you add one
for your product, put it behind authentication and bind it to an interface you
control.

The button is scoped to Wi-Fi only. It does not touch majestic's config, the
U-Boot environment, or credentials for any other service.

## Known limitations

- **Open setup AP by default** — discussed above.
- **No TLS on the setup page.** A self-signed certificate on `192.168.4.1`
  produces a browser warning that trains users to click through, and breaks
  captive-portal auto-open. The mitigation is that the AP is temporary and
  serves nothing else. HTTPS would only help against a passive listener who,
  on an open AP, can see the association anyway.
- **No rate limiting on the CGI.** The AP allows 4 stations and exists for
  minutes; the manager serializes connection attempts.
- **`wifi-dnsd` answers every A query with the camera's address** while setup
  mode is active. That is the point of a captive portal, and it is why it
  binds to the provisioning address only and never runs outside setup mode.
- **The `verified` flag is trust-on-first-use.** A camera tricked into
  associating with a rogue AP that answers DHCP will mark those credentials
  verified. Defending against that needs mutual authentication the WPA2-PSK
  model does not provide.
