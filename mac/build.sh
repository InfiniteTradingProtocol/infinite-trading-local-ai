#!/bin/bash
# Builds "Infinite Agent Manager.app" (universal) and three DMGs in dist/: InfiniteAgentManager-<version>.dmg
# (universal), -apple-silicon.dmg (arm64 only) and -intel.dmg (x86_64 only).
# Only the current version lives in build/ and dist/; past releases are kept in "old versions/" (see CHANGELOG.md).
#
#   bash mac/build.sh             ad-hoc signed (what CI publishes, and what scripts/verify.sh rebuilds)
#   DEVELOPER_ID="Developer ID Application: … (TEAM)" NOTARY_PROFILE=<notarytool keychain profile> bash mac/build.sh
#                                 Developer ID signed + notarized + stapled
#
# The executable is reproducible: the same commit and the same Swift toolchain give the same
# bytes, except the random LC_UUID and the code signature (scripts/verify.sh normalizes both).
set -euo pipefail
cd "$(dirname "$0")/.."
name="Infinite Agent Manager"
exe="InfiniteAgentManager"
version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" mac/Info.plist)
build="$PWD/build"
app="$build/$name.app"
rm -rf "$build"/*.app "$build"/thin-* "$build/dmg" dist/*.dmg && mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" dist

# Icon: pad the round artwork onto a 1024 canvas so it sits like other macOS icons.
iconset="$build/AppIcon.iconset" && rm -rf "$iconset" && mkdir -p "$iconset"
/usr/bin/sips -z 860 860 assets/AppIcon-source.png --out "$build/icon-860.png" >/dev/null
/usr/bin/sips --padToHeightWidth 1024 1024 "$build/icon-860.png" --out "$build/icon-1024.png" >/dev/null
for size in 16 32 128 256 512; do
	/usr/bin/sips -z "$size" "$size" "$build/icon-1024.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
	/usr/bin/sips -z $((size * 2)) $((size * 2)) "$build/icon-1024.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
/usr/bin/iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"

# -module-name is explicit so the output path can't change mangled names in the binary.
for arch in arm64 x86_64; do
	xcrun swiftc -O -swift-version 5 -module-name "$exe" -target "$arch-apple-macos13.0" \
		mac/Sources/*.swift -o "$build/$exe-$arch"
done
/usr/bin/lipo -create "$build/$exe-arm64" "$build/$exe-x86_64" -output "$app/Contents/MacOS/$exe"
cp mac/Info.plist "$app/Contents/Info.plist"
cp catalog/models.json "$app/Contents/Resources/"
commit=$(git rev-parse --verify -q HEAD 2>/dev/null || echo unknown)
printf '{"version":"%s","commit":"%s","swift":"%s"}\n' "$version" "$commit" \
	"$(xcrun swiftc --version 2>&1 | head -1 | sed 's/"/\\"/g')" > "$app/Contents/Resources/build-info.json"
/usr/bin/plutil -lint "$app/Contents/Info.plist" >/dev/null

sign_app() { # $1 app bundle
	if [[ -n "${DEVELOPER_ID:-}" ]]; then
		/usr/bin/codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$1"
	else
		/usr/bin/codesign --force --sign - "$1"
	fi
	/usr/bin/codesign --verify --strict "$1"
}

make_dmg() { # $1 app bundle, $2 dmg path
	local stage="$build/dmg"
	rm -rf "$stage" && mkdir -p "$stage" && /usr/bin/ditto "$1" "$stage/$name.app"
	ln -s /Applications "$stage/Applications"
	cp "$1/Contents/Resources/AppIcon.icns" "$stage/.VolumeIcon.icns"
	/usr/bin/hdiutil create -quiet -volname "$name" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$2"
	if [[ -n "${DEVELOPER_ID:-}" ]]; then
		/usr/bin/codesign --force --timestamp --sign "$DEVELOPER_ID" "$2"
		if [[ -n "${NOTARY_PROFILE:-}" ]]; then
			xcrun notarytool submit "$2" --keychain-profile "$NOTARY_PROFILE" --wait
			xcrun stapler staple "$2"
		fi
	fi
	printf 'DMG: %s (%s) SHA-256 %s\n' "$PWD/$2" "$(du -h "$2" | cut -f1)" "$(shasum -a 256 "$2" | cut -d' ' -f1)"
}

# Universal (Apple Silicon + Intel), plus a single-architecture DMG for each (about the same size; the executable is small next to the icon and resources).
# The thin executables are byte-identical slices of the universal one.
sign_app "$app"
make_dmg "$app" "dist/$exe-$version.dmg"
for arch in arm64 x86_64; do
	label=$([[ $arch == arm64 ]] && echo apple-silicon || echo intel)
	thin="$build/thin-$arch/$name.app"
	rm -rf "$build/thin-$arch" && mkdir -p "$build/thin-$arch" && /usr/bin/ditto "$app" "$thin"
	/usr/bin/lipo -thin "$arch" "$app/Contents/MacOS/$exe" -output "$thin/Contents/MacOS/$exe"
	sign_app "$thin"
	make_dmg "$thin" "dist/$exe-$version-$label.dmg"
done
printf 'App: %s\n' "$app"
