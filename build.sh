#!/bin/bash
# Builds "Remote.app" and installs it to /Applications.
#   ./build.sh            build + install + (re)launch
#   ./build.sh --no-install
set -euo pipefail
cd "$(dirname "$0")"
APP="build/Remote.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -target arm64-apple-macosx14.0 \
  -framework AppKit -framework ApplicationServices -framework ScreenCaptureKit -framework Carbon -framework ServiceManagement -framework Speech -framework AVFoundation -framework SwiftUI \
  Sources/*.swift -o "$APP/Contents/MacOS/Remote"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Stable identity so macOS permissions survive rebuilds (ad-hoc resets them).
# Name comes from $SIGN_IDENTITY, else an untracked .signing-identity file, else
# the one tools/make-signing-cert.sh creates.
IDENTITY="${SIGN_IDENTITY:-$(cat .signing-identity 2>/dev/null || echo "Remote Local Signing")}"
if security find-identity -p codesigning | grep -q "$IDENTITY"; then
  codesign --force --sign "$IDENTITY" --identifier dev.readaloud.ReadAloud "$APP"
else
  echo "warning: no \"$IDENTITY\" identity; ad-hoc signing (permissions reset on every rebuild)."
  echo "         Run tools/make-signing-cert.sh once to fix that."
  codesign --force --sign - --identifier dev.readaloud.ReadAloud "$APP"
fi
echo "built $APP"
[[ "${1:-}" == "--no-install" ]] && exit 0
pkill -x Remote 2>/dev/null || true
rm -rf "/Applications/Remote.app"
cp -R "$APP" /Applications/
open "/Applications/Remote.app"
echo "installed and launched /Applications/Remote.app"
