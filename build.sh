#!/bin/zsh
# Build No One Lock.app
#   ./build.sh           -> build/No One Lock.app
#   ./build.sh install   -> build lalu salin ke /Applications dan jalankan
#   ./build.sh dist      -> build lalu buat build/NoOneLock.zip untuk dibagikan
set -euo pipefail
cd "$(dirname "$0")"

APP="build/No One Lock.app"
BIN="$APP/Contents/MacOS/NoOneLock"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Universal binary: Apple Silicon + Intel
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 \
    -target $arch-apple-macos14.0 \
    Sources/main.swift \
    -o "build/NoOneLock-$arch"
done
lipo -create build/NoOneLock-arm64 build/NoOneLock-x86_64 -output "$BIN"
rm build/NoOneLock-arm64 build/NoOneLock-x86_64

codesign --force --sign - "$APP"
echo "Built: $APP ($(lipo -archs "$BIN"))"

if [[ "${1:-}" == "dist" ]]; then
  rm -f build/NoOneLock.zip
  ditto -c -k --keepParent "$APP" build/NoOneLock.zip
  echo "Zip: build/NoOneLock.zip"
fi

if [[ "${1:-}" == "install" ]]; then
  pkill -x NoOneLock 2>/dev/null || true
  rm -rf "/Applications/No One Lock.app"
  cp -R "$APP" /Applications/
  open "/Applications/No One Lock.app"
  echo "Installed & launched: /Applications/No One Lock.app"
fi
