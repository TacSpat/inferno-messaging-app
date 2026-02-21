#!/usr/bin/env bash
set -euo pipefail

# Build a self-contained Tebako binary packaging the entire Rails app + Ruby runtime.
# Prerequisites: tebako CLI installed, assets pre-compiled via build_assets.sh.

cd "$(dirname "$0")/.."

RUBY_VERSION="3.4.2"
OUTPUT_NAME="${1:-inferno}"

echo "==> Cleaning dev/test artifacts..."
rm -rf tmp/cache tmp/pids log/*.log node_modules .git

echo "==> Building Tebako package (Ruby ${RUBY_VERSION})..."
tebako press \
  --root=. \
  --entry-point=bin/rails \
  --output="${OUTPUT_NAME}" \
  --Ruby="${RUBY_VERSION}"

echo "==> Built: ${OUTPUT_NAME}"
ls -lh "${OUTPUT_NAME}"
