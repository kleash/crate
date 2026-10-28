#!/bin/bash
# Releases Crate: the universal app signed with the Developer ID and the hardened runtime, notarized and stapled, as
# build/Crate-<version>.zip, published as the GitHub release v<version>. The build workflow then updates the
# Homebrew cask.
#   scripts/release.sh             build, sign, notarize, publish
#   scripts/release.sh --dry-run   build, sign, notarize; don't publish
# One-time setup: Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ + ▸ Developer ID Application, then
#   xcrun notarytool store-credentials crate-notary --apple-id <Apple ID> --team-id <team ID>
# NOTARY_PROFILE names another notarytool profile.
set -euo pipefail
cd "$(dirname "$0")/.."

case "${1:-}" in
    "") publish=true ;;
    --dry-run) publish=false ;;
    *) echo "usage: $0 [--dry-run]" >&2; exit 2 ;;
esac
version=$(tr -d '[:space:]' < VERSION)
app=build/Crate.app
appex=$app/Contents/PlugIns/CrateQuickLook.appex
zip=build/Crate-$version.zip
profile=${NOTARY_PROFILE:-crate-notary}

if $publish; then
    [ -z "$(git status --porcelain)" ] || { echo "Commit your changes first: the release is built from HEAD." >&2; exit 1; }
    ! git rev-parse -q --verify "refs/tags/v$version" >/dev/null || { echo "v$version is already tagged: bump VERSION." >&2; exit 1; }
fi
identity=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -n 1)
[ -n "$identity" ] || { echo "No \"Developer ID Application\" identity in the Keychain: see the top of $0." >&2; exit 1; }
xcrun notarytool history --keychain-profile "$profile" >/dev/null \
    || { echo "No notarytool profile \"$profile\": see the top of $0." >&2; exit 1; }

./build.sh
# build.sh signs ad hoc; re-sign inside-out with the Developer ID, the hardened runtime and a secure timestamp.
codesign --force --options runtime --timestamp --entitlements Resources/CrateQuickLook.entitlements --sign "$identity" "$appex"
codesign --force --options runtime --timestamp --sign "$identity" "$app"
codesign --verify --deep --strict "$app"

rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"
echo "Notarizing (a few minutes)..."
xcrun notarytool submit "$zip" --keychain-profile "$profile" --wait
xcrun stapler staple "$app"
spctl --assess --type execute --verbose=2 "$app"
# The zip people download holds the stapled app, so it opens without a network check.
rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"
sha=$(shasum -a 256 "$zip" | cut -d' ' -f1)
echo "Built $zip: Developer ID signed, notarized and stapled. SHA-256: $sha"

if $publish; then
    git tag "v$version"
    git push origin "v$version"
    gh release create "v$version" "$zip" --title "Crate $version" --generate-notes --notes "SHA-256: \`$sha\`"
fi
