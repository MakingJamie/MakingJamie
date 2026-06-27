#!/usr/bin/env bash
#
# build-releases.sh — refresh the "Latest from StillMind" block in README.md.
#
# Pulls the live iOS version/date from Apple's public iTunes Lookup API (reliable,
# no auth, no dependency beyond curl + jq) and best-effort scrapes the Android
# version from the Google Play listing (no official API — fails gracefully to a
# plain store badge). Rewrites ONLY the content between the STILLMIND-RELEASES
# markers, leaving the rest of the file byte-identical. Idempotent: identical
# output means no diff, so the workflow makes no commit and cannot loop.
#
# Security: the only inputs are the static, author-controlled store IDs below.
# The HTTP responses are untrusted — they are parsed for a version string / a
# known store URL via strict regex and never executed or eval'd.
#
# Usage: scripts/build-releases.sh [path-to-README]   (defaults to ./README.md)

set -uo pipefail

README="${1:-README.md}"
START='<!-- STILLMIND-RELEASES:START -->'
END='<!-- STILLMIND-RELEASES:END -->'

IOS_ID="6749165508"
AND_PKG="com.prioritised.stillmindjournal"
IOS_STORE="https://apps.apple.com/app/id${IOS_ID}"
AND_STORE="https://play.google.com/store/apps/details?id=${AND_PKG}"
UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"

VER_RE='^[0-9]+(\.[0-9]+){1,3}$'   # accept 1.3, 1.3.0, 1.2.9.1 etc.

# Format an ISO-8601 timestamp as "16 Jun 2026" on both GNU (CI) and BSD (local) date.
fmt_date() {
  local raw="$1" out=""
  out=$(date -u -d "$raw" "+%-d %b %Y" 2>/dev/null) || out=""
  if [ -z "$out" ]; then
    out=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$raw" "+%e %b %Y" 2>/dev/null) || out=""
    out=$(printf '%s' "$out" | tr -s ' ' | sed 's/^ //')
  fi
  [ -z "$out" ] && out="$raw"
  printf '%s' "$out"
}

# --- iOS (Apple iTunes Lookup API) -------------------------------------------
ios_json=$(curl -fsS --max-time 20 "https://itunes.apple.com/lookup?id=${IOS_ID}" 2>/dev/null || true)
ios_ver=$(printf '%s' "$ios_json"  | jq -r '.results[0].version // empty' 2>/dev/null || true)
ios_date=$(printf '%s' "$ios_json" | jq -r '.results[0].currentVersionReleaseDate // empty' 2>/dev/null || true)
ios_url=$(printf '%s'  "$ios_json" | jq -r '.results[0].trackViewUrl // empty' 2>/dev/null || true)

# Validate before trusting any of it.
[[ "$ios_ver" =~ $VER_RE ]] || ios_ver=""
case "$ios_url" in https://apps.apple.com/*) : ;; *) ios_url="$IOS_STORE" ;; esac
if [ -n "$ios_date" ]; then ios_date=$(fmt_date "$ios_date"); else ios_date="—"; fi

if [ -n "$ios_ver" ]; then
  ios_line="| 📱 **iOS** | \`v${ios_ver}\` | ${ios_date} | [App Store ↗](${ios_url}) |"
else
  ios_line="| 📱 **iOS** | — | — | [App Store ↗](${IOS_STORE}) |"
fi

# --- Android (best-effort Play Store scrape) ---------------------------------
and_html=$(curl -fsS --max-time 20 -A "$UA" "${AND_STORE}&hl=en" 2>/dev/null || true)
and_ver=$(printf '%s' "$and_html" \
  | grep -oE '\[\[\["[0-9]+(\.[0-9]+){1,3}"' \
  | head -1 \
  | grep -oE '[0-9]+(\.[0-9]+){1,3}' \
  | head -1 || true)
[[ "$and_ver" =~ $VER_RE ]] || and_ver=""

if [ -n "$and_ver" ]; then
  and_line="| 🤖 **Android** | \`v${and_ver}\` | — | [Google Play ↗](${AND_STORE}) |"
else
  and_line="| 🤖 **Android** | — | — | [Google Play ↗](${AND_STORE}) |"
fi

# --- Render the block --------------------------------------------------------
block=$(cat <<EOF

| Platform | Version | Released | Get it |
| --- | --- | --- | --- |
${ios_line}
${and_line}

<sub>iOS version &amp; date update automatically from the App Store; Android is best-effort and may lag.</sub>
EOF
)

# --- Splice between the markers (index match, no regex on the marker text) ----
tmp_block=$(mktemp)
printf '%s\n' "$block" > "$tmp_block"
tmp_out=$(mktemp)

awk -v s="$START" -v e="$END" -v f="$tmp_block" '
  index($0, s) { print; while ((getline line < f) > 0) print line; close(f); skip=1; next }
  index($0, e) { skip=0 }
  !skip        { print }
' "$README" > "$tmp_out"

if ! grep -qF "$START" "$tmp_out" || ! grep -qF "$END" "$tmp_out"; then
  echo "error: STILLMIND-RELEASES markers not found in $README — aborting, file unchanged." >&2
  rm -f "$tmp_block" "$tmp_out"
  exit 1
fi

mv "$tmp_out" "$README"
rm -f "$tmp_block"
echo "build-releases: iOS='${ios_ver:-none}' Android='${and_ver:-none}' → $README"
