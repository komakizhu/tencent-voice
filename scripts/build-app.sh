#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$PROJECT_DIR/dist/TencentVoiceMVP.app"
PRODUCT_NAME="TencentVoiceMVP"
SIGNING_IDENTITY="${CODESIGN_IDENTITY:-OneKeyIFlyVoice Local Code Signing v4}"

cd "$PROJECT_DIR"
rm -rf "$APP_DIR"

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
BIN_PATH="$BIN_DIR/$PRODUCT_NAME"
if [[ ! -x "$BIN_PATH" ]]; then
    echo "release binary not found: $BIN_PATH" >&2
    exit 1
fi

CURRENT_BUILD="$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$PROJECT_DIR/Resources/Info.plist")"
if [[ ! "$CURRENT_BUILD" =~ ^[0-9]+$ ]]; then
    echo "CFBundleVersion must be a non-negative integer: $CURRENT_BUILD" >&2
    exit 1
fi
NEXT_BUILD=$((CURRENT_BUILD + 1))
/usr/bin/plutil -replace CFBundleVersion -string "$NEXT_BUILD" "$PROJECT_DIR/Resources/Info.plist"
echo "Bundle build: $CURRENT_BUILD -> $NEXT_BUILD"

mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/$PRODUCT_NAME"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
if ! /usr/bin/security find-identity -v -p codesigning | rg -Fq "\"$SIGNING_IDENTITY\""; then
    echo "required signing identity not found: $SIGNING_IDENTITY" >&2
    echo "set CODESIGN_IDENTITY to an installed signing certificate" >&2
    exit 1
fi
codesign --force --deep --sign "$SIGNING_IDENTITY" "$APP_DIR" >/dev/null

echo "Built $APP_DIR"
