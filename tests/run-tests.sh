#!/bin/sh
#
# Copyright (c) OpenIPC  https://openipc.org  MIT License
#
# Host-side test suite for the Wi-Fi provisioning logic.
#
# Everything here runs against the real scripts with no target hardware: the
# parts that touch a radio are isolated in wifi-sta.sh / wifi-ap.sh, and what
# is tested here is the part where a bug is a security bug -- decoding form
# input, validating it, and turning it into configuration files.
#
# Run with:  sh tests/run-tests.sh
# Uses dash when available, since busybox ash is closer to dash than to bash.

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PKG=$ROOT/package/wifi-provision/files
WORK=${TMPDIR:-/tmp}/wifi-provision-tests.$$

PASS=0
FAIL=0

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

mkdir -p "$WORK/etc" "$WORK/run"

# The library reads these before anything else, so point it at the sandbox.
WIFI_ETC_DIR=$WORK/etc
WIFI_RUN_DIR=$WORK/run
export WIFI_ETC_DIR WIFI_RUN_DIR

. "$PKG/usr/libexec/wifi/wifi-lib.sh"
. "$PKG/usr/libexec/wifi/wifi-scan.sh" 2>/dev/null || true

# Pull the CGI's form decoder in without running the CGI's dispatch.
eval "$(sed -n '/^form_to_hex()/,/^}$/p' "$PKG/var/www-wifi/cgi-bin/wifi")"
field() { printf '%s\n' "$FORM" | awk -v want="$1" '$1 == want { print $2; exit }'; }

ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; [ $# -gt 1 ] && printf '       %s\n' "$2"; }
is()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got [$2] want [$3]"; fi; }
yes_() { if "$@" >/dev/null 2>&1; then ok "$*"; else bad "$*"; fi; }
no_()  { if "$@" >/dev/null 2>&1; then bad "$* (should have failed)"; else ok "! $*"; fi; }

section() { printf '\n== %s\n' "$1"; }

# ---------------------------------------------------------------------------
section "hex codec round-trips"

for s in \
	'MyHomeWiFi' \
	'My Home 2.4G' \
	'$(reboot)' \
	'"; rm -rf / #' \
	'`reboot`' \
	'${IFS}cat${IFS}/etc/shadow' \
	'a|b&c;d' \
	'back\slash' \
	'percent %s %d %n' \
	'café ümlaut' \
	'网络名称' \
	'  leading and trailing  '
do
	h=$(printf '%s' "$s" | wifi_hex_encode)
	d=$(wifi_hex_decode "$h")
	is "round-trip [$s]" "$d" "$s"
done

no_ wifi_hex_decode 'nothex'
no_ wifi_hex_decode 'abc'
no_ wifi_is_hex 'AABB'          # uppercase is not our canonical form

# ---------------------------------------------------------------------------
section "input validation"

yes_ wifi_validate_ssid_raw 'MyHomeWiFi'
yes_ wifi_validate_ssid_raw '$(reboot)'
yes_ wifi_validate_ssid_raw '12345678901234567890123456789012'
no_  wifi_validate_ssid_raw ''
no_  wifi_validate_ssid_raw '123456789012345678901234567890123'
no_  wifi_validate_ssid_raw "$(printf 'ab\ncd')"
no_  wifi_validate_ssid_raw "$(printf 'ab\tcd')"

yes_ wifi_validate_key_raw ''
yes_ wifi_validate_key_raw 'password'
yes_ wifi_validate_key_raw '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
no_  wifi_validate_key_raw 'short7c'
no_  wifi_validate_key_raw "$(printf 'pass\nword')"
# 64 characters that are not hex must be treated as a passphrase, not a PSK,
# and 64 is inside the 8..63 range check only by the hex branch -- so this
# must be rejected.
no_  wifi_validate_key_raw '................................................................'

# ---------------------------------------------------------------------------
section "credential store"

ssid_hex=$(printf '%s' 'My Home 2.4G' | wifi_hex_encode)
key_hex=$(printf '%s' '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef' | wifi_hex_encode)

yes_ wifi_store_save "$ssid_hex" psk "$key_hex" 0 1
yes_ wifi_store_exists
yes_ wifi_store_load
is "ssid survives"     "$(wifi_hex_decode "$WIFI_CFG_SSID")" 'My Home 2.4G'
is "key type survives" "$WIFI_CFG_KEY_TYPE" 'psk'
is "verified survives" "$WIFI_CFG_VERIFIED" '1'

mode=$(ls -l "$WIFI_CONF" | cut -c1-10)
is "store is not world or group readable" "$mode" '-rw-------'

# A store the writer never finished must not half-load.
printf 'version=1\nssid=%s\n' "$ssid_hex" > "$WIFI_CONF"
no_ wifi_store_load
printf 'version=1\nssid=zzz\nkey_type=psk\nkey=\n' > "$WIFI_CONF"
no_ wifi_store_load

wifi_store_clear
no_ wifi_store_exists

# ---------------------------------------------------------------------------
section "wpa_supplicant.conf generation"

gen_conf() {
	# $1 raw ssid, $2 key type, $3 raw key, $4 hidden
	WIFI_CFG_SSID=$(printf '%s' "$1" | wifi_hex_encode)
	WIFI_CFG_KEY_TYPE=$2
	WIFI_CFG_KEY=$(printf '%s' "$3" | wifi_hex_encode)
	WIFI_CFG_HIDDEN=${4:-0}
	WIFI_CFG_VERIFIED=0
	wifi_write_supplicant_conf
}

evil='$(touch '"$WORK"'/pwned); rm -rf / #'
gen_conf "$evil" psk '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'

if [ -e "$WORK/pwned" ]; then
	bad "config generation executed the SSID"
else
	ok "config generation does not execute an SSID containing \$( ) and ;"
fi

if grep -q 'ssid=2428746f75636820' "$WIFI_SUPPLICANT_CONF"; then
	ok "SSID is written as unquoted hex"
else
	bad "SSID is not hex-encoded in the config" "$(sed -n '/ssid=/p' "$WIFI_SUPPLICANT_CONF")"
fi

if grep -qF 'rm -rf' "$WIFI_SUPPLICANT_CONF"; then
	bad "raw SSID text reached the config file"
else
	ok "no raw SSID text appears in the config file"
fi

is "one network block" "$(grep -c '^network={' "$WIFI_SUPPLICANT_CONF")" '1'
is "config is not world readable" "$(ls -l "$WIFI_SUPPLICANT_CONF" | cut -c1-10)" '-rw-------'

# A passphrase that has to be stored in plaintext must still be escaped.
gen_conf 'Net' passphrase 'pa"ss\word'
psk_line=$(sed -n 's/^\tpsk=//p' "$WIFI_SUPPLICANT_CONF")
is "quotes and backslashes escaped" "$psk_line" '"pa\"ss\\word"'

# An SSID whose bytes would close the quoted string cannot, because it is
# never quoted in the first place.
gen_conf 'a"b' psk '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
is "quote in SSID stays hex" "$(sed -n 's/^\tssid=//p' "$WIFI_SUPPLICANT_CONF")" '612262'

gen_conf 'Open Net' open ''
yes_ grep -q 'key_mgmt=NONE' "$WIFI_SUPPLICANT_CONF"

gen_conf 'Hidden' psk '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef' 1
yes_ grep -q 'scan_ssid=1' "$WIFI_SUPPLICANT_CONF"

# ---------------------------------------------------------------------------
section "form decoding (the CGI boundary)"

FORM=$(printf '%s' 'action=connect&ssid=%24%28touch+'"$(printf '%s' "$WORK/pwned2" | sed 's|/|%2F|g')"%29'&psk=secret12' | form_to_hex)
decoded=$(wifi_hex_decode "$(field ssid)")
if [ -e "$WORK/pwned2" ]; then
	bad "form decoding executed the SSID"
else
	ok "form decoding does not execute \$(touch ...)"
fi
case "$decoded" in
	'$(touch '*) ok "command substitution survives as literal text" ;;
	*) bad "unexpected decode" "[$decoded]" ;;
esac

FORM=$(printf '%s' 'ssid=a%26b%3Dc' | form_to_hex)
is "& and = inside a value" "$(wifi_hex_decode "$(field ssid)")" 'a&b=c'

FORM=$(printf '%s' 'ssid=My+Home' | form_to_hex)
is "+ decodes to space" "$(wifi_hex_decode "$(field ssid)")" 'My Home'

FORM=$(printf '%s' 'ssid=caf%C3%A9' | form_to_hex)
is "UTF-8 percent escapes" "$(wifi_hex_decode "$(field ssid)")" 'café'

FORM=$(printf '%s' 'evil;name=x&../../etc=y&ok_name=z&ssid=Good' | form_to_hex)
names=$(printf '%s\n' "$FORM" | awk '{print $1}' | sort | tr '\n' ' ')
is "hostile field names dropped" "$names" 'ok_name ssid '

FORM=$(printf '%s' 'ssid=%ZZ%2' | form_to_hex)
is "invalid escapes stay literal" "$(wifi_hex_decode "$(field ssid)")" '%ZZ%2'

FORM=$(printf '%s' 'noequalshere' | form_to_hex)
is "field with no = is skipped" "$FORM" ''

# ---------------------------------------------------------------------------
section "JSON encoding"

is "quote and backslash escaped" "$(wifi_json_str 'a"b\c')" '"a\"b\\c"'
is "control bytes stripped" "$(wifi_json_str "$(printf 'a\tb')")" '"ab"'
is "utf-8 passes through" "$(wifi_json_str 'café')" '"café"'

# ---------------------------------------------------------------------------
section "scan result parsing"

chk_scan() {
	h=$(printf '%s' "$1" | wifi_scan_unescape_to_hex)
	is "scan unescape [$1]" "$(wifi_hex_decode "$h")" "$2"
}
chk_scan 'MyHomeWiFi' 'MyHomeWiFi'
chk_scan 'caf\xc3\xa9' 'café'
chk_scan 'Guest\\Net' 'Guest\Net'
chk_scan 'say \"hi\"' 'say "hi"'
chk_scan '$(reboot)' '$(reboot)'

is "WPA2 flags"  "$(wifi_scan_security '[WPA2-PSK-CCMP][ESS]')" 'WPA2'
is "WPA3 flags"  "$(wifi_scan_security '[WPA2-PSK-CCMP][WPA2-SAE-CCMP][ESS]')" 'WPA3'
is "open flags"  "$(wifi_scan_security '[ESS]')" 'Open'
is "WEP flags"   "$(wifi_scan_security '[WEP][ESS]')" 'WEP'

# ---------------------------------------------------------------------------
section "command channel"

wifi_cmd_post connect "ssid=$ssid_hex" "key=" "hidden=1"
yes_ wifi_cmd_take
is "command taken"  "$WIFI_CMD" 'connect'
is "ssid carried"   "$WIFI_CMD_SSID" "$ssid_hex"
is "hidden carried" "$WIFI_CMD_HIDDEN" '1'
no_ wifi_cmd_take   # consumed exactly once

# An unknown verb must not be dispatched.
printf 'cmd=rm -rf /\n' > "$WIFI_CMD_FILE"
no_ wifi_cmd_take

# A non-hex SSID in a hand-written command file must be dropped, not passed on.
printf 'cmd=connect\nssid=; reboot\n' > "$WIFI_CMD_FILE"
wifi_cmd_take >/dev/null 2>&1
is "non-hex ssid dropped" "$WIFI_CMD_SSID" ''

# ---------------------------------------------------------------------------
section "candidate isolation"

wifi_store_save "$ssid_hex" psk "$key_hex" 0 1
other=$(printf '%s' 'WrongNet' | wifi_hex_encode)
wifi_candidate_save "$other" open '' 0
wifi_store_load
is "store untouched by a candidate" "$(wifi_hex_decode "$WIFI_CFG_SSID")" 'My Home 2.4G'
wifi_candidate_load
is "candidate loads separately" "$(wifi_hex_decode "$WIFI_CFG_SSID")" 'WrongNet'
yes_ wifi_candidate_commit
wifi_store_load
is "commit promotes the candidate" "$(wifi_hex_decode "$WIFI_CFG_SSID")" 'WrongNet'
is "commit marks it verified" "$WIFI_CFG_VERIFIED" '1'
no_ test -e "$WIFI_CANDIDATE_FILE"

# ---------------------------------------------------------------------------
section "no secret is ever echoed"

wifi_store_save "$ssid_hex" passphrase "$(printf '%s' 'SuperSecret123' | wifi_hex_encode)" 0 1
if grep -rl 'SuperSecret123' "$WORK/run" 2>/dev/null | grep -q .; then
	bad "a passphrase leaked into the run directory"
else
	ok "no passphrase in the run directory"
fi
# wifi-ctl has no code path that prints the key.
if grep -n 'WIFI_CFG_KEY' "$PKG/usr/sbin/wifi-ctl" | grep -qv 'KEY_TYPE'; then
	bad "wifi-ctl references the stored key"
else
	ok "wifi-ctl never reads the stored key"
fi
# Neither does the CGI.
if grep -n 'WIFI_CFG_KEY' "$PKG/var/www-wifi/cgi-bin/wifi" | grep -qv 'KEY_TYPE'; then
	bad "the CGI references the stored key"
else
	ok "the CGI never reads the stored key"
fi

# ---------------------------------------------------------------------------
section "LED indicator"

# Driven against a directory of ordinary files standing in for sysfs, so the
# patterns, the polarity and the hand-back are all exercised without a camera.
LEDW=$WORK/gpio
mkdir -p "$LEDW/gpio52" "$LEDW/gpio53" "$WORK/bin"
for g in 52 53; do
	echo out > "$LEDW/gpio$g/direction"
	echo 0 > "$LEDW/gpio$g/value"
done
touch "$LEDW/export"
# busybox has usleep; a build host may not.
if ! command -v usleep >/dev/null 2>&1; then
	printf '#!/bin/sh\nexec sleep 0.1\n' > "$WORK/bin/usleep"
	chmod +x "$WORK/bin/usleep"
	PATH=$WORK/bin:$PATH
	export PATH
fi

WIFI_GPIO_SYSFS=$LEDW
WIFI_LIB_DIR=$PKG/usr/libexec/wifi
export WIFI_GPIO_SYSFS WIFI_LIB_DIR

led_val() { printf '%s%s' "$(cat "$LEDW/gpio52/value")" "$(cat "$LEDW/gpio53/value")"; }

# Sample a state for a moment and report which distinct LED combinations it
# produced, sorted -- enough to tell the patterns apart without asserting on
# exact timing, which would make the suite flaky.
led_combos() {
	echo "$1" > "$WIFI_STATE_FILE"
	printf 'WIFI_LED_WARN_GPIO=52\nWIFI_LED_OK_GPIO=53\nWIFI_LED_ACTIVE_LOW=%s\n' \
		"${2:-0}" > "$WIFI_DEFAULTS"
	sh "$PKG/usr/sbin/wifi-led" run >/dev/null 2>&1 &
	_lp=$!
	_seen=
	_i=0
	while [ $_i -lt 22 ]; do
		_seen="$_seen$(led_val) "
		sleep 0.1
		_i=$((_i + 1))
	done
	kill "$_lp" 2>/dev/null
	wait "$_lp" 2>/dev/null
	printf '%s' "$_seen" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ',' 
}

# 10 = amber only, 01 = blue only, 11 = both, 00 = off.
case "$(led_combos INIT)" in
	*10*) ok "INIT lights the warn LED" ;;
	*)    bad "INIT pattern" "combos: $(led_combos INIT)" ;;
esac

_prov=$(led_combos PROVISIONING)
case "$_prov" in
	*10*) case "$_prov" in
		*01*) ok "PROVISIONING alternates warn and ok" ;;
		*)    bad "PROVISIONING never lit the ok LED" "combos: $_prov" ;;
	      esac ;;
	*)    bad "PROVISIONING never lit the warn LED" "combos: $_prov" ;;
esac

case "$(led_combos TESTING)" in
	*11*) ok "TESTING lights both (white)" ;;
	*)    bad "TESTING never lit both LEDs" ;;
esac

_conn=$(led_combos CONNECTING)
case "$_conn" in
	*01*) case "$_conn" in
		*10*) bad "CONNECTING lit the warn LED" "combos: $_conn" ;;
		*)    ok "CONNECTING uses the ok LED only" ;;
	      esac ;;
	*)    bad "CONNECTING never lit the ok LED" "combos: $_conn" ;;
esac

_recon=$(led_combos RECONNECTING)
case "$_recon" in
	*10*) case "$_recon" in
		*01*) bad "RECONNECTING lit the ok LED" "combos: $_recon" ;;
		*)    ok "RECONNECTING uses the warn LED only" ;;
	      esac ;;
	*)    bad "RECONNECTING never lit the warn LED" "combos: $_recon" ;;
esac

# Active-low boards must invert, or a "lit" LED is dark on real hardware.
case "$(led_combos INIT 1)" in
	*01*) ok "active-low inverts the written value" ;;
	*)    bad "active-low did not invert" "combos: $(led_combos INIT 1)" ;;
esac

# Connected: brief confirmation, then the LEDs go back to the board.
printf 'WIFI_LED_WARN_GPIO=52\nWIFI_LED_OK_GPIO=53\n' > "$WIFI_DEFAULTS"
echo CONNECTED > "$WIFI_STATE_FILE"
sh "$PKG/usr/sbin/wifi-led" run >/dev/null 2>&1 &
_lp=$!
sleep 1
_during=$(led_val)
sleep 4
_after=$(led_val)
kill "$_lp" 2>/dev/null; wait "$_lp" 2>/dev/null
is "CONNECTED confirms on the ok LED" "$_during" "01"
is "CONNECTED then releases the LEDs" "$_after" "00"
no_ test -e "$WORK/run/led.claimed"

# SIGTERM must hand the LEDs back rather than freeze them mid-blink.
echo PROVISIONING > "$WIFI_STATE_FILE"
sh "$PKG/usr/sbin/wifi-led" run >/dev/null 2>&1 &
_lp=$!
sleep 1
kill -TERM "$_lp" 2>/dev/null
sleep 1
wait "$_lp" 2>/dev/null
is "SIGTERM leaves the LEDs off" "$(led_val)" "00"
no_ test -e "$WORK/run/led.pid"

# The default build configures no LEDs at all and must stay silent.
: > "$WIFI_DEFAULTS"
_out=$(sh "$PKG/usr/sbin/wifi-led" run 2>&1)
_rc=$?
is "no LEDs configured exits 0" "$_rc" "0"
is "no LEDs configured says nothing" "$_out" ""

unset WIFI_GPIO_SYSFS WIFI_LIB_DIR

# ---------------------------------------------------------------------------
printf '\n%s\n' "-----------------------------------------"
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
