#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
output_dir="${ROUTEBAR_OUTPUT_DIR:-$project_root/dist}"
app_dir="$output_dir/RouteBar.app"
if [[ ! -d "$app_dir" ]]; then
    printf 'Build RouteBar.app first with: bash scripts/build-app.sh\n' >&2
    exit 1
fi
codesign --verify --deep --strict "$app_dir"
app_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_dir/Contents/Info.plist")
app_build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app_dir/Contents/Info.plist")
app_arch=$(lipo -archs "$app_dir/Contents/MacOS/RouteBar" | tr ' ' '-')
output_path="$output_dir/RouteBar-${app_version}-${app_build}-${app_arch}.dmg"
staging_dir=$(mktemp -d "${TMPDIR:-/tmp}/routebar-dmg.XXXXXX")
trap 'rm -rf "$staging_dir"' EXIT
ditto "$app_dir" "$staging_dir/RouteBar.app"
ln -s /Applications "$staging_dir/Applications"
hdiutil create -volname "RouteBar" -srcfolder "$staging_dir" -format UDZO -imagekey zlib-level=9 "$output_path"
hdiutil verify "$output_path"
(cd "$output_dir" && shasum -a 256 "$(basename "$output_path")") > "$output_path.sha256"
printf 'Packaged: %s\n' "$output_path"
