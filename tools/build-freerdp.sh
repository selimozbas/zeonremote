#!/bin/bash
# Builds a small FreeRDP (libraries only, no clients, no ffmpeg / X11 /
# audio backends) for Zeon Remote's RDP support and installs it into a prefix
# that CMake finds with -DFREERDP_DIR=<prefix>.
#
# Usage: tools/build-freerdp.sh <prefix> [--with-sample-server]
#
# --with-sample-server also builds FreeRDP's sample server (sfreerdp-server),
# which tools/run-tests.sh uses to test the RDP client.
set -euo pipefail

FREERDP_VERSION=3.32.1
PREFIX="$(mkdir -p "${1:?usage: tools/build-freerdp.sh <prefix> [--with-sample-server]}" && cd "$1" && pwd)"
SAMPLE=OFF
[ "${2:-}" = "--with-sample-server" ] && SAMPLE=ON

WORK="${TMPDIR:-/tmp}/zv-freerdp-build"
if [ ! -d "$WORK/FreeRDP-$FREERDP_VERSION" ]; then
  mkdir -p "$WORK"
  git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$FREERDP_VERSION" \
    https://github.com/FreeRDP/FreeRDP "$WORK/FreeRDP-$FREERDP_VERSION"
fi

extra=()
if [ "$(uname)" = Darwin ]; then
  OPENSSL=$(brew --prefix openssl@3)
  extra+=(-DOPENSSL_ROOT_DIR="$OPENSSL" -DCMAKE_OSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-15.0}"
          -DCMAKE_INSTALL_NAME_DIR="$PREFIX/lib" -DWITH_MACAUDIO=OFF -DWITH_CLIENT_MAC=OFF)
else
  # Linux (development and tests only): no ICU needed
  extra+=(-DWITH_UNICODE_BUILTIN=ON)
fi

cmake -S "$WORK/FreeRDP-$FREERDP_VERSION" -B "$WORK/build" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DBUILD_SHARED_LIBS=ON -DBUILD_TESTING=OFF \
  -DWITH_CLIENT_COMMON=ON -DWITH_CLIENT=OFF -DWITH_CLIENT_SDL=OFF -DWITH_X11=OFF \
  -DWITH_CHANNELS=ON -DWITH_CLIENT_CHANNELS=ON \
  -DWITH_SERVER="$SAMPLE" -DWITH_SAMPLE="$SAMPLE" -DWITH_SHADOW=OFF -DWITH_PROXY=OFF \
  -DWITH_PLATFORM_SERVER=OFF -DWITH_SERVER_CHANNELS="$SAMPLE" \
  -DWITH_FFMPEG=OFF -DWITH_SWSCALE=OFF -DWITH_OPENH264=OFF -DWITH_CAIRO=OFF \
  -DWITH_OPUS=OFF -DWITH_FDK_AAC=OFF -DWITH_ALSA=OFF -DWITH_PULSE=OFF -DWITH_OSS=OFF \
  -DWITH_SNDIO=OFF -DWITH_CUPS=OFF -DWITH_FUSE=OFF -DWITH_PCSC=OFF -DWITH_SMARTCARD_PCSC=OFF \
  -DWITH_PKCS11=OFF -DWITH_KRB5=OFF -DWITH_SYSTEMD=OFF -DWITH_URIPARSER=OFF \
  -DWITH_JSON_DISABLED=ON -DWITH_CJSON=OFF -DWITH_AAD=OFF \
  -DWITH_WEBP=OFF -DWITH_PNG=OFF -DWITH_JPEG=OFF -DWITH_LODEPNG=OFF \
  -DWITH_MANPAGES=OFF -DWITH_WINPR_TOOLS=OFF -DWITH_CCACHE=OFF -DWITH_CLANG_FORMAT=OFF \
  -DWITH_RDTK="$SAMPLE" -DCHANNEL_URBDRC=OFF -DCHANNEL_TSMF=OFF \
  ${extra[@]+"${extra[@]}"} >/dev/null
cmake --build "$WORK/build"
cmake --install "$WORK/build" >/dev/null
echo "FreeRDP $FREERDP_VERSION installed in $PREFIX"
