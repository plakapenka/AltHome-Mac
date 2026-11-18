#!/bin/bash
set -eu
cd "$(dirname "$0")"
bundle="TaskShelf.app/Contents"
mkdir -p "$bundle/MacOS"
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos13.0 Source/*.swift -o "$bundle/MacOS/TaskShelf"
cp Info.plist "$bundle/Info.plist"
codesign --force --sign - TaskShelf.app
