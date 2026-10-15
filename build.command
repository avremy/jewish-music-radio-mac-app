#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo 'Xcode Command Line Tools are required. Run: xcode-select --install'
  read -r -p 'Press Return to close...'
  exit 1
fi
APP="$PWD/JewishMusic Stream.app"
CACHE_DIR="$PWD/.build-cache"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
mkdir -p "$CACHE_DIR/clang" "$CACHE_DIR/swift"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "Resources/JewishMusicStreamLogo.png" "$APP/Contents/Resources/JewishMusicStreamLogo.png"
cp "Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>JewishMusic Stream</string>
<key>CFBundleDisplayName</key><string>JewishMusic Stream</string>
<key>CFBundleIdentifier</key><string>com.local.jewishmusicstream.menubar</string>
<key>CFBundleExecutable</key><string>JewishMusicMenuBar</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleURLTypes</key><array><dict>
<key>CFBundleURLName</key><string>com.local.jewishmusicstream.menubar</string>
<key>CFBundleURLSchemes</key><array><string>jewishmusicstream</string></array>
</dict></array>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.0</string>
<key>CFBundleVersion</key><string>7</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoadsForMedia</key><true/></dict>
</dict></plist>
PLIST
if ! SDKROOT="$SDK_PATH" \
  CLANG_MODULE_CACHE_PATH="$CACHE_DIR/clang" \
  SWIFT_MODULECACHE_PATH="$CACHE_DIR/swift" \
  xcrun swiftc -parse-as-library -O -swift-version 5 \
    -target arm64-apple-macos14.0 \
    -module-cache-path "$CACHE_DIR/swift" \
    -sdk "$SDK_PATH" \
    -framework SwiftUI -framework AppKit -framework AVFoundation -framework ServiceManagement -framework Carbon \
    JewishMusicMenuBar.swift -o "$APP/Contents/MacOS/JewishMusicMenuBar"; then
  echo
  echo 'Build failed. If the message says the SDK is not supported by the compiler,'
  echo 'update or reinstall Xcode Command Line Tools, then run this file again.'
  exit 1
fi
codesign --force --deep --sign - "$APP"
echo "Built: $APP"
open "$APP"
