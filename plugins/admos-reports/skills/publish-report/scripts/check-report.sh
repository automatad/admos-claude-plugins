#!/usr/bin/env bash
# check-report.sh - local pre-flight for a report file before it is uploaded.
#
# Prints size, SHA-256, whether the file would be accepted by the ingest Worker
# (ADMOS reports contract, section 3), and how many external resources it references.
# It NEVER prints file content: the only text taken from the file is hostnames
# and numeric counts.
#
# Usage: check-report.sh [-m|--max-bytes N] <file>
#   REPORT_MAX_BYTES=N may be used instead of --max-bytes (default 10485760 = 10 MiB,
#   the Worker default; the upload pass carries the real limit as upload.max_bytes).
#
# Exit codes: 0 ok (external references are reported, not fatal)
#             1 usage error / unreadable file
#             2 larger than the limit
#             3 the ingest Worker would reject it (empty, NUL bytes, not UTF-8,
#               does not start with <!doctype html> or <html>)
#
# Needs only bash, grep, sed, tr, wc, head, tail, od, cut, sort, uniq and one of
# shasum / sha256sum (macOS and Linux). iconv is used if present.

set -euo pipefail
export LC_ALL=C

readonly DEFAULT_MAX_BYTES=10485760
readonly MAX_HOSTS_SHOWN=20

usage() {
  cat >&2 <<'USAGE'
Usage: check-report.sh [-m|--max-bytes N] <file>

Pre-flight check for a report file. Prints size, sha256, HTML sanity and the
hostnames of external resources. Never prints file content.
USAGE
}

max_bytes="${REPORT_MAX_BYTES:-$DEFAULT_MAX_BYTES}"
file=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    -m | --max-bytes)
      [ "$#" -ge 2 ] || { usage; exit 1; }
      max_bytes="$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "check-report.sh: unknown option: $1" >&2
      usage
      exit 1
      ;;
    *)
      [ -z "$file" ] || { echo "check-report.sh: only one file allowed" >&2; exit 1; }
      file="$1"
      shift
      ;;
  esac
done
if [ -z "$file" ] && [ "$#" -gt 0 ]; then
  file="$1"
fi

if [ -z "$file" ]; then
  usage
  exit 1
fi
case "$max_bytes" in
  '' | *[!0-9]*)
    echo "check-report.sh: --max-bytes must be a whole number" >&2
    exit 1
    ;;
esac
if [ ! -f "$file" ] || [ ! -r "$file" ]; then
  echo "check-report.sh: not a readable file: $file" >&2
  exit 1
fi

# ---- size and digest ---------------------------------------------------------

size="$(wc -c <"$file" | tr -d '[:space:]')"

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum <"$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 <"$1" | cut -d' ' -f1
  else
    echo "unavailable"
  fi
}
digest="$(sha256_of "$file")"

human_size() {
  awk -v b="$1" 'BEGIN {
    if (b >= 1048576) printf "%.2f MiB", b / 1048576
    else if (b >= 1024) printf "%.1f KiB", b / 1024
    else printf "%d B", b
  }'
}

# ---- would the ingest Worker reject it? --------------------------------------

rejections=()

if [ "$size" -eq 0 ]; then
  rejections+=("empty (zero bytes)")
fi

# NUL bytes -> binary_content
kept="$(tr -d '\000' <"$file" | wc -c | tr -d '[:space:]')"
if [ "$kept" -ne "$size" ]; then
  rejections+=("binary_content (contains NUL bytes)")
fi

# invalid UTF-8 -> not_utf8
utf8="unknown (iconv not found)"
if command -v iconv >/dev/null 2>&1; then
  if iconv -f UTF-8 -t UTF-8 <"$file" >/dev/null 2>&1; then
    utf8="valid"
  else
    utf8="INVALID"
    rejections+=("not_utf8 (invalid UTF-8)")
  fi
fi

# first non-space, non-BOM, non-comment content must be <!doctype html or <html
starts_html="no"
if [ "$size" -gt 0 ]; then
  first3="$(head -c 3 <"$file" | od -An -tx1 | tr -d ' \n')"
  skip=1
  [ "$first3" = "efbbbf" ] && skip=4
  # head first, then tail: neither side closes its pipe early (pipefail-safe).
  sample="$(head -c 65540 <"$file" | tail -c +"$skip" | tr '\n\r\t' '   ' | tr -d '\000')"
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    sample="${sample#"${sample%%[![:space:]]*}"}"
    case "$sample" in
      '<!--'*)
        rest="${sample#*-->}"
        [ "$rest" != "$sample" ] || break
        sample="$rest"
        ;;
      *) break ;;
    esac
  done
  head15="$(printf '%s' "${sample:0:15}" | tr 'A-Z' 'a-z')"
  case "$head15" in
    '<!doctype html'* | '<html'*) starts_html="yes" ;;
  esac
fi
if [ "$size" -gt 0 ] && [ "$starts_html" = "no" ]; then
  rejections+=("disguised (must start with <!doctype html> or <html>)")
fi

# ---- scans (counts and hostnames only) ---------------------------------------

count_matches() { # count_matches <ERE> -> number of case-insensitive matches
  { grep -Eoi -- "$1" "$file" || true; } | wc -l | tr -d '[:space:]'
}

# Same families as the Worker's external_resource warning (ADMOS reports contract, section 3).
re_attr='(^|[^A-Za-z0-9_-])(src|href|poster|action|data|srcset)[[:space:]]*=[[:space:]]*["'"'"']?[[:space:]]*(https?:)?//[^"'"'"'[:space:]>]+'
re_cssurl='url\([[:space:]]*["'"'"']?[[:space:]]*(https?:)?//[^"'"'"')[:space:]]+'
re_import='@import[[:space:]]+["'"'"']?[[:space:]]*(https?:)?//[^"'"'"';[:space:]]+'

external_matches() {
  { grep -Eoi -- "$re_attr" "$file" || true; }
  { grep -Eoi -- "$re_cssurl" "$file" || true; }
  { grep -Eoi -- "$re_import" "$file" || true; }
}

hosts_of_matches() { # stdin: matches; stdout: one lowercase hostname per line
  sed -E 's#^[^/]*//##' \
    | sed -E 's%[/?#:"'"'"')\\;, ].*$%%' \
    | tr 'A-Z' 'a-z' \
    | { grep -v '^$' || true; }
}

matches_tmp="$(mktemp)"
trap 'rm -f "$matches_tmp"' EXIT
external_matches >"$matches_tmp"
ext_total="$(wc -l <"$matches_tmp" | tr -d '[:space:]')"
host_counts="$(hosts_of_matches <"$matches_tmp" | sort | uniq -c | sort -rn)"
if [ -n "$host_counts" ]; then
  ext_hosts="$(printf '%s\n' "$host_counts" | wc -l | tr -d '[:space:]')"
else
  ext_hosts=0
fi

has_html_end="no"
if grep -qi -- '</html>' "$file"; then has_html_end="yes"; fi

# Informational counts for the other warning families.
n_network="$(count_matches 'fetch[[:space:]]*\(|XMLHttpRequest|WebSocket[[:space:]]*\(|EventSource[[:space:]]*\(|navigator\.sendBeacon|RTCPeerConnection|importScripts[[:space:]]*\(|new[[:space:]]+Worker[[:space:]]*\(')"
n_nav="$(count_matches '<meta[^>]*http-equiv[[:space:]]*=[[:space:]]*["'"'"']?refresh|<base[[:space:]>]|window\.open[[:space:]]*\(|top\.location|parent\.location|location\.href[[:space:]]*=')"
n_form="$(count_matches '<form')"
n_frame="$(count_matches '<iframe|<object|<embed')"
n_storage="$(count_matches 'document\.cookie|localStorage|sessionStorage|indexedDB')"
n_dyn="$(count_matches 'eval[[:space:]]*\(|new[[:space:]]+Function[[:space:]]*\(')"

# ---- report ------------------------------------------------------------------

over_limit="no"
if [ "$size" -gt "$max_bytes" ]; then over_limit="yes"; fi

printf 'file:               %s\n' "$file"
printf 'size_bytes:         %s (%s)\n' "$size" "$(human_size "$size")"
printf 'limit_bytes:        %s (%s)\n' "$max_bytes" "$(human_size "$max_bytes")"
printf 'sha256:             %s\n' "$digest"
printf 'starts_like_html:   %s\n' "$starts_html"
printf 'utf8:               %s\n' "$utf8"
printf 'nul_bytes:          %s\n' "$([ "$kept" -eq "$size" ] && echo none || echo PRESENT)"
printf 'has_closing_html:   %s\n' "$has_html_end"
printf 'external_references: %s across %s host(s)\n' "$ext_total" "$ext_hosts"
if [ -n "$host_counts" ]; then
  printf '%s\n' "$host_counts" | sed -n "1,${MAX_HOSTS_SHOWN}p" | awk '{ printf "  %5s  %s\n", $1, $2 }'
  if [ "$ext_hosts" -gt "$MAX_HOSTS_SHOWN" ]; then
    printf '  ... and %s more host(s)\n' "$((ext_hosts - MAX_HOSTS_SHOWN))"
  fi
fi
printf 'other patterns the server will warn about (occurrence counts, informational):\n'
printf '  network_api:        %s\n' "$n_network"
printf '  navigation:         %s\n' "$n_nav"
printf '  form:               %s\n' "$n_form"
printf '  embedded_frame:     %s\n' "$n_frame"
printf '  storage_or_cookie:  %s\n' "$n_storage"
printf '  dynamic_code:       %s\n' "$n_dyn"

if [ "$ext_total" -gt 0 ]; then
  echo "note: external resources will be blocked by the viewer's CSP (scripts, styles, fonts, images and network calls must be inline) and raise an external_resource warning."
fi
if [ "$has_html_end" = "no" ] && [ "$size" -gt 0 ]; then
  echo "note: no closing </html> tag; the server will add a missing_html_end warning."
fi

rc=0
if [ "${#rejections[@]}" -gt 0 ]; then
  rc=3
  for r in "${rejections[@]}"; do
    echo "FAIL: the ingest Worker would reject this file: $r"
  done
elif [ "$over_limit" = "yes" ]; then
  rc=2
fi
if [ "$over_limit" = "yes" ]; then
  echo "FAIL: file is larger than the limit ($size > $max_bytes bytes)."
fi
if [ "$rc" -eq 0 ]; then
  echo "RESULT: OK"
else
  echo "RESULT: FAIL"
fi
exit "$rc"
