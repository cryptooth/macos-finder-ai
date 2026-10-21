#!/bin/bash
# Builds Finder AI.app and installs it into ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"

APP="Finder AI.app"
BIN="FinderAI"
OUT="build/$APP"

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"

echo "→ Compiling…"
swiftc -O -swift-version 5 \
  -target "$(uname -m)-apple-macos13.0" \
  main.swift -o "$OUT/Contents/MacOS/$BIN"

if [ -f AppIcon.png ]; then
  echo "→ Building icon…"
  ICONSET="build/AppIcon.iconset"
  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$OUT/Contents/Resources/AppIcon.icns"
fi

cat > "$OUT/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>      <string>com.kayhan.finderai</string>
    <key>CFBundleName</key>            <string>Finder AI</string>
    <key>CFBundleDisplayName</key>     <string>Finder AI</string>
    <key>CFBundleExecutable</key>      <string>FinderAI</string>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>1.0</string>
    <key>CFBundleVersion</key>         <string>1</string>
    <key>CFBundleDevelopmentRegion</key> <string>en</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Finder AI reads the front Finder window and the selected files.</string>
</dict>
</plist>
PLIST

echo "→ Signing (ad-hoc)…"
codesign --force --deep -s - "$OUT"

echo "→ Installing to ~/Applications…"
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/$APP" "$HOME/Applications/Claude Here.app"
cp -R "$OUT" "$HOME/Applications/"
touch "$HOME/Applications/$APP"   # refresh Finder's icon cache

echo "✓ Done: ~/Applications/$APP"
open -R "$HOME/Applications/$APP"
