#!/bin/sh
#
# Copyright (c) OpenIPC  https://openipc.org  MIT License
#
# Set one key in a majestic.yaml, in place, leaving everything else in the
# file -- comments, key order, unrelated sections -- exactly as it was.
#
#   tools/majestic-set.sh <majestic.yaml> <section.key> <value>
#
# On the camera this job belongs to majestic's own `cli -s .section.key value`
# (a wrapper around yaml-cli). That is an ARM binary and the image is
# assembled on an x86 build host, so the build needs a host-side equivalent.
#
# The file majestic reads is one level deep everywhere, which is why only
# section.key is accepted: anything deeper is refused rather than guessed at.
set -eu

die() { printf 'majestic-set: %s\n' "$1" >&2; exit 1; }

[ $# -eq 3 ] || {
    printf 'usage: %s <majestic.yaml> <section.key> <value>\n' "$0" >&2
    exit 2
}
file=$1
path=$2
value=$3

[ -f "$file" ] || die "no such file: $file"
[ -w "$file" ] || die "not writable: $file"

# section.key, both plain YAML identifiers. A dot in the value is fine; a
# second dot in the path is not, because this cannot express it.
case "$path" in
    *.*.*) die "only section.key paths are supported: $path" ;;
    *.*)   : ;;
    *)     die "expected section.key, got: $path" ;;
esac
section=${path%%.*}
key=${path#*.}
for _part in "$section" "$key"; do
    case "$_part" in
        '' | *[!A-Za-z0-9_]* | [!A-Za-z_]*) die "not a YAML identifier: $_part" ;;
    esac
done

# A newline in the value would silently write a second, bogus line into the
# file; anything else non-printable would land in a config majestic parses.
[ -n "$value" ] || die "empty value for $path"
_len=$(printf '%s' "$value" | wc -c)
_vis=$(printf '%s' "$value" | tr -d '[:cntrl:]' | wc -c)
[ "$_len" -eq "$_vis" ] || die "value for $path contains control characters"

tmp=$file.majestic-set.$$
trap 'rm -f "$tmp"' EXIT INT TERM
# cp first, then truncate through the redirect: the new file inherits the
# old one's mode instead of whatever the umask says.
cp "$file" "$tmp"

awk -v sec="$section" -v key="$key" -v val="$value" '
	function emit(   pad) { pad = (ind == "" ? "  " : ind); print pad key ": " val }
	{
		# A top-level key ends whatever section we were in.
		if (match($0, /^[A-Za-z_][A-Za-z0-9_]*:/)) {
			if (insec && !done) { emit(); done = 1 }
			insec = (substr($0, 1, RLENGTH - 1) == sec)
			if (insec) ind = ""
			print
			next
		}
		if (insec && match($0, /^[ \t]+/)) {
			pad = substr($0, 1, RLENGTH)
			rest = substr($0, RLENGTH + 1)
			# Take the indentation from the first real key, not from a
			# comment, which may be indented differently.
			if (ind == "" && substr(rest, 1, 1) != "#") ind = pad
			if (!done && substr(rest, 1, length(key) + 1) == key ":") {
				print pad key ": " val
				done = 1
				next
			}
		}
		print
	}
	END {
		if (!done) {
			if (insec) emit()                       # section ran to EOF
			else { print sec ":"; ind = ""; emit() }  # no such section yet
		}
	}
' "$file" > "$tmp"

# An awk that fell over would leave a short file, and this runs against the
# rootfs of an image about to be flashed. Refuse to install a shrunken config.
_in=$(wc -l < "$file")
_out=$(wc -l < "$tmp")
[ "$_out" -ge "$_in" ] || die "rewrite lost lines ($_in -> $_out); $file untouched"
grep -q "^[[:space:]]*$key: $(printf '%s' "$value" | sed 's/[][\.*^$/]/\\&/g')\$" "$tmp" ||
    die "rewrite did not produce '$key: $value'; $file untouched"

mv "$tmp" "$file"
trap - EXIT INT TERM
