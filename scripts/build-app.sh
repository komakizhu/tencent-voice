#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRODUCT_NAME="TencentVoiceMVP"
SIGNING_IDENTITY="${CODESIGN_IDENTITY:-OneKeyIFlyVoice Local Code Signing v4}"
PACING_PRESET="${TVMVP_PACING_PRESET:-balanced}"
PUBLIC_RELEASE="${TVMVP_PUBLIC_RELEASE:-0}"
INFO_PLIST="$PROJECT_DIR/Resources/Info.plist"
BUNDLE_SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
BUNDLE_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")"

case "$PUBLIC_RELEASE" in
0|1)
    ;;
*)
    echo "TVMVP_PUBLIC_RELEASE must be 0 or 1" >&2
    exit 1
    ;;
esac

SWIFT_DEFINITIONS=()
case "$PACING_PRESET" in
balanced)
    ;;
responsive)
    SWIFT_DEFINITIONS=(-Xswiftc -DTVMVP_PACING_RESPONSIVE)
    ;;
silky)
    SWIFT_DEFINITIONS=(-Xswiftc -DTVMVP_PACING_SILKY)
    ;;
flowing)
    SWIFT_DEFINITIONS=(-Xswiftc -DTVMVP_PACING_FLOWING)
    ;;
flowing-a)
    SWIFT_DEFINITIONS=(-Xswiftc -DTVMVP_PACING_FLOWING_A)
    ;;
flowing-b)
    SWIFT_DEFINITIONS=(-Xswiftc -DTVMVP_PACING_FLOWING_B)
    ;;
flowing-c)
    SWIFT_DEFINITIONS=(-Xswiftc -DTVMVP_PACING_FLOWING_C)
    ;;
silky-a)
    SWIFT_DEFINITIONS=(-Xswiftc -DTVMVP_PACING_SILKY_A)
    ;;
silky-b)
    SWIFT_DEFINITIONS=(-Xswiftc -DTVMVP_PACING_SILKY_B)
    ;;
silky-c)
    SWIFT_DEFINITIONS=(-Xswiftc -DTVMVP_PACING_SILKY_C)
    ;;
blind-1)
    SWIFT_DEFINITIONS=(-Xswiftc -DTVMVP_PACING_BLIND_1)
    ;;
blind-2)
    SWIFT_DEFINITIONS=(-Xswiftc -DTVMVP_PACING_BLIND_2)
    ;;
blind-3)
    SWIFT_DEFINITIONS=(-Xswiftc -DTVMVP_PACING_BLIND_3)
    ;;
*)
    echo "unknown pacing preset: $PACING_PRESET" >&2
    exit 1
    ;;
esac

if [[ -n "${TVMVP_OUTPUT_APP:-}" ]]; then
    APP_DIR="$TVMVP_OUTPUT_APP"
elif [[ "$PACING_PRESET" == "balanced" ]]; then
    APP_DIR="$PROJECT_DIR/dist/Rime Voice.app"
else
    APP_DIR="$PROJECT_DIR/dist/presets/Rime Voice-$BUNDLE_SHORT_VERSION-build$BUNDLE_BUILD-$PACING_PRESET.app"
fi

mkdir -p "$PROJECT_DIR/dist"
DIST_ROOT="$(cd -P "$PROJECT_DIR/dist" && pwd)"
APP_PARENT="$(dirname "$APP_DIR")"
MISSING_PARENTS=()
while [[ ! -d "$APP_PARENT" ]]; do
    if (( ${#MISSING_PARENTS[@]} == 0 )); then
        MISSING_PARENTS=("$(basename "$APP_PARENT")")
    else
        MISSING_PARENTS=("$(basename "$APP_PARENT")" "${MISSING_PARENTS[@]}")
    fi
    NEXT_PARENT="$(dirname "$APP_PARENT")"
    if [[ "$NEXT_PARENT" == "$APP_PARENT" ]]; then
        echo "output app parent cannot be resolved: $APP_DIR" >&2
        exit 1
    fi
    APP_PARENT="$NEXT_PARENT"
done
APP_PARENT="$(cd -P "$APP_PARENT" && pwd)"
APP_NAME="$(basename "$APP_DIR")"
if [[ "$APP_NAME" == "." || "$APP_NAME" == ".." || "$APP_NAME" != *.app ]]; then
    echo "output app must be an .app bundle: $APP_DIR" >&2
    exit 1
fi
case "$APP_PARENT" in
    "$DIST_ROOT"|"$DIST_ROOT"/*)
        APP_DIR="$APP_PARENT"
        if (( ${#MISSING_PARENTS[@]} > 0 )); then
            for missing_parent in "${MISSING_PARENTS[@]}"; do
                APP_DIR="$APP_DIR/$missing_parent"
            done
        fi
        APP_DIR="$APP_DIR/$APP_NAME"
        ;;
    *)
        echo "output app must be inside $DIST_ROOT: $APP_DIR" >&2
        exit 1
        ;;
esac

DISPLAY_NAME="${TVMVP_DISPLAY_NAME:-Rime Voice}"

cd "$PROJECT_DIR"
rm -rf -- "$APP_DIR"

if (( ${#SWIFT_DEFINITIONS[@]} > 0 )); then
    swift build -c release "${SWIFT_DEFINITIONS[@]}"
else
    swift build -c release
fi
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
cp "$PROJECT_DIR/Resources/brand-kit-graphite/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
cp "$PROJECT_DIR/Resources/brand-kit-graphite/statusbar-matched.png" "$APP_DIR/Contents/Resources/statusbar-matched.png"
plutil -replace CFBundleDisplayName -string "$DISPLAY_NAME" "$APP_DIR/Contents/Info.plist"
if [[ "$PUBLIC_RELEASE" == "1" ]]; then
    plutil -replace RimeVoiceShowBuild -bool false "$APP_DIR/Contents/Info.plist"
else
    plutil -replace RimeVoiceShowBuild -bool true "$APP_DIR/Contents/Info.plist"
fi
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    codesign --force --deep --sign - "$APP_DIR" >/dev/null
else
    if ! /usr/bin/security find-identity -v -p codesigning | rg -Fq "\"$SIGNING_IDENTITY\""; then
        echo "required signing identity not found: $SIGNING_IDENTITY" >&2
        echo "set CODESIGN_IDENTITY to an installed signing certificate" >&2
        exit 1
    fi
    codesign --force --deep --sign "$SIGNING_IDENTITY" "$APP_DIR" >/dev/null
fi

echo "Built $APP_DIR (pacing: $PACING_PRESET)"
