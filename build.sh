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

# Hardened runtime + Developer ID signing
SIGN_IDENTITY="Developer ID Application: Mystic Coders, LLC (REMBT6JY4N)"
TEAM_ID="REMBT6JY4N"

echo "Signing with: ${SIGN_IDENTITY}"
codesign --force --options runtime --sign "${SIGN_IDENTITY}" "${APP_BUNDLE}"

# Create zip for notarization submission
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
rm "${APP_NAME}.zip"
cd ..

# Create DMG
DMG_NAME="${APP_NAME}"
DMG_PATH="${BUILD_DIR}/${DMG_NAME}.dmg"
DMG_TEMP="${BUILD_DIR}/dmg-staging"

echo "Creating DMG..."
rm -rf "${DMG_TEMP}" "${DMG_PATH}"
mkdir -p "${DMG_TEMP}"
cp -R "${APP_BUNDLE}" "${DMG_TEMP}/"
ln -s /Applications "${DMG_TEMP}/Applications"

# Create a read-write DMG first for customization
DMG_RW="${BUILD_DIR}/${DMG_NAME}-rw.dmg"
hdiutil create -volname "${APP_NAME}" \
    -srcfolder "${DMG_TEMP}" \
    -ov -format UDRW \
    -fs HFS+ \
    "${DMG_RW}"

# Detach any stale mounts from previous runs so the new attach gets /Volumes/${APP_NAME}
# (otherwise macOS renames the mount to "Smoosh 1", "Smoosh 2", ... and AppleScript can't find it)
for stale in /Volumes/"${APP_NAME}"*; do
    [ -d "${stale}" ] && hdiutil detach "${stale}" -force >/dev/null 2>&1 || true
done

# Mount the read-write DMG
MOUNT_DIR=$(hdiutil attach "${DMG_RW}" -readwrite -noverify -noautoopen \
    | awk -F '\t' '/\/Volumes\// { print $NF; exit }')
if [ -z "${MOUNT_DIR}" ] || [ ! -d "${MOUNT_DIR}" ]; then
    echo "Failed to mount ${DMG_RW}" >&2
    exit 1
fi
if ! touch "${MOUNT_DIR}/.rwcheck" 2>/dev/null; then
    echo "Mount ${MOUNT_DIR} is read-only — aborting" >&2
    hdiutil detach "${MOUNT_DIR}" -force >/dev/null 2>&1 || true
    exit 1
fi
rm "${MOUNT_DIR}/.rwcheck"
echo "Mounted DMG at: ${MOUNT_DIR}"

# Copy background image
mkdir -p "${MOUNT_DIR}/.background"
cp dmg-background.png "${MOUNT_DIR}/.background/background.png"

# Configure Finder window layout via AppleScript
osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "${APP_NAME}"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {100, 100, 760, 500}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 96
        set background picture of viewOptions to file ".background:background.png"
        set position of item "${APP_NAME}.app" of container window to {165, 200}
        set position of item "Applications" of container window to {495, 200}
        close
        open
        update without registering applications
        delay 2
        close
    end tell
end tell
APPLESCRIPT

# Unmount, convert to compressed read-only
hdiutil detach "${MOUNT_DIR}" -quiet
hdiutil convert "${DMG_RW}" -format UDZO -imagekey zlib-level=9 -o "${DMG_PATH}"
rm -f "${DMG_RW}"
rm -rf "${DMG_TEMP}"

# Notarize the DMG
echo "Notarizing DMG..."
xcrun notarytool submit "${DMG_PATH}" \
    --keychain-profile "notarytool-profile" \
    --team-id "${TEAM_ID}" \
    --wait

xcrun stapler staple "${DMG_PATH}"

echo ""
echo "Done! Signed, notarized, and stapled."
echo "App bundle: ${APP_BUNDLE}"
echo "DMG installer: ${DMG_PATH}"
echo "App size: $(du -sh "${APP_BUNDLE}" | cut -f1)"
echo "DMG size: $(du -sh "${DMG_PATH}" | cut -f1)"
