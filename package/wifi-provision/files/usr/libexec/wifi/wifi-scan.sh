#!/bin/sh
#
# Copyright (c) OpenIPC  https://openipc.org  MIT License
#
# wifi-scan.sh -- neighbour scan for the provisioning UI.
#
# Scanning goes through wpa_cli rather than iw or iwlist. wpa_supplicant is
# already in every OpenIPC image that has Wi-Fi at all, it works over both
# nl80211 and wext (so the Realtek out-of-tree drivers are covered without a
# second code path), and it reports signal, security flags and frequency in
# one place. Adding iw would be a package and ~90 KB of flash for the same
# answer.
#
# Sourced after wifi-lib.sh and wifi-sta.sh.

WIFI_SCAN_CONF=$WIFI_RUN_DIR/wpa_scan.conf

# Cache format, tab separated, one BSS per line:
#   <ssid_hex>  <signal_dbm>  <security>  <freq_mhz>
# The SSID is hex so nothing downstream has to think about quoting, and an
# SSID that is genuinely empty (a hidden network beaconing a blank SSID) is
# simply an empty first field and gets dropped.

wifi_scan_write_conf() {
	{
		echo "ctrl_interface=$WIFI_CTRL_DIR"
		echo "update_config=0"
		echo "ap_scan=1"
	} > "$WIFI_SCAN_CONF"
}

# wpa_supplicant prints SSIDs through printf_encode: printable ASCII passes
# through, and everything else -- including UTF-8 bytes -- arrives as \xNN,
# with backslash, quote, newline, carriage return, tab and escape as their
# own two-character escapes. Convert that straight to hex so the raw bytes
# survive intact and never touch a shell.
wifi_scan_unescape_to_hex() {
	awk '
	BEGIN {
		for (i = 0; i < 256; i++) ord[sprintf("%c", i)] = i
		split("n:10 r:13 t:9 e:27", pairs, " ")
		for (p in pairs) {
			split(pairs[p], kv, ":")
			esc[kv[1]] = kv[2]
		}
		esc["\\"] = 92; esc["\""] = 34
	}
	{
		out = ""
		i = 1
		n = length($0)
		while (i <= n) {
			c = substr($0, i, 1)
			if (c == "\\" && i < n) {
				d = substr($0, i + 1, 1)
				if (d == "x" && i + 3 <= n) {
					out = out tolower(substr($0, i + 2, 2))
					i += 4
					continue
				}
				if (d in esc) {
					out = out sprintf("%02x", esc[d])
					i += 2
					continue
				}
			}
			out = out sprintf("%02x", ord[c])
			i++
		}
		print out
	}'
}

# Reduce wpa_supplicant capability flags to one word the UI can show.
wifi_scan_security() {
	case "$1" in
		*WPA3*|*SAE*) echo "WPA3" ;;
		*WPA2*|*RSN*) echo "WPA2" ;;
		*WPA*)        echo "WPA" ;;
		*WEP*)        echo "WEP" ;;
		*)            echo "Open" ;;
	esac
}

# Run a scan and refresh the cache. Requires wpa_supplicant to be running --
# the caller decides whether that is the provisioning instance or a
# scan-only one, because on a single-radio device the AP has to be down for
# a scan to return anything useful.
#
# 0 = cache refreshed, 1 = no supplicant, 2 = scan produced nothing.
wifi_scan_run() {
	_own_supplicant=0
	if ! wifi_sta_running; then
		wifi_scan_write_conf
		wifi_sta_start_supplicant "$WIFI_SCAN_CONF" || return 1
		_own_supplicant=1
	fi

	wifi_wpa_cli scan >/dev/null 2>&1
	# A scan across 13 channels takes a couple of seconds; poll for results
	# rather than sleeping a fixed worst case.
	_i=0
	_raw=
	while [ $_i -lt 8 ]; do
		sleep 1
		_i=$((_i + 1))
		_raw=$(wifi_wpa_cli scan_results 2>/dev/null)
		[ "$(printf '%s\n' "$_raw" | wc -l)" -gt 1 ] && break
	done

	[ "$_own_supplicant" = "1" ] && wifi_sta_stop_supplicant

	if [ -z "$_raw" ]; then
		wifi_log "scan returned no networks"
		return 2
	fi

	_tmp=$WIFI_SCAN_FILE.tmp.$$
	: > "$_tmp"
	# Fields: bssid / frequency / signal level / flags / ssid
	printf '%s\n' "$_raw" | tail -n +2 | while IFS='	' read -r _bssid _freq _sig _flags _ssid; do
		[ -n "$_bssid" ] || continue
		[ -n "$_ssid" ] || continue
		_hex=$(printf '%s' "$_ssid" | wifi_scan_unescape_to_hex)
		[ -n "$_hex" ] || continue
		printf '%s\t%s\t%s\t%s\n' \
			"$_hex" "${_sig:-0}" "$(wifi_scan_security "$_flags")" "${_freq:-0}" >> "$_tmp"
	done

	# Strongest first, one entry per SSID: a mesh network with four APs
	# should be one row in the list, not four identical ones.
	sort -t'	' -k2,2nr "$_tmp" | awk -F'\t' '!seen[$1]++' > "$_tmp.sorted"
	mv -f "$_tmp.sorted" "$WIFI_SCAN_FILE"
	rm -f "$_tmp"
	date +%s > "$WIFI_SCAN_STAMP"
	wifi_log "scan complete: $(wc -l < "$WIFI_SCAN_FILE") networks"
	return 0
}
