#!/usr/bin/env bash
set -euo pipefail

# Build an AppImage from the Tebako binary.
# Expects: packaging/linux/ to contain AppRun, inferno.desktop, inferno.png
# Expects: the tebako binary at the path given as $1 (default: ./inferno)

cd "$(dirname "$0")/../.."

TEBAKO_BINARY="${1:-./inferno}"
APPDIR="Inferno.AppDir"

echo "==> Creating AppDir structure..."
rm -rf "$APPDIR"
mkdir -p "$APPDIR/usr/bin" "$APPDIR/usr/lib"

# Launcher
cp packaging/linux/AppRun "$APPDIR/AppRun"
chmod +x "$APPDIR/AppRun"

# Desktop entry and icon
cp packaging/linux/inferno.desktop "$APPDIR/inferno.desktop"
if [ -f packaging/linux/inferno.png ]; then
  cp packaging/linux/inferno.png "$APPDIR/inferno.png"
else
  echo "WARNING: packaging/linux/inferno.png not found — using placeholder"
  # Generate a 256x256 placeholder icon
  convert -size 256x256 xc:"#FF4500" -gravity center \
    -font DejaVu-Sans-Bold -pointsize 120 -fill white \
    -annotate 0 "I" "$APPDIR/inferno.png" 2>/dev/null || \
    touch "$APPDIR/inferno.png"
fi

# Tebako binary
cp "$TEBAKO_BINARY" "$APPDIR/usr/bin/inferno"
chmod +x "$APPDIR/usr/bin/inferno"

# Bundle libsodium
LIBSODIUM=$(ldconfig -p 2>/dev/null | grep 'libsodium.so.23' | head -1 | awk '{print $NF}')
if [ -n "$LIBSODIUM" ]; then
  cp "$LIBSODIUM" "$APPDIR/usr/lib/libsodium.so.23"
  # Patch AppRun to set LD_LIBRARY_PATH
  sed -i '2i export LD_LIBRARY_PATH="$APPDIR/usr/lib:${LD_LIBRARY_PATH:-}"' "$APPDIR/AppRun"
else
  echo "WARNING: libsodium.so.23 not found on system — you must bundle it manually"
fi

# Download appimagetool if not present
if ! command -v appimagetool &> /dev/null; then
  echo "==> Downloading appimagetool..."
  ARCH=$(uname -m)
  curl -fsSL -o /tmp/appimagetool "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-${ARCH}.AppImage"
  chmod +x /tmp/appimagetool
  APPIMAGETOOL=/tmp/appimagetool
else
  APPIMAGETOOL=appimagetool
fi

echo "==> Building AppImage..."
ARCH=$(uname -m) "$APPIMAGETOOL" "$APPDIR" "Inferno-${ARCH}.AppImage"

echo "==> Done!"
ls -lh "Inferno-$(uname -m).AppImage"
