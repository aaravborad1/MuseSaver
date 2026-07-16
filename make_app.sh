#!/bin/bash
# Builds MuseSaver and packages it into a proper MuseSaver.app bundle so it can be
# launched into the GUI session (menu bar apps must run as bundled apps).
set -e
cd "$(dirname "$0")"

CONFIG="${1:-release}"

echo "Building ($CONFIG)…"
swift build -c "$CONFIG"

BIN="$(swift build -c "$CONFIG" --show-bin-path)/MuseSaver"
APP="MuseSaver.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/MuseSaver"
cp AppSupport/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc code signature so macOS will run and keychain access is stable.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "Built $APP"
echo "Launch it with:  open $APP"
