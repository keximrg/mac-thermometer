#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK="${THERMOMETER_SDK:-$(xcrun --sdk macosx --show-sdk-path)}"
BUILD_ROOT="$ROOT/.build"
DIST_ROOT="$ROOT/dist"
APP="$DIST_ROOT/Thermometer.app"
ICON_SOURCE="$ROOT/Resources/AppIcon.png"
DEPLOYMENT_TARGET="13.0"

rm -rf "$BUILD_ROOT" "$APP"
mkdir -p "$BUILD_ROOT" "$DIST_ROOT" "$APP/Contents/MacOS" "$APP/Contents/Resources"

SOURCES=("$ROOT"/Sources/Thermometer/*.swift)
ARCHS=(arm64 x86_64)

for ARCH in "${ARCHS[@]}"; do
    ARCH_ROOT="$BUILD_ROOT/$ARCH"
    mkdir -p "$ARCH_ROOT/ModuleCache"
    CLANG_MODULE_CACHE_PATH="$ARCH_ROOT/ModuleCache" xcrun swiftc \
        -O \
        -whole-module-optimization \
        -module-name Thermometer \
        -module-cache-path "$ARCH_ROOT/ModuleCache" \
        -sdk "$SDK" \
        -target "$ARCH-apple-macosx$DEPLOYMENT_TARGET" \
        -framework AppKit \
        -framework SwiftUI \
        -framework IOKit \
        -framework ServiceManagement \
        -framework UniformTypeIdentifiers \
        "${SOURCES[@]}" \
        -o "$ARCH_ROOT/Thermometer"
done

lipo -create \
    "$BUILD_ROOT/arm64/Thermometer" \
    "$BUILD_ROOT/x86_64/Thermometer" \
    -output "$APP/Contents/MacOS/Thermometer"

cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

if [ -f "$ICON_SOURCE" ]; then
    ICON_ROOT="$BUILD_ROOT/AppIcon"
    mkdir -p "$ICON_ROOT"
    TIFFS=()
    for SIZE in 16 32 48 128 256 512 1024; do
        TIFF="$ICON_ROOT/icon-$SIZE.tiff"
        sips -z "$SIZE" "$SIZE" -s format tiff "$ICON_SOURCE" --out "$TIFF" >/dev/null
        TIFFS+=("$TIFF")
    done
    tiffutil -cat "${TIFFS[@]}" -out "$ICON_ROOT/AppIcon.tiff" >/dev/null
    tiff2icns "$ICON_ROOT/AppIcon.tiff" "$APP/Contents/Resources/AppIcon.icns"
fi

codesign --force --deep --sign - --timestamp=none "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

rm -rf "$BUILD_ROOT"

echo "$APP"
lipo -archs "$APP/Contents/MacOS/Thermometer"
