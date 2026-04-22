#!/bin/bash
set -euo pipefail

APP_NAME="Smoosh"
BUILD_DIR="build-appstore"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
CONTENTS="${APP_BUNDLE}/Contents"
MACOS="${CONTENTS}/MacOS"
RESOURCES="${CONTENTS}/Resources"

HOMEBREW_PREFIX="$(brew --prefix)"
WEBP_INCLUDE="${HOMEBREW_PREFIX}/include"
WEBP_LIB="${HOMEBREW_PREFIX}/lib"

TEAM_ID="REMBT6JY4N"
APP_SIGN_IDENTITY="3rd Party Mac Developer Application: Mystic Coders, LLC (${TEAM_ID})"
INSTALLER_SIGN_IDENTITY="3rd Party Mac Developer Installer: Mystic Coders, LLC (${TEAM_ID})"

echo "Building ${APP_NAME} for Mac App Store..."

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
VPX_LIB="${HOMEBREW_PREFIX}/opt/libvpx/lib"

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

# Copy Info.plist and app icon
cp Info.plist "${CONTENTS}/Info.plist"
cp AppIcon.icns "${RESOURCES}/AppIcon.icns"

# Copy provisioning profile if it exists
PROVISION_PROFILE="Smoosh_AppStore.provisionprofile"
if [ -f "${PROVISION_PROFILE}" ]; then
    cp "${PROVISION_PROFILE}" "${CONTENTS}/embedded.provisionprofile"
    echo "Embedded provisioning profile"
else
    echo "WARNING: No provisioning profile found at ${PROVISION_PROFILE}"
    echo "  Download one from App Store Connect and save it as ${PROVISION_PROFILE}"
    echo "  Continuing without it (upload will fail without one)..."
fi

# Sign with App Store identity and entitlements
echo "Signing with: ${APP_SIGN_IDENTITY}"
codesign --force --options runtime \
    --entitlements Smoosh.entitlements \
    --sign "${APP_SIGN_IDENTITY}" \
    "${APP_BUNDLE}"

# Verify signing
echo "Verifying signature..."
codesign --verify --deep --strict "${APP_BUNDLE}"

# Build installer package for App Store
PKG_PATH="${BUILD_DIR}/${APP_NAME}.pkg"
echo "Creating installer package..."
productbuild \
    --component "${APP_BUNDLE}" /Applications \
    --sign "${INSTALLER_SIGN_IDENTITY}" \
    "${PKG_PATH}"

echo ""
echo "Done! App Store build complete."
echo "App bundle: ${APP_BUNDLE}"
echo "Installer:  ${PKG_PATH}"
echo "App size:   $(du -sh "${APP_BUNDLE}" | cut -f1)"
echo "Pkg size:   $(du -sh "${PKG_PATH}" | cut -f1)"
echo ""
echo "To upload to App Store Connect:"
echo "  xcrun altool --upload-app -f ${PKG_PATH} -t macos -u YOUR_APPLE_ID -p @keychain:altool-password"
echo "  -- or --"
echo "  Open Transporter.app and drag in ${PKG_PATH}"
