#!/bin/bash
set -eu
cd "$(dirname "$0")"
app="AltHome Mac.app"
bundle="$app/Contents"
mkdir -p "$bundle/MacOS" "$bundle/Resources"
xcrun --sdk macosx swiftc -swift-version 5 -O -target arm64-apple-macos13.0 Source/*.swift -o "$bundle/MacOS/AltHomeMac"
cp Info.plist "$bundle/Info.plist"
cp LICENSE "$bundle/Resources/LICENSE"
# Keep Accessibility grants valid across local rebuilds with the same development identity.
identity=${ALTHOME_SIGN_IDENTITY:-${TASKSHELF_SIGN_IDENTITY:-}}
if [ -z "$identity" ]; then
    identity=$(security find-identity -v -p codesigning | awk '/"Apple Development:/ { key=$2; n++ } END { if (n == 1) print key }')
fi
codesign --force --sign "${identity:--}" "$app"
