#!/bin/zsh
# Build BCKUP.app (release) into ./build
set -e
cd "$(dirname "$0")"
swift build -c release
APP=build/BCKUP.app
rm -rf build/Amanin.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/BCKUP "$APP/Contents/MacOS/BCKUP"

if [ ! -f build/AppIcon.icns ]; then
  ICONSET=build/AppIcon.iconset
  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  swift tools/make_icon.swift build/icon_1024.png
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon_1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) build/icon_1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Bundle rclone so the app works on Macs without it (rclone is MIT licensed).
RCLONE_SRC="${RCLONE_BIN:-$(command -v rclone || true)}"
if [ -n "$RCLONE_SRC" ]; then
  cp "$(readlink -f "$RCLONE_SRC")" "$APP/Contents/Resources/rclone"
  chmod 755 "$APP/Contents/Resources/rclone"
  echo "rclone dibundel: $("$APP/Contents/Resources/rclone" version | head -1)"
else
  echo "PERINGATAN: rclone tidak ditemukan, app dibuat tanpa rclone bawaan."
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>BCKUP</string>
  <key>CFBundleDisplayName</key><string>BCKUP</string>
  <key>CFBundleIdentifier</key><string>local.bckup.app</string>
  <key>CFBundleExecutable</key><string>BCKUP</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.photography</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDocumentTypes</key>
  <array><dict>
    <key>CFBundleTypeName</key><string>Card, folder or files</string>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>LSHandlerRank</key><string>Alternate</string>
    <key>LSItemContentTypes</key><array><string>public.folder</string><string>public.volume</string><string>public.item</string></array>
  </dict></array>
  <key>NSDownloadsFolderUsageDescription</key><string>Sort downloads lists your recent downloads so you can copy them into a project folder. Nothing is moved unless you choose to.</string>
  <key>NSDesktopFolderUsageDescription</key><string>Sort downloads can list files on the Desktop so you can copy them into a project folder.</string>
  <key>NSAppleEventsUsageDescription</key><string>BCKUP asks Finder to open the card and its destination folder side by side. Finder is never asked to change or delete anything.</string>
  <key>NSRemovableVolumesUsageDescription</key><string>BCKUP reads camera cards to copy them. Nothing on a card is ever changed.</string>
  <key>NSHumanReadableCopyright</key><string>Made for personal use</string>
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP"
echo "Selesai: $(pwd)/$APP"
