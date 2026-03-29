#!/bin/bash
# Build libsignal_ffi.a for iOS device and simulator.
# Run from the repo root: ./App/build_ffi_ios.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT/vendored/libsignal"

echo "=== Building for iOS device (aarch64-apple-ios) ==="
RUSTUP_TOOLCHAIN=stable CARGO_BUILD_TARGET=aarch64-apple-ios ./swift/build_ffi.sh -r

echo ""
echo "=== Building for iOS simulator (aarch64-apple-ios-sim) ==="
RUSTUP_TOOLCHAIN=stable \
  CARGO_BUILD_TARGET=aarch64-apple-ios-sim \
  BINDGEN_EXTRA_CLANG_ARGS="--target=arm64-apple-ios16.0-simulator" \
  ./swift/build_ffi.sh -r

echo ""
echo "=== Done ==="
echo "Device:    target/aarch64-apple-ios/release/libsignal_ffi.a"
echo "Simulator: target/aarch64-apple-ios-sim/release/libsignal_ffi.a"
