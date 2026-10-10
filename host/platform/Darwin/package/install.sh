#!/bin/bash
# Builds the macOS Looking Glass host and installs it as
# ~/Applications/LookingGlassHost.app with a login item that keeps it running.
#
#   install.sh [build-dir]     (default: <repo>/build-macos)
#
# The app is signed with the "LGMac Local Code Signing" certificate when it
# exists (see create-signing-cert.sh), so the Screen Recording and
# Accessibility permissions survive rebuilds. Otherwise it is signed ad-hoc and
# macOS asks for the permissions again after every rebuild.
set -e

PKG=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$PKG/../../../.." && pwd)
BUILD=${1:-$REPO/build-macos}
APP=$HOME/Applications/LookingGlassHost.app
LABEL=local.lgmac.LookingGlassHost
AGENT=$HOME/Library/LaunchAgents/$LABEL.plist
CERT="LGMac Local Code Signing"

if [ ! -f "$BUILD/CMakeCache.txt" ]; then
  cmake -S "$REPO/host" -B "$BUILD" -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DENABLE_BACKTRACE=OFF -DOPTIMIZE_FOR_NATIVE=OFF
fi
cmake --build "$BUILD" -j "$(sysctl -n hw.ncpu)"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PKG/Info.plist" "$APP/Contents/Info.plist"
cp "$BUILD/looking-glass-host" "$APP/Contents/MacOS/"
if [ -f "$PKG/AppIcon.icns" ]; then
  cp "$PKG/AppIcon.icns" "$APP/Contents/Resources/"
fi

IDENTITY=$(security find-certificate -c "$CERT" -Z 2>/dev/null |
  awk '/SHA-1/ { print $3 }')
if [ -n "$IDENTITY" ]; then
  codesign --force --sign "$IDENTITY" "$APP"
else
  echo "warning: no \"$CERT\" certificate, signing ad-hoc" >&2
  codesign --force --sign - "$APP"
fi
codesign --verify "$APP"

mkdir -p "$(dirname "$AGENT")" "$HOME/Library/Logs"
sed "s|@HOME@|$HOME|g" "$PKG/$LABEL.plist" > "$AGENT"
launchctl bootstrap "gui/$(id -u)" "$AGENT"

echo "installed $APP, log: $HOME/Library/Logs/LookingGlassHost.log"
