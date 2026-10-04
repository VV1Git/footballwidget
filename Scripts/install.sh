#!/bin/bash
# Installs the built app to /Applications and relaunches it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/FootballWidget.app"
DEST="/Applications/FootballWidget.app"

[ -d "$APP" ] || { echo "error: build it first with Scripts/build_app.sh" >&2; exit 1; }

echo "==> stopping any running copy"
pkill -x FootballWidget 2>/dev/null || true
# A copy that finds another already running quits, so the old one must be gone first.
for _ in $(seq 1 50); do
    pgrep -x FootballWidget >/dev/null || break
    sleep 0.1
done

echo "==> installing to $DEST"
rm -rf "$DEST"
# Moved, not copied: a second bundle left in build/ shares this bundle id, so opening it
# (or a login item still pointing at it) runs a second widget beside the installed one,
# each polling ESPN and posting its own notifications.
mv "$APP" "$DEST"

echo "==> launching"
open "$DEST"
echo "installed. Enable 'Launch at login' in the widget's Settings if you want it on boot."
