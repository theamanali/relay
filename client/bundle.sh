#!/bin/sh
# Build a release binary and wrap it in Relay.app so macOS treats it as a
# real app (local-network permission prompt, Dock icon, double-click to launch).
set -eu
cd "$(dirname "$0")"
swift build -c release
APP=Relay.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Relay "$APP/Contents/MacOS/Relay"
cp Info.plist "$APP/Contents/Info.plist"
# The icon: Assets/AppIcon.icon compiled by Xcode's actool gives the system
# the layers it renders light, dark, clear and tinted from (macOS 26);
# without Xcode, the flattened Relay.icns.
if xcrun --find actool >/dev/null 2>&1 && xcrun actool Assets/AppIcon.icon --compile "$APP/Contents/Resources" \
        --platform macosx --minimum-deployment-target 13.0 --app-icon AppIcon \
        --output-partial-info-plist "$APP/icon.plist" >/dev/null 2>&1 \
        && [ -f "$APP/Contents/Resources/Assets.car" ]; then
    plutil -replace CFBundleIconFile -string AppIcon "$APP/Contents/Info.plist"
    plutil -replace CFBundleIconName -string AppIcon "$APP/Contents/Info.plist"
    rm -f "$APP/icon.plist"
else
    cp Assets/Relay.icns "$APP/Contents/Resources/Relay.icns"
fi
# The About panel's build number: commits on this branch, so a report can
# name the exact build. The marketing version stays what Info.plist says.
if BUILD=$(git rev-list --count HEAD 2>/dev/null); then
    plutil -replace CFBundleVersion -string "$BUILD" "$APP/Contents/Info.plist"
fi
# Ad-hoc signature so the local-network entitlement dialog attributes to the app.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "built $APP  (open it, or: open $APP --args --help)"
