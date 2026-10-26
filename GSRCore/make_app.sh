#!/bin/zsh
# Builds GSRApp and wraps it in a minimal .app bundle (ad-hoc signed) in ./build/GSR24M.app
set -e
cd "$(dirname "$0")"
VERSION=$(cat ../VERSION)
swift build -c release --product GSRApp
APP=build/GSR24M.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/GSRApp "$APP/Contents/MacOS/GSRApp"
(cd ../dicedump && clang -O1 -Wall -o dicedump dicedump.c -framework IOKit -framework CoreFoundation)
cp ../dicedump/dicedump "$APP/Contents/Resources/dicedump"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>GSRApp</string>
<key>CFBundleIdentifier</key><string>com.gsr24m.app</string>
<key>CFBundleName</key><string>GSR24M</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$VERSION</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PL
codesign --force --sign - "$APP"
echo "built $APP"
