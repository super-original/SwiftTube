#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$ROOT_DIR/Build/SwiftTube.app"
EXECUTABLE_NAME="SwiftTubeApp"
RESOURCE_BUNDLE_NAME="SwiftTubeApp_SwiftTubeApp.bundle"
ICON_SOURCE="$ROOT_DIR/AppIcon.icon"
ICON_BUILD_DIR="$ROOT_DIR/Build/IconAssets"
ACTOOL_BIN="$(xcrun --find actool)"
VERSION_FILE="$ROOT_DIR/VERSION"
FRAMEWORKS_DIR="$APP_DIR/Contents/Frameworks"
BUILD_DIR=""
EXECUTABLE_PATH=""
RESOURCE_BUNDLE_PATH=""
SIGNING_IDENTITY="${SWIFTTUBE_SIGNING_IDENTITY:-}"

if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk '/^[[:space:]]*[0-9]+\)/ { print $2; exit }')"
fi
if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY="-"
fi

cd "$ROOT_DIR"
swift build
BUILD_DIR="$(swift build --show-bin-path)"
EXECUTABLE_PATH="$BUILD_DIR/$EXECUTABLE_NAME"
RESOURCE_BUNDLE_PATH="$BUILD_DIR/$RESOURCE_BUNDLE_NAME"

if [[ ! -f "$VERSION_FILE" ]]; then
    echo "Missing version file: $VERSION_FILE" >&2
    exit 1
fi

APP_VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
if [[ -z "$APP_VERSION" ]]; then
    echo "Version file is empty: $VERSION_FILE" >&2
    exit 1
fi

BUILD_NUMBER="$(git -C "$ROOT_DIR" rev-list --count HEAD 2>/dev/null || echo 1)"

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
    --minimum-deployment-target 27.0 \
    --platform macosx \
    --standalone-icon-behavior all

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
mkdir -p "$APP_DIR/Contents/Resources/Docs"
mkdir -p "$FRAMEWORKS_DIR"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
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
    <string>$APP_VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>
    <string>27.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

if [[ ! -f "$EXECUTABLE_PATH" ]]; then
    echo "Missing executable: $EXECUTABLE_PATH" >&2
    exit 1
fi

if [[ ! -d "$RESOURCE_BUNDLE_PATH" ]]; then
    echo "Missing resource bundle: $RESOURCE_BUNDLE_PATH" >&2
    exit 1
fi

cp "$EXECUTABLE_PATH" "$APP_DIR/Contents/MacOS/$EXECUTABLE_NAME"
ditto "$RESOURCE_BUNDLE_PATH" "$APP_DIR/Contents/Resources/$RESOURCE_BUNDLE_NAME"
# Old local Python environments may still exist under the ignored source
# resources directory. They are never part of the native app and must not be
# copied into or invalidate the signed bundle.
rm -rf "$APP_DIR/Contents/Resources/$RESOURCE_BUNDLE_NAME/Contents/Resources/Resources/backend"
if [[ -f "$ROOT_DIR/../CHANGELOG.md" ]]; then
    cp "$ROOT_DIR/../CHANGELOG.md" "$APP_DIR/Contents/Resources/Docs/CHANGELOG.md"
fi
if [[ -f "$ICON_BUILD_DIR/AppIcon.icns" ]]; then
    cp "$ICON_BUILD_DIR/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi
cp "$ICON_BUILD_DIR/Assets.car" "$APP_DIR/Contents/Resources/Assets.car"

function binary_rpaths() {
    local binary_path="$1"
    otool -l "$binary_path" 2>/dev/null | awk '
        $1 == "cmd" && $2 == "LC_RPATH" {
            getline
            getline
            if ($1 == "path") {
                print $2
            }
        }
    '
}

function framework_executable_name() {
    local framework_path="$1"
    local info_plist="$framework_path/Info.plist"
    local fallback_name="${framework_path:t:r}"

    if [[ -f "$info_plist" ]]; then
        local executable_name
        executable_name=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$info_plist" 2>/dev/null || true)
        if [[ -n "$executable_name" ]]; then
            print "$executable_name"
            return
        fi
    fi

    print "$fallback_name"
}

function resolve_dependency_path() {
    local binary_path="$1"
    local dependency="$2"
    local binary_dir="${binary_path:h}"
    local executable_dir="$BUILD_DIR"
    local candidate
    local resolved_rpath

    case "$dependency" in
        /System/*|/usr/lib/*)
            return
            ;;
        @loader_path/*)
            candidate="${dependency/@loader_path/$binary_dir}"
            [[ -e "$candidate" ]] && print "$candidate"
            return
            ;;
        @executable_path/*)
            candidate="${dependency/@executable_path/$executable_dir}"
            [[ -e "$candidate" ]] && print "$candidate"
            return
            ;;
        @rpath/*)
            while IFS= read -r raw_rpath; do
                resolved_rpath="${raw_rpath/@loader_path/$binary_dir}"
                resolved_rpath="${resolved_rpath/@executable_path/$executable_dir}"
                candidate="${dependency/@rpath/$resolved_rpath}"
                if [[ -e "$candidate" ]]; then
                    print "$candidate"
                    return
                fi
            done < <(binary_rpaths "$binary_path")
            return
            ;;
        *)
            [[ -e "$dependency" ]] && print "$dependency"
            return
            ;;
    esac
}

function ensure_framework_rpath() {
    local binary_path="$1"
    local desired_rpath="@executable_path/../Frameworks"

    if ! binary_rpaths "$binary_path" | grep -Fxq "$desired_rpath"; then
        install_name_tool -add_rpath "$desired_rpath" "$binary_path"
    fi
}

typeset -A COPIED_FRAMEWORKS

function embed_framework_dependencies() {
    local source_binary="$1"
    local consumer_binary="$2"
    local dependency
    local resolved_dependency
    local source_framework
    local framework_name
    local destination_framework
    local source_framework_binary
    local destination_framework_binary
    local install_name

    while IFS= read -r dependency; do
        dependency="${dependency%% *}"
        [[ -z "$dependency" ]] && continue

        resolved_dependency="$(resolve_dependency_path "$source_binary" "$dependency")"
        [[ -z "$resolved_dependency" ]] && continue
        [[ "$resolved_dependency" != *".framework/"* ]] && continue

        source_framework="${resolved_dependency%%.framework/*}.framework"
        framework_name="${source_framework:t}"
        destination_framework="$FRAMEWORKS_DIR/$framework_name"
        destination_framework_binary="$destination_framework/$(framework_executable_name "$destination_framework")"
        install_name="@rpath/$framework_name/$(framework_executable_name "$destination_framework")"

        if [[ -z "${COPIED_FRAMEWORKS[$framework_name]:-}" ]]; then
            ditto "$source_framework" "$destination_framework"
            COPIED_FRAMEWORKS[$framework_name]=1

            source_framework_binary="$source_framework/$(framework_executable_name "$source_framework")"
            if [[ -f "$destination_framework_binary" ]]; then
                install_name_tool -id "$install_name" "$destination_framework_binary" 2>/dev/null || true
                embed_framework_dependencies "$source_framework_binary" "$destination_framework_binary"
            fi
        fi

        if [[ -f "$consumer_binary" ]]; then
            install_name_tool -change "$dependency" "$install_name" "$consumer_binary" 2>/dev/null || true
        fi
    done < <(otool -L "$source_binary" 2>/dev/null | tail -n +2 | awk '{print $1}')
}

embed_framework_dependencies "$EXECUTABLE_PATH" "$APP_DIR/Contents/MacOS/$EXECUTABLE_NAME"
ensure_framework_rpath "$APP_DIR/Contents/MacOS/$EXECUTABLE_NAME"
find "$FRAMEWORKS_DIR" -maxdepth 1 -type d -name '*.framework' -print0 | while IFS= read -r -d '' framework; do
    codesign --force --timestamp=none --sign "$SIGNING_IDENTITY" "$framework"
done
codesign --force --timestamp=none --sign "$SIGNING_IDENTITY" "$APP_DIR"

echo "Updated $APP_DIR"
