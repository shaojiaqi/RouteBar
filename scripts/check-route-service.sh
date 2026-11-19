#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
app="${ROUTEBAR_OUTPUT_DIR:-$root/dist}/RouteBar.app"
gui="$app/Contents/MacOS/RouteBar"
helpers="$app/Contents/Helpers"
manifest="$app/Contents/Info.plist"

if [ "${1:-}" = --approved ]; then
    exec "$gui" --probe-route-service
fi
if [ "$#" -ne 0 ] || [ "$(id -u)" -eq 0 ]; then
    printf 'Usage: run as a normal user: bash %s [--approved]\n' "$0" >&2
    exit 64
fi

"$gui" --check-route-service-build
stage=$(mktemp -d "${TMPDIR:-/tmp}/routebar-check.XXXXXXXX")
trap 'test ! -e "$stage/RouteBarHelper" || unlink "$stage/RouteBarHelper"; test ! -e "$stage/Localizations.json" || unlink "$stage/Localizations.json"; rmdir "$stage"' EXIT
cp -X "$helpers/RouteBarHelper" "$stage/RouteBarHelper"
cp -X "$helpers/RouteBar_RouteBarCore.bundle/Contents/Resources/Localizations.json" "$stage/Localizations.json"
helper_sha=$(/usr/libexec/PlistBuddy -c 'Print :RouteBarHelperSHA256' "$manifest")
catalog_sha=$(/usr/libexec/PlistBuddy -c 'Print :RouteBarCatalogSHA256' "$manifest")
(cd "$stage" && printf '%s  RouteBarHelper\n%s  Localizations.json\n' "$helper_sha" "$catalog_sha" | shasum -a 256 -c)
chmod 700 "$stage/RouteBarHelper"
codesign --verify --strict --test-requirement '=identifier "io.routebar.app.helper"' "$stage/RouteBarHelper"

request=$(printf '{"kind":"applyPgy","uid":%s,"expectedFingerprint":"check-no-route-change","language":"en","settings":{"pgyVirtualIP":"","pgyNodes":[],"selectedSubnets":[],"maintainPgy":false,"maintainTailscale":false}}' "$(id -u)" | base64)
reply=$("$stage/RouteBarHelper" --apply "$request")
test "$(printf '%s' "$reply" | plutil -extract success raw -o - -)" = false
test "$(printf '%s' "$reply" | plutil -extract message raw -o - -)" = 'Administrator authorization is required to change routes.'
status=0
"$stage/RouteBarHelper" --serve-installed probe "$(id -u)" probe || status=$?
test "$status" -eq 77
printf 'Staged helper passed signature and unprivileged execution checks.\n'
