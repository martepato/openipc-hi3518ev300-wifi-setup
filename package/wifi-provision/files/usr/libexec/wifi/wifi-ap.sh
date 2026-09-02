#!/bin/sh
#
# Copyright (c) OpenIPC  https://openipc.org  MIT License
#
# wifi-ap.sh -- provisioning access point: hostapd, DHCP server, captive
# portal web server and wildcard DNS.
#
# Sourced after wifi-lib.sh.

WIFI_HOSTAPD_PID=$WIFI_RUN_DIR/hostapd.pid
WIFI_UDHCPD_PID=$WIFI_RUN_DIR/udhcpd.pid
WIFI_HTTPD_PID=$WIFI_RUN_DIR/httpd.pid
WIFI_DNSD_PID=$WIFI_RUN_DIR/dnsd.pid
WIFI_HTTPD_CONF=$WIFI_RUN_DIR/httpd.conf
WIFI_MAJESTIC_PREEMPTED=$WIFI_RUN_DIR/majestic.preempted

# hostapd needs to be told which backend to drive: nl80211 for anything that
# registers a cfg80211 wiphy, or Realtek's own rtw interface for the
# out-of-tree drivers built without CONFIG_IOCTL_CFG80211 (which is why
# OpenIPC ships rtw-hostapd at all).
#
# Decided by asking the kernel, not by matching the driver's name. Whether a
# Realtek driver speaks nl80211 is a build-time option, not a property of the
# chip: OpenIPC's own 8189fs for the Xiaomi MJSXJ02HL is built with cfg80211
# and its stock config drives wpa_supplicant with -D nl80211, so a name-based
# guess of "8189 means rtw" is wrong on exactly the hardware this was written
# for. The phy80211 link exists if and only if the driver registered a wiphy,
# which is the same condition nl80211 needs.
wifi_ap_driver() {
	if [ "$WIFI_AP_DRIVER" != "auto" ]; then
		printf '%s' "$WIFI_AP_DRIVER"
		return
	fi
	if [ -e "/sys/class/net/$WIFI_IFACE/phy80211" ]; then
		printf 'nl80211'
	else
		printf 'rtw'
	fi
}

# The AP SSID is generated from [A-Za-z0-9-] only and the passphrase comes
# from the integrator's defaults file, never from the network -- but the
# passphrase is still turned into a pre-hashed wpa_psk so no user-supplied
# text is ever quoted into hostapd.conf.
wifi_ap_write_conf() {
	_ssid=$(wifi_ap_ssid)
	_tmp=$WIFI_HOSTAPD_CONF.tmp.$$
	( umask 077
	  {
		printf '%s\n' "interface=$WIFI_IFACE"
		printf '%s\n' "driver=$(wifi_ap_driver)"
		printf '%s\n' "ssid=$_ssid"
		printf '%s\n' "hw_mode=g"
		printf '%s\n' "channel=$WIFI_AP_CHANNEL"
		printf '%s\n' "ieee80211n=1"
		printf '%s\n' "wmm_enabled=1"
		printf '%s\n' "auth_algs=1"
		printf '%s\n' "ignore_broadcast_ssid=0"
		printf '%s\n' "max_num_sta=4"
		if [ "$WIFI_AP_SECURITY" = "wpa2" ] && [ -n "$WIFI_AP_PASSPHRASE" ]; then
			printf '%s\n' "wpa=2"
			printf '%s\n' "wpa_key_mgmt=WPA-PSK"
			printf '%s\n' "wpa_pairwise=CCMP"
			printf '%s\n' "rsn_pairwise=CCMP"
			if _psk=$(wifi_derive_psk "$_ssid" "$WIFI_AP_PASSPHRASE"); then
				printf '%s\n' "wpa_psk=$_psk"
			else
				printf '%s\n' "wpa_passphrase=$WIFI_AP_PASSPHRASE"
			fi
		fi
	  } > "$_tmp"
	) || { rm -f "$_tmp"; return 1; }
	mv -f "$_tmp" "$WIFI_HOSTAPD_CONF"
}

wifi_ap_write_dhcpd_conf() {
	: > "$WIFI_UDHCPD_LEASES"
	{
		printf '%s\n' "start $WIFI_AP_DHCP_START"
		printf '%s\n' "end $WIFI_AP_DHCP_END"
		printf '%s\n' "interface $WIFI_IFACE"
		printf '%s\n' "lease_file $WIFI_UDHCPD_LEASES"
		printf '%s\n' "pidfile $WIFI_UDHCPD_PID"
		printf '%s\n' "max_leases 20"
		printf '%s\n' "auto_time 0"
		printf '%s\n' "decline_time 60"
		printf '%s\n' "conflict_time 60"
		printf '%s\n' "offer_time 60"
		printf '%s\n' "min_lease 60"
		printf '%s\n' "opt subnet $WIFI_AP_NETMASK"
		# Point DNS at ourselves so the captive portal resolves, and hand out
		# a router option so phones that require a default gateway before
		# they will use the network are satisfied. No internet is reachable
		# through it -- provisioning is entirely local.
		printf '%s\n' "opt dns $WIFI_AP_IP"
		printf '%s\n' "opt router $WIFI_AP_IP"
		printf '%s\n' "opt lease 600"
	} > "$WIFI_UDHCPD_CONF"
}

# BusyBox httpd serves the portal. E404 is what makes captive detection work:
# any URL a phone probes that we do not have a file for is answered with the
# setup page itself, which is the signal iOS, Android and Windows all use to
# decide a network is a captive portal and pop the sign-in sheet.
wifi_ap_write_httpd_conf() {
	{
		printf '%s\n' "E404:/index.html"
		# Refuse anything that is not on the provisioning subnet. The socket
		# is already bound to the AP address; this is the second lock. The
		# subnet is derived from WIFI_AP_IP rather than hardcoded, so moving
		# the portal off 192.168.4.x does not silently lock every client out.
		printf '%s\n' "A:$(echo "$WIFI_AP_IP" | cut -d. -f1-3).0/24"
		printf '%s\n' "A:127.0.0.1"
		printf '%s\n' "D:*"
	} > "$WIFI_HTTPD_CONF"
}

wifi_ap_hostapd_running() {
	[ -r "$WIFI_HOSTAPD_PID" ] && wifi_pid_alive "$(cat "$WIFI_HOSTAPD_PID" 2>/dev/null)"
}

# Majestic serves its own web UI on port 80 across every address, so it and
# the portal cannot both hold that port. Provisioning is a temporary,
# exclusive mode, so the portal wins for its duration and majestic is put
# back exactly as it was on the way out.
wifi_ap_stop_majestic() {
	[ "$WIFI_PORTAL_STOP_MAJESTIC" = "1" ] || return 0
	[ -x /etc/init.d/S95majestic ] || return 0
	pidof majestic >/dev/null 2>&1 || return 0
	wifi_log "pausing majestic for the duration of provisioning (port $WIFI_PORTAL_PORT)"
	/etc/init.d/S95majestic stop >/dev/null 2>&1
	touch "$WIFI_MAJESTIC_PREEMPTED"
}

wifi_ap_restore_majestic() {
	[ -e "$WIFI_MAJESTIC_PREEMPTED" ] || return 0
	rm -f "$WIFI_MAJESTIC_PREEMPTED"
	[ -x /etc/init.d/S95majestic ] || return 0
	wifi_log "resuming majestic"
	/etc/init.d/S95majestic start >/dev/null 2>&1
}

wifi_ap_start() {
	wifi_log "starting provisioning access point"
	mkdir -p "$WIFI_RUN_DIR"

	# Station side must be fully down: one radio, one role. That includes
	# anything ifup started, which our pidfiles know nothing about --
	# hostapd cannot bring up an AP while a supplicant holds the interface.
	wifi_sta_stop 2>/dev/null
	wifi_kill_stray_clients

	wifi_ap_write_conf || { wifi_err "could not write hostapd config"; return 1; }
	wifi_ap_write_dhcpd_conf
	wifi_ap_write_httpd_conf

	ip link set dev "$WIFI_IFACE" up 2>/dev/null
	if ! hostapd -B -P "$WIFI_HOSTAPD_PID" "$WIFI_HOSTAPD_CONF" >/dev/null 2>&1; then
		wifi_err "hostapd failed to start -- the driver may not support AP mode"
		wifi_error_set ap_failed "The camera could not start its setup network."
		return 1
	fi

	# hostapd resets the interface, so address it only once it is up.
	_i=0
	while [ $_i -lt 10 ] && ! wifi_ap_hostapd_running; do
		_i=$((_i + 1)); sleep 1
	done
	ip addr flush dev "$WIFI_IFACE" 2>/dev/null
	ip addr add "$WIFI_AP_IP/24" dev "$WIFI_IFACE" 2>/dev/null
	ip link set dev "$WIFI_IFACE" up 2>/dev/null

	if ! udhcpd -S "$WIFI_UDHCPD_CONF" >/dev/null 2>&1; then
		wifi_warn "DHCP server failed to start; clients must set a static address"
	fi

	wifi_ap_stop_majestic
	if ! wifi_ap_start_portal; then
		# Without the portal the setup page is unreachable, so hand port 80
		# back rather than leaving the camera with no web interface at all.
		# OpenIPC's own network page writes wlanssid/wlanpass, which
		# wifi-manager watches for -- so the camera stays configurable, just
		# through a different page.
		wifi_err "setup page unavailable; restoring the camera's own web UI so it stays configurable"
		wifi_error_set portal_failed \
			"The setup page could not start. Configure Wi-Fi from the camera's own web interface instead."
		wifi_ap_restore_majestic
	fi
	wifi_ap_start_dns

	wifi_log "setup network '$(wifi_ap_ssid)' is up on $WIFI_AP_IP"
	return 0
}

wifi_ap_start_portal() {
	wifi_stop_pidfile "$WIFI_HTTPD_PID"
	# -f keeps httpd in the foreground so start-stop-daemon owns a pid that
	# stays valid; busybox httpd has no pidfile option of its own.
	if start-stop-daemon -S -b -m -p "$WIFI_HTTPD_PID" -x /usr/sbin/httpd -- \
		-f -p "$WIFI_AP_IP:$WIFI_PORTAL_PORT" -h "$WIFI_PORTAL_ROOT" \
		-c "$WIFI_HTTPD_CONF" >/dev/null 2>&1; then
		# start-stop-daemon returns 0 for "forked successfully", which says
		# nothing about whether httpd could bind. Confirm the listener.
		_i=0
		while [ $_i -lt 5 ]; do
			if wifi_ap_portal_listening; then
				wifi_log "setup page available at http://$WIFI_AP_IP/"
				return 0
			fi
			_i=$((_i + 1))
			sleep 1
		done
		wifi_err "setup web server started but is not listening on $WIFI_AP_IP:$WIFI_PORTAL_PORT"
		wifi_err "another process is probably holding that port -- check: netstat -ltnp | grep :$WIFI_PORTAL_PORT"
		wifi_stop_pidfile "$WIFI_HTTPD_PID"
		return 1
	fi
	wifi_err "setup web server failed to start (is /usr/sbin/httpd present?)"
	return 1
}

# True when something is listening on the portal's address and port. Checked
# in /proc/net/tcp rather than with netstat -p, which needs a bigger busybox
# than some builds have. Matches both the specific address and 0.0.0.0.
wifi_ap_portal_listening() {
	_hexport=$(printf '%04X' "$WIFI_PORTAL_PORT")
	awk -v p=":$_hexport" '$4 == "0A" && index($2, p) { found = 1 } END { exit !found }' \
		/proc/net/tcp 2>/dev/null
}

wifi_ap_start_dns() {
	[ "$WIFI_CAPTIVE_DNS" = "1" ] || return 0
	[ -x /usr/sbin/wifi-dnsd ] || {
		wifi_log "captive DNS helper not installed; setup page reachable at http://$WIFI_AP_IP/"
		return 0
	}
	wifi_stop_pidfile "$WIFI_DNSD_PID"
	if start-stop-daemon -S -b -m -p "$WIFI_DNSD_PID" -x /usr/sbin/wifi-dnsd -- \
		-a "$WIFI_AP_IP" >/dev/null 2>&1; then
		wifi_log "captive DNS responding on $WIFI_AP_IP"
		return 0
	fi
	# Not fatal: without it the user types the address instead of being
	# redirected, which is the documented fallback.
	wifi_warn "captive DNS failed to start; setup page still at http://$WIFI_AP_IP/"
	return 1
}

# Always tears down every provisioning daemon, even when hostapd has already
# died: gating this on wifi_ap_running would leave httpd holding port 80 and
# 192.168.4.1 still on the interface after a driver crash, which then blocks
# station mode from ever getting an address.
wifi_ap_stop() {
	wifi_log "stopping provisioning access point"
	wifi_stop_pidfile "$WIFI_DNSD_PID"
	wifi_stop_pidfile "$WIFI_HTTPD_PID"
	wifi_stop_pidfile "$WIFI_UDHCPD_PID"
	wifi_stop_pidfile "$WIFI_HOSTAPD_PID"
	ip addr flush dev "$WIFI_IFACE" 2>/dev/null
	ip link set dev "$WIFI_IFACE" down 2>/dev/null
	wifi_ap_restore_majestic
	return 0
}

wifi_ap_running() {
	wifi_ap_hostapd_running
}
