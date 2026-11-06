#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
swift build -c release
binary_dir="$(swift build -c release --show-bin-path)"
app_dir="$project_root/dist/RouteBar.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Helpers" "$app_dir/Contents/Resources"
cp "$binary_dir/RouteBar" "$app_dir/Contents/MacOS/RouteBar"
cp "$binary_dir/RouteBarHelper" "$app_dir/Contents/Helpers/RouteBarHelper"
cp "$binary_dir/routebarctl" "$project_root/dist/routebarctl"
# SwiftPM resource lookup must work for the GUI, privileged helper and CLI.
resource_bundle="$binary_dir/RouteBar_RouteBarCore.bundle"
ditto "$resource_bundle" "$app_dir/Contents/Resources/RouteBar_RouteBarCore.bundle"
ditto "$resource_bundle" "$app_dir/Contents/Helpers/RouteBar_RouteBarCore.bundle"
ditto "$resource_bundle" "$project_root/dist/RouteBar_RouteBarCore.bundle"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>RouteBar</string>
<key>CFBundleIdentifier</key><string>io.routebar.app</string>
<key>CFBundleName</key><string>RouteBar</string>
<key>CFBundleDisplayName</key><string>RouteBar</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.0</string>
<key>CFBundleVersion</key><string>7</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hant</string><string>zh-Hans</string></array>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
icon_dir="$project_root/.build/RouteBar.iconset"
mkdir -p "$icon_dir"
swift "$project_root/scripts/make-icon.swift" "$project_root/.build/icon-1024.png"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$project_root/.build/icon-1024.png" --out "$icon_dir/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$project_root/.build/icon-1024.png" --out "$icon_dir/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$icon_dir" -o "$app_dir/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$app_dir/Contents/Helpers/RouteBar_RouteBarCore.bundle"
codesign --force --sign - "$app_dir/Contents/Resources/RouteBar_RouteBarCore.bundle"
codesign --force --sign - "$app_dir/Contents/Helpers/RouteBarHelper"
codesign --force --sign - "$app_dir"
codesign --verify --deep --strict "$app_dir"
printf 'Built: %s\n' "$app_dir"
