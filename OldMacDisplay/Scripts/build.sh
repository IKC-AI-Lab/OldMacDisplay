#!/bin/bash
#
# Builds OldMacDisplay as a single universal .app that runs on both machines.
#
#   ./Scripts/build.sh          # tests, then the app, then verification
#   ./Scripts/build.sh app
#   ./Scripts/build.sh test
#
# One binary, two roles. It is built for arm64 + x86_64 with a 10.15 minimum so
# the same bundle runs on the M2 Max and the 2013 Intel iMac; the app decides at
# runtime which half of itself is usable.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT/build"
CONFIG="${CONFIG:-release}"
APP="$BUILD_DIR/OldMacDisplay.app"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# Pick a code-signing identity.
#
# This matters far more than it looks. TCC (Screen Recording, Local Network)
# remembers a permission against the app's *designated requirement*. For an
# ad-hoc signature that requirement is the cdhash:
#
#     designated => cdhash H"afd872..."
#
# which changes on every single build, so every rebuild silently revokes the
# permission and the app reports "user declined TCCs" with no way to tell that
# a rebuild was the cause.
#
# Signing with a real identity makes the requirement identity-based instead:
#
#     designated => identifier "com.oldmacdisplay.app" and anchor apple generic
#                   and certificate leaf[subject.CN] = "Apple Development: ..."
#
# which is stable across rebuilds, so the permission is granted once and stays.
# Any Apple Development certificate works; no paid account or notarisation is
# needed for local use. Override with CODESIGN_IDENTITY, or fall back to ad-hoc.
pick_identity() {
    if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
        printf '%s' "$CODESIGN_IDENTITY"
        return
    fi
    # Output looks like:  1) <SHA1> "Apple Development: Name (TEAMID)"
    # so take the first quoted field of the first numbered line.
    local found
    found="$(security find-identity -v -p codesigning 2>/dev/null \
             | awk -F'\"' '/^ *[0-9]+\)/ { print $2; exit }')"
    printf '%s' "${found:--}"
}

build_tests() {
    log "Running Shared test suite"
    (cd "$ROOT/Shared" && swift test)
}

build_app() {
    log "Building OldMacDisplay ($CONFIG, universal arm64 + x86_64)"
    (cd "$ROOT/App" && swift build -c "$CONFIG" --arch arm64 --arch x86_64)
    local bin
    bin="$(cd "$ROOT/App" && swift build -c "$CONFIG" --arch arm64 --arch x86_64 --show-bin-path)"

    rm -rf "$APP"
    mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
    cp "$bin/OldMacDisplay" "$APP/Contents/MacOS/OldMacDisplay"

    # The icon is generated, not committed. Re-render whenever the generator
    # has changed, or an edited design silently never reaches the bundle.
    if [[ ! -f "$ROOT/Resources/AppIcon.icns" ]] \
       || [[ "$ROOT/Scripts/make-icon.swift" -nt "$ROOT/Resources/AppIcon.icns" ]]; then
        bash "$ROOT/Scripts/icon.sh"
    fi
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

    cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>OldMacDisplay</string>
    <key>CFBundleDisplayName</key><string>OldMacDisplay</string>
    <key>CFBundleIdentifier</key><string>com.oldmacdisplay.app</string>
    <key>CFBundleExecutable</key><string>OldMacDisplay</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.3.5</string>
    <key>CFBundleVersion</key><string>8</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key><string>10.15</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <!-- macOS 15+ gates Bonjour browsing and local connections behind the
         local network privacy prompt. Both keys are required or discovery
         silently returns nothing. Harmless on Catalina. -->
    <key>NSLocalNetworkUsageDescription</key>
    <string>OldMacDisplay finds and streams to Macs on your local network.</string>
    <key>NSBonjourServices</key>
    <array><string>_oldmacdisplay._tcp</string></array>
</dict>
</plist>
PLIST

    local identity
    identity="$(pick_identity)"
    codesign --force --sign "$identity" --timestamp=none "$APP" >/dev/null 2>&1 \
        || die "codesign failed for $APP (identity: $identity)"

    if [[ "$identity" == "-" ]]; then
        warn "No code-signing identity found; signed ad-hoc."
        warn "Screen Recording permission will be revoked on every rebuild."
        warn "Create a self-signed Code Signing certificate in Keychain Access to fix this."
    else
        log "Signed with: $identity"
    fi

    log "Built $APP"
    "$ROOT/Scripts/verify-catalina.sh" "$APP/Contents/MacOS/OldMacDisplay"

    # Transfer archive: a plain copy to a USB stick loses the executable bit and
    # macOS then refuses to treat the bundle as an application.
    rm -f "$BUILD_DIR/OldMacDisplay.zip"
    (cd "$BUILD_DIR" && ditto -c -k --sequesterRsrc --keepParent "OldMacDisplay.app" "OldMacDisplay.zip")
    log "Transfer archive: $BUILD_DIR/OldMacDisplay.zip"
}

case "${1:-all}" in
    app)  build_app ;;
    test) build_tests ;;
    all)  build_tests; build_app ;;
    *)    die "unknown target '${1}' (expected: all, app, test)" ;;
esac

log "Done."
