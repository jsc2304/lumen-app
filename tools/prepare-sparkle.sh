#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
version=2.10.1
digest=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27
archive="build/Sparkle-$version.tar.xz"
mkdir -p build
if [ ! -f "$archive" ]; then
    download=$(mktemp build/sparkle-download.XXXXXX)
    trap 'rm -f "$download"' EXIT
    curl --fail --silent --show-error --location --proto '=https' \
        "https://github.com/sparkle-project/Sparkle/releases/download/$version/Sparkle-$version.tar.xz" \
        --output "$download"
    printf '%s  %s\n' "$digest" "$download" | shasum -a 256 --check --status
    mv "$download" "$archive"
fi
printf '%s  %s\n' "$digest" "$archive" | shasum -a 256 --check
staging=$(mktemp -d build/sparkle.XXXXXX)
trap 'rm -rf "$staging"' EXIT
tar -xf "$archive" -C "$staging"
rm -rf build/sparkle
mv "$staging" build/sparkle
