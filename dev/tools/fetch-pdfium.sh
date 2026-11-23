#!/bin/sh
# Fetch the pinned PDFium build (bblanchon/pdfium-binaries, BSD-3 / Apache-2.0) into lib/pdfium.c3l/linux-x64,
# verify its hash, and refresh the license notices in licenses/pdfium/. Run from anywhere: dev/tools/fetch-pdfium.sh
set -eu
cd "$(dirname "$0")/../.."
TAG=chromium/8165
SHA256=ba7865e16c0271daab75256790be06c26272190afe6e2a70eae0bb39bb99089c
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
curl -fsSL -o "$work/pdfium.tgz" "https://github.com/bblanchon/pdfium-binaries/releases/download/$TAG/pdfium-linux-x64.tgz"
echo "$SHA256  $work/pdfium.tgz" | sha256sum -c --quiet
tar -xzf "$work/pdfium.tgz" -C "$work"
cp "$work/lib/libpdfium.so" lib/pdfium.c3l/linux-x64/libpdfium.so
rm -rf licenses/pdfium && mkdir -p licenses/pdfium
cp "$work/LICENSE" licenses/pdfium/LICENSE
cp "$work"/licenses/* licenses/pdfium/
echo "PDFium $TAG -> lib/pdfium.c3l/linux-x64/libpdfium.so"
