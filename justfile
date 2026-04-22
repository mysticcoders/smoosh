set shell := ["bash", "-euo", "pipefail", "-c"]

# List available recipes
default:
    @just --list

# Build signed, notarized, stapled .app + .dmg (Developer ID distribution)
build:
    ./build.sh

# Build the Mac App Store package
build-appstore:
    ./build-appstore.sh

# Fast local build — unsigned, no notarization, for iterative development
dev:
    #!/usr/bin/env bash
    set -euo pipefail
    HOMEBREW_PREFIX="$(brew --prefix)"
    SDK_PATH="$(xcrun --show-sdk-path)"
    VPX_LIB="${HOMEBREW_PREFIX}/Cellar/libvpx/1.15.2/lib"
    mkdir -p build-dev/Smoosh.app/Contents/{MacOS,Resources}
    cc -O2 -c -target arm64-apple-macosx13.0 -isysroot "${SDK_PATH}" \
        -I "${HOMEBREW_PREFIX}/include" -o build-dev/webm_muxer.o webm_muxer.c
    swiftc -O -target arm64-apple-macosx13.0 -sdk "${SDK_PATH}" \
        -framework SwiftUI -framework AppKit -framework CoreGraphics \
        -framework ImageIO -framework AVFoundation -framework CoreMedia -framework CoreVideo \
        -import-objc-header webp-bridge.h \
        -I "${HOMEBREW_PREFIX}/include" -L "${HOMEBREW_PREFIX}/lib" \
        "${HOMEBREW_PREFIX}/lib/libwebp.a" "${HOMEBREW_PREFIX}/lib/libsharpyuv.a" \
        "${VPX_LIB}/libvpx.a" build-dev/webm_muxer.o -parse-as-library \
        -o build-dev/Smoosh.app/Contents/MacOS/Smoosh Smoosh.swift
    cp Info.plist build-dev/Smoosh.app/Contents/Info.plist
    cp AppIcon.icns build-dev/Smoosh.app/Contents/Resources/AppIcon.icns
    echo "Built: build-dev/Smoosh.app"

# Launch the dev build
run: dev
    open build-dev/Smoosh.app

# Launch the release build
run-release:
    open build/Smoosh.app

# Remove all build artifacts
clean:
    rm -rf build build-appstore build-dev

# Tag and publish a GitHub release, auto-bumping from the latest tag
# Usage: just release            (defaults to patch)
#        just release minor
#        just release major
release BUMP="patch":
    #!/usr/bin/env bash
    set -euo pipefail
    case "{{BUMP}}" in
        major|minor|patch) ;;
        *) echo "Usage: just release [major|minor|patch]"; exit 1 ;;
    esac
    test -f build/Smoosh.dmg || { echo "build/Smoosh.dmg not found — run 'just build' first"; exit 1; }
    git fetch --tags --quiet
    LATEST=$(git tag --sort=-v:refname | head -n1 || true)
    if [ -z "$LATEST" ]; then
        MAJOR=0; MINOR=0; PATCH=0
    else
        IFS='.' read -r MAJOR MINOR PATCH <<< "${LATEST#v}"
    fi
    case "{{BUMP}}" in
        major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
        minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
        patch) PATCH=$((PATCH + 1)) ;;
    esac
    NEW="v${MAJOR}.${MINOR}.${PATCH}"
    echo "Releasing ${NEW} (previous: ${LATEST:-none})"
    read -p "Proceed? [y/N] " -n 1 -r REPLY
    echo
    [[ $REPLY =~ ^[Yy]$ ]] || exit 0
    git tag "${NEW}"
    git push origin "${NEW}"
    gh release create "${NEW}" build/Smoosh.dmg \
        --title "Smoosh ${NEW}" \
        --generate-notes

# Report whether a release is ready to publish
release-check:
    @if [ -f build/Smoosh.dmg ]; then \
        echo "Ready: build/Smoosh.dmg ($(du -h build/Smoosh.dmg | cut -f1))"; \
    else \
        echo "Missing: build/Smoosh.dmg — run 'just build'"; \
    fi
