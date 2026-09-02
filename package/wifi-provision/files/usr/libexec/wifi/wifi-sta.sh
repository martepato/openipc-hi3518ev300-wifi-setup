#!/bin/sh
#
# Copyright (c) OpenIPC  https://openipc.org  MIT License
#
# wifi-sta.sh -- station (client) mode: association and DHCP.
#
# Sourced after wifi-lib.sh.

WIFI_WPA_PID=$WIFI_RUN_DIR/wpa_supplicant.pid
WIFI_WPA_LOG=$WIFI_RUN_DIR/wpa_supplicant.log
WIFI_DHCP_PID=$WIFI_RUN_DIR/udhcpc.pid

# wpa_supplicant driver backends, tried in order. nl80211 first for anything
# mac80211-based (atbm, aic8800, ssv), wext second for the Realtek
# out-of-tree drivers that only register a wireless extensions interface.
WIFI_STA_DRIVER=${WIFI_STA_DRIVER:-nl80211,wext}

wifi_wpa_cli() {
	wpa_cli -p "$WIFI_CTRL_DIR" -i "$WIFI_IFACE" "$@" 2>/dev/null
}

wifi_sta_running() {
	[ -r "$WIFI_WPA_PID" ] && wifi_pid_alive "$(cat "$WIFI_WPA_PID" 2>/dev/null)"
}

# Start wpa_supplicant against $1 (a config path). The log is kept because it
# is the only place that says *why* an association failed -- at the default
# verbosity it carries the association and 4-way-handshake events but no key
# material.
wifi_sta_start_supplicant() {
	_conf=$1
	wifi_sta_stop_supplicant
	# ifup may have left one of its own on this interface; ours cannot
	# initialise the driver alongside it.
	wifi_kill_stray_clients
	mkdir -p "$WIFI_CTRL_DIR" "$WIFI_RUN_DIR"
	: > "$WIFI_WPA_LOG"
	chmod 600 "$WIFI_WPA_LOG" 2>/dev/null
	ip link set dev "$WIFI_IFACE" up 2>/dev/null

	for _drv in $(echo "$WIFI_STA_DRIVER" | tr ',' ' '); do
		if wpa_supplicant -B -P "$WIFI_WPA_PID" -i "$WIFI_IFACE" \
			-D "$_drv" -c "$_conf" -f "$WIFI_WPA_LOG" >/dev/null 2>&1; then
			# -B returns before the control interface is necessarily up.
			_i=0
			while [ $_i -lt 10 ]; do
				wifi_wpa_cli ping 2>/dev/null | grep -q PONG && break
				_i=$((_i + 1))
				sleep 1
			done
			wifi_log "supplicant started (driver $_drv)"
			return 0
		fi
		wifi_log "supplicant driver $_drv unavailable, trying next"
	done
	wifi_err "wpa_supplicant failed to start on $WIFI_IFACE"
	return 1
}

wifi_sta_stop_supplicant() {
	wifi_stop_pidfile "$WIFI_WPA_PID"
	rm -f "$WIFI_CTRL_DIR/$WIFI_IFACE"
}

wifi_sta_state() {
	wifi_wpa_cli status 2>/dev/null | sed -n 's/^wpa_state=//p' | head -1
}

# Block until associated or $1 seconds elapse. 0 = associated.
wifi_sta_wait_assoc() {
	_timeout=${1:-$WIFI_STA_ASSOC_TIMEOUT}
	_i=0
	while [ $_i -lt "$_timeout" ]; do
		case "$(wifi_sta_state)" in
			COMPLETED) return 0 ;;
		esac
		# Bail out early on an unambiguous rejection rather than burning the
		# whole timeout: the user is watching a progress bar.
		if grep -q 'reason=WRONG_KEY\|pre-shared key may be incorrect' "$WIFI_WPA_LOG" 2>/dev/null; then
			return 2
		fi
		_i=$((_i + 1))
		sleep 1
	done
	return 1
}

# Classify a failed attempt into something a non-technical user can act on.
# Echoes "code|message".
wifi_sta_diagnose() {
	if grep -q 'reason=WRONG_KEY\|pre-shared key may be incorrect\|4-Way Handshake failed' "$WIFI_WPA_LOG" 2>/dev/null; then
		echo 'wrong_key|Wrong Wi-Fi password. Please check the password and try again.'
		return
	fi
	if grep -q 'CTRL-EVENT-NETWORK-NOT-FOUND' "$WIFI_WPA_LOG" 2>/dev/null; then
		echo 'not_found|That network was not found. Check the name, move the camera closer to the router, and make sure the network is 2.4 GHz.'
		return
	fi
	if grep -q 'CTRL-EVENT-ASSOC-REJECT' "$WIFI_WPA_LOG" 2>/dev/null; then
		echo 'assoc_reject|The router refused the connection. It may use a security mode this camera does not support, or have a MAC address filter.'
		return
	fi
	echo 'timeout|Could not connect to that network. Please check the password and the signal strength, then try again.'
}

# One-shot DHCP used to prove a candidate network really works.
# 0 = lease obtained.
wifi_sta_dhcp_probe() {
	_timeout=${1:-$WIFI_STA_DHCP_TIMEOUT}
	_tries=$(( _timeout / 4 ))
	[ "$_tries" -lt 2 ] && _tries=2
	udhcpc -i "$WIFI_IFACE" -n -q -t "$_tries" -T 2 -A 2 \
		-s /usr/share/udhcpc/default.script >/dev/null 2>&1
}

# Long-running DHCP client for normal operation: keeps the lease renewed and
# survives the AP going away and coming back.
wifi_sta_dhcp_start() {
	wifi_sta_dhcp_stop
	udhcpc -i "$WIFI_IFACE" -b -t 5 -T 3 -A 10 -p "$WIFI_DHCP_PID" \
		-s /usr/share/udhcpc/default.script >/dev/null 2>&1
}

wifi_sta_dhcp_stop() {
	wifi_stop_pidfile "$WIFI_DHCP_PID"
}

wifi_sta_dhcp_running() {
	[ -r "$WIFI_DHCP_PID" ] && wifi_pid_alive "$(cat "$WIFI_DHCP_PID" 2>/dev/null)"
}

# Tear down everything station-side and drop the address, so a later AP mode
# starts from a clean interface.
wifi_sta_stop() {
	wifi_sta_dhcp_stop
	wifi_sta_stop_supplicant
	ip -4 addr flush dev "$WIFI_IFACE" 2>/dev/null
}

# Full connection attempt against the stored credentials.
#   0 connected (associated + lease)
#   1 could not start
#   2 associated but no DHCP lease
#   3 association failed (see wifi_sta_diagnose)
wifi_sta_connect() {
	wifi_write_supplicant_conf || {
		wifi_err "could not build supplicant configuration"
		return 1
	}
	wifi_sta_start_supplicant "$WIFI_SUPPLICANT_CONF" || return 1

	wifi_log "connecting to configured network"
	wifi_sta_wait_assoc "$WIFI_STA_ASSOC_TIMEOUT"
	case $? in
		0) : ;;
		*) wifi_log "association failed"; return 3 ;;
	esac
	wifi_log "association successful"

	wifi_log "requesting DHCP lease"
	if ! wifi_sta_dhcp_probe "$WIFI_STA_DHCP_TIMEOUT"; then
		wifi_log "no DHCP lease"
		return 2
	fi
	_ip=$(wifi_iface_ipv4)
	wifi_log "acquired address ${_ip:-unknown}"
	wifi_sta_dhcp_start
	return 0
}

# True while the link is usable: supplicant associated, carrier up, and an
# IPv4 address present.
wifi_sta_healthy() {
	wifi_sta_running || return 1
	[ "$(wifi_sta_state)" = "COMPLETED" ] || return 1
	wifi_iface_has_carrier || return 1
	[ -n "$(wifi_iface_ipv4)" ] || return 1
	return 0
}
