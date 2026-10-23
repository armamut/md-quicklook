#!/bin/bash
# Notarizes a Developer ID signed build and staples the ticket to the app.
#
#   NOTARY_PROFILE=md-quicklook scripts/notarize.sh "build/MD QuickLook.app"
#       (profile saved once with `xcrun notarytool store-credentials`)
#   APPLE_API_KEY=key.p8 APPLE_API_KEY_ID=… APPLE_API_ISSUER=… scripts/notarize.sh …
#       (App Store Connect API key, as on CI)
set -euo pipefail

APP="$1"
if [ -n "${NOTARY_PROFILE:-}" ]; then
    auth=(--keychain-profile "$NOTARY_PROFILE")
else
    auth=(--key "$APPLE_API_KEY" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER")
fi

zip="$(mktemp -d)/notarize.zip"
trap 'rm -rf "$(dirname "$zip")"' EXIT
ditto -c -k --keepParent "$APP" "$zip"

printf '\033[1;34m==>\033[0m %s\n' "Notarizing (this usually takes a few minutes)"
xcrun notarytool submit "$zip" "${auth[@]}" --wait --output-format json | tee "$zip.json"
if ! grep -q '"status" *: *"Accepted"' "$zip.json"; then
    id="$(grep -o '"id" *: *"[^"]*"' "$zip.json" | head -1 | cut -d'"' -f4)"
    [ -n "$id" ] && xcrun notarytool log "$id" "${auth[@]}" || true
    exit 1
fi

xcrun stapler staple "$APP"
spctl --assess --type execute --verbose "$APP"
