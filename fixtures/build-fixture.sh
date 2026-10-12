#!/bin/bash
set -euo pipefail

case "${DESKTOP_TRANSLATE_DEV_TAG:-}" in
    ''|*[!A-Za-z0-9-]*)
        printf '%s\n' 'DESKTOP_TRANSLATE_DEV_TAG must be nonempty and contain only A-Z, a-z, 0-9, or hyphens.' >&2
        exit 2
        ;;
esac

fixture_source_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(CDPATH= cd -- "$fixture_source_dir/.." && pwd)"
dev_root="$repo_root/.dev"
output_dir="$dev_root/fixture"
bundle_id='local.desktop-translate.public-fixture'
installed_app="$output_dir/Public Fixture.app"

# Do not follow redirected development paths or replace an unrelated bundle.
if [[ -L "$dev_root" || -L "$output_dir" || -L "$installed_app" ]]; then
    printf '%s\n' 'Refusing symlinked fixture output paths.' >&2
    exit 2
fi
mkdir -p -- "$output_dir"
if [[ -e "$installed_app" ]]; then
    if [[ ! -d "$installed_app" || -L "$installed_app/Contents" || -L "$installed_app/Contents/Info.plist" ]] ||
       [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$installed_app/Contents/Info.plist" 2>/dev/null || true)" != "$bundle_id" ]] ||
       [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$installed_app/Contents/Info.plist" 2>/dev/null || true)" != 'public-fixture' ]]; then
        printf '%s\n' 'Refusing to replace an unrecognized Public Fixture.app.' >&2
        exit 2
    fi
fi

stage="$(mktemp -d "$output_dir/.build-${DESKTOP_TRANSLATE_DEV_TAG}.XXXXXX")"
cleanup() {
    # Restore the previous fixture if installation failed after moving it aside.
    if [[ -d "$stage/previous.app" && ! -e "$installed_app" && ! -L "$installed_app" ]]; then
        mv -- "$stage/previous.app" "$installed_app"
    fi
    rm -rf -- "$stage"
}
trap cleanup EXIT
staged_app="$stage/Public Fixture.app"
mkdir -p -- "$staged_app/Contents/MacOS"
cat > "$staged_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>local.desktop-translate.public-fixture</string>
    <key>CFBundleExecutable</key><string>public-fixture</string>
    <key>CFBundleName</key><string>Public Fixture</string>
    <key>CFBundleDisplayName</key><string>Public Fixture</string>
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
    "$fixture_source_dir/PublicFixtureApp.swift" \
    -framework AppKit -o "$staged_app/Contents/MacOS/public-fixture"
/usr/bin/codesign --force --sign - "$staged_app"

if [[ -e "$installed_app" ]]; then
    mv -- "$installed_app" "$stage/previous.app"
fi
mv -- "$staged_app" "$installed_app"
printf 'Built %s\n' "$installed_app"
