#!/usr/bin/env bash
# Build an UNSIGNED .ipa for sideloading with SideStore / AltStore.
#
# The output is deliberately unsigned: SideStore re-signs it on device with the
# user's own Apple ID. Authentication takes place in the app's web view;
# no Safari extension or App Group is required.
set -euo pipefail

cd "$(dirname "$0")/.."
: "${DEVELOPER_DIR:=$(xcode-select -p)}"
export DEVELOPER_DIR

CONFIG="${1:-Release}"
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT
OUT="$PWD/build/PhotosBackup.ipa"

command -v xcodegen >/dev/null || { echo "xcodegen not found" >&2; exit 1; }
# Fail instead of silently compiling out continued background backup.
XCODE_MAJOR=$(xcodebuild -version | sed -n 's/^Xcode \([0-9]*\).*/\1/p')
if [ "${XCODE_MAJOR:-0}" -lt 26 ]; then
  echo "Xcode 26 or newer is required for continued background backup. Set DEVELOPER_DIR to a compatible Xcode installation." >&2
  exit 1
fi
xcodegen generate

xcodebuild -project PhotosBackup.xcodeproj -scheme PhotosBackup \
  -sdk iphoneos -configuration "$CONFIG" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  -derivedDataPath "$BUILD_DIR" build

APP="$BUILD_DIR/Build/Products/$CONFIG-iphoneos/PhotosBackup.app"
[ -d "$APP" ] || { echo "no .app at $APP" >&2; exit 1; }

STAGE="$BUILD_DIR/stage"
mkdir -p "$STAGE/Payload" "$PWD/build"
cp -R "$APP" "$STAGE/Payload/"
rm -f "$OUT"
( cd "$STAGE" && zip -qry "$OUT" Payload )

echo "Unsigned IPA: $OUT ($(du -h "$OUT" | cut -f1))"
echo "Install by opening it in SideStore; it signs with your Apple ID on device."
