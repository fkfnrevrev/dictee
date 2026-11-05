#!/bin/zsh
# Compile Emile et l'installe dans /Applications.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Emile.app
rm -rf build
mkdir -p "$APP/Contents/MacOS"
swiftc -O -swift-version 5 -target arm64-apple-macos13.0 main.swift -o "$APP/Contents/MacOS/Emile"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - --identifier com.martinkrotoff.dictee "$APP"

# Ferme aussi l'ancienne version, qui s'appelait Dictee.
for name in Dictee Emile; do
    if pgrep -x "$name" >/dev/null; then
        osascript -e "quit app \"$name\"" 2>/dev/null || true
    fi
done
rm -rf /Applications/Dictee.app /Applications/Emile.app
cp -R "$APP" /Applications/Emile.app
echo "Installe : /Applications/Emile.app"
