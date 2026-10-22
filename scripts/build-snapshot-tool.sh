#!/bin/bash
# Builds the development tools:
#   build/native-snapshot  renders Markdown with the native renderer into a PNG
#                          (for checking layout without Finder)
#   build/math-coverage    reports which formulas SwiftMath cannot typeset
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
M="$ROOT/macos"
OUT="$ROOT/build"
mkdir -p "$OUT"
cargo build --quiet --release --lib --manifest-path "$ROOT/core/Cargo.toml"
build_tool() { # module name, tool folder, output name
    swiftc -O -swift-version 5 -module-name "$1" \
        -import-objc-header "$ROOT/core/include/mdql.h" \
        $(find "$M/Vendor/SwiftMath" -name '*.swift') "$M"/Native/*.swift \
        "$M/Shared/Renderer.swift" "$M/Shared/Settings.swift" "$M/Tools/$2/main.swift" \
        -L "$ROOT/core/target/release" -lmdql -framework AppKit \
        -o "$OUT/$3" 2>&1 | grep -v "built for newer 'macOS' version" || true
    test -x "$OUT/$3"
    echo "Built $OUT/$3"
}
build_tool NativeSnapshot NativeSnapshot native-snapshot
build_tool MathCoverage MathCoverage math-coverage
rm -rf "$OUT/mathFonts.bundle"
cp -R "$M/Vendor/SwiftMath/mathFonts.bundle" "$OUT/"
