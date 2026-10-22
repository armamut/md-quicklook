#!/bin/bash
# Builds build/native-snapshot, which renders Markdown with the native
# renderer into a PNG (for checking layout without Finder).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
M="$ROOT/macos"
OUT="$ROOT/build"
mkdir -p "$OUT"
cargo build --quiet --release --lib --manifest-path "$ROOT/core/Cargo.toml"
swiftc -O -swift-version 5 -module-name NativeSnapshot \
    -import-objc-header "$ROOT/core/include/mdql.h" \
    $(find "$M/Vendor/SwiftMath" -name '*.swift') "$M"/Native/*.swift \
    "$M/Shared/Renderer.swift" "$M/Shared/Settings.swift" "$M/Tools/NativeSnapshot/main.swift" \
    -L "$ROOT/core/target/release" -lmdql -framework AppKit \
    -o "$OUT/native-snapshot"
rm -rf "$OUT/mathFonts.bundle"
cp -R "$M/Vendor/SwiftMath/mathFonts.bundle" "$OUT/"
echo "Built $OUT/native-snapshot"
