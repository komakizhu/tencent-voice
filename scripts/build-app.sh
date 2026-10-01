#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRODUCT_NAME="TencentVoiceMVP"
SIGNING_IDENTITY="${CODESIGN_IDENTITY:-OneKeyIFlyVoice Local Code Signing v4}"
ALLOW_ADHOC_SIGNING="${TVMVP_ALLOW_ADHOC_SIGNING:-0}"
PACING_PRESET="${TVMVP_PACING_PRESET:-balanced}"
INFO_PLIST="$PROJECT_DIR/Resources/Info.plist"
CURRENT_BUILD="$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$INFO_PLIST")"
if [[ ! "$CURRENT_BUILD" =~ ^[0-9]+$ ]]; then
    echo "CFBundleVersion must be a non-negative integer: $CURRENT_BUILD" >&2
    exit 1
fi
NEXT_BUILD=$((CURRENT_BUILD + 1))

case "$ALLOW_ADHOC_SIGNING" in
0|1)
    ;;
*)
    echo "TVMVP_ALLOW_ADHOC_SIGNING must be 0 or 1" >&2
    exit 1
    ;;
esac

if [[ "$SIGNING_IDENTITY" == "-" && "$ALLOW_ADHOC_SIGNING" != "1" ]]; then
    echo "refusing to build an ad hoc-signed app for local use" >&2
    echo "use the stable local signing identity, or set TVMVP_ALLOW_ADHOC_SIGNING=1 for CI-only artifacts" >&2
    exit 1
fi

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
    APP_DIR="$PROJECT_DIR/dist/Rime Voice Build${NEXT_BUILD}.app"
else
    APP_DIR="$PROJECT_DIR/dist/presets/Rime Voice Build${NEXT_BUILD}-$PACING_PRESET.app"
fi

EXTERNAL_VOLUME="/Volumes/T7_1T"
EXTERNAL_CODEX_ROOT="$EXTERNAL_VOLUME/codex"
EXTERNAL_VOLUME_UUID="E70D0032-CFF1-499D-81A2-DA2A661FCAD5"
BUILD_ON_EXTERNAL=0
case "$APP_DIR" in
    "$EXTERNAL_CODEX_ROOT"/*) BUILD_ON_EXTERNAL=1 ;;
esac

if [[ "$BUILD_ON_EXTERNAL" == "1" ]]; then
    VOLUME_INFO="$(/usr/sbin/diskutil info -plist "$EXTERNAL_VOLUME")"
    ACTUAL_VOLUME_UUID="$(printf '%s' "$VOLUME_INFO" | /usr/bin/plutil -extract VolumeUUID raw -o - -)"
    FILESYSTEM_TYPE="$(printf '%s' "$VOLUME_INFO" | /usr/bin/plutil -extract FilesystemType raw -o - -)"
    WRITABLE_VOLUME="$(printf '%s' "$VOLUME_INFO" | /usr/bin/plutil -extract WritableVolume raw -o - -)"
    MOUNT_POINT="$(printf '%s' "$VOLUME_INFO" | /usr/bin/plutil -extract MountPoint raw -o - -)"
    if [[ "$ACTUAL_VOLUME_UUID" != "$EXTERNAL_VOLUME_UUID" || "$FILESYSTEM_TYPE" != "apfs" \
        || "$WRITABLE_VOLUME" != "true" || "$MOUNT_POINT" != "$EXTERNAL_VOLUME" ]]; then
        echo "refusing external build: $EXTERNAL_VOLUME is not the writable expected APFS volume" >&2
        exit 1
    fi
    for storage_path in "${TVMVP_SWIFTPM_SCRATCH_PATH:-}" "${TVMVP_SWIFTPM_CACHE_PATH:-}" \
        "${TVMVP_SWIFTPM_SECURITY_PATH:-}" "${TVMVP_BUILD_TMPDIR:-}"; do
        case "$storage_path" in
            "$EXTERNAL_CODEX_ROOT"/*) ;;
            *) echo "external builds require all SwiftPM caches and temporary files under $EXTERNAL_CODEX_ROOT" >&2; exit 1 ;;
        esac
    done
    SWIFTPM_SCRATCH_PATH="$TVMVP_SWIFTPM_SCRATCH_PATH"
    SWIFTPM_CACHE_PATH="$TVMVP_SWIFTPM_CACHE_PATH"
    SWIFTPM_SECURITY_PATH="$TVMVP_SWIFTPM_SECURITY_PATH"
    BUILD_TMPDIR="$TVMVP_BUILD_TMPDIR"
    for storage_path in "$SWIFTPM_SCRATCH_PATH" "$SWIFTPM_CACHE_PATH" "$SWIFTPM_SECURITY_PATH" "$BUILD_TMPDIR"; do
        if [[ ! -d "$storage_path" ]]; then
            echo "external build storage directory must already exist: $storage_path" >&2
            exit 1
        fi
        RESOLVED_STORAGE_PATH="$(cd -P "$storage_path" && pwd)"
        case "$RESOLVED_STORAGE_PATH" in
            "$EXTERNAL_CODEX_ROOT"/*) ;;
            *) echo "refusing storage path outside $EXTERNAL_CODEX_ROOT: $RESOLVED_STORAGE_PATH" >&2; exit 1 ;;
        esac
    done
    export TMPDIR="$BUILD_TMPDIR"
    SWIFTPM_STORAGE_ARGS=(
        --scratch-path "$SWIFTPM_SCRATCH_PATH"
        --cache-path "$SWIFTPM_CACHE_PATH"
        --security-path "$SWIFTPM_SECURITY_PATH"
        --manifest-cache local
        --disable-automatic-resolution
    )
else
    SWIFTPM_STORAGE_ARGS=()
fi

if [[ -d "$PROJECT_DIR/dist" ]]; then
    DIST_ROOT="$(cd -P "$PROJECT_DIR/dist" && pwd)"
elif [[ "$BUILD_ON_EXTERNAL" == "0" ]]; then
    mkdir -p "$PROJECT_DIR/dist"
    DIST_ROOT="$(cd -P "$PROJECT_DIR/dist" && pwd)"
else
    DIST_ROOT="$PROJECT_DIR/dist"
fi
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
if [[ "$APP_NAME" != *"Build${NEXT_BUILD}"*.app ]]; then
    echo "output app name must include Build${NEXT_BUILD}: $APP_NAME" >&2
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
    "$EXTERNAL_CODEX_ROOT"|"$EXTERNAL_CODEX_ROOT"/*)
        if [[ "$BUILD_ON_EXTERNAL" != "1" ]]; then
            echo "external app output must be requested under $EXTERNAL_CODEX_ROOT" >&2
            exit 1
        fi
        APP_DIR="$APP_PARENT"
        if (( ${#MISSING_PARENTS[@]} > 0 )); then
            for missing_parent in "${MISSING_PARENTS[@]}"; do
                APP_DIR="$APP_DIR/$missing_parent"
            done
        fi
        APP_DIR="$APP_DIR/$APP_NAME"
        ;;
    *)
        echo "output app must be inside $DIST_ROOT or $EXTERNAL_CODEX_ROOT: $APP_DIR" >&2
        exit 1
        ;;
esac

DISPLAY_NAME="${TVMVP_DISPLAY_NAME:-Rime Voice}"

cd "$PROJECT_DIR"
if [[ "$BUILD_ON_EXTERNAL" == "1" ]]; then
    if [[ -e "$APP_DIR" ]]; then
        echo "refusing to overwrite external app bundle: $APP_DIR" >&2
        exit 1
    fi
else
    rm -rf -- "$APP_DIR"
fi

if (( ${#SWIFT_DEFINITIONS[@]} > 0 )); then
    swift build -c release "${SWIFTPM_STORAGE_ARGS[@]+"${SWIFTPM_STORAGE_ARGS[@]}"}" "${SWIFT_DEFINITIONS[@]}"
else
    swift build -c release "${SWIFTPM_STORAGE_ARGS[@]+"${SWIFTPM_STORAGE_ARGS[@]}"}"
fi
BIN_DIR="$(swift build -c release "${SWIFTPM_STORAGE_ARGS[@]+"${SWIFTPM_STORAGE_ARGS[@]}"}" --show-bin-path)"
BIN_PATH="$BIN_DIR/$PRODUCT_NAME"
if [[ ! -f "$BIN_PATH" ]]; then
    echo "release binary not found: $BIN_PATH" >&2
    exit 1
fi
# Some shared workspace filesystems drop executable bits when Swift writes the
# binary. Restore it before the bundle is assembled so Finder can launch it.
chmod +x "$BIN_PATH"

/usr/bin/plutil -replace CFBundleVersion -string "$NEXT_BUILD" "$PROJECT_DIR/Resources/Info.plist"
echo "Bundle build: $CURRENT_BUILD -> $NEXT_BUILD"

mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/$PRODUCT_NAME"
chmod +x "$APP_DIR/Contents/MacOS/$PRODUCT_NAME"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$PROJECT_DIR/Resources/brand-kit-graphite/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
cp "$PROJECT_DIR/Resources/brand-kit-graphite/statusbar-matched.png" "$APP_DIR/Contents/Resources/statusbar-matched.png"
plutil -replace CFBundleDisplayName -string "$DISPLAY_NAME" "$APP_DIR/Contents/Info.plist"
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

codesign --verify --deep --strict "$APP_DIR"
if [[ "$SIGNING_IDENTITY" != "-" ]] \
    && /usr/bin/codesign -d -r- "$APP_DIR" 2>&1 | rg -q 'cdhash|adhoc'; then
    echo "stable signing identity did not produce a stable designated requirement" >&2
    exit 1
fi

echo "Built $APP_DIR (pacing: $PACING_PRESET)"
