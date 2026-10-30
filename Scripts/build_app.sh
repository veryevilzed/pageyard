#!/bin/bash
# Builds build/PageYard.app.
#
#   ./Scripts/build_app.sh                         universal, ad-hoc signature
#   ARCHS=arm64 ./Scripts/build_app.sh             only Apple Silicon
#   SIGN_IDENTITY="Developer ID Application: …" ./Scripts/build_app.sh
#
# Environment: VERSION, BUILD_NUMBER, BUNDLE_ID, COPYRIGHT, ARCHS, SIGN_IDENTITY, OUT_DIR.
set -euo pipefail
cd "$(dirname "$0")/.."

PLIST_SRC=Resources/Info.plist
VERSION=${VERSION:-$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST_SRC")}
BUILD_NUMBER=${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}
BUNDLE_ID=${BUNDLE_ID:-$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$PLIST_SRC")}
COPYRIGHT=${COPYRIGHT:-"© $(date +%Y)"}
ARCHS=${ARCHS:-"arm64 x86_64"}
SIGN_IDENTITY=${SIGN_IDENTITY:--}
OUT_DIR=${OUT_DIR:-build}
APP="$OUT_DIR/PageYard.app"

[ -f vendor/mupdf/lib/libmupdf.a ] || ./Scripts/build_mupdf.sh

# Compile each architecture and merge into one binary.
BINARIES=()
for ARCH in $ARCHS; do
  TRIPLE="$ARCH-apple-macosx13.0"
  echo "Компиляция ($ARCH)…"
  # Separate scratch dirs: the build backend doesn't keep triples apart.
  swift build -c release --triple "$TRIPLE" --scratch-path ".build/$ARCH" 2>&1 | grep -E "error:" || true
  BIN="$(swift build -c release --triple "$TRIPLE" --scratch-path ".build/$ARCH" --show-bin-path)/PageYard"
  [ -x "$BIN" ] || { echo "Нет бинарника для $ARCH" >&2; exit 1; }
  BINARIES+=("$BIN")
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Licenses"
lipo -create "${BINARIES[@]}" -output "$APP/Contents/MacOS/PageYard"

cp "$PLIST_SRC" "$APP/Contents/Info.plist"
PB=/usr/libexec/PlistBuddy
$PB -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
$PB -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
$PB -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Contents/Info.plist"
$PB -c "Add :NSHumanReadableCopyright string $COPYRIGHT" "$APP/Contents/Info.plist" 2>/dev/null \
  || $PB -c "Set :NSHumanReadableCopyright $COPYRIGHT" "$APP/Contents/Info.plist"

# Icon
TMP=$(mktemp -d)
swift Scripts/make_icon.swift "$TMP/AppIcon.iconset" >/dev/null
iconutil -c icns "$TMP/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$TMP"

# Licenses: our code (Apache-2.0) and the bundled MuPDF (AGPL-3.0).
cp LICENSE NOTICE "$APP/Contents/Resources/Licenses/"
cp vendor/mupdf/licenses/MuPDF-AGPL-3.0.txt "$APP/Contents/Resources/Licenses/"
cp Resources/Credits.rtf "$APP/Contents/Resources/Credits.rtf"

if [ "$SIGN_IDENTITY" = "-" ]; then
  codesign --force --sign - "$APP"
else
  # Hardened Runtime + timestamp: required for notarization.
  codesign --force --options runtime --timestamp --entitlements Resources/PageYard.entitlements \
    --sign "$SIGN_IDENTITY" "$APP"
fi
echo "Готово: $APP ($VERSION, $(lipo -archs "$APP/Contents/MacOS/PageYard"))"
