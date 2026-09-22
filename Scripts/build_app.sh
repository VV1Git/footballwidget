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
ICNS="$ROOT/Sources/FootballWidget/Resources/AppIcon.icns"
if [ -f "$ICNS" ]; then
    cp "$ICNS" "$RES_DIR/AppIcon.icns"

    # macOS 26 looks an app's icon up by CFBundleIconName in a compiled asset catalog
    # before it falls back to the icns, and notification banners came up blank without
    # one. The catalog is built from the icns so there is still one source image.
    if xcrun --find actool >/dev/null 2>&1; then
        echo "==> compiling asset catalog"
        ICON_WORK="$(mktemp -d)"
        SET="$ICON_WORK/Assets.xcassets/AppIcon.appiconset"
        mkdir -p "$SET"
        echo '{"info":{"author":"xcode","version":1}}' > "$ICON_WORK/Assets.xcassets/Contents.json"
        iconutil -c iconset -o "$ICON_WORK/AppIcon.iconset" "$ICNS"
        cp "$ICON_WORK/AppIcon.iconset/"*.png "$SET/"
        {
            printf '{"images":['
            sep=""
            for pt in 16 32 128 256 512; do
                for scale in 1 2; do
                    suffix=""; [ "$scale" = 2 ] && suffix="@2x"
                    printf '%s{"filename":"icon_%sx%s%s.png","idiom":"mac","scale":"%sx","size":"%sx%s"}' \
                        "$sep" "$pt" "$pt" "$suffix" "$scale" "$pt" "$pt"
                    sep=","
                done
            done
            printf '],"info":{"author":"xcode","version":1}}\n'
        } > "$SET/Contents.json"
        xcrun actool "$ICON_WORK/Assets.xcassets" --compile "$RES_DIR" \
            --platform macosx --minimum-deployment-target 26.0 --app-icon AppIcon \
            --output-partial-info-plist "$ICON_WORK/partial.plist" \
            --errors --output-format human-readable-text >/dev/null
        rm -rf "$ICON_WORK"
    else
        echo "warning: actool not found (needs Xcode) — icon ships as icns only" >&2
    fi
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
