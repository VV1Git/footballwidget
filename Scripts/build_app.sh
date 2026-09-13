#!/bin/bash
# Builds FootballWidget.app. No Xcode project needed.
#
#   Scripts/build_app.sh            release build
#   Scripts/build_app.sh debug      debug build
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP="$ROOT/build/FootballWidget.app"
BIN_DIR="$APP/Contents/MacOS"
RES_DIR="$APP/Contents/Resources"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG" --product FootballWidget

BINARY="$(swift build -c "$CONFIG" --product FootballWidget --show-bin-path)/FootballWidget"
[ -f "$BINARY" ] || { echo "error: binary not found at $BINARY" >&2; exit 1; }

echo "==> assembling bundle"
rm -rf "$APP"
mkdir -p "$BIN_DIR" "$RES_DIR"
cp "$BINARY" "$BIN_DIR/FootballWidget"
cp "$ROOT/Sources/FootballWidget/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# The icon macOS shows on notification banners.
if [ -f "$ROOT/Sources/FootballWidget/Resources/AppIcon.icns" ]; then
    cp "$ROOT/Sources/FootballWidget/Resources/AppIcon.icns" "$RES_DIR/AppIcon.icns"
else
    echo "warning: AppIcon.icns missing — run Scripts/make_icon.sh" >&2
fi

# SwiftPM emits resource bundles next to the binary; carry them along.
for b in "$(dirname "$BINARY")"/*.bundle; do
    [ -e "$b" ] && cp -R "$b" "$RES_DIR/" || true
done

echo "==> ad-hoc signing"
# UNUserNotificationCenter refuses to deliver from an unsigned bundle, so sign even
# for local use. Ad-hoc (`-`) is enough; no developer account required.
codesign --force --deep --sign - --timestamp=none "$APP"
codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/    /'

echo
echo "built: $APP"
echo "run:   open '$APP'"
