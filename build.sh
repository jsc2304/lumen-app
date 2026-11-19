#!/bin/sh
# Runs the logic self-check, builds Lumen.app and installs it to ~/Applications by default.
# Signs with the "NotchShelf Dev" certificate (a self-signed code-signing identity in the login keychain)
# when it exists, so macOS keeps the Accessibility grant and Keychain access across rebuilds. Without it
# the build is ad-hoc signed and every rebuild has to be granted Accessibility again.
set -e
case "$#:${1-}" in
    0:|1:--build-only) ;;
    *) printf 'Usage: %s [--build-only]\n' "$0" >&2; exit 2 ;;
esac
cd "$(dirname "$0")"
mkdir -p build
./check.sh
APP=build/Lumen.app
if [ -n "${LUMEN_SIGN_IDENTITY:-}" ]; then
    IDENTITY=$LUMEN_SIGN_IDENTITY
else
    IDENTITY="NotchShelf Dev"
    security find-certificate -c "$IDENTITY" >/dev/null 2>&1 || IDENTITY=-
fi
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/"
cp AppIcon.icns "$APP/Contents/Resources/"
BUILD_MODE=${1-}
MINIMUM_OS=$(plutil -extract LSMinimumSystemVersion raw "$APP/Contents/Info.plist")
# A public verification key enables the stable feed unless a test feed is provided.
if [ -n "${LUMEN_UPDATE_PUBLIC_KEY:-}" ] && [ -z "${LUMEN_UPDATE_FEED:-}" ]; then
    LUMEN_UPDATE_FEED=https://github.com/jsc2304/lumen-app/releases/latest/download/appcast.xml
fi
# Keep unconfigured source builds independent of the download and signing keys.
if [ -n "${LUMEN_UPDATE_FEED:-}${LUMEN_UPDATE_PUBLIC_KEY:-}" ]; then
    case "${LUMEN_UPDATE_FEED:-}" in
        https://?*) ;;
        *) printf '%s\n' 'Set LUMEN_UPDATE_FEED to an HTTPS appcast URL.' >&2; exit 2 ;;
    esac
    if ! printf '%s' "${LUMEN_UPDATE_PUBLIC_KEY:-}" | /usr/bin/grep -Eq '^[A-Za-z0-9+/]{43}=$'; then
        printf '%s\n' 'Set LUMEN_UPDATE_PUBLIC_KEY to the Sparkle Ed25519 public key.' >&2
        exit 2
    fi
    ./tools/prepare-sparkle.sh
    mkdir -p "$APP/Contents/Frameworks"
    ditto build/sparkle/Sparkle.framework "$APP/Contents/Frameworks/Sparkle.framework"
    cp build/sparkle/LICENSE "$APP/Contents/Resources/Sparkle-LICENSE"
    PLIST=$APP/Contents/Info.plist
    plutil -insert SUFeedURL -string "$LUMEN_UPDATE_FEED" "$PLIST"
    plutil -insert SUPublicEDKey -string "$LUMEN_UPDATE_PUBLIC_KEY" "$PLIST"
    plutil -insert SUVerifyUpdateBeforeExtraction -bool YES "$PLIST"
    plutil -insert SURequireSignedFeed -bool YES "$PLIST"
    plutil -insert SUSignedFeedFailureExpirationInterval -integer 0 "$PLIST"
    plutil -insert SUEnableAutomaticChecks -bool NO "$PLIST"
    plutil -insert SUAllowsAutomaticUpdates -bool NO "$PLIST"
    plutil -insert SUShowReleaseNotes -bool NO "$PLIST"
    set -- -F "$APP/Contents/Frameworks" -framework Sparkle \
        -Xlinker -rpath -Xlinker '@executable_path/../Frameworks'
else
    set --
fi
if [ -n "${LUMEN_UPDATE_FEED:-}" ]; then
    for arch in arm64 x86_64; do
        swiftc -O -swift-version 5 -target "$arch-apple-macos$MINIMUM_OS" "$@" *.swift -o "build/Lumen-$arch"
    done
    lipo -create build/Lumen-arm64 build/Lumen-x86_64 -output "$APP/Contents/MacOS/Lumen"
else
    swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos$MINIMUM_OS" *.swift -o "$APP/Contents/MacOS/Lumen"
fi
case "$IDENTITY" in
    'Developer ID Application:'*)
        if [ -n "${LUMEN_UPDATE_FEED:-}" ]; then
            SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
            VERSION="$SPARKLE/Versions/Current"
            for component in "$VERSION/Autoupdate" "$VERSION/Updater.app" "$VERSION"/XPCServices/*.xpc "$SPARKLE"; do
                codesign --force --options runtime --timestamp -s "$IDENTITY" "$component"
            done
        fi
        codesign --force --options runtime --timestamp -s "$IDENTITY" "$APP"
        ;;
    *) codesign --force -s "$IDENTITY" "$APP" ;;
esac
codesign --verify --deep --strict "$APP"
if [ "$BUILD_MODE" = "--build-only" ]; then
    exit 0
fi
pkill -x Lumen && sleep 1 || true
rm -rf ~/Applications/Lumen.app
cp -R "$APP" ~/Applications/
open ~/Applications/Lumen.app
