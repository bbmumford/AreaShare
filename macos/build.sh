#!/bin/bash
# Builds AreaShare.app, signs it, and with "install" copies it to
# /Applications and starts it.
#
#   ./build.sh            build and sign into the build directory
#   ./build.sh install    the same, then replace /Applications/AreaShare.app
#
# AREASHARE_VERSION       version to stamp into the app, such as 1.4.2 (default:
#                         the one in Resources/Info.plist).
# AREASHARE_UNIVERSAL     set to 1 to build for both Apple silicon and Intel.
# AREASHARE_BUILD_DIR     where to build (default: /private/tmp/areashare-build).
#                         Keep it outside cloud-synced folders.
# AREASHARE_SIGN_IDENTITY the code-signing identity to use. Defaults to the
#                         name in .signing-identity beside this script, if
#                         that file exists, and otherwise "AreaShare Local".
#                         Use "-" for an ad-hoc signature.
#
# The signature matters: macOS ties the Screen Recording permission to it. A
# local identity gives every build the same signature, so the permission
# carries over; with an ad-hoc signature it has to be granted again after
# every build.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd -P)"
build="${AREASHARE_BUILD_DIR:-/private/tmp/areashare-build}"
app="$build/AreaShare.app"

has_identity() {
    security find-identity -p codesigning | grep -q "\"$1\""
}

identity="${AREASHARE_SIGN_IDENTITY:-}"
if [ -z "$identity" ] && [ -f "$here/.signing-identity" ]; then
    identity="$(head -n 1 "$here/.signing-identity")"
fi
identity="${identity:-AreaShare Local}"
if [ "$identity" != "-" ] && ! has_identity "$identity"; then
    echo "error: signing identity \"$identity\" is not in the keychain." >&2
    echo "       Run Scripts/make-identity.sh once to create \"AreaShare Local\"," >&2
    echo "       or set AREASHARE_SIGN_IDENTITY=- for an ad-hoc signature." >&2
    exit 1
fi

flags=(-c release --package-path "$here" --scratch-path "$build")
if [ "${AREASHARE_UNIVERSAL:-}" = "1" ]; then
    flags+=(--arch arm64 --arch x86_64)
fi
swift build "${flags[@]}"
binary="$(swift build "${flags[@]}" --show-bin-path)/AreaShare"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/AreaShare"
cp "$here/Resources/Info.plist" "$app/Contents/Info.plist"
if [ -n "${AREASHARE_VERSION:-}" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $AREASHARE_VERSION" "$app/Contents/Info.plist"
fi

iconset="$build/AreaShare.iconset"
rm -rf "$iconset"
mkdir -p "$iconset"
swift "$here/Scripts/make-icon.swift" "$build/icon-1024.png"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$build/icon-1024.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$build/icon-1024.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AreaShare.icns"

codesign --force --sign "$identity" "$app"
codesign --verify --strict "$app"
echo "built and signed with \"$identity\": $app"

if [ "${1:-}" = "install" ]; then
    target="/Applications/AreaShare.app"
    osascript -e 'tell application id "app.areashare.mac" to quit' >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -x AreaShare >/dev/null || break
        sleep 0.5
    done
    rm -rf "$target"
    ditto "$app" "$target"
    codesign --verify --strict "$target"
    open "$target"
    echo "installed and started: $target"
fi
