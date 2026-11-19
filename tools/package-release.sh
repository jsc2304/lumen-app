#!/bin/sh
# Produce a signed Sparkle appcast and ZIP from a built Lumen.app.
set -eu

if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then
    printf 'Usage: %s Lumen.app ARCHIVE_HTTPS_URL OUTPUT_DIR [SPARKLE_KEY_ACCOUNT]\n' "$0" >&2
    exit 2
fi

APP=$1
ARCHIVE_URL=$2
OUT=$3
ACCOUNT=${4:-ed25519}
TOOLS=$(cd "$(dirname "$0")/../build/sparkle/bin" && pwd)
PLIST="$APP/Contents/Info.plist"

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

[ "$(basename "$APP")" = Lumen.app ] || fail "Expected a Lumen.app bundle."
codesign --verify --deep --strict "$APP"
VERSION=$(plutil -extract CFBundleShortVersionString raw "$PLIST")
BUILD=$(plutil -extract CFBundleVersion raw "$PLIST")
BUNDLE_ID=$(plutil -extract CFBundleIdentifier raw "$PLIST")
MIN_OS=$(plutil -extract LSMinimumSystemVersion raw "$PLIST")
FEED_URL=$(plutil -extract SUFeedURL raw "$PLIST")
PUBLIC_KEY=$(plutil -extract SUPublicEDKey raw "$PLIST")
KEYCHAIN_PUBLIC_KEY=$("$TOOLS/generate_keys" --account "$ACCOUNT" -p)
[ -n "$PUBLIC_KEY" ] && [ "$PUBLIC_KEY" = "$KEYCHAIN_PUBLIC_KEY" ] ||
    fail "The Sparkle signing key does not match the public key embedded in Lumen.app."

ARCHIVE=$(python3 - "$ARCHIVE_URL" <<'PY'
import re
import sys
from urllib.parse import urlsplit

url = urlsplit(sys.argv[1])
name = url.path.rsplit("/", 1)[-1]
if (
    url.scheme != "https"
    or not url.hostname
    or url.username is not None
    or url.query
    or url.fragment
    or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*\.zip", name)
):
    sys.exit("Provide a direct HTTPS URL ending in a release ZIP filename.")
print(name)
PY
)

mkdir -p "$OUT"
for destination in "$OUT/$ARCHIVE" "$OUT/appcast.xml"; do
    if [ -e "$destination" ] || [ -L "$destination" ]; then
        fail "Destination already exists: $destination"
    fi
done
STAGING=$(mktemp -d "$OUT/.package.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
trap 'exit 1' HUP INT TERM
ditto -c -k --sequesterRsrc --keepParent "$APP" "$STAGING/$ARCHIVE"
SIGNATURE=$("$TOOLS/sign_update" --account "$ACCOUNT" -p "$STAGING/$ARCHIVE")
"$TOOLS/sign_update" --account "$ACCOUNT" --verify "$STAGING/$ARCHIVE" "$SIGNATURE"

python3 - "$STAGING" "$ARCHIVE" "$ARCHIVE_URL" "$VERSION" "$BUILD" "$BUNDLE_ID" "$MIN_OS" "$FEED_URL" "$SIGNATURE" <<'PY'
import sys
from pathlib import Path
from xml.etree import ElementTree as ET

staging, archive, url, version, build, bundle_id, minimum_os, feed_url, signature = sys.argv[1:]
staging = Path(staging)
sparkle = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", sparkle)

rss = ET.Element("rss", {"version": "2.0"})
channel = ET.SubElement(rss, "channel")
ET.SubElement(channel, "title").text = "Lumen stable updates"
ET.SubElement(channel, "description").text = "Updates for the Lumen macOS launcher."
ET.SubElement(channel, "link").text = feed_url
ET.SubElement(channel, f"{{{sparkle}}}bundleIdentifier").text = bundle_id
item = ET.SubElement(channel, "item")
ET.SubElement(item, "title").text = f"Lumen {version}"
ET.SubElement(item, f"{{{sparkle}}}version").text = build
ET.SubElement(item, f"{{{sparkle}}}shortVersionString").text = version
ET.SubElement(item, f"{{{sparkle}}}minimumSystemVersion").text = ".".join((minimum_os.split(".") + ["0", "0"])[:3])
ET.SubElement(item, "enclosure", {
    "url": url,
    f"{{{sparkle}}}edSignature": signature,
    "length": str((staging / archive).stat().st_size),
    "type": "application/octet-stream",
})
tree = ET.ElementTree(rss)
ET.indent(tree)
tree.write(staging / "appcast.xml", encoding="utf-8", xml_declaration=True)
PY

"$TOOLS/sign_update" --account "$ACCOUNT" "$STAGING/appcast.xml"
"$TOOLS/sign_update" --account "$ACCOUNT" --verify "$STAGING/appcast.xml"

# Hard links fail atomically if another invocation already produced these names.
ln -h "$STAGING/$ARCHIVE" "$OUT/$ARCHIVE" || fail "The ZIP destination already exists."
if ! ln -h "$STAGING/appcast.xml" "$OUT/appcast.xml"; then
    rm "$OUT/$ARCHIVE"
    fail "The appcast destination already exists."
fi
printf '%s\n' "$OUT/$ARCHIVE" "$OUT/appcast.xml"
