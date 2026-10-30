#!/bin/bash
# Builds MuPDF as universal (arm64 + x86_64) static libraries for macOS 13+
# into vendor/mupdf/{include,lib}. Only the PDF core is compiled in: no
# JavaScript, HTML/EPUB/XPS/SVG/CBZ, OCR or CJK fonts.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${MUPDF_VERSION:-1.28.6}
MIN_MACOS=13.0
SRC=vendor/mupdf-src/mupdf-$VERSION-source
OUT=vendor/mupdf

if [ ! -d "$SRC" ]; then
  mkdir -p vendor/mupdf-src
  echo "Скачиваю MuPDF ${VERSION}…"
  curl -fL "https://mupdf.com/downloads/archive/mupdf-$VERSION-source.tar.gz" -o vendor/mupdf-src/mupdf.tar.gz
  echo "SHA-256: $(shasum -a 256 vendor/mupdf-src/mupdf.tar.gz | cut -d' ' -f1)"
  tar -xzf vendor/mupdf-src/mupdf.tar.gz -C vendor/mupdf-src
fi

FEATURES="-DTOFU -DTOFU_CJK -DFZ_ENABLE_JS=0 -DFZ_ENABLE_HTML=0 -DFZ_ENABLE_EPUB=0 -DFZ_ENABLE_FB2=0 \
-DFZ_ENABLE_MOBI=0 -DFZ_ENABLE_XPS=0 -DFZ_ENABLE_SVG=0 -DFZ_ENABLE_CBZ=0 -DFZ_ENABLE_IMG=0 -DFZ_ENABLE_OFFICE=0 -DFZ_ENABLE_TXT=0"

for ARCH in arm64 x86_64; do
  echo "Сборка MuPDF для ${ARCH}…"
  make -C "$SRC" -j"$(sysctl -n hw.ncpu)" build=release OUT="build/$ARCH" \
    HAVE_X11=no HAVE_GLUT=no HAVE_CURL=no USE_TESSERACT=no USE_SYSTEM_LIBS=no \
    XCFLAGS="-arch $ARCH -mmacosx-version-min=$MIN_MACOS $FEATURES" \
    XLDFLAGS="-arch $ARCH -mmacosx-version-min=$MIN_MACOS" \
    libs >/dev/null
done

rm -rf "$OUT"
mkdir -p "$OUT/lib" "$OUT/licenses"
for LIB in libmupdf.a libmupdf-third.a; do
  lipo -create "$SRC/build/arm64/$LIB" "$SRC/build/x86_64/$LIB" -output "$OUT/lib/$LIB"
done
cp -R "$SRC/include" "$OUT/include"
cp "$SRC/COPYING" "$OUT/licenses/MuPDF-AGPL-3.0.txt"
echo "$VERSION" > "$OUT/VERSION"
lipo -info "$OUT/lib/libmupdf.a"
du -sh "$OUT/lib"/*
