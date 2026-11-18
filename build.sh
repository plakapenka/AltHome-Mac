#!/bin/bash
set -eu
cd "$(dirname "$0")"
bundle="TaskShelf.app/Contents"
mkdir -p "$bundle/MacOS"
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos13.0 Source/*.swift -o "$bundle/MacOS/TaskShelf"
cp Info.plist "$bundle/Info.plist"
# Keep Accessibility grants valid across local rebuilds with the same development identity.
identity=${TASKSHELF_SIGN_IDENTITY:-}
if [ -z "$identity" ]; then
    identity=$(security find-identity -v -p codesigning | awk '/"Apple Development:/ { key=$2; n++ } END { if (n == 1) print key }')
fi
codesign --force --sign "${identity:--}" TaskShelf.app
