#!/bin/sh
set -eu
out="$1"
work="$2"
version="$3"
mkdir -p "$work/tmp"
export CARGO_TARGET_DIR="$work/target" TMPDIR="$work/tmp"
set -- --version "$version" --locked --no-default-features \
    --features rustls-tls-webpki-roots --root "$work/stage" --force --quiet
if [ -n "${CARGO_BUILD_TARGET:-}" ]; then
    set -- "$@" --target "$CARGO_BUILD_TARGET"
fi
cargo install librespot "$@"
cp "$work/stage/bin/librespot" "$out"
