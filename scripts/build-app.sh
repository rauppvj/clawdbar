#!/usr/bin/env bash
#
# Build ClawdBar.app from this SPM project and wrap it in ClawdBar.dmg.
#
# Outputs land in ./dist/:
#   dist/ClawdBar.app
#   dist/ClawdBar.dmg     (drag-to-Applications installer)
#
# Optional env vars:
#   SIGN_IDENTITY  — codesign identity (default: ad-hoc "-")
#                    Example: SIGN_IDENTITY="Developer ID Application: Name (TEAMID)"
#   SKIP_DMG=1     — skip DMG packaging
#   SKIP_ICON=1    — skip icon generation (uses existing .icns if present)

set -euo pipefail

APP_NAME="ClawdBar"
BUNDLE_ID="com.vinicius.clawdbar"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
MIN_OS="15.0"
COPYRIGHT="Copyright © 2026 Vinicius Joaquim. MIT licensed."

SIGN_IDENTITY="${SIGN_IDENTITY:--}"
SKIP_DMG="${SKIP_DMG:-0}"
SKIP_ICON="${SKIP_ICON:-0}"

cd "$(dirname "$0")/.."
REPO_ROOT="$PWD"
DIST_DIR="$REPO_ROOT/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"

ARCH="$(uname -m)"
case "$ARCH" in
    arm64)  BUILD_DIR=".build/arm64-apple-macosx/release" ;;
    x86_64) BUILD_DIR=".build/x86_64-apple-macosx/release" ;;
    *) echo "unsupported arch: $ARCH" >&2; exit 1 ;;
esac

BIN_PATH="$REPO_ROOT/$BUILD_DIR/$APP_NAME"
RESOURCE_BUNDLE="$REPO_ROOT/$BUILD_DIR/${APP_NAME}_${APP_NAME}.bundle"

TMP_DIR="$(mktemp -d -t clawdbar-build)"
trap 'rm -rf "$TMP_DIR"' EXIT

log() { printf '\033[1;36m→\033[0m %s\n' "$*"; }
ok()  { printf '\033[1;32m✓\033[0m %s\n' "$*"; }

# 1. Compile
log "Compiling release binary"
swift build -c release >/dev/null

# 2. Reset output
rm -rf "$DIST_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

# 3. Generate icon
ICON_PATH="$APP_DIR/Contents/Resources/AppIcon.icns"
if [[ "$SKIP_ICON" != "1" ]]; then
    log "Rendering app icon (mascot-based, 1024×1024)"
    SOURCE_PNG="$TMP_DIR/icon-source.png"
    "$BIN_PATH" --export-icon "$SOURCE_PNG" >/dev/null

    ICONSET="$TMP_DIR/AppIcon.iconset"
    mkdir -p "$ICONSET"

    # logical_name : pixel_size
    SIZES=(
        "16x16:16"
        "16x16@2x:32"
        "32x32:32"
        "32x32@2x:64"
        "128x128:128"
        "128x128@2x:256"
        "256x256:256"
        "256x256@2x:512"
        "512x512:512"
        "512x512@2x:1024"
    )
    for entry in "${SIZES[@]}"; do
        name="${entry%:*}"
        px="${entry#*:}"
        sips -z "$px" "$px" "$SOURCE_PNG" --out "$ICONSET/icon_${name}.png" >/dev/null
    done
    iconutil --convert icns "$ICONSET" --output "$ICON_PATH"
fi

# 4. Copy executable + resource bundle
log "Assembling .app structure"
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/$APP_NAME"
chmod +x "$APP_DIR/Contents/MacOS/$APP_NAME"

# Copy the package's Resources/ contents straight into Contents/Resources/
# rather than dropping the SPM-generated `ClawdBar_ClawdBar.bundle` into the
# .app. Two reasons:
#   1. Codesign on CI runners (macOS 15 Sequoia) treats "unsealed contents
#      present in the bundle root" as a fatal error, so the SPM bundle
#      can't live at the top of the .app where SPM's auto-accessor
#      expects it.
#   2. FontRegistration was refactored to resolve resources via Bundle.main
#      in the .app case, so we don't need SPM's accessor here at all.
# The .lproj/ directories land in Contents/Resources/ directly, which is
# what AppKit/SwiftUI's localization machinery looks for on Bundle.main.
RESOURCES_SRC="$REPO_ROOT/Sources/$APP_NAME/Resources"
if [[ -d "$RESOURCES_SRC" ]]; then
    log "Copying app resources (fonts + .lproj) to Contents/Resources"
    cp -R "$RESOURCES_SRC/." "$APP_DIR/Contents/Resources/"
fi

# 5. Info.plist
cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>          <string>en</string>
    <key>CFBundleLocalizations</key>              <array><string>en</string><string>pt-BR</string></array>
    <key>CFBundleExecutable</key>                 <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>                   <string>AppIcon</string>
    <key>CFBundleIconName</key>                   <string>AppIcon</string>
    <key>CFBundleIdentifier</key>                 <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>      <string>6.0</string>
    <key>CFBundleName</key>                       <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>                <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>                <string>APPL</string>
    <key>CFBundleShortVersionString</key>         <string>${VERSION}</string>
    <key>CFBundleVersion</key>                    <string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key>             <string>${MIN_OS}</string>
    <key>LSUIElement</key>                        <true/>
    <key>NSHighResolutionCapable</key>            <true/>
    <key>NSHumanReadableCopyright</key>           <string>${COPYRIGHT}</string>
    <key>NSPrincipalClass</key>                   <string>NSApplication</string>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
PLIST

# 6. Sign
log "Stripping extended attributes (codesign hates them)"
xattr -cr "$APP_DIR"

log "Signing with identity: ${SIGN_IDENTITY}"
# --options runtime requires a real signing identity (Developer ID); ad-hoc
# can't enable hardened runtime, so fall back without the flag.
if [[ "${SIGN_IDENTITY}" == "-" ]]; then
    codesign --force --deep --sign - "$APP_DIR" >/dev/null
else
    codesign --force --deep --sign "${SIGN_IDENTITY}" --options runtime --timestamp "$APP_DIR" >/dev/null
fi

# Verify signature is loadable
codesign --verify --verbose=1 "$APP_DIR" 2>&1 | head -3 || true

ok "Built $APP_DIR"

# 7. DMG
if [[ "$SKIP_DMG" != "1" ]]; then
    log "Packaging DMG"
    STAGING="$TMP_DIR/dmg-staging"
    mkdir -p "$STAGING"
    cp -R "$APP_DIR" "$STAGING/"
    ln -s /Applications "$STAGING/Applications"
    DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION.dmg"
    hdiutil create \
        -volname "$APP_NAME $VERSION" \
        -srcfolder "$STAGING" \
        -ov \
        -format UDZO \
        "$DMG_PATH" >/dev/null
    ok "Built $DMG_PATH"
fi

echo ""
ok "Done."
echo "  Open the .app:   open $APP_DIR"
echo "  Or the DMG:      open $DIST_DIR/$APP_NAME-$VERSION.dmg"
