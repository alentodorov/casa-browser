#!/bin/bash
# Builds Casa.app into ~/Applications (no Xcode project needed), like the widgets.
# libghostty comes from vendor/GhosttyKit.xcframework (see vendor/README.md); its resources
# (terminfo, themes, shell integration) go into the bundle in Ghostty.app's own layout, which is
# where libghostty looks for them relative to the executable.
set -e
cd "$(dirname "$0")"
APP="${CASA_APP:-$HOME/Applications/Casa.app}"   # CASA_APP=dist/Casa.app CASA_SIGN=- ./build.sh for a build to hand out
KIT="vendor/GhosttyKit.xcframework/macos-arm64"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 src/*.swift \
  -I "$KIT/Headers" -L "$KIT" -lghostty-internal -lc++ -lsqlite3 \
  -framework AppKit -framework WebKit -framework Metal -framework MetalKit -framework CoreText \
  -framework CoreVideo -framework QuartzCore -framework Carbon -framework IOSurface \
  -framework UniformTypeIdentifiers -framework CoreGraphics -framework Foundation -framework Security \
  -o "$APP/Contents/MacOS/casa"

rsync -a --delete vendor/ghostty-share/ghostty/ "$APP/Contents/Resources/ghostty/"
rsync -a --delete vendor/ghostty-share/terminfo/ "$APP/Contents/Resources/terminfo/"
cp vendor/LICENSE-ghostty "$APP/Contents/Resources/ghostty/LICENSE"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.alentodorov.casa</string>
  <key>CFBundleName</key><string>Casa</string>
  <key>CFBundleDisplayName</key><string>Casa</string>
  <key>CFBundleExecutable</key><string>casa</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>LSUIElement</key><false/>
  <key>CFBundleURLTypes</key>
  <array><dict>
    <key>CFBundleURLName</key><string>Web URL</string>
    <key>CFBundleURLSchemes</key><array><string>http</string><string>https</string></array>
  </dict></array>
  <key>CFBundleDocumentTypes</key>
  <array><dict>
    <key>CFBundleTypeName</key><string>HTML document</string>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>LSItemContentTypes</key><array><string>public.html</string></array>
  </dict></array>
</dict></plist>
PLIST
# Signed with the Apple Development certificate when there is one, so macOS keeps Casa's
# Accessibility permission (for the key swap, src/KeySwap.swift) across rebuilds; ad-hoc otherwise
IDENTITY=${CASA_SIGN:-$(security find-identity -v -p codesigning | awk '/Apple Development/ { print $2; exit }')}
codesign -s "${IDENTITY:--}" -f "$APP"
echo "Built $APP"
