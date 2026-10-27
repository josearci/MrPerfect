#!/bin/bash
# Builds MrPerfect.app, signs it, installs it to ~/Applications and launches it.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
APP="$HOME/Applications/MrPerfect.app"

osascript -e 'quit app "MrPerfect"' 2>/dev/null || true  # a clean quit also closes the Gemma SSH tunnel
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/MrPerfect "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"

# A stable signing identity keeps the Accessibility grant and Keychain access across rebuilds.
# Ad-hoc ("-") works too, but macOS will ask for Accessibility again after every build.
ID=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')
codesign --force --sign "${ID:--}" "$APP"
echo "Installed $APP (signed: ${ID:-ad-hoc})"
open "$APP"
