#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CRATE_DIR="$REPO_ROOT/Native/pilot_bridge"
BUILD_DIR="${PILOT_BRIDGE_BUILD_DIR:-$REPO_ROOT/Build/PilotBridge}"
OUTPUT="${1:-$REPO_ROOT/Build/PilotBridge.xcframework}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-17.0}"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
RUST_TOOLCHAIN="${RUST_TOOLCHAIN:-stable}"

if ! command -v rustup >/dev/null 2>&1; then
  echo "error: rustup is required; Homebrew Cargo cannot install Apple target std libraries" >&2
  exit 1
fi

if ! command -v cbindgen >/dev/null 2>&1; then
  echo "error: cbindgen is required (install with: cargo install cbindgen)" >&2
  exit 1
fi

# Homebrew's rustc may precede rustup's proxy in PATH. Cargo otherwise silently
# invokes that compiler, which cannot see rustup's installed iOS standard libraries.
export RUSTC
RUSTC="$(rustup which --toolchain "$RUST_TOOLCHAIN" rustc)"

TARGETS=(
  aarch64-apple-ios
  aarch64-apple-ios-sim
  aarch64-apple-darwin
)

for target in "${TARGETS[@]}"; do
  if ! rustup target list --toolchain "$RUST_TOOLCHAIN" --installed | rg -qx "$target"; then
    echo "error: Rust target $target is not installed (run: rustup target add --toolchain $RUST_TOOLCHAIN $target)" >&2
    exit 1
  fi
done

mkdir -p "$BUILD_DIR/include" "$(dirname "$OUTPUT")"
cbindgen \
  --verify \
  --config "$CRATE_DIR/cbindgen.toml" \
  --crate pilot_bridge \
  --output "$CRATE_DIR/include/pilot_bridge.h" \
  "$CRATE_DIR"
cp "$CRATE_DIR/include/pilot_bridge.h" "$BUILD_DIR/include/pilot_bridge.h"
cp "$CRATE_DIR/include/module.modulemap" "$BUILD_DIR/include/module.modulemap"

for target in "${TARGETS[@]}"; do
  rustup run "$RUST_TOOLCHAIN" cargo build \
    --manifest-path "$CRATE_DIR/Cargo.toml" \
    --release \
    --locked \
    --target "$target"
done

rm -rf "$OUTPUT"
xcodebuild -create-xcframework \
  -library "$CRATE_DIR/target/aarch64-apple-ios/release/libpilot_bridge.a" \
  -headers "$BUILD_DIR/include" \
  -library "$CRATE_DIR/target/aarch64-apple-ios-sim/release/libpilot_bridge.a" \
  -headers "$BUILD_DIR/include" \
  -library "$CRATE_DIR/target/aarch64-apple-darwin/release/libpilot_bridge.a" \
  -headers "$BUILD_DIR/include" \
  -output "$OUTPUT"

echo "Built $OUTPUT"
