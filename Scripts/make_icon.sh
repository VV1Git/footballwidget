#!/bin/bash
# Regenerates Sources/FootballWidget/Resources/AppIcon.icns.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

swift "$ROOT/Scripts/make_icon.swift" "$WORK/AppIcon.iconset"
iconutil -c icns "$WORK/AppIcon.iconset" -o "$ROOT/Sources/FootballWidget/Resources/AppIcon.icns"
echo "wrote Sources/FootballWidget/Resources/AppIcon.icns"
