#!/bin/sh
# Compiles the app sources (without main.swift) together with checks/ and runs the self-checks.
# Builds into a private temp folder, so several checks can run at the same time.
set -e
cd "$(dirname "$0")"
OUT=$(mktemp -d)
swiftc -Onone -swift-version 5 -parse-as-library $(ls *.swift | grep -v '^main.swift$') checks/*.swift -o "$OUT/check"
"$OUT/check"
rm -rf "$OUT"
