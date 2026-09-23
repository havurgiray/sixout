#!/bin/bash
# Builds SixOut.app with the command-line tools only (no Xcode needed).
set -euo pipefail
cd "$(dirname "$0")"
SDK=$(xcrun --show-sdk-path)
TARGET=arm64-apple-macos14.2
FF="$(pwd)/ffmpeg/install"   # patched static ffmpeg (see ffmpeg/build-ffmpeg.sh); no Homebrew dependency
[ -f "$FF/lib/libavcodec.a" ] || ./ffmpeg/build-ffmpeg.sh   # fresh clone: build the vendored ffmpeg libraries first (a few minutes)
mkdir -p build/obj
CXXFLAGS="-std=c++17 -O2 -fobjc-arc -target $TARGET -isysroot $SDK -I Core -I Core/TPCircularBuffer -I $FF/include -Wno-deprecated-declarations"
echo "== compiling native core"
for f in Core/*.cpp; do clang++ $CXXFLAGS -c "$f" -o "build/obj/$(basename "$f" .cpp).o"; done
for f in Core/*.mm; do clang++ $CXXFLAGS -x objective-c++ -c "$f" -o "build/obj/$(basename "$f" .mm).o"; done
clang -O2 -target $TARGET -isysroot $SDK -c Core/TPCircularBuffer/TPCircularBuffer.c -o build/obj/TPCircularBuffer.o
if [ "${1:-}" = "core" ]; then echo "core ok"; exit 0; fi
echo "== compiling Swift app"
swiftc -O -target $TARGET -sdk "$SDK" -parse-as-library -import-objc-header Core/EngineBridge.h \
  Sources/*.swift build/obj/*.o \
  "$FF/lib/libavformat.a" "$FF/lib/libavcodec.a" "$FF/lib/libswresample.a" "$FF/lib/libavutil.a" -lc++ -lz -lbz2 -liconv \
  -framework CoreAudio -framework AudioToolbox -framework AVFoundation -framework AppKit -framework SwiftUI -framework ServiceManagement \
  -o build/SixOut
echo "== bundling"
APP=build/SixOut.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/SixOut "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
cp -R Resources/voices "$APP/Contents/Resources/"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/" || true
# stable local identity (tools/make-signing-identity.sh) so macOS permissions survive rebuilds; ad-hoc otherwise
codesign -s "SixOut Dev" --force --deep "$APP" 2>/dev/null || codesign -s - --force --deep "$APP" >/dev/null 2>&1
echo "built $APP"
