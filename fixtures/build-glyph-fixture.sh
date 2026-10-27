#!/bin/bash
# Builds the independent glyph-scene fixture into .dev/glyph-fixture/<tag>/Glyph Fixture <tag>.app
# with a tag-unique bundle identifier. Does not touch Public Fixture.app or its build script.
set -euo pipefail

case "${DESKTOP_TRANSLATE_DEV_TAG:-}" in
    ''|*[!A-Za-z0-9-]*)
        printf '%s\n' 'DESKTOP_TRANSLATE_DEV_TAG must be nonempty and contain only A-Z, a-z, 0-9, or hyphens.' >&2
        exit 2
        ;;
esac
tag="$DESKTOP_TRANSLATE_DEV_TAG"

src_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(CDPATH= cd -- "$src_dir/.." && pwd)"
dev_root="$repo_root/.dev"
glyph_root="$dev_root/glyph-fixture"
output_dir="$glyph_root/$tag"
bundle_id="local.desktop-translate.glyph-fixture.$tag"
app_name="Glyph Fixture $tag.app"
installed_app="$output_dir/$app_name"

if [[ -L "$dev_root" || -L "$glyph_root" || -L "$output_dir" || -L "$installed_app" ]]; then
    printf '%s\n' 'Refusing symlinked glyph fixture output paths.' >&2
    exit 2
fi
mkdir -p -- "$output_dir"
if [[ -e "$installed_app" ]]; then
    if [[ ! -d "$installed_app" || -L "$installed_app/Contents" || -L "$installed_app/Contents/Info.plist" ]] ||
       [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$installed_app/Contents/Info.plist" 2>/dev/null || true)" != "$bundle_id" ]]; then
        printf '%s\n' 'Refusing to replace an unrecognized glyph fixture bundle.' >&2
        exit 2
    fi
fi

stage="$(mktemp -d "$output_dir/.build.XXXXXX")"
cleanup() {
    if [[ -d "$stage/previous.app" && ! -e "$installed_app" && ! -L "$installed_app" ]]; then
        mv -- "$stage/previous.app" "$installed_app"
    fi
    rm -rf -- "$stage"
}
trap cleanup EXIT
staged_app="$stage/$app_name"
mkdir -p -- "$staged_app/Contents/MacOS"
cat > "$staged_app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>$bundle_id</string>
    <key>CFBundleExecutable</key><string>glyph-fixture</string>
    <key>CFBundleName</key><string>Glyph Fixture $tag</string>
    <key>CFBundleDisplayName</key><string>Glyph Fixture $tag</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

sdk="$(xcrun --sdk macosx --show-sdk-path)"
xcrun --sdk macosx swiftc -parse-as-library \
    -target arm64-apple-macosx15.0 -sdk "$sdk" \
    "$src_dir/GlyphSceneManifest.swift" "$src_dir/GlyphSceneFixtureApp.swift" \
    "$src_dir/GlyphSceneFixtureDrawing.swift" "$src_dir/GlyphSceneFixtureDelegate.swift" \
    -framework AppKit -framework CoreText -o "$staged_app/Contents/MacOS/glyph-fixture"
/usr/bin/codesign --force --sign - "$staged_app"

if [[ -e "$installed_app" ]]; then
    mv -- "$installed_app" "$stage/previous.app"
fi
mv -- "$staged_app" "$installed_app"
printf 'Built %s\n' "$installed_app"
