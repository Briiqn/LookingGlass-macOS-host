#!/bin/bash
# Builds Looking Glass macOS Host and packages it into release-ready installable artifacts:
#   - LookingGlassHost.dmg           (Drag-and-drop / Easy Install DMG)
#   - LookingGlassHost-Installer.pkg (Standard macOS installer package)
#   - LookingGlassHost.zip           (Zipped .app bundle preserving permissions)
#
# Usage:
#   build-release.sh [output-dir]
set -e

PKG_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_DIR=$(cd "$PKG_DIR/../../../.." && pwd)
BUILD_DIR="$REPO_DIR/build-macos"
OUTPUT_DIR="${1:-$HOME/Desktop/LookingGlassHost-Release}"
CERT="LGMac Local Code Signing"
APP_NAME="LookingGlassHost.app"
LABEL="local.lgmac.LookingGlassHost"

echo "==> Building looking-glass-host binary..."
if [ ! -f "$BUILD_DIR/CMakeCache.txt" ]; then
  cmake -S "$REPO_DIR/host" -B "$BUILD_DIR" -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DENABLE_BACKTRACE=OFF -DOPTIMIZE_FOR_NATIVE=OFF
fi
cmake --build "$BUILD_DIR" -j "$(sysctl -n hw.ncpu)"

echo "==> Assembling $APP_NAME bundle..."
APP_BUNDLE="$BUILD_DIR/$APP_NAME"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

cp "$PKG_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$BUILD_DIR/looking-glass-host" "$APP_BUNDLE/Contents/MacOS/"
if [ -f "$PKG_DIR/AppIcon.icns" ]; then
  cp "$PKG_DIR/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/"
fi

# Codesign the application bundle
IDENTITY=$(security find-certificate -c "$CERT" -Z 2>/dev/null | awk '/SHA-1/ { print $3 }')
if [ -n "$IDENTITY" ]; then
  echo "==> Signing with $CERT ($IDENTITY)..."
  codesign --force --sign "$IDENTITY" "$APP_BUNDLE"
else
  echo "==> Signing ad-hoc..."
  codesign --force --sign - "$APP_BUNDLE"
fi
codesign --verify "$APP_BUNDLE"

mkdir -p "$OUTPUT_DIR"

# ----------------------------------------------------
# 1. Create DMG
# ----------------------------------------------------
echo "==> Creating DMG installer..."
DMG_STAGING="$BUILD_DIR/dmg-staging"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"

# Copy App bundle
cp -R "$APP_BUNDLE" "$DMG_STAGING/"

# Add Applications symlink for drag-and-drop
ln -s /Applications "$DMG_STAGING/Applications"

# Add Easy Install command
cat << 'EOF' > "$DMG_STAGING/Easy Install.command"
#!/bin/bash
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
APP_SRC="$DIR/LookingGlassHost.app"
TARGET_APP="/Applications/LookingGlassHost.app"
LABEL="local.lgmac.LookingGlassHost"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"

echo "=========================================="
echo "   Looking Glass Host - Easy Installer   "
echo "=========================================="
echo ""

echo "[1/4] Installing LookingGlassHost.app into /Applications..."
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -rf "$TARGET_APP"
cp -R "$APP_SRC" "$TARGET_APP"
codesign --force --sign - "$TARGET_APP" 2>/dev/null || true

echo "[2/4] Registering auto-start LaunchAgent..."
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
cat <<PLIST > "$AGENT"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>local.lgmac.LookingGlassHost</string>
	<key>ProgramArguments</key>
	<array>
		<string>/Applications/LookingGlassHost.app/Contents/MacOS/looking-glass-host</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>ThrottleInterval</key>
	<integer>5</integer>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>StandardOutPath</key>
	<string>@HOME@/Library/Logs/LookingGlassHost.log</string>
	<key>StandardErrorPath</key>
	<string>@HOME@/Library/Logs/LookingGlassHost.log</string>
</dict>
</plist>
PLIST
sed -i '' "s|@HOME@|$HOME|g" "$AGENT"

echo "[3/4] Starting Looking Glass Host service..."
launchctl bootstrap "gui/$(id -u)" "$AGENT"

echo "[4/4] Opening Privacy & Security settings..."
echo ""
echo "------------------------------------------------------------"
echo "IMPORTANT: Please grant permissions to 'Looking Glass Host':"
echo "  1. Screen Recording (to capture your display)"
echo "  2. Accessibility (to inject mouse/keyboard events)"
echo "------------------------------------------------------------"
open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture" 2>/dev/null || true
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" 2>/dev/null || true

echo ""
echo "Installation complete! Looking Glass Host is now active."
echo "Log file: $HOME/Library/Logs/LookingGlassHost.log"
echo ""
read -p "Press [Enter] to exit..."
EOF
chmod +x "$DMG_STAGING/Easy Install.command"

# Add Uninstall command
cat << 'EOF' > "$DMG_STAGING/Uninstall.command"
#!/bin/bash
set -e
LABEL="local.lgmac.LookingGlassHost"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"

echo "Stopping Looking Glass Host service..."
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$AGENT"
echo "Removing /Applications/LookingGlassHost.app..."
rm -rf /Applications/LookingGlassHost.app
echo ""
echo "Looking Glass Host has been successfully uninstalled."
read -p "Press [Enter] to exit..."
EOF
chmod +x "$DMG_STAGING/Uninstall.command"

# Add README.txt
cat << 'EOF' > "$DMG_STAGING/README.txt"
Looking Glass Host for macOS
-----------------------------

How to install:
  Option 1 (Recommended): Double-click "Easy Install.command"
    - Copies LookingGlassHost.app to /Applications
    - Configures and starts the background service automatically
    - Guides you to grant Screen Recording and Accessibility permissions

  Option 2 (Manual):
    - Drag LookingGlassHost.app into the Applications folder
    - Run: open /Applications/LookingGlassHost.app

Permissions:
  System Settings > Privacy & Security:
  - Screen & System Audio Recording -> Enable "Looking Glass Host"
  - Accessibility -> Enable "Looking Glass Host"

To uninstall:
  Double-click "Uninstall.command"
EOF

DMG_OUT="$OUTPUT_DIR/LookingGlassHost.dmg"
rm -f "$DMG_OUT"
hdiutil create -volname "Looking Glass Host" -srcfolder "$DMG_STAGING" -ov -format UDZO "$DMG_OUT"
rm -rf "$DMG_STAGING"

# ----------------------------------------------------
# 2. Create PKG Installer
# ----------------------------------------------------
echo "==> Creating PKG installer..."
PKG_ROOT="$BUILD_DIR/pkg-root"
PKG_SCRIPTS="$BUILD_DIR/pkg-scripts"
rm -rf "$PKG_ROOT" "$PKG_SCRIPTS"
mkdir -p "$PKG_ROOT/Applications" "$PKG_SCRIPTS"

cp -R "$APP_BUNDLE" "$PKG_ROOT/Applications/"

cat << 'EOF' > "$PKG_SCRIPTS/postinstall"
#!/bin/bash
CONSOLE_USER=$(stat -f "%Su" /dev/console 2>/dev/null || echo "$USER")
USER_HOME=$(eval echo "~$CONSOLE_USER")
USER_ID=$(id -u "$CONSOLE_USER" 2>/dev/null || echo "501")
LABEL="local.lgmac.LookingGlassHost"
AGENT="$USER_HOME/Library/LaunchAgents/$LABEL.plist"

mkdir -p "$USER_HOME/Library/LaunchAgents" "$USER_HOME/Library/Logs"
cat <<PLIST > "$AGENT"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>local.lgmac.LookingGlassHost</string>
	<key>ProgramArguments</key>
	<array>
		<string>/Applications/LookingGlassHost.app/Contents/MacOS/looking-glass-host</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>ThrottleInterval</key>
	<integer>5</integer>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>StandardOutPath</key>
	<string>$USER_HOME/Library/Logs/LookingGlassHost.log</string>
	<key>StandardErrorPath</key>
	<string>$USER_HOME/Library/Logs/LookingGlassHost.log</string>
</dict>
</plist>
PLIST
chown "$CONSOLE_USER" "$AGENT"

# Launch service for the active console user
launchctl bootout "gui/$USER_ID/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$USER_ID" "$AGENT" 2>/dev/null || true
exit 0
EOF
chmod +x "$PKG_SCRIPTS/postinstall"

PKG_OUT="$OUTPUT_DIR/LookingGlassHost-Installer.pkg"
rm -f "$PKG_OUT"
pkgbuild --root "$PKG_ROOT" \
         --scripts "$PKG_SCRIPTS" \
         --identifier local.lgmac.LookingGlassHost \
         --version "1.0" \
         --install-location "/" \
         "$PKG_OUT"
rm -rf "$PKG_ROOT" "$PKG_SCRIPTS"

# ----------------------------------------------------
# 3. Create ZIP Archive
# ----------------------------------------------------
echo "==> Creating ZIP archive..."
ZIP_OUT="$OUTPUT_DIR/LookingGlassHost.zip"
rm -f "$ZIP_OUT"
ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_OUT"

echo ""
echo "=========================================="
echo "Build complete! Artifacts created in:"
echo "  $OUTPUT_DIR"
echo "Files:"
ls -lh "$OUTPUT_DIR"
echo "=========================================="
