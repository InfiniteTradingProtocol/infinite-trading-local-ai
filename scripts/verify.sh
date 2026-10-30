#!/bin/bash
# Verify a downloaded Infinite Agent Manager DMG against this source tree.
#
#   git clone https://github.com/InfiniteTradingProtocol/infinite-local-ai && cd infinite-local-ai
#   git checkout v<version>                     # the tag the release was built from
#   bash scripts/verify.sh ~/Downloads/InfiniteAgentManager-<version>.dmg
#
# It prints the DMG's SHA-256 (compare it with the release page), then rebuilds the
# executable from this checkout and compares it, per architecture, with the one in
# the DMG. Both are normalized first: re-signed ad-hoc then unsigned (code
# signatures differ by signer) and LC_UUID zeroed (the linker randomizes it).
# A match needs the same Swift toolchain as the release (listed in its notes).
set -euo pipefail
cd "$(dirname "$0")/.."
dmg=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
work=$(mktemp -d)
trap 'hdiutil detach -quiet "$work/mnt" 2>/dev/null || true; rm -rf "$work"' EXIT

echo "DMG SHA-256:   $(shasum -a 256 "$dmg" | cut -d' ' -f1)"
hdiutil attach -nobrowse -readonly -mountpoint "$work/mnt" "$dmg" >/dev/null
shipped="$work/mnt/Infinite Agent Manager.app/Contents/MacOS/InfiniteAgentManager"
info="$work/mnt/Infinite Agent Manager.app/Contents/Resources/build-info.json"
[[ -f "$info" ]] && echo "Built from:    $(cat "$info")"
echo "Your toolchain: $(xcrun swiftc --version 2>&1 | head -1)"
echo "This checkout: $(git rev-parse --verify -q HEAD 2>/dev/null || echo 'not a git checkout')"

normalize() { # $1 binary slice → normalized SHA-256
	cp "$1" "$work/n" && codesign --force --sign - "$work/n" 2>/dev/null && codesign --remove-signature "$work/n"
	python3 -I scripts/normalize-macho.py "$work/n"
}

status=0
for arch in arm64 x86_64; do
	lipo -thin "$arch" "$shipped" -output "$work/shipped-$arch"
	xcrun swiftc -O -swift-version 5 -module-name InfiniteAgentManager -target "$arch-apple-macos13.0" \
		mac/Sources/*.swift -o "$work/InfiniteAgentManager-$arch"
	a=$(normalize "$work/shipped-$arch"); b=$(normalize "$work/InfiniteAgentManager-$arch")
	if [[ "$a" == "$b" ]]; then echo "✅ $arch: identical ($a)"; else echo "❌ $arch: differs (DMG $a, source $b)"; status=1; fi
done
[[ $status == 0 ]] && echo "The app in this DMG was built from this source." \
	|| echo "Mismatch: check you're on the release tag and using the toolchain listed in the release notes."
exit $status
