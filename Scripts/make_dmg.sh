#!/bin/bash
# Packs an app into a compressed .dmg with an "Applications" shortcut:
#   ./Scripts/make_dmg.sh build/PageYard.app build/PageYard.dmg ["PageYard 1.0.0"]
set -euo pipefail
APP=$1
DMG=$2
VOLNAME=${3:-$(basename "$APP" .app)}

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/$(basename "$APP")"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname "$VOLNAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
echo "Образ: $DMG"
