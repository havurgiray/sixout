#!/bin/bash
# Rebuilds the minimal, patched static ffmpeg libraries used by SixOut (AC-3 + DTS encoders, S/PDIF framing).
# The DTS encoder carries Core/ffmpeg-dcaenc-lfe-history.patch (sub-channel history fix). Output: ffmpeg/install.
set -euo pipefail
cd "$(dirname "$0")"
VER=8.1
[ -f ffmpeg-$VER.tar.xz ] || curl -sSL -o ffmpeg-$VER.tar.xz https://ffmpeg.org/releases/ffmpeg-$VER.tar.xz
rm -rf ffmpeg-$VER && tar -xf ffmpeg-$VER.tar.xz
( cd ffmpeg-$VER && patch -p1 < ../../Core/ffmpeg-dcaenc-lfe-history.patch && \
  ./configure --prefix="$(pwd)/../install" --disable-everything --disable-autodetect --disable-doc --disable-x86asm \
    --enable-static --disable-shared --enable-encoder=dca,ac3 --enable-decoder=dca,ac3 --enable-muxer=spdif \
    --enable-demuxer=spdif --enable-protocol=file --enable-swresample --disable-programs --cc=clang \
    --extra-cflags="-target arm64-apple-macos14.2" --extra-ldflags="-target arm64-apple-macos14.2" && \
  make -j"$(sysctl -n hw.ncpu)" && make install )
rm -rf install/lib/pkgconfig install/share install/bin
echo "ffmpeg libraries installed into ffmpeg/install"
