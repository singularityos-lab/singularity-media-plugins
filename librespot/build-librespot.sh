#!/bin/sh
set -eu
out="$1"
work="$2"
version="$3"
mkdir -p "$work/tmp"
export CARGO_TARGET_DIR="$work/target" TMPDIR="$work/tmp"
cargo install librespot --version "$version" --locked --no-default-features \
    --features rustls-tls-webpki-roots --root "$work/stage" --quiet
cp "$work/stage/bin/librespot" "$out"
