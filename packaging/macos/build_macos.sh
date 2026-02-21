#!/usr/bin/env bash
set -euo pipefail

# Build a macOS .app bundle from the Tebako binary and zip it for distribution.
# Expects: the tebako binary at the path given as $1 (default: ./inferno)

cd "$(dirname "$0")/../.."

TEBAKO_BINARY="${1:-./inferno}"
APP_BUNDLE="Inferno.app"

echo "==> Creating .app bundle structure..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Info.plist
cp packaging/macos/Info.plist "$APP_BUNDLE/Contents/Info.plist"

# Launcher script
cp packaging/macos/inferno-launcher "$APP_BUNDLE/Contents/MacOS/inferno-launcher"
chmod +x "$APP_BUNDLE/Contents/MacOS/inferno-launcher"

# Tebako binary
cp "$TEBAKO_BINARY" "$APP_BUNDLE/Contents/Resources/inferno"
chmod +x "$APP_BUNDLE/Contents/Resources/inferno"

# Icon (optional — use .icns if available)
if [ -f packaging/macos/inferno.icns ]; then
  cp packaging/macos/inferno.icns "$APP_BUNDLE/Contents/Resources/inferno.icns"
fi

# Bundle libsodium
LIBSODIUM=$(find /opt/homebrew/lib /usr/local/lib -name "libsodium.dylib" 2>/dev/null | head -1)
if [ -n "$LIBSODIUM" ]; then
  cp "$LIBSODIUM" "$APP_BUNDLE/Contents/Resources/libsodium.dylib"
else
  echo "WARNING: libsodium.dylib not found — install via: brew install libsodium"
fi

echo "==> Creating zip archive..."
zip -r "Inferno-macos.zip" "$APP_BUNDLE"

echo "==> Done!"
ls -lh "Inferno-macos.zip"
