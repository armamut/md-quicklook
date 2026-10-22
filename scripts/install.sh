#!/bin/bash
# Installs the latest MD QuickLook release into /Applications.
#   curl -fsSL https://raw.githubusercontent.com/armamut/md-quicklook/main/scripts/install.sh | bash
set -euo pipefail

REPO="armamut/md-quicklook"
APP="/Applications/MD QuickLook.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

url="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
    | grep -o '"browser_download_url": *"[^"]*\.zip"' | head -1 | cut -d'"' -f4)"
[ -n "$url" ] || { echo "Could not find a release download." >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
echo "Downloading $url"
curl -fsSL "$url" -o "$tmp/app.zip"
ditto -x -k "$tmp/app.zip" "$tmp"

pkill -x MDQuickLook 2>/dev/null || true
rm -rf "$APP"
ditto "$tmp/MD QuickLook.app" "$APP"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
"$LSREGISTER" -f -R "$APP"
open "$APP"
echo "Installed $APP"
