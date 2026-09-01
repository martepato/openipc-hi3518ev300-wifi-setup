# Troubleshooting

Start here, then jump to the matching section.

```sh
wifi-ctl status
logread | grep wifi | tail -40
```

`wifi-ctl status` prints the state the machine is in, which narrows it
immediately:

| State | Meaning | Go to |
|---|---|---|
| `NO_HARDWARE` | No `wlan0`. Driver or SDIO problem. | §1, §2 |
| `PROVISIONING` | Setup AP is up, waiting for someone. | §4 |
| `CONNECTING` / `TESTING` | Trying a network right now. | §5 |
| `RECONNECTING` | Was connected, network went away. | §6 |
| `CONNECTED` | Working. | — |

## 1. SDIO: the chip does not enumerate

```sh
dmesg | grep -iE 'mmc|sdio|sdhci'
ls -l /sys/bus/sdio/devices/
ls -l /sys/bus/platform/drivers/sdhci-hisi/
```

**`/sys/bus/sdio/devices/` is empty.** The MMC core scanned and found nothing.
Almost always power or reset:

- The chip's power-enable GPIO is not being driven. Check your board profile
  in `/etc/wireless/sdio` — see `docs/02-hardware.md`.
- The GPIO *is* driven, but after the MMC core already scanned. The core
  scans once at boot and does not look again. Force a rescan **after**
  powering the chip:

  ```sh
  dev=$(ls /sys/bus/platform/drivers/sdhci-hisi/ | grep 10020000 | head -1)
  echo "$dev" > /sys/bus/platform/drivers/sdhci-hisi/unbind
  sleep 1
  echo "$dev" > /sys/bus/platform/drivers/sdhci-hisi/bind
  sleep 2
  ls -l /sys/bus/sdio/devices/
  ```

  If that makes the device appear, put `sdio_rescan` into your board profile.

- Wrong MMC instance. `mmc1` (`0x10020000`) is the usual one; try `10010000`.

**A device is listed.** Read its IDs and confirm you are loading the matching
driver:

```sh
for d in /sys/bus/sdio/devices/*/; do
    echo "vendor=$(cat $d/vendor) device=$(cat $d/device)"
done
```

`0x024c/0xf179` is RTL8189FTV, `0x024c/0x8179` is RTL8189ES/8188ETV. See the
table in `docs/02-hardware.md`.

## 2. Driver: loads but no `wlan0`

```sh
lsmod
dmesg | tail -50
find /lib/modules -name '*.ko'
```

- **Module not present** → the driver package is not enabled in your
  defconfig. See `docs/03-openipc-changes.md`.
- **`modprobe` fails with "Invalid module format"** → the module was built
  against a different kernel. Rebuild the whole image rather than the module
  alone.
- **Module loads, no `wlan0`** → usually the chip is not actually responding
  on SDIO; back to §1.
- **`wlandev` is unset** → nothing loads anything:

  ```sh
  fw_printenv wlandev
  fw_setenv wlandev rtl8189fs-generic
  ```

- **Firmware blob missing** — some chips need one from
  `/lib/firmware`. `dmesg` says so explicitly. Enable
  `BR2_PACKAGE_LINUX_FIRMWARE_OPENIPC` plus the sub-option for your chip.
  The Realtek SDIO drivers here have their firmware compiled in and need
  nothing.

## 3. `hostapd`: the setup network does not appear

```sh
logread | grep -i hostapd
hostapd -dd /tmp/wifi/hostapd.conf      # run it in the foreground to see why
cat /tmp/wifi/hostapd.conf
```

- **"Could not read interface wlan0 flags"** → `wlan0` is gone; §1/§2.
- **"driver rtw not found" / "Unsupported driver"** → the wrong backend.
  Realtek out-of-tree drivers need `rtw`; mac80211 chips need `nl80211`. Force
  it:

  ```sh
  echo 'WIFI_AP_DRIVER=nl80211' >> /etc/wifi/wifi.defaults
  /etc/init.d/S41wifi restart
  ```

- **"nl80211 driver initialization failed"** on a Realtek chip is the same
  problem the other way round — use `rtw`.
- **The driver has no AP mode at all.** Some SDIO radios are station-only.
  The camera still works as a station; you lose over-the-air setup and
  provision with `wifi-ctl configure`. Check with
  `iw list | grep -A10 'Supported interface modes'` if `iw` is installed.

## 4. Setup mode: the AP is up but the page does not load

```sh
ip addr show wlan0                  # expect 192.168.4.1/24
netstat -ltnp | grep :80
cat /tmp/wifi/udhcpd.leases         # did the phone get a lease?
logread | grep -iE 'httpd|dnsd|udhcpd'
```

- **The phone gets no address** → `udhcpd` did not start. Check the log; a
  client with a static `192.168.4.50/24` will still reach the page.
- **No address on `wlan0`** → `hostapd` reset the interface after we
  addressed it. `/etc/init.d/S41wifi restart`.
- **Port 80 is busy** → majestic. See `docs/03-openipc-changes.md`, and

  ```sh
  logread | grep 'pausing majestic'
  ```

- **The page does not open by itself** but `http://192.168.4.1/` works →
  the captive DNS is not running. Not fatal; check:

  ```sh
  ls -l /usr/sbin/wifi-dnsd
  logread | grep dnsd
  nslookup captive.apple.com 192.168.4.1
  ```

  Some phones also refuse to auto-open when the network offers no internet at
  all; typing the address always works.

## 5. Connecting: it will not join the network

```sh
logread | grep wifi | tail -30
cat /tmp/wifi/wpa_supplicant.log     # no key material at this verbosity
wpa_cli -i wlan0 status
wpa_cli -i wlan0 scan_results
```

The manager already classifies this and the setup page shows the result, but
to see it directly:

| In the log | Means |
|---|---|
| `reason=WRONG_KEY`, `4-Way Handshake failed` | Wrong password |
| `CTRL-EVENT-NETWORK-NOT-FOUND` | SSID not seen — out of range, or 5 GHz-only |
| `CTRL-EVENT-ASSOC-REJECT` | Router refused — MAC filter, or an unsupported security mode |
| Associated, no address | DHCP; see below |

- **Associated but no IP.** The router's DHCP server is off, its pool is
  exhausted, or a MAC filter drops it:

  ```sh
  udhcpc -i wlan0 -n -q -t 5 -T 3 -s /usr/share/udhcpc/default.script
  ```

- **A 5 GHz-only network** will never be found by a 2.4 GHz radio. Check the
  `freq` column in `wifi-ctl scan`.
- **WPA3-only networks** need `WIFI_ENABLE_SAE=1`, a wpa_supplicant built
  with `BR2_PACKAGE_WPA_SUPPLICANT_WPA3=y`, and a driver that supports it.
  Most SDIO camera radios do not. Set the router to WPA2/WPA3 mixed mode.
- **WEP** is not supported. Nor should it be.

## 6. Keeps disconnecting

```sh
logread | grep -E 'connection lost|reconnected'
cat /proc/net/wireless          # link quality and signal
```

- **Weak signal.** `wifi-ctl scan` reports dBm. Below about −80 dBm expect
  trouble.
- **Router power-saving / band steering.** Some drivers take
  `rtw_power_mgnt=0`; add it to the `modprobe` line in your board profile.
- **DHCP lease not renewing.** `wifi-manager` restarts the client when it sees
  an association with no address; if that is happening repeatedly the log will
  show it.

The camera does **not** fall back to setup mode on a network outage, by
design (`docs/01-architecture.md` §4). If you want it to, set
`WIFI_FALLBACK_AFTER` to a number of seconds — and read that section first.

## 7. Settings do not survive a reboot

```sh
ls -la /etc/wifi/wifi.conf              # expect -rw------- and non-empty
mount | grep -E 'overlay|jffs2|ubifs'
df -h /overlay
```

- **`/overlay` is a tmpfs** → the jffs2/ubifs partition failed to mount and
  the boot fell back to RAM. `dmesg | grep -iE 'jffs2|ubi'`. Nothing persists
  in this state, and that is the real problem to fix.
- **`/overlay` is full** → nothing can be written. Clear space.
- **The file exists but is not loaded** → it is corrupt. The parser fails
  closed on purpose rather than half-loading. `wifi-ctl forget` and set it up
  again.

## Collecting a report

```sh
{
  echo "=== status ==="  ; wifi-ctl status
  echo "=== os ==="      ; cat /etc/os-release
  echo "=== env ==="     ; fw_printenv wlandev wlanmac 2>/dev/null
  echo "=== sdio ==="    ; ls -l /sys/bus/sdio/devices/
  echo "=== dmesg ==="   ; dmesg | grep -iE 'mmc|sdio|wlan|cfg80211'
  echo "=== modules ===" ; lsmod
  echo "=== links ==="   ; ip addr
  echo "=== log ==="     ; logread | grep -i wifi | tail -60
} > /tmp/wifi-report.txt
```

`wifi-ctl status` never prints a password, and the wpa_supplicant log at its
default verbosity carries no key material — but skim the file before posting
it publicly anyway.
