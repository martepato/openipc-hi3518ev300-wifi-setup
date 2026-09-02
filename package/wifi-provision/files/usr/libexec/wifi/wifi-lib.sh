#!/bin/sh
#
# Copyright (c) OpenIPC  https://openipc.org  MIT License
#
# wifi-lib.sh -- shared primitives for the Wi-Fi provisioning system.
#
# Sourced by wifi-manager, wifi-ctl and the portal CGI. Nothing in here may
# ever pass attacker-controlled text (an SSID, a passphrase) to a shell in
# command position, or write it unescaped into a configuration file. The two
# rules that make that structural rather than a matter of care:
#
#   1. Untrusted values live hex-encoded everywhere they are stored. The
#      credential store, the scan cache and the pending-request file hold
#      only [0-9a-f]* -- so a parser that reads them can never be surprised
#      and never needs to quote anything.
#   2. They are decoded only at the two points that consume raw bytes:
#      wpa_supplicant.conf (written as ssid=<hex>, which the config parser
#      accepts unquoted) and the JSON the portal renders. Neither is a shell.
#
# An SSID of $(reboot) or "; rm -rf / # is therefore just 28 or 34 bytes of
# hex on the way through.

WIFI_ETC_DIR=${WIFI_ETC_DIR:-/etc/wifi}
WIFI_RUN_DIR=${WIFI_RUN_DIR:-/tmp/wifi}
WIFI_CONF=$WIFI_ETC_DIR/wifi.conf
WIFI_DEFAULTS=$WIFI_ETC_DIR/wifi.defaults

WIFI_STATE_FILE=$WIFI_RUN_DIR/state
WIFI_ERROR_FILE=$WIFI_RUN_DIR/last_error
WIFI_SCAN_FILE=$WIFI_RUN_DIR/scan.tsv
WIFI_SCAN_STAMP=$WIFI_RUN_DIR/scan.stamp
WIFI_PENDING_FILE=$WIFI_RUN_DIR/pending
WIFI_RESULT_FILE=$WIFI_RUN_DIR/result
WIFI_SUPPLICANT_CONF=$WIFI_RUN_DIR/wpa_supplicant.conf
WIFI_HOSTAPD_CONF=$WIFI_RUN_DIR/hostapd.conf
WIFI_UDHCPD_CONF=$WIFI_RUN_DIR/udhcpd.conf
WIFI_UDHCPD_LEASES=$WIFI_RUN_DIR/udhcpd.leases
WIFI_CTRL_DIR=/var/run/wpa_supplicant

# ---------------------------------------------------------------- defaults --
# Every knob is overridable from /etc/wifi/wifi.defaults, which ships with the
# package and is a plain shell fragment written by the integrator (not by the
# user, and never by the web UI) -- so sourcing it is safe.

WIFI_IFACE=wlan0
WIFI_AP_IP=192.168.4.1
WIFI_AP_NETMASK=255.255.255.0
WIFI_AP_DHCP_START=192.168.4.100
WIFI_AP_DHCP_END=192.168.4.150
WIFI_AP_SSID_PREFIX=OpenIPC
WIFI_AP_CHANNEL=6
WIFI_AP_SECURITY=open
WIFI_AP_PASSPHRASE=
WIFI_AP_DRIVER=auto
WIFI_PORTAL_PORT=80
WIFI_PORTAL_ROOT=/var/www-wifi
WIFI_PORTAL_STOP_MAJESTIC=1
WIFI_CAPTIVE_DNS=1
WIFI_ENABLE_SAE=0
WIFI_STA_ASSOC_TIMEOUT=25
WIFI_STA_DHCP_TIMEOUT=20
WIFI_CONNECT_ATTEMPTS=3
WIFI_MONITOR_INTERVAL=10
WIFI_FALLBACK_AFTER=0
WIFI_AP_IDLE_TIMEOUT=900
WIFI_MIRROR_UBOOT_ENV=0
WIFI_BUTTON_GPIO=
WIFI_BUTTON_HOLD=5
WIFI_BUTTON_ACTIVE_LOW=1
WIFI_HOSTNAME_PREFIX=openipc
WIFI_LED_WARN_GPIO=
WIFI_LED_OK_GPIO=
WIFI_LED_ACTIVE_LOW=0
WIFI_LED_PAUSE_SERVICE=
WIFI_LED_HOOK=

# Root of the sysfs GPIO interface. Never changes on a real camera; it is a
# variable so the LED patterns and the button watcher can be exercised
# against a directory of ordinary files on a build host.
WIFI_GPIO_SYSFS=${WIFI_GPIO_SYSFS:-/sys/class/gpio}

# Root of procfs. Never changes on a real camera; a variable so the
# stray-process sweep below can be exercised against a directory of ordinary
# files on a build host.
WIFI_PROC=${WIFI_PROC:-/proc}

# shellcheck source=/dev/null  # path is deliberately variable
[ -r "$WIFI_DEFAULTS" ] && . "$WIFI_DEFAULTS"

# ----------------------------------------------------------------- logging --
# Passphrases are never arguments to these. Callers pass descriptions, and
# wifi_redact() exists for the one place a value could otherwise slip in.

wifi_log() {
	logger -t wifi -p daemon.info -- "$*" 2>/dev/null
	[ "${WIFI_VERBOSE:-0}" = "1" ] && echo "wifi: $*" >&2
	return 0
}

wifi_warn() {
	logger -t wifi -p daemon.warning -- "$*" 2>/dev/null
	echo "wifi: $*" >&2
	return 0
}

wifi_err() {
	logger -t wifi -p daemon.err -- "$*" 2>/dev/null
	echo "wifi: $*" >&2
	return 0
}

# Replace anything that looks like a secret with a fixed marker. Used when a
# tool's own output is logged, since we do not control what it prints.
wifi_redact() {
	sed -e 's/\(psk[^=]*=\)[^ ]*/\1<redacted>/gi' \
	    -e 's/\(passphrase[^=]*=\)[^ ]*/\1<redacted>/gi' \
	    -e 's/\(password[^=]*=\)[^ ]*/\1<redacted>/gi'
}

# ---------------------------------------------------------------- hex codec --

# stdin (raw bytes) -> stdout (lowercase hex, no separators, no newline)
wifi_hex_encode() {
	od -An -v -tx1 | tr -d ' \n\t'
}

# $1 = hex string -> stdout raw bytes, no trailing newline.
# Rejects anything that is not an even-length lowercase hex string, so a
# corrupted store can never produce a surprising byte sequence downstream.
wifi_hex_decode() {
	_h=$1
	case "$_h" in
		*[!0-9a-f]*) return 1 ;;
	esac
	[ -n "$_h" ] || return 0
	[ $(( ${#_h} % 2 )) -eq 0 ] || return 1
	# Rendered through %b with POSIX \0NNN octal escapes rather than the
	# \xNN hex form: \x in a format string is a busybox/bash extension that
	# dash and the host test harness do not implement, and %b takes the
	# escapes as an *argument*, so a % byte in the decoded data is never a
	# conversion specifier.
	printf '%b' "$(printf '%s' "$_h" | awk '
		BEGIN { for (i = 0; i < 16; i++) v[sprintf("%x", i)] = i }
		{
			for (i = 1; i <= length($0); i += 2)
				printf "\\0%03o", v[substr($0, i, 1)] * 16 + v[substr($0, i + 1, 1)]
		}')"
}

wifi_is_hex() {
	case "$1" in
		'' ) return 1 ;;
		*[!0-9a-f]*) return 1 ;;
	esac
	[ $(( ${#1} % 2 )) -eq 0 ]
}

# --------------------------------------------------------------- validation --

# True when the argument contains no C0 control byte. Written with tr rather
# than a case pattern because a control character cannot be spelled inside a
# shell glob: $(printf '\n') collapses to the empty string, and the pattern
# *""* matches everything -- a check that silently passes nothing.
wifi_has_no_control_chars() {
	_raw_len=$(printf '%s' "$1" | wc -c)
	_stripped_len=$(printf '%s' "$1" | tr -d '\000-\037\177' | wc -c)
	[ "$_raw_len" -eq "$_stripped_len" ]
}

# An SSID is 1..32 octets and may contain anything except NUL. We additionally
# reject control bytes: they cannot appear in a real SSID, and allowing them
# would let a crafted value inject a line into any file we produce.
wifi_validate_ssid_raw() {
	_s=$1
	_len=$(printf '%s' "$_s" | wc -c)
	[ "$_len" -ge 1 ] && [ "$_len" -le 32 ] || {
		WIFI_VALIDATION_ERROR="Network name must be 1 to 32 characters."
		return 1
	}
	if ! wifi_has_no_control_chars "$_s"; then
		WIFI_VALIDATION_ERROR="Network name contains an invalid character."
		return 1
	fi
	return 0
}

# A WPA-PSK key is either an 8..63 character passphrase or exactly 64 hex
# digits (a pre-derived PSK). Empty means an open network.
wifi_validate_key_raw() {
	_k=$1
	_len=$(printf '%s' "$_k" | wc -c)
	if [ "$_len" -eq 0 ]; then
		return 0
	fi
	if ! wifi_has_no_control_chars "$_k"; then
		WIFI_VALIDATION_ERROR="Password contains an invalid character."
		return 1
	fi
	if [ "$_len" -eq 64 ]; then
		case "$_k" in
			*[!0-9a-fA-F]*) : ;;
			*) return 0 ;;
		esac
	fi
	[ "$_len" -ge 8 ] && [ "$_len" -le 63 ] || {
		WIFI_VALIDATION_ERROR="Password must be 8 to 63 characters."
		return 1
	}
	return 0
}

# ----------------------------------------------------- credential store I/O --
#
# Format (all values hex, one key=value per line, LF terminated):
#   version=1
#   ssid=<hex>
#   key_type=open|psk|passphrase
#   key=<hex of the 64-hex PSK, or hex of the raw passphrase, or empty>
#   hidden=0|1
#   verified=0|1
#
# "verified" records that these credentials once produced a working
# association plus a DHCP lease. It is what stops a router outage from
# dropping the camera back into provisioning mode -- see wifi_should_fallback.

wifi_store_exists() {
	[ -s "$WIFI_CONF" ]
}

# Reads $WIFI_CONF into WIFI_CFG_* variables. Only whitelisted keys are read
# and only hex/0/1 values are accepted, so a truncated or corrupt file fails
# closed instead of half-loading.
wifi_store_load() {
	WIFI_CFG_SSID=
	WIFI_CFG_KEY_TYPE=
	WIFI_CFG_KEY=
	WIFI_CFG_HIDDEN=0
	WIFI_CFG_VERIFIED=0
	[ -r "$WIFI_CONF" ] || return 1
	while IFS='=' read -r _k _v; do
		case "$_k" in
			ssid)     wifi_is_hex "$_v" && WIFI_CFG_SSID=$_v ;;
			key)
				if [ -z "$_v" ]; then
					WIFI_CFG_KEY=
				elif wifi_is_hex "$_v"; then
					WIFI_CFG_KEY=$_v
				fi ;;
			key_type)
				case "$_v" in
					open|psk|passphrase) WIFI_CFG_KEY_TYPE=$_v ;;
				esac ;;
			hidden)   [ "$_v" = "1" ] && WIFI_CFG_HIDDEN=1 ;;
			verified) [ "$_v" = "1" ] && WIFI_CFG_VERIFIED=1 ;;
		esac
	done < "$WIFI_CONF"
	[ -n "$WIFI_CFG_SSID" ] && [ -n "$WIFI_CFG_KEY_TYPE" ]
}

# Atomic save: write a sibling temp file, fsync it, rename over the target.
# rename(2) within a directory is atomic on jffs2, ubifs and overlayfs, so a
# power cut during provisioning leaves either the old credentials or the new
# ones -- never a half-written file.
#
# $1=ssid_hex $2=key_type $3=key_hex $4=hidden $5=verified
wifi_store_save() {
	mkdir -p "$WIFI_ETC_DIR" || return 1
	_tmp=$WIFI_CONF.tmp.$$
	( umask 077
	  {
		printf '%s\n' "version=1"
		printf '%s\n' "ssid=$1"
		printf '%s\n' "key_type=$2"
		printf '%s\n' "key=$3"
		printf '%s\n' "hidden=${4:-0}"
		printf '%s\n' "verified=${5:-0}"
	  } > "$_tmp"
	) || { rm -f "$_tmp"; return 1; }
	chmod 600 "$_tmp" 2>/dev/null
	# Flush the file's own data before the rename so the directory entry can
	# never point at a block that was not written.
	sync
	mv -f "$_tmp" "$WIFI_CONF" || { rm -f "$_tmp"; return 1; }
	sync
	wifi_log "credentials stored"
	[ "$WIFI_MIRROR_UBOOT_ENV" = "1" ] && wifi_mirror_uboot_env
	return 0
}

wifi_store_mark_verified() {
	wifi_store_load || return 1
	[ "$WIFI_CFG_VERIFIED" = "1" ] && return 0
	wifi_store_save "$WIFI_CFG_SSID" "$WIFI_CFG_KEY_TYPE" "$WIFI_CFG_KEY" \
		"$WIFI_CFG_HIDDEN" 1
}

wifi_store_clear() {
	rm -f "$WIFI_CONF"
	sync
	wifi_log "credentials erased"
}

# Optional compatibility mirror into the U-Boot environment, so a stock
# OpenIPC image reflashed over this one still finds its network. Off by
# default: fw_setenv rewrites a raw flash sector, and doing that on every
# credential change trades flash wear and a small brick risk for a
# convenience most builds do not need.
wifi_mirror_uboot_env() {
	command -v fw_setenv >/dev/null 2>&1 || return 0
	wifi_store_load || return 1
	_ssid=$(wifi_hex_decode "$WIFI_CFG_SSID") || return 1
	case "$WIFI_CFG_KEY_TYPE" in
		passphrase) _key=$(wifi_hex_decode "$WIFI_CFG_KEY") ;;
		*) _key= ;;
	esac
	fw_setenv wlanssid "$_ssid" >/dev/null 2>&1
	[ -n "$_key" ] && fw_setenv wlanpass "$_key" >/dev/null 2>&1
	wifi_log "mirrored SSID to U-Boot environment"
	return 0
}

# One-time migration: a device that was already configured the stock OpenIPC
# way (wlanssid/wlanpass in the U-Boot environment) keeps working after the
# firmware update instead of dropping into provisioning mode.
wifi_import_uboot_env() {
	wifi_store_exists && return 1
	command -v fw_printenv >/dev/null 2>&1 || return 1
	_ssid=$(fw_printenv -n wlanssid 2>/dev/null) || return 1
	[ -n "$_ssid" ] || return 1
	_pass=$(fw_printenv -n wlanpass 2>/dev/null)
	wifi_validate_ssid_raw "$_ssid" || return 1
	wifi_validate_key_raw "$_pass" || return 1
	_ssid_hex=$(printf '%s' "$_ssid" | wifi_hex_encode)
	if [ -z "$_pass" ]; then
		wifi_store_save "$_ssid_hex" open "" 0 0
	else
		_type=passphrase
		_key_hex=$(printf '%s' "$_pass" | wifi_hex_encode)
		if _psk=$(wifi_derive_psk "$_ssid" "$_pass"); then
			_type=psk
			_key_hex=$(printf '%s' "$_psk" | wifi_hex_encode)
		fi
		wifi_store_save "$_ssid_hex" "$_type" "$_key_hex" 0 0
	fi
	wifi_log "imported existing credentials from U-Boot environment"
	return 0
}

# ------------------------------------------------------------- candidate --
#
# A candidate is a credential set submitted from the portal that has not yet
# proved it works. It lives in the run directory (tmpfs), never in /etc, and
# is promoted into the store only after a successful association *and* a DHCP
# lease. Same hex-only format as the store.

WIFI_CANDIDATE_FILE=$WIFI_RUN_DIR/candidate

# $1=ssid_hex $2=key_type $3=key_hex $4=hidden
wifi_candidate_save() {
	mkdir -p "$WIFI_RUN_DIR"
	_tmp=$WIFI_CANDIDATE_FILE.tmp.$$
	( umask 077
	  {
		printf '%s\n' "version=1"
		printf '%s\n' "ssid=$1"
		printf '%s\n' "key_type=$2"
		printf '%s\n' "key=$3"
		printf '%s\n' "hidden=${4:-0}"
		printf '%s\n' "verified=0"
	  } > "$_tmp"
	) || { rm -f "$_tmp"; return 1; }
	mv -f "$_tmp" "$WIFI_CANDIDATE_FILE"
}

wifi_candidate_load() {
	WIFI_CONF_SAVED=$WIFI_CONF
	WIFI_CONF=$WIFI_CANDIDATE_FILE
	wifi_store_load
	_rc=$?
	WIFI_CONF=$WIFI_CONF_SAVED
	return $_rc
}

wifi_candidate_clear() {
	rm -f "$WIFI_CANDIDATE_FILE"
}

# Promote the loaded candidate into the persistent store, already verified.
wifi_candidate_commit() {
	wifi_candidate_load || return 1
	wifi_store_save "$WIFI_CFG_SSID" "$WIFI_CFG_KEY_TYPE" "$WIFI_CFG_KEY" \
		"$WIFI_CFG_HIDDEN" 1 || return 1
	wifi_candidate_clear
	return 0
}

# ------------------------------------------------------- command channel --
#
# The portal CGI never touches the radio. It drops a request here and the
# manager daemon, which is the only thing that runs hostapd, wpa_supplicant
# or udhcpc, picks it up. That keeps every privileged network operation in
# one process with one code path, and means a bug in the CGI cannot do more
# than enqueue a badly formed request that the manager rejects.

WIFI_CMD_FILE=$WIFI_RUN_DIR/cmd

# $1=command, remaining args are pre-validated hex key=value lines.
wifi_cmd_post() {
	mkdir -p "$WIFI_RUN_DIR"
	_cmd=$1
	shift
	_tmp=$WIFI_CMD_FILE.tmp.$$
	( umask 077
	  {
		printf '%s\n' "cmd=$_cmd"
		for _line in "$@"; do echo "$_line"; done
	  } > "$_tmp"
	) || { rm -f "$_tmp"; return 1; }
	mv -f "$_tmp" "$WIFI_CMD_FILE"
}

# Consume the pending command, exporting WIFI_CMD / WIFI_CMD_SSID /
# WIFI_CMD_KEY / WIFI_CMD_HIDDEN. Values that are not on the whitelist are
# dropped rather than passed on.
wifi_cmd_take() {
	WIFI_CMD=
	WIFI_CMD_SSID=
	WIFI_CMD_KEY=
	WIFI_CMD_HIDDEN=0
	[ -r "$WIFI_CMD_FILE" ] || return 1
	_taken=$WIFI_CMD_FILE.taken.$$
	mv -f "$WIFI_CMD_FILE" "$_taken" 2>/dev/null || return 1
	while IFS='=' read -r _k _v; do
		case "$_k" in
			cmd)
				case "$_v" in
					connect|rescan|provision|forget|reconnect) WIFI_CMD=$_v ;;
				esac ;;
			ssid)   wifi_is_hex "$_v" && WIFI_CMD_SSID=$_v ;;
			key)    [ -z "$_v" ] || { wifi_is_hex "$_v" && WIFI_CMD_KEY=$_v; } ;;
			hidden) [ "$_v" = "1" ] && WIFI_CMD_HIDDEN=1 ;;
		esac
	done < "$_taken"
	rm -f "$_taken"
	[ -n "$WIFI_CMD" ]
}

# ------------------------------------------------------------ test result --
#
# What the portal polls while a candidate is being tried. Written by the
# manager, read by the CGI. Never contains a key.

wifi_result_set() {
	mkdir -p "$WIFI_RUN_DIR"
	_tmp=$WIFI_RESULT_FILE.tmp.$$
	{
		printf '%s\n' "status=$1"
		printf '%s\n' "code=$2"
		printf '%s\n' "message=$3"
		printf '%s\n' "ip=$4"
		printf '%s\n' "ssid=$5"
	} > "$_tmp"
	mv -f "$_tmp" "$WIFI_RESULT_FILE"
}

wifi_result_get() {
	WIFI_RES_STATUS=idle
	WIFI_RES_CODE=
	WIFI_RES_MESSAGE=
	WIFI_RES_IP=
	WIFI_RES_SSID=
	[ -r "$WIFI_RESULT_FILE" ] || return 1
	while IFS='=' read -r _k _v; do
		case "$_k" in
			status)  WIFI_RES_STATUS=$_v ;;
			code)    WIFI_RES_CODE=$_v ;;
			message) WIFI_RES_MESSAGE=$_v ;;
			ip)      WIFI_RES_IP=$_v ;;
			ssid)    wifi_is_hex "$_v" && WIFI_RES_SSID=$_v ;;
		esac
	done < "$WIFI_RESULT_FILE"
	return 0
}

# ------------------------------------------- externally-set credentials --
#
# OpenIPC's own web UI already has a Wi-Fi page: it calls setnetwork, which
# writes wlanssid/wlanpass into the U-Boot environment and rewrites
# interfaces.d/wlan0 -- and then stops, because the stock design expects a
# reboot to pick it up.
#
# Rather than duplicate that page or fight it, wifi-manager watches the
# environment and adopts anything set there. Configuring Wi-Fi through the
# camera's own interface then behaves exactly like configuring it through the
# setup portal: the credentials are tested, committed on success, and the
# setup AP is torn down. It is also the safety net for the case where the
# portal cannot start at all -- the camera is still configurable, just
# through a different page.
#
# The marker records what we last acted on, so a value we wrote ourselves
# (WIFI_MIRROR_UBOOT_ENV) or one we already adopted does not re-trigger.

WIFI_ENV_SEEN=$WIFI_RUN_DIR/env.seen

# Echoes a stable fingerprint of the environment's credentials, or nothing
# when none are set. The passphrase is hashed, never written out in the
# clear -- this file lives in tmpfs but there is no reason for it to hold a
# secret.
wifi_env_fingerprint() {
	command -v fw_printenv >/dev/null 2>&1 || return 1
	_e_ssid=$(fw_printenv -n wlanssid 2>/dev/null)
	[ -n "$_e_ssid" ] || return 1
	_e_pass=$(fw_printenv -n wlanpass 2>/dev/null)
	printf '%s\0%s' "$_e_ssid" "$_e_pass" | md5sum | cut -d' ' -f1
}

wifi_env_mark_seen() {
	mkdir -p "$WIFI_RUN_DIR"
	_fp=${1:-$(wifi_env_fingerprint)}
	printf '%s\n' "$_fp" > "$WIFI_ENV_SEEN.tmp" 2>/dev/null &&
		mv -f "$WIFI_ENV_SEEN.tmp" "$WIFI_ENV_SEEN"
}

# 0 when the environment holds credentials we have not acted on yet, with
# WIFI_ENV_SSID / WIFI_ENV_PASS set to the raw values.
wifi_env_changed() {
	WIFI_ENV_SSID=
	WIFI_ENV_PASS=
	_fp=$(wifi_env_fingerprint) || return 1
	_prev=
	[ -r "$WIFI_ENV_SEEN" ] && _prev=$(cat "$WIFI_ENV_SEEN" 2>/dev/null)
	[ "$_fp" = "$_prev" ] && return 1

	_ssid=$(fw_printenv -n wlanssid 2>/dev/null)
	_pass=$(fw_printenv -n wlanpass 2>/dev/null)
	if ! wifi_validate_ssid_raw "$_ssid" || ! wifi_validate_key_raw "$_pass"; then
		# Rejected once and marked seen, so a value we can never use does
		# not make us re-check and re-log every ten seconds.
		wifi_warn "ignoring invalid Wi-Fi settings from the U-Boot environment: $WIFI_VALIDATION_ERROR"
		wifi_env_mark_seen "$_fp"
		return 1
	fi

	# Already exactly what we have committed: nothing to do, just remember it.
	if wifi_store_load; then
		_cur_ssid=$(wifi_hex_decode "$WIFI_CFG_SSID")
		if [ "$_cur_ssid" = "$_ssid" ] && [ "$WIFI_CFG_VERIFIED" = "1" ]; then
			wifi_env_mark_seen "$_fp"
			return 1
		fi
	fi

	WIFI_ENV_SSID=$_ssid
	WIFI_ENV_PASS=$_pass
	return 0
}

# ------------------------------------------------- interfaces.d/wlan0 --
#
# setnetwork rewrites this file with the stock stanza every time someone
# saves the web UI's network page, which would put a second wpa_supplicant
# back in the boot path, racing ours. Re-assert ours whenever that happens.
#
# The stanza deliberately contains the word "dhcp" in a comment. fw-network.cgi
# decides whether to show "Use DHCP" as on with
#     grep -q dhcp /etc/network/interfaces.d/wlan0
# and this interface really is DHCP -- wifi-manager runs udhcpc on it. Without
# the word the page reports "static" for a camera that is using DHCP, which is
# simply wrong information.

wifi_wlan0_stanza() {
	cat <<'STANZA'
# Managed by wifi-provision.
#
# Addressing is dhcp, performed by wifi-manager rather than by ifupdown, so
# that one process owns the supplicant, the DHCP client and hostapd on this
# radio. (The word "dhcp" above is also what the web UI greps for to report
# the addressing mode, and reporting dhcp here is accurate.)
#
# The stock stanza is kept alongside as wlan0.stock. To go back to it, move
# it over this file and disable /etc/init.d/S41wifi.
iface wlan0 inet manual
    pre-up ip link set dev wlan0 up
STANZA
}

# True when the file has been replaced by something that starts its own
# supplicant -- i.e. setnetwork has been here.
wifi_wlan0_stanza_clobbered() {
	[ -r /etc/network/interfaces.d/wlan0 ] || return 0
	grep -q 'wpa_supplicant' /etc/network/interfaces.d/wlan0 2>/dev/null
}

wifi_wlan0_stanza_restore() {
	wifi_wlan0_stanza_clobbered || return 1
	wifi_log "interfaces.d/wlan0 was rewritten (setnetwork); restoring ours"
	_tmp=/etc/network/interfaces.d/wlan0.tmp.$$
	wifi_wlan0_stanza > "$_tmp" 2>/dev/null || { rm -f "$_tmp"; return 1; }
	mv -f "$_tmp" /etc/network/interfaces.d/wlan0
	return 0
}

# ------------------------------------------------------------- PSK handling --

# Derive the 256-bit PSK so the store never has to hold the plaintext
# passphrase. Only possible for an 8..63 byte ASCII passphrase; wpa_passphrase
# rejects anything else, and we fall back to storing the raw passphrase.
# Both arguments are passed as argv, never interpolated into a command line.
wifi_derive_psk() {
	_out=$(wpa_passphrase "$1" "$2" 2>/dev/null) || return 1
	_psk=$(printf '%s\n' "$_out" | sed -n 's/^[[:space:]]*psk=\([0-9a-f]\{64\}\)$/\1/p' | head -1)
	[ -n "$_psk" ] || return 1
	printf '%s' "$_psk"
}

# ------------------------------------------------ wpa_supplicant.conf writer --
#
# The SSID goes in as bare hex, which wpa_supplicant's parser accepts and
# which cannot terminate a string or start a comment. The key is either a bare
# 64-hex PSK, or -- only when the passphrase could not be pre-hashed -- a
# quoted string with backslash and double-quote escaped.

# Escape for a wpa_supplicant quoted string. Only reached for a passphrase
# that could not be pre-hashed -- everything else in the file is bare hex.
#
# Note that every line of the generated config is written with printf, never
# echo: the echo built-in in dash and in busybox ash expands backslash
# escapes in its argument, so `echo "psk=\"a\\\\b\""` silently undoes the
# doubling this function just did and emits an invalid config.
wifi_escape_conf_string() {
	printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# Builds the config from the WIFI_CFG_* variables, NOT from the store. The
# caller decides where they came from -- wifi_store_load for the committed
# credentials, wifi_candidate_load for a set that is only being tested. That
# split is what lets a candidate be tried on the radio without ever being
# written to /etc, so a mistyped password leaves the last working
# configuration untouched.
wifi_write_supplicant_conf() {
	[ -n "$WIFI_CFG_SSID" ] && [ -n "$WIFI_CFG_KEY_TYPE" ] || return 1
	_tmp=$WIFI_SUPPLICANT_CONF.tmp.$$
	( umask 077
	  {
		printf '%s\n' "ctrl_interface=$WIFI_CTRL_DIR"
		printf '%s\n' "update_config=0"
		printf '%s\n' "ap_scan=1"
		printf '%s\n' "network={"
		printf '%s\n' "	ssid=$WIFI_CFG_SSID"
		[ "$WIFI_CFG_HIDDEN" = "1" ] && echo "	scan_ssid=1"
		case "$WIFI_CFG_KEY_TYPE" in
			open)
				printf '%s\n' "	key_mgmt=NONE"
				;;
			psk)
				# Stored value is the 64-hex PSK: emit it unquoted.
				printf '%s\n' "	key_mgmt=WPA-PSK"
				printf '%s\n' "	psk=$(wifi_hex_decode "$WIFI_CFG_KEY")"
				;;
			passphrase)
				_pp=$(wifi_hex_decode "$WIFI_CFG_KEY")
				if [ "$WIFI_ENABLE_SAE" = "1" ]; then
					# WPA3-Personal needs the passphrase, not the PSK, and
					# management-frame protection negotiated as optional so
					# the same block still joins a WPA2-only AP.
					printf '%s\n' "	key_mgmt=WPA-PSK SAE"
					printf '%s\n' "	ieee80211w=1"
					printf '%s\n' "	sae_password=\"$(wifi_escape_conf_string "$_pp")\""
				else
					printf '%s\n' "	key_mgmt=WPA-PSK"
				fi
				printf '%s\n' "	psk=\"$(wifi_escape_conf_string "$_pp")\""
				;;
		esac
		printf '%s\n' "}"
	  } > "$_tmp"
	) || { rm -f "$_tmp"; return 1; }
	chmod 600 "$_tmp" 2>/dev/null
	mv -f "$_tmp" "$WIFI_SUPPLICANT_CONF" || { rm -f "$_tmp"; return 1; }
	return 0
}

# --------------------------------------------------------------- device ID --

# A stable 4 hex digit suffix for the provisioning SSID and the hostname, so
# two cameras powered on side by side are never ambiguous. Preference order:
# the Wi-Fi MAC (unique, and what the user's phone will show), then the
# U-Boot ethaddr, then the SoC serial. All three can be missing on a bare
# board, hence the final constant -- documented, not silent.
wifi_device_id() {
	_src=
	[ -r "/sys/class/net/$WIFI_IFACE/address" ] &&
		_src=$(cat "/sys/class/net/$WIFI_IFACE/address" 2>/dev/null)
	if [ -z "$_src" ] && command -v fw_printenv >/dev/null 2>&1; then
		_src=$(fw_printenv -n ethaddr 2>/dev/null)
	fi
	if [ -z "$_src" ]; then
		_src=$(sed -n 's/^Serial[[:space:]]*:[[:space:]]*//p' /proc/cpuinfo 2>/dev/null | head -1)
	fi
	if [ -z "$_src" ] || [ "$_src" = "00:00:00:00:00:00" ]; then
		echo "0000"
		return 1
	fi
	printf '%s' "$_src" | tr -d ':' | tr 'a-z' 'A-Z' | tail -c 5 | head -c 4
}

wifi_ap_ssid() {
	printf '%s-%s' "$WIFI_AP_SSID_PREFIX" "$(wifi_device_id)"
}

wifi_hostname() {
	printf '%s-%s' "$WIFI_HOSTNAME_PREFIX" "$(wifi_device_id | tr 'A-Z' 'a-z')"
}

# ------------------------------------------------------------------- state --

wifi_state_set() {
	mkdir -p "$WIFI_RUN_DIR"
	printf '%s\n' "$1" > "$WIFI_STATE_FILE.tmp"
	mv -f "$WIFI_STATE_FILE.tmp" "$WIFI_STATE_FILE"
	wifi_log "state -> $1"
}

wifi_state_get() {
	[ -r "$WIFI_STATE_FILE" ] && cat "$WIFI_STATE_FILE" 2>/dev/null || echo UNKNOWN
}

# $1 = machine-readable code, $2 = message shown to the user
wifi_error_set() {
	mkdir -p "$WIFI_RUN_DIR"
	printf '%s\n%s\n' "$1" "$2" > "$WIFI_ERROR_FILE.tmp"
	mv -f "$WIFI_ERROR_FILE.tmp" "$WIFI_ERROR_FILE"
}

wifi_error_clear() {
	rm -f "$WIFI_ERROR_FILE"
}

wifi_error_code() {
	[ -r "$WIFI_ERROR_FILE" ] && sed -n 1p "$WIFI_ERROR_FILE" || echo ""
}

wifi_error_message() {
	[ -r "$WIFI_ERROR_FILE" ] && sed -n 2p "$WIFI_ERROR_FILE" || echo ""
}

# -------------------------------------------------------------- JSON output --
#
# Hand-rolled because the alternative is pulling a JSON library onto an 8 MB
# flash for six fields. Only these two encoders ever emit untrusted text.

# Escape a raw string for inclusion between JSON double quotes. Control bytes
# are dropped rather than encoded as \u00XX: nothing we emit is allowed to
# contain one in the first place (validation rejects them on the way in), so
# this is a backstop, and dropping needs no \xNN support in sed -- which
# busybox sed does not reliably provide. Non-ASCII passes through as UTF-8,
# which is what a browser wants for an SSID with accents or CJK.
wifi_json_escape() {
	printf '%s' "$1" | tr -d '\000-\037\177' |
		sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

wifi_json_str() {
	printf '"%s"' "$(wifi_json_escape "$1")"
}

# Seconds since the scan cache was refreshed, or -1 if there is none. Lives
# here rather than in wifi-scan.sh because the portal CGI reports it and has
# no business loading the scan machinery it would otherwise pull in.
wifi_scan_age() {
	[ -r "$WIFI_SCAN_STAMP" ] || { echo -1; return; }
	_then=$(cat "$WIFI_SCAN_STAMP" 2>/dev/null)
	case "$_then" in
		''|*[!0-9]*) echo -1; return ;;
	esac
	echo $(( $(date +%s) - _then ))
}

# ------------------------------------------------- stray radio clients --
#
# S40network runs before us and calls `ifup wlan0`. If the stanza on disk is
# the stock one -- which it will be on an upgrade, because setnetwork wrote
# it into the writable overlay and a rootfs reflash does not clear that --
# ifup has already started its own wpa_supplicant by the time we run. Two
# supplicants on one radio is undefined at best; ours typically fails to
# initialise the driver and the camera never associates.
#
# Fixing the file (wifi_wlan0_stanza_restore) is not enough on that boot,
# because ifup has already acted on it. So sweep the interface clear before
# taking it over.
#
# Targeted deliberately: matched on argv[0] AND on our interface appearing in
# the arguments, and never touching a pid we started ourselves. A blanket
# `killall wpa_supplicant` on a camera that may be running other radios is
# how you take out the wrong process.
wifi_kill_stray_clients() {
	_mine=" $(cat "$WIFI_WPA_PID" 2>/dev/null) $(cat "$WIFI_DHCP_PID" 2>/dev/null) "
	_found=0
	for _entry in "$WIFI_PROC"/[0-9]*; do
		[ -r "$_entry/cmdline" ] || continue
		_pid=${_entry##*/}
		case "$_mine" in
			*" $_pid "*) continue ;;
		esac
		# argv[0] identifies the applet even when the binary is busybox.
		_argv0=$(tr '\0' '\n' < "$_entry/cmdline" 2>/dev/null | head -1)
		case "${_argv0##*/}" in
			wpa_supplicant|udhcpc) : ;;
			*) continue ;;
		esac
		# Only if it is on OUR interface.
		tr '\0' ' ' < "$_entry/cmdline" 2>/dev/null |
			grep -q -- "[ =]$WIFI_IFACE\( \|$\)" || continue
		wifi_log "clearing a stray ${_argv0##*/} on $WIFI_IFACE (pid $_pid) started outside the manager"
		kill "$_pid" 2>/dev/null
		_found=1
	done
	[ "$_found" = "1" ] && sleep 1
	return 0
}

# ------------------------------------------------------------ misc helpers --

wifi_iface_exists() {
	[ -e "/sys/class/net/$WIFI_IFACE" ]
}

wifi_iface_has_carrier() {
	[ "$(cat "/sys/class/net/$WIFI_IFACE/carrier" 2>/dev/null)" = "1" ]
}

wifi_iface_ipv4() {
	ip -4 addr show dev "$WIFI_IFACE" 2>/dev/null |
		sed -n 's/.*inet \([0-9.]*\)\/.*/\1/p' | head -1
}

wifi_pid_alive() {
	[ -n "$1" ] && [ -d "/proc/$1" ]
}

# Stop a daemon by pidfile, then confirm. Never killall: on a camera that also
# runs a streamer, killall wpa_supplicant during a firmware race is how you
# take out the wrong process.
wifi_stop_pidfile() {
	_pf=$1
	[ -r "$_pf" ] || return 0
	_pid=$(cat "$_pf" 2>/dev/null)
	if wifi_pid_alive "$_pid"; then
		kill "$_pid" 2>/dev/null
		_i=0
		while wifi_pid_alive "$_pid" && [ $_i -lt 5 ]; do
			_i=$((_i + 1))
			sleep 1
		done
		wifi_pid_alive "$_pid" && kill -9 "$_pid" 2>/dev/null
	fi
	rm -f "$_pf"
	return 0
}
