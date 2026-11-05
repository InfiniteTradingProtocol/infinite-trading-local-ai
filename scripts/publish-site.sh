#!/bin/bash
# Copies a GitHub release's DMGs into the website and writes public/downloads/latest.json:
# the /local-ai page's download data and the app updater's site feed.
#   bash scripts/publish-site.sh v0.5.1 ~/infinite-trading-frontend
# Keeps only the given version's DMGs in public/downloads. Commit and deploy the site afterwards.
set -euo pipefail
cd "$(dirname "$0")/.."
tag="${1:?tag, e.g. v0.5.1}"; site="${2:?path to infinite-trading-frontend}"
repo="InfiniteTradingProtocol/infinite-local-ai"; out="$site/public/downloads"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
gh release download "$tag" -R "$repo" -p '*.dmg' -p SHA256SUMS -D "$tmp"
(cd "$tmp" && grep '\.dmg$' SHA256SUMS | shasum -a 256 -c -)
mkdir -p "$out" && rm -f "$out"/InfiniteAgentManager-*.dmg && cp "$tmp"/*.dmg "$out/"
commit=$(gh api "repos/$repo/commits/$tag" --jq .sha)
published=$(gh release view "$tag" -R "$repo" --json publishedAt --jq .publishedAt)
python3 -I - "$tmp" "$out/latest.json" "$tag" "$commit" "$published" CHANGELOG.md <<'PY'
import json, os, re, sys
tmp, dest, tag, commit, published, changelog = sys.argv[1:]
version = tag.lstrip("v")
sums = {l.split()[1]: l.split()[0] for l in open(os.path.join(tmp, "SHA256SUMS")) if l.strip().endswith(".dmg")}
text = open(changelog).read()
m = re.search(r"^## " + re.escape(version) + r"\b.*?$(.*?)(?=^## |\Z)", text, re.S | re.M)
arch = lambda f: "apple-silicon" if f.endswith("-apple-silicon.dmg") else "intel" if f.endswith("-intel.dmg") else "universal"
files = [{"arch": arch(f), "file": f, "url": "/downloads/" + f, "sha256": h,
          "size": os.path.getsize(os.path.join(tmp, f))} for f, h in sorted(sums.items())]
json.dump({"version": version, "tag": tag, "commit": commit, "publishedAt": published,
           "notes": (m.group(1).strip() if m else ""), "files": files}, open(dest, "w"), indent=2)
print(f"wrote {dest}: {version}, {len(files)} files")
PY
