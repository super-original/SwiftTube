#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT_DIR/.build/debug"
APP_DIR="$ROOT_DIR/Build/SwiftTube.app"
EXECUTABLE_NAME="SwiftTubeApp"
RESOURCE_BUNDLE_NAME="SwiftTubeApp_SwiftTubeApp.bundle"
ICON_SOURCE="$ROOT_DIR/AppIcon.icon"
ICON_BUILD_DIR="$ROOT_DIR/Build/IconAssets"
ACTOOL_BIN="$(xcrun --find actool)"

cd "$ROOT_DIR"
swift build

if [[ ! -d "$ICON_SOURCE" ]]; then
    echo "Missing icon package: $ICON_SOURCE" >&2
    exit 1
fi

mkdir -p "$ICON_BUILD_DIR"
"$ACTOOL_BIN" "$ICON_SOURCE" \
    --compile "$ICON_BUILD_DIR" \
    --output-format human-readable-text \
    --notices \
    --warnings \
    --output-partial-info-plist "$ICON_BUILD_DIR/partial.plist" \
    --app-icon AppIcon \
    --enable-on-demand-resources NO \
    --development-region en \
    --target-device mac \
    --minimum-deployment-target 26.0 \
    --platform macosx \
    --standalone-icon-behavior all

mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>SwiftTubeApp</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.swifttube.app</string>
    <key>CFBundleName</key>
    <string>SwiftTube</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

cp "$BUILD_DIR/$EXECUTABLE_NAME" "$APP_DIR/Contents/MacOS/$EXECUTABLE_NAME"
ditto "$BUILD_DIR/$RESOURCE_BUNDLE_NAME" "$APP_DIR/Contents/Resources/$RESOURCE_BUNDLE_NAME"
if [[ -f "$ICON_BUILD_DIR/AppIcon.icns" ]]; then
    cp "$ICON_BUILD_DIR/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi
cp "$ICON_BUILD_DIR/Assets.car" "$APP_DIR/Contents/Resources/Assets.car"
codesign --force --deep --sign - "$APP_DIR"

echo "Updated $APP_DIR"
