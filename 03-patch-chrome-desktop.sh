#!/usr/bin/env bash
set -euo pipefail

SRC="/usr/share/applications/google-chrome.desktop"
DST="$HOME/.local/share/applications/google-chrome.desktop"
FEATURE="--enable-features=WebRtcPipeWireCamera"

if [[ ! -f "$SRC" ]]; then
  echo "Cannot find $SRC" >&2
  exit 1
fi

mkdir -p "$(dirname "$DST")"
install -m 0644 "$SRC" "$DST"

sed -i -E "s/[[:space:]]+$FEATURE//g" "$DST"
sed -i -E 's#^Exec=/usr/bin/google-chrome-stable(.*)$#Exec=/usr/bin/google-chrome-stable '"$FEATURE"'\1#' "$DST"

if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$HOME/.local/share/applications" || true
fi

echo "Patched $DST"
grep '^Exec=' "$DST"
echo
echo "Chrome will use PipeWire for WebRTC camera access."
echo "Fully quit Chrome and start it again from the app launcher."
