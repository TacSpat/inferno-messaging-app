#!/usr/bin/env bash
set -euo pipefail

# Pre-compile JS/CSS assets for production packaging.
# Run this BEFORE tebako_build.sh so assets are baked into the binary.

cd "$(dirname "$0")/.."

echo "==> Installing JS dependencies..."
bun install --frozen-lockfile

echo "==> Precompiling assets..."
RAILS_ENV=production SECRET_KEY_BASE=placeholder bundle exec rails assets:precompile

echo "==> Assets ready in public/assets/"
