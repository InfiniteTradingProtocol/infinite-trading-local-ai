#!/bin/bash
# Builds "Infinite Agent Manager.app" (universal) and dist/InfiniteAgentManager-<version>.dmg.
# Only the current version lives in build/ and dist/; past releases are kept in "old versions/" (see CHANGELOG.md).
#   bash mac/build.sh                 ad-hoc signed (runs here; other Macs need right-click → Open)
#   DEVELOPER_ID="Developer ID Application: … (TEAM)" NOTARY_PROFILE=<notarytool keychain profile> bash mac/build.sh
#                                     signed + notarized + stapled, opens cleanly everywhere
set -euo pipefail
cd "$(dirname "$0")/.."
name="Infinite Agent Manager"
exe="InfiniteAgentManager"
version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" mac/Info.plist)
build="$PWD/build"
app="$build/$name.app"
rm -rf "$build"/*.app "$build/dmg" dist/*.dmg && mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" dist

# Icon: pad the round artwork onto a 1024 canvas so it sits like other macOS icons.
iconset="$build/AppIcon.iconset" && rm -rf "$iconset" && mkdir -p "$iconset"
/usr/bin/sips -z 860 860 assets/AppIcon-source.png --out "$build/icon-860.png" >/dev/null
/usr/bin/sips --padToHeightWidth 1024 1024 "$build/icon-860.png" --out "$build/icon-1024.png" >/dev/null
for size in 16 32 128 256 512; do
	/usr/bin/sips -z "$size" "$size" "$build/icon-1024.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
	/usr/bin/sips -z $((size * 2)) $((size * 2)) "$build/icon-1024.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
/usr/bin/iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"

for arch in arm64 x86_64; do
	/usr/bin/swiftc -O -swift-version 5 -target "$arch-apple-macos13.0" mac/Sources/*.swift -o "$build/$exe-$arch"
done
/usr/bin/lipo -create "$build/$exe-arm64" "$build/$exe-x86_64" -output "$app/Contents/MacOS/$exe"
cp mac/Info.plist "$app/Contents/Info.plist"
cp catalog/models.json "$app/Contents/Resources/"
/usr/bin/plutil -lint "$app/Contents/Info.plist" >/dev/null

if [[ -n "${DEVELOPER_ID:-}" ]]; then
	/usr/bin/codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$app"
else
	/usr/bin/codesign --force --sign - "$app"
fi
/usr/bin/codesign --verify --strict "$app"

dmg="dist/$exe-$version.dmg"
mkdir -p "$build/dmg" && /usr/bin/ditto "$app" "$build/dmg/$name.app"
ln -s /Applications "$build/dmg/Applications"
cp "$app/Contents/Resources/AppIcon.icns" "$build/dmg/.VolumeIcon.icns"
rm -f "$dmg"
/usr/bin/hdiutil create -quiet -volname "$name" -srcfolder "$build/dmg" -fs HFS+ -format UDZO -ov "$dmg"

if [[ -n "${DEVELOPER_ID:-}" ]]; then
	/usr/bin/codesign --force --timestamp --sign "$DEVELOPER_ID" "$dmg"
	if [[ -n "${NOTARY_PROFILE:-}" ]]; then
		/usr/bin/xcrun notarytool submit "$dmg" --keychain-profile "$NOTARY_PROFILE" --wait
		/usr/bin/xcrun stapler staple "$dmg"
	fi
fi
printf 'App: %s\nDMG: %s (%s)\n' "$app" "$PWD/$dmg" "$(du -h "$dmg" | cut -f1)"
