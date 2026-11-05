#!/bin/zsh
# Compile Dictee et l'installe dans /Applications.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Dictee.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -swift-version 5 -target arm64-apple-macos13.0 main.swift -o "$APP/Contents/MacOS/Dictee"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - --identifier com.martinkrotoff.dictee "$APP"

osascript -e 'quit app "Dictee"' 2>/dev/null || true
rm -rf /Applications/Dictee.app
cp -R "$APP" /Applications/Dictee.app
echo "Installe : /Applications/Dictee.app"
