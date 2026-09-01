# Setting up the camera (for the person unboxing it)

## First time

1. **Power the camera on** and wait about 30 seconds.
2. On a phone or laptop, **open the Wi-Fi list**. Look for a network called
   something like:

   ```
   OpenIPC-A1B2
   ```

   The four characters at the end are unique to your camera, so if you are
   setting up more than one you can tell them apart.
3. **Join that network.** Ignore any "no internet" warning — the camera is
   not meant to have internet.
4. The setup page usually **opens by itself**. If it does not, open a browser
   and go to:

   ```
   http://192.168.4.1/
   ```

5. **Pick your home Wi-Fi** from the list, **type its password**, and press
   **Connect**.
6. The setup network disappears for up to a minute while the camera tries
   your Wi-Fi. This is normal.
   - **It worked:** the page shows "Connected" and the camera's new address.
     Put your phone back on your normal Wi-Fi.
   - **It did not:** the setup network comes back on its own. Rejoin it and
     the page will tell you what went wrong — usually a wrong password.

You never have to type the password twice or reset anything: a wrong password
cannot lock you out.

## Things that work

- Network names with spaces, accents or non-Latin characters.
- Passwords with any punctuation.
- **Hidden networks** — type the name into "Or type a network name".
- Open networks with no password.

## Note on 5 GHz

Most cameras of this type have a 2.4 GHz-only radio. If your router publishes
one name for both bands this is handled automatically. If 2.4 GHz has a
separate name, pick that one. Networks the camera sees on 5 GHz are marked in
the list.

## Finding the camera afterwards

The setup page shows the address the router gave it. If you missed it:

- Look for `openipc-a1b2` in your router's client list.
- If mDNS is enabled in the firmware, `http://openipc-a1b2.local/` works.

## Changing to a different Wi-Fi network

**If your camera has a setup button** — hold it for 5 seconds. The camera
forgets its Wi-Fi settings and starts the `OpenIPC-XXXX` network again. Then
follow the first-time steps.

This only clears the Wi-Fi settings. Recordings, image settings and
everything else are untouched.

**If it does not have a button**, over SSH:

```sh
wifi-ctl provision      # start setup mode, keep the current settings as a fallback
wifi-ctl forget         # erase the Wi-Fi settings and start setup mode
```

There is deliberately no button on the camera's normal web page for this: a
page reachable from your LAN that can drop the camera off the network is not
something to leave lying around unauthenticated.

## Setting the network from the command line

```sh
wifi-ctl status                                     # where things stand
wifi-ctl scan                                       # what the camera can see
WIFI_PASSWORD='my secret' wifi-ctl configure 'My Network'
wifi-ctl configure 'Hidden Net' --hidden
```

Putting the password in `WIFI_PASSWORD` keeps it out of your shell history and
out of `ps`. `wifi-ctl configure` tests before saving, exactly like the web
page, and prints the reason if it fails.

There is no command that prints a stored Wi-Fi password. That is deliberate.

## If the camera loses Wi-Fi later

It keeps retrying, indefinitely, and reconnects by itself when the network
comes back. It does **not** turn itself back into a setup hotspot, because a
router reboot and a wrong password look identical from the camera's side, and
a camera that self-resets on every network blip is one you have to set up
again every time.

To force it back into setup mode, use the button or `wifi-ctl` above.
