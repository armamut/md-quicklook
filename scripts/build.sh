#!/bin/bash
# Builds "MD QuickLook.app" without Xcode: Rust core + swiftc + manual bundling.
#
#   scripts/build.sh                    universal (arm64 + x86_64), ad-hoc signed
#   ARCHS=arm64 scripts/build.sh        native only, faster
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCHS="${ARCHS:-arm64 x86_64}"
MIN_MACOS="${MIN_MACOS:-12.0}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
BUILD_NUMBER="${BUILD_NUMBER:-$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)}"
OUT="$ROOT/build"
WORK="$OUT/intermediate"
APP="$OUT/MD QuickLook.app"
SDK="$(xcrun --sdk macosx --show-sdk-path)"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

rust_target() { [ "$1" = arm64 ] && echo aarch64-apple-darwin || echo x86_64-apple-darwin; }

rm -rf "$APP" "$WORK"
mkdir -p "$WORK"

# 1. Rust core -------------------------------------------------------------
libs=()
for arch in $ARCHS; do
    target="$(rust_target "$arch")"
    log "Building Rust core ($target)"
    rustup target list --installed 2>/dev/null | grep -qx "$target" || rustup target add "$target"
    MACOSX_DEPLOYMENT_TARGET="$MIN_MACOS" cargo build --quiet --release --lib \
        --manifest-path "$ROOT/core/Cargo.toml" --target "$target"
    libs+=("$ROOT/core/target/$target/release/libmdql.a")
done
mkdir -p "$WORK/lib"
lipo -create "${libs[@]}" -output "$WORK/lib/libmdql.a"

# 2. Swift executables -----------------------------------------------------
# compile NAME [swiftc args…] — builds one universal binary into $WORK/NAME
compile() {
    local name="$1"; shift
    local slices=()
    for arch in $ARCHS; do
        swiftc -O -whole-module-optimization -swift-version 5 \
            -sdk "$SDK" -target "$arch-apple-macos$MIN_MACOS" \
            -module-name "$name" -o "$WORK/$name-$arch" "$@"
        slices+=("$WORK/$name-$arch")
    done
    lipo -create "${slices[@]}" -output "$WORK/$name"
}

M="$ROOT/macos"
log "Compiling preview extension"
compile MDQuickLookPreview -application-extension \
    -import-objc-header "$ROOT/core/include/mdql.h" \
    "$M"/Preview/*.swift "$M"/Native/*.swift "$M/Shared/Renderer.swift" "$M/Shared/Settings.swift" \
    $(find "$M/Vendor/SwiftMath" -name '*.swift') \
    -L "$WORK/lib" -lmdql -framework QuickLookUI -framework WebKit -framework AppKit

log "Compiling thumbnail extension"
compile MDQuickLookThumbnail -application-extension -parse-as-library \
    -import-objc-header "$ROOT/core/include/mdql.h" \
    "$M/Thumbnail/ThumbnailProvider.swift" "$M"/Native/*.swift "$M/Shared/Renderer.swift" "$M/Shared/Settings.swift" \
    $(find "$M/Vendor/SwiftMath" -name '*.swift') \
    -L "$WORK/lib" -lmdql -framework QuickLookThumbnailing -framework AppKit \
    -Xlinker -e -Xlinker _NSExtensionMain

log "Compiling host app"
compile MDQuickLook "$M/App/main.swift" "$M/Shared/Settings.swift" -framework AppKit -framework Quartz

# 3. Bundle ----------------------------------------------------------------
log "Assembling bundle"
plist() { sed -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD__/$BUILD_NUMBER/g" -e "s/__MIN_MACOS__/$MIN_MACOS/g" "$1" > "$2"; }

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/PlugIns"
plist "$M/App/Info.plist" "$APP/Contents/Info.plist"
cp "$WORK/MDQuickLook" "$APP/Contents/MacOS/"
cp "$M/App/AppIcon.icns" "$APP/Contents/Resources/"
printf 'APPL????' > "$APP/Contents/PkgInfo"

for ext in Preview Thumbnail; do
    appex="$APP/Contents/PlugIns/MDQuickLook$ext.appex"
    mkdir -p "$appex/Contents/MacOS" "$appex/Contents/Resources"
    plist "$M/$ext/Info.plist" "$appex/Contents/Info.plist"
    cp "$WORK/MDQuickLook$ext" "$appex/Contents/MacOS/"
done
for ext in Preview Thumbnail; do
    cp -R "$M/Vendor/SwiftMath/mathFonts.bundle" "$APP/Contents/PlugIns/MDQuickLook$ext.appex/Contents/Resources/"
done

# 4. Sign (inside out) -----------------------------------------------------
log "Signing (${SIGN_IDENTITY/#-/ad-hoc})"
sign_flags=(--force --sign "$SIGN_IDENTITY" --options runtime)
[ "$SIGN_IDENTITY" != "-" ] && sign_flags+=(--timestamp)
for ext in Preview Thumbnail; do
    codesign "${sign_flags[@]}" --entitlements "$M/$ext/$ext.entitlements" \
        "$APP/Contents/PlugIns/MDQuickLook$ext.appex"
done
codesign "${sign_flags[@]}" --entitlements "$M/App/App.entitlements" "$APP"
codesign --verify --deep --strict "$APP"

log "Built $APP ($VERSION, $(echo $ARCHS | tr ' ' '+'))"
