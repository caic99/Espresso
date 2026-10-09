#!/bin/bash
# Build Espresso and assemble a minimal .app bundle (menu bar app, no Dock icon).
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

GIT_VERSION="$( { git describe --tags --always 2>/dev/null || true; } | sed 's/^v//')"
VERSION="${ESPRESSO_VERSION:-${GIT_VERSION:-0.0.0}}"

APP=build/Espresso.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Espresso "$APP/Contents/MacOS/Espresso"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundlePackageType</key>      <string>APPL</string>
    <key>CFBundleExecutable</key>       <string>Espresso</string>
    <key>CFBundleIdentifier</key>       <string>com.chucai.espresso</string>
    <key>CFBundleName</key>             <string>Espresso</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key>           <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>   <string>13.0</string>
    <key>LSUIElement</key>              <true/>
    <key>CFBundleIconFile</key>         <string>AppIcon</string>
</dict>
</plist>
EOF

codesign --force -s - "$APP"
echo "✅ Built $APP (v${VERSION})"
echo "   Launch:         open $APP"
echo "   Start at login: System Settings → General → Login Items"
