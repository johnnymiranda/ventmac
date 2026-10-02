#!/bin/bash
# Build release dependencies for the app's deployment target, rather than the
# newer deployment targets in locally installed Homebrew bottles.
set -euo pipefail
cd "$(dirname "$0")/.."

CODEC_ROOT="$PWD/.build/codecs-macos13"
CODEC_PREFIX="$CODEC_ROOT/install"
mkdir -p "$CODEC_ROOT" "$CODEC_PREFIX/licenses"
export MACOSX_DEPLOYMENT_TARGET=13.0

build_codec() {
    local name="$1" version="$2" checksum="$3"
    shift 3
    local archive="$CODEC_ROOT/$name-$version.tar.gz"
    local stamp="$CODEC_PREFIX/.$name-$version-$checksum"
    [ ! -f "$stamp" ] || return 0
    local release_dir="$name"
    if [ "$name" = speexdsp ]; then release_dir=speex; fi
    curl --fail --location --retry 3 --max-time 120 \
        "https://ftp.osuosl.org/pub/xiph/releases/$release_dir/$name-$version.tar.gz" \
        -o "$archive"
    local actual
    actual=$(shasum -a 256 "$archive" | awk '{print $1}')
    [ "$actual" = "$checksum" ] || { echo "Checksum mismatch for $name" >&2; exit 1; }
    tar -xzf "$archive" -C "$CODEC_ROOT"
    (
        cd "$CODEC_ROOT/$name-$version"
        CFLAGS="-O2 -mmacosx-version-min=13.0" LDFLAGS="-mmacosx-version-min=13.0" \
            ./configure --prefix="$CODEC_PREFIX" --disable-static --enable-shared "$@"
        make -j "$(sysctl -n hw.ncpu)"
        make install
        cp COPYING "$CODEC_PREFIX/licenses/$name.txt"
    )
    touch "$stamp"
}

build_codec speex 1.2.1 4b44d4f2b38a370a2d98a78329fefc56a0cf93d1c1be70029217baae6628feea --disable-binaries
build_codec speexdsp 1.2.1 8c777343e4a6399569c72abc38a95b24db56882c83dbdb6c6424a5f4aeb54d3d --disable-examples
build_codec opus 1.6.1 6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1 --disable-extra-programs --disable-doc
