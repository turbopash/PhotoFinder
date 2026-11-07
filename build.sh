#!/bin/zsh
# Сборка PhotoFinder.app (нужны только Command Line Tools: xcode-select --install)
set -e
cd "$(dirname "$0")"
APP=PhotoFinder.app
rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos14.0 \
  Sources/*.swift -o $APP/Contents/MacOS/PhotoFinder
cat > $APP/Contents/Info.plist <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>PhotoFinder</string>
  <key>CFBundleDisplayName</key><string>Поиск фото</string>
  <key>CFBundleIdentifier</key><string>local.photofinder</string>
  <key>CFBundleExecutable</key><string>PhotoFinder</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDevelopmentRegion</key><string>ru</string>
  <key>NSPhotoLibraryUsageDescription</key><string>Для поиска похожих снимков в медиатеке.</string>
</dict></plist>
PL
[ -f AppIcon.icns ] && cp AppIcon.icns $APP/Contents/Resources/
codesign --force --deep -s - $APP
echo "Готово: $(pwd)/$APP"
