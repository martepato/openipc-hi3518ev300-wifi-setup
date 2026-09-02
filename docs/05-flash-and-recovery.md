# Flashing and recovery

## Updating a camera that is already running OpenIPC

Over SSH or serial, with the camera on a network:

```sh
sysupgrade --kernel=<url>/uImage.hi3518ev300 \
           --rootfs=<url>/rootfs.squashfs.hi3518ev300 -z
```

`sysupgrade` is already in the image (`/usr/sbin/sysupgrade`).

**Wi-Fi settings and `sysupgrade`.** Credentials live in `/etc/wifi/wifi.conf`
on the jffs2/ubifs overlay. Whether they survive depends on how you invoke
`sysupgrade` — a run that erases the overlay drops them, and the camera comes
back up in setup mode. That is a recoverable state, not a brick, but if you
are updating a fleet remotely it is the difference between "reboots and
reconnects" and "someone has to visit each camera".

Two ways to avoid it:

```sh
# Before the upgrade: note the network and re-apply after.
wifi-ctl show

# Or, before flashing, mirror the credentials into the U-Boot environment,
# which sysupgrade never touches:
sed -i 's/^#*WIFI_MIRROR_UBOOT_ENV=.*/WIFI_MIRROR_UBOOT_ENV=1/' /etc/wifi/wifi.defaults
wifi-ctl reconnect      # rewrites the store, which triggers the mirror
```

On the next boot after a wipe, `wifi-manager` imports `wlanssid`/`wlanpass`
from the environment automatically and reconnects without any setup pass.

## First flash on a blank or vendor-firmware camera

Follow OpenIPC's own procedure for the Hi3518EV300 — this project changes
nothing about it. See <https://openipc.org/> and the OpenIPC wiki. In short:
a serial console at 115200 8N1, a TFTP server, then `sf` commands from the
U-Boot prompt.

After the first boot, set the board profile so the Wi-Fi driver is loaded:

```sh
fw_setenv wlandev rtl8189fs-generic     # or your board's profile
reboot
```

Without `wlandev` there is no Wi-Fi at all, and `wifi-ctl status` says so:

```
State:      NO_HARDWARE
Interface:  wlan0 MISSING
```

## Recovery

### The camera never appears as `OpenIPC-XXXX` and is not on the network

Connect a serial console (115200 8N1) and look:

```sh
wifi-ctl status
logread | grep wifi
dmesg | grep -iE 'mmc|sdio'
```

`docs/07-troubleshooting.md` walks each failure from there.

### Wi-Fi is fine but the setup page will not load

The portal binds to `192.168.4.1:80` only. If majestic held port 80 first,
the manager pauses it for the duration of setup mode; if you set
`WIFI_PORTAL_STOP_MAJESTIC=0` without moving `WIFI_PORTAL_PORT`, the portal
cannot bind. Check:

```sh
netstat -ltnp | grep :80
logread | grep 'setup web server'
```

### Bad credentials saved and no way in

```sh
wifi-ctl forget         # erase and reopen setup mode
```

or, if the filesystem is all you can reach (e.g. from a rescue shell):

```sh
rm -f /etc/wifi/wifi.conf && sync && reboot
```

### The Wi-Fi changes made the camera unusable

Revert to OpenIPC's stock behaviour without reflashing:

```sh
/etc/init.d/S41wifi stop
mv /etc/network/interfaces.d/wlan0.stock /etc/network/interfaces.d/wlan0
chmod -x /etc/init.d/S41wifi
fw_setenv wlanssid 'My Network'
fw_setenv wlanpass 'my-password'
reboot
```

### A failed flash

The provisioning system lives entirely in the root filesystem. It cannot
affect U-Boot, so a camera that fails to boot after an update is recovered the
normal OpenIPC way: serial console, U-Boot prompt, TFTP.

**Wi-Fi failure never blocks the boot.** If the driver does not load, the
chip does not enumerate, or `hostapd` will not start, `wifi-manager` logs the
reason and exits 0. The sensor, encoder, RTSP server and Ethernet come up as
usual.
