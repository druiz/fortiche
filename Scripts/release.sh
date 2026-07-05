#!/bin/bash
# Archive Fortiche and upload it to App Store Connect (TestFlight).
#
# Requires an App Store Connect API key (App Store Connect → Users & Access →
# Integrations → App Store Connect API → Team Keys; role: App Manager).
# Download the .p8 once and keep it at the default AuthKey location.
#
# Usage:
#   Scripts/release.sh <KEY_ID> <ISSUER_ID> [path/to/AuthKey_<KEY_ID>.p8]
#
# Notes:
# - Uses cloud signing (-allowProvisioningUpdates) — no local certs needed.
# - App Store *release* builds must be built with a non-beta Xcode/SDK;
#   TestFlight generally accepts beta-SDK builds during the beta cycle.
set -euo pipefail

KEY_ID="${1:?usage: release.sh <KEY_ID> <ISSUER_ID> [key.p8]}"
ISSUER_ID="${2:?usage: release.sh <KEY_ID> <ISSUER_ID> [key.p8]}"
KEY_PATH="${3:-$HOME/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8}"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app}"
cd "$(dirname "$0")/.."

ARCHIVE="build/Fortiche.xcarchive"

echo "==> Regenerating project"
xcodegen generate

echo "==> Archiving (cloud signing)"
xcodebuild archive \
  -project Fortiche.xcodeproj \
  -scheme Fortiche \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  -authenticationKeyID "$KEY_ID" \
  -authenticationKeyIssuerID "$ISSUER_ID" \
  -authenticationKeyPath "$KEY_PATH" \
  | grep -E 'error|warning: Signing|ARCHIVE' || true

echo "==> Uploading to App Store Connect"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist AppStore/ExportOptions.plist \
  -allowProvisioningUpdates \
  -authenticationKeyID "$KEY_ID" \
  -authenticationKeyIssuerID "$ISSUER_ID" \
  -authenticationKeyPath "$KEY_PATH"

echo "==> Done. Track processing in App Store Connect → TestFlight."
