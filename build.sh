#!/bin/zsh
# Compile Emile et l'installe dans /Applications.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Emile.app
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
swiftc -O -swift-version 5 -target arm64-apple-macos13.0 main.swift Prefs.swift Overlay.swift Settings.swift -o "$APP/Contents/MacOS/Emile"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - --identifier com.martinkrotoff.dictee "$APP"

# Ferme aussi l'ancienne version, qui s'appelait Dictee.
# SIGTERM : l'app se ferme proprement et arrete son moteur Whisper.
for name in Dictee Emile; do
    pkill -TERM -x "$name" 2>/dev/null || true
done
for _ in {1..30}; do
    pgrep -qx Emile || pgrep -qx Dictee || break
    sleep 0.1
done
pkill -x whisper-server 2>/dev/null || true
rm -rf /Applications/Dictee.app /Applications/Emile.app
cp -R "$APP" /Applications/Emile.app

# Ne garde qu'un seul Emile sur le Mac : la copie de compilation ne doit pas apparaitre dans Spotlight.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -u "$PWD/$APP" 2>/dev/null || true
rm -rf build
echo "Installe : /Applications/Emile.app"
