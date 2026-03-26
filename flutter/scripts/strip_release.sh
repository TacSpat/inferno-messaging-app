#!/bin/bash
# Strip debug symbols from release bundle shared libraries.
# Run after: flutter build linux --release
# Saves ~30MB on Linux builds.
set -e

BUNDLE="${1:-build/linux/x64/release/bundle}"

if [ ! -d "$BUNDLE/lib" ]; then
  echo "Bundle not found at $BUNDLE" >&2
  exit 1
fi

echo "Stripping $BUNDLE/lib/*.so"
for lib in "$BUNDLE"/lib/*.so; do
  before=$(stat -c%s "$lib")
  strip --strip-unneeded "$lib"
  after=$(stat -c%s "$lib")
  saved=$(( (before - after) / 1024 ))
  [ "$saved" -gt 0 ] && printf "  %-40s -%dKB\n" "$(basename "$lib")" "$saved"
done

echo "Done. Bundle size: $(du -sh "$BUNDLE" | cut -f1)"
