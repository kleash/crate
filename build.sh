#!/bin/bash
# Builds build/Crate.app (with the Quick Look appex inside) and ad-hoc signs it.
#   ./build.sh           universal: arm64 + x86_64
#   ./build.sh --native  host architecture only (fast dev loop)
set -euo pipefail
cd "$(dirname "$0")"

case "${1:-}" in
    "") archs=(arm64 x86_64) ;;
    --native) archs=("$(uname -m)") ;;
    *) echo "usage: $0 [--native]" >&2; exit 2 ;;
esac

version=$(tr -d '[:space:]' < VERSION)
app=build/Crate.app
appex=$app/Contents/PlugIns/CrateQuickLook.appex

# `swift build --arch` needs Xcode's build system; per-triple builds + lipo work with CLT alone.
app_bins=()
appex_bins=()
for arch in "${archs[@]}"; do
    triple=$arch-apple-macosx13.1
    swift build -c release --triple "$triple"
    bin=$(swift build -c release --triple "$triple" --show-bin-path)
    app_bins+=("$bin/Crate")
    appex_bins+=("$bin/CrateQuickLook")
done

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$appex/Contents/MacOS"
lipo -create "${app_bins[@]}" -output "$app/Contents/MacOS/Crate"
lipo -create "${appex_bins[@]}" -output "$appex/Contents/MacOS/CrateQuickLook"
cp Resources/Crate-Info.plist "$app/Contents/Info.plist"
cp Resources/CrateQuickLook-Info.plist "$appex/Contents/Info.plist"
for plist in "$app/Contents/Info.plist" "$appex/Contents/Info.plist"; do
    plutil -replace CFBundleShortVersionString -string "$version" "$plist"
    plutil -replace CFBundleVersion -string "$version" "$plist"
done
if [ -f Resources/AppIcon.icns ]; then
    mkdir -p "$app/Contents/Resources"
    cp Resources/AppIcon.icns "$app/Contents/Resources/"
fi

# Sign inside-out: the appex with its sandbox entitlements, then the app (no --deep).
codesign --force --sign - --entitlements Resources/CrateQuickLook.entitlements "$appex"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
echo "Built $app $version (${archs[*]})"
