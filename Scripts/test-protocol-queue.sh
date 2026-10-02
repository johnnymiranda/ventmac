#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

QUEUE_TEST_DIR=$(mktemp -d)
trap 'rm -rf "$QUEUE_TEST_DIR"' EXIT
clang -Wno-implicit-function-declaration -Wno-int-conversion \
    -Wno-incompatible-function-pointer-types -Wno-deprecated-non-prototype \
    -DNO_AUTOMAKE -DHAVE_SPEEX=1 -DHAVE_SPEEX_DSP=1 -DHAVE_OPUS=1 -DHAVE_OPUS_H=1 \
    -ISources/CVentrilo3 -ISources/CVentrilo3/include \
    $(pkg-config --cflags speex speexdsp opus) \
    Tests/ProtocolQueue/main.c Sources/CVentrilo3/libventrilo3.c \
    Sources/CVentrilo3/libventrilo3_message.c Sources/CVentrilo3/ventrilo3_handshake.c \
    $(pkg-config --libs speex speexdsp opus) -o "$QUEUE_TEST_DIR/queue-test"
"$QUEUE_TEST_DIR/queue-test"
