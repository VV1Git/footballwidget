#!/bin/bash
# Installs the built app to /Applications and relaunches it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/FootballWidget.app"
DEST="/Applications/FootballWidget.app"

[ -d "$APP" ] || { echo "error: build it first with Scripts/build_app.sh" >&2; exit 1; }

echo "==> stopping any running copy"
pkill -x FootballWidget 2>/dev/null || true
sleep 1

echo "==> installing to $DEST"
rm -rf "$DEST"
cp -R "$APP" "$DEST"

echo "==> launching"
open "$DEST"
echo "installed. Enable 'Launch at login' in the widget's Settings if you want it on boot."
