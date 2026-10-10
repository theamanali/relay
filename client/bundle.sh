#!/bin/sh
# Build a release binary and wrap it in Relay.app so macOS treats it as a
# real app (local-network permission prompt, Dock icon, double-click to launch).
set -eu
cd "$(dirname "$0")"
SDK_VERSION=$(xcrun --sdk macosx --show-sdk-version)
# SwiftPM may otherwise stamp its deployment floor as the linked SDK too.
# The floor stays 14; opt into the behavior of the SDK actually used to build.
swift build -c release --arch arm64 -Xlinker -platform_version -Xlinker macos -Xlinker 14.0 -Xlinker "$SDK_VERSION"
BIN_DIR=$(swift build -c release --arch arm64 --show-bin-path)
APP=Relay.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
test "$(lipo -archs "$BIN_DIR/Relay")" = arm64
cp "$BIN_DIR/Relay" "$APP/Contents/MacOS/Relay"
cp Info.plist "$APP/Contents/Info.plist"
# The icon: Assets/AppIcon.icon compiled by Xcode's actool gives the system
# the layers it renders light, dark, clear and tinted from (macOS 26);
# without Xcode, the flattened Relay.icns.
if xcrun --find actool >/dev/null 2>&1 && xcrun actool Assets/AppIcon.icon --compile "$APP/Contents/Resources" \
        --platform macosx --minimum-deployment-target 14.0 --app-icon AppIcon \
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
# Local builds use ad-hoc signing. Releases supply a Developer ID identity and,
# optionally, an existing notarytool keychain profile; no credentials in source.
SIGN_IDENTITY=${RELAY_SIGN_IDENTITY:--}
if [ "$SIGN_IDENTITY" = - ]; then
    codesign --force --sign - "$APP"
else
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
fi
codesign --verify --deep --strict "$APP"
if [ -n "${RELAY_NOTARY_PROFILE:-}" ]; then
    if [ "$SIGN_IDENTITY" = - ]; then
        echo "Notarization requires RELAY_SIGN_IDENTITY (Developer ID)" >&2
        exit 1
    fi
    ditto -c -k --keepParent "$APP" Relay-notarize.zip
    xcrun notarytool submit Relay-notarize.zip --keychain-profile "$RELAY_NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    rm Relay-notarize.zip
fi
echo "built $APP  (open it, or for the flags: $APP/Contents/MacOS/Relay --help)"
