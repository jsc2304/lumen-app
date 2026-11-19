# Releasing Lumen

The repository description is “Open apps, files and everyday tools from your keyboard.” Suggested topics are `macos`, `swift`, `appkit`, `launcher`, and `productivity`. Enable Issues and private vulnerability reporting.

## Publication checks

Keep personal records, real screenshots, internal plans, and release credentials outside the repository. The ignored `.private/` directory is available for local notes. If a path was already tracked, adding an ignore rule leaves it in Git history.

- Before committing, review `git diff --cached --name-status` and `git diff --cached`, inspect staged images, and run a secret scan.
- Before pushing, review the outgoing commits and their binary assets. Scan the outgoing commit range, including any release tag, for secrets. Check the first public commit from root.
- Compare the version in Settings, `Info.plist`, the changelog, the tag, and the published release. Stage the ZIP of the app bundle and the signed appcast as assets on the same release. Keep the EdDSA signing key dedicated to Lumen. Publish updates as app bundles in ZIP archives. Mark the current stable release as latest.
- On a clean test account, run the installed update check from an older signed build, confirm installation, and verify relaunch and data retention. Record both versions and release asset links under G14 in the [PRD](PRD.md).
- Check the released-state gates before publishing. Each public version tag needs a corresponding GitHub Release with matching changelog notes. Begin the public history with the first public version.

## Build and sign

Sparkle 2.10.1 handles the in-app check, download, installation and relaunch. Lumen verifies the signed appcast and the archive before extraction. The check runs from the menu bar at the user's request. A source build without a configured feed remains usable without Sparkle.

1. Run `./tools/prepare-sparkle.sh` to fetch the pinned distribution and verify its SHA-256. Audit the pinned version before release.
2. The stable feed is `https://github.com/jsc2304/lumen-app/releases/latest/download/appcast.xml`. For a pre-release test use a separate accessible HTTPS appcast and test signing key. Use a dedicated Sparkle account and run its `generate_keys --account lumen-release` once on the signing Mac. Keep the private key in Keychain and arrange a secure backup. Do not reuse a QA key in distribution.
3. Build a universal app with the feed, the public key and the Developer ID Application identity. Verify the version and build number in `Info.plist` before each release.

```sh
LUMEN_SIGN_IDENTITY=- \
LUMEN_UPDATE_PUBLIC_KEY="$(build/sparkle/bin/generate_keys --account lumen-release -p)" \
./build.sh --build-only
```

4. For a Developer ID distribution, archive the signed bundle with `ditto -c -k --keepParent build/Lumen.app build/Lumen-notary.zip` and submit it with `xcrun notarytool submit build/Lumen-notary.zip --keychain-profile PROFILE --wait`. Staple to the app with `xcrun stapler staple build/Lumen.app` and check it with `codesign --verify --deep --strict build/Lumen.app` and `spctl --assess --type execute --verbose build/Lumen.app`. Use the stapled bundle for packaging.
5. Produce the release ZIP and signed appcast together, then upload them without changing either signed file.

```sh
./tools/package-release.sh build/Lumen.app \
  'https://github.com/jsc2304/lumen-app/releases/download/v0.3.0/Lumen-0.3.0.zip' \
  build/release lumen-release
```

Stage the release with the version tag, both assets and matching changelog notes. For the stable feed, publish the intended release as latest. Test both asset URLs anonymously. Preserve older compatible offerings in a future aggregate feed if the minimum OS increases.


## Local verification

On 18.11.2026, Lumen 0.3.0 built for arm64 and x86_64 with macOS 26.0 as the minimum. The QA appcast and archive signatures verified. Modifying the feed content or archive caused verification to fail. On a second Mac, the manual update from 0.3.0-qa.1 (build 3) to 0.3.0 (build 4) installed and relaunched using a signed loopback feed. A second test via signed GitHub HTTPS assets installed 0.3.0-qa.2 (build 4) from 0.3.0-qa.1 (build 3), relaunched and retained existing data. The stable anonymous release URL remains to be verified.
