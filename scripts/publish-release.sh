#!/bin/bash
# Signs the draft that CI made for a tag, publishes it and updates the
# Homebrew cask. Needs the release key in the keychain.
#   scripts/publish-release.sh v1.2.5
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="armamut/md-quicklook"
tag="${1:?usage: publish-release.sh vX.Y.Z}"
version="${tag#v}"
zip="MD-QuickLook-$version.zip"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

[ "$(gh release view "$tag" --repo "$REPO" --json isDraft --jq .isDraft)" = true ] \
    || { echo "$tag is not a draft release." >&2; exit 1; }
gh release download "$tag" --repo "$REPO" --pattern "$zip" --dir "$work"
swift "$ROOT/scripts/release-key.swift" sign "$work/$zip"
gh release upload "$tag" "$work/$zip.sig" --repo "$REPO"
gh release edit "$tag" --repo "$REPO" --draft=false --latest

sha="$(shasum -a 256 "$work/$zip" | cut -d' ' -f1)"
gh repo clone armamut/homebrew-tap "$work/tap" -- --quiet
cd "$work/tap"
sed -i '' -e "s/^  version \".*\"/  version \"$version\"/" -e "s/^  sha256 \".*\"/  sha256 \"$sha\"/" Casks/md-quicklook.rb
git commit -qam "md-quicklook $version"
git push -q
echo "Published $tag"
