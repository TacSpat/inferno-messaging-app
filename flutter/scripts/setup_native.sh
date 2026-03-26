#!/bin/bash
# Setup native dependencies for Inferno Flutter app.
# Run after cloning: ./scripts/setup_native.sh
#
# Downloads DeepFilterNet model and builds the native library from source.
# Requires: git, cargo (Rust toolchain)
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=== Inferno native setup ==="

# 1. Download DeepFilterNet model
MODEL_DIR="$ROOT/assets/models"
MODEL_FILE="$MODEL_DIR/DeepFilterNet3_onnx.tar.gz"
mkdir -p "$MODEL_DIR"

if [ -f "$MODEL_FILE" ]; then
  echo "[model] Already present: $MODEL_FILE"
else
  echo "[model] Downloading DeepFilterNet3 model..."
  REPO_DIR="$ROOT/native/deepfilter/DeepFilterNet"
  if [ ! -d "$REPO_DIR" ]; then
    git clone --depth 1 https://github.com/Rikorose/DeepFilterNet.git "$REPO_DIR"
  fi
  cp "$REPO_DIR/models/DeepFilterNet3_onnx.tar.gz" "$MODEL_FILE"
  echo "[model] Done: $(du -h "$MODEL_FILE" | cut -f1)"
fi

# 2. Build libdf native library
echo "[libdf] Building DeepFilterNet native library..."
REPO_DIR="$ROOT/native/deepfilter/DeepFilterNet"
if [ ! -d "$REPO_DIR" ]; then
  git clone --depth 1 https://github.com/Rikorose/DeepFilterNet.git "$REPO_DIR"
fi

cd "$REPO_DIR"
cargo build --release --lib --features "capi" -p deep_filter

# Detect platform and copy library
LIBDF_DIR="$ROOT/native/deepfilter"
if [ "$(uname)" = "Darwin" ]; then
  cp target/release/libdf.dylib "$LIBDF_DIR/"
  strip -x "$LIBDF_DIR/libdf.dylib"
  echo "[libdf] Done: $(du -h "$LIBDF_DIR/libdf.dylib" | cut -f1)"
elif [ "$(uname)" = "Linux" ]; then
  cp target/release/libdf.so "$LIBDF_DIR/"
  strip --strip-unneeded "$LIBDF_DIR/libdf.so"
  echo "[libdf] Done: $(du -h "$LIBDF_DIR/libdf.so" | cut -f1)"
else
  # Windows (MSYS2/Git Bash)
  cp target/release/df.dll "$LIBDF_DIR/" 2>/dev/null || true
  echo "[libdf] Done: $(du -h "$LIBDF_DIR/df.dll" | cut -f1)"
fi

echo "=== Setup complete. Run: flutter build linux --release ==="
