#!/bin/sh
# Build a release binary and wrap it in TravelDisplay.app so macOS treats it as a
# real app (local-network permission prompt, Dock icon, double-click to launch).
set -eu
cd "$(dirname "$0")"
swift build -c release
APP=TravelDisplay.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/TravelDisplay "$APP/Contents/MacOS/TravelDisplay"
cp Info.plist "$APP/Contents/Info.plist"
# Ad-hoc signature so the local-network entitlement dialog attributes to the app.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "built $APP  (open it, or: open $APP --args --help)"
