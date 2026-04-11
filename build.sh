#!/bin/bash
set -euo pipefail

APP_NAME="Smoosh"
BUILD_DIR="build"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
CONTENTS="${APP_BUNDLE}/Contents"
MACOS="${CONTENTS}/MacOS"
RESOURCES="${CONTENTS}/Resources"

HOMEBREW_PREFIX="$(brew --prefix)"
WEBP_INCLUDE="${HOMEBREW_PREFIX}/include"
WEBP_LIB="${HOMEBREW_PREFIX}/lib"

echo "Building ${APP_NAME}..."

# Clean previous build
rm -rf "${BUILD_DIR}"
mkdir -p "${MACOS}" "${RESOURCES}"

# Compile the C muxer
SDK_PATH="$(xcrun --show-sdk-path)"
cc -O2 -c \
    -target arm64-apple-macosx13.0 \
    -isysroot "${SDK_PATH}" \
    -I "${WEBP_INCLUDE}" \
    -o "${BUILD_DIR}/webm_muxer.o" \
    webm_muxer.c

# Compile and link Swift + C objects with libwebp and libvpx statically linked
VPX_INCLUDE="${HOMEBREW_PREFIX}/include"
VPX_LIB="${HOMEBREW_PREFIX}/Cellar/libvpx/1.15.2/lib"

swiftc \
    -O \
    -whole-module-optimization \
    -target arm64-apple-macosx13.0 \
    -sdk "${SDK_PATH}" \
    -framework SwiftUI \
    -framework AppKit \
    -framework CoreGraphics \
    -framework ImageIO \
    -framework AVFoundation \
    -framework CoreMedia \
    -framework CoreVideo \
    -import-objc-header webp-bridge.h \
    -I "${WEBP_INCLUDE}" \
    -I "${VPX_INCLUDE}" \
    -L "${WEBP_LIB}" \
    -L "${VPX_LIB}" \
    "${WEBP_LIB}/libwebp.a" \
    "${WEBP_LIB}/libsharpyuv.a" \
    "${VPX_LIB}/libvpx.a" \
    "${BUILD_DIR}/webm_muxer.o" \
    -parse-as-library \
    -o "${MACOS}/${APP_NAME}" \
    Smoosh.swift

# Copy Info.plist
cp Info.plist "${CONTENTS}/Info.plist"

# Hardened runtime + Developer ID signing
SIGN_IDENTITY="Developer ID Application: Mystic Coders, LLC (REMBT6JY4N)"
TEAM_ID="REMBT6JY4N"

echo "Signing with: ${SIGN_IDENTITY}"
codesign --force --options runtime --sign "${SIGN_IDENTITY}" "${APP_BUNDLE}"

# Create zip for notarization
cd "${BUILD_DIR}"
zip -r "${APP_NAME}.zip" "${APP_NAME}.app"

# Notarize
echo "Submitting for notarization..."
xcrun notarytool submit "${APP_NAME}.zip" \
    --keychain-profile "notarytool-profile" \
    --team-id "${TEAM_ID}" \
    --wait

# Staple the notarization ticket to the app
echo "Stapling notarization ticket..."
xcrun stapler staple "${APP_NAME}.app"

# Re-zip with stapled ticket
rm "${APP_NAME}.zip"
zip -r "${APP_NAME}.zip" "${APP_NAME}.app"
cd ..

echo ""
echo "Done! Signed, notarized, and stapled."
echo "App bundle: ${APP_BUNDLE}"
echo "Shareable zip:    ${BUILD_DIR}/${APP_NAME}.zip"
echo "Size: $(du -sh "${APP_BUNDLE}" | cut -f1)"
