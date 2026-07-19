#!/usr/bin/env bash

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="${PROJECT_PATH:-$ROOT_DIR/Hashy/Hashy.xcodeproj}"
SCHEME="${SCHEME:-Hashy}"
CONFIGURATION="${CONFIGURATION:-Release}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/build/unsigned-ios}"
DERIVED_DATA_DIR="$OUTPUT_DIR/DerivedData"
LOG_DIR="$OUTPUT_DIR/logs"
IPA_DIR="$OUTPUT_DIR/ipa"
PAYLOAD_DIR="$OUTPUT_DIR/Payload"

mkdir -p "$LOG_DIR" "$IPA_DIR"
rm -rf "$DERIVED_DATA_DIR" "$PAYLOAD_DIR"

exec > >(tee -a "$LOG_DIR/script.log") 2>&1

echo "== Hashy unsigned iOS build =="
echo "Started: $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
echo "Repository root: $ROOT_DIR"
echo "Project: $PROJECT_PATH"
echo "Scheme: $SCHEME"
echo "Configuration: $CONFIGURATION"
echo "Output: $OUTPUT_DIR"

echo "::group::Environment"
uname -a || true
sw_vers || true
xcode-select -p || true
xcodebuild -version || true
xcrun --sdk iphoneos --show-sdk-version || true
xcrun --sdk iphoneos --show-sdk-path || true
echo "::endgroup::"

echo "::group::Project and schemes"
set +e
xcodebuild -list -project "$PROJECT_PATH" 2>&1 | tee "$LOG_DIR/xcodebuild-list.log"
LIST_STATUS=${PIPESTATUS[0]}
set -e
if [[ $LIST_STATUS -ne 0 ]]; then
  echo "xcodebuild -list failed with status $LIST_STATUS"
fi
echo "::endgroup::"

echo "::group::Resolve Swift packages"
set +e
xcodebuild \
  -resolvePackageDependencies \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -clonedSourcePackagesDirPath "$OUTPUT_DIR/SourcePackages" \
  2>&1 | tee "$LOG_DIR/package-resolution.log"
RESOLVE_STATUS=${PIPESTATUS[0]}
set -e
if [[ $RESOLVE_STATUS -ne 0 ]]; then
  echo "Package resolution failed with status $RESOLVE_STATUS. Continuing to the build so the full failure is logged."
fi
echo "::endgroup::"

echo "::group::Build unsigned device app"
set +e
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  -clonedSourcePackagesDirPath "$OUTPUT_DIR/SourcePackages" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY='' \
  DEVELOPMENT_TEAM='' \
  clean build \
  2>&1 | tee "$LOG_DIR/xcodebuild.log"
BUILD_STATUS=${PIPESTATUS[0]}
set -e
echo "::endgroup::"

# Always collect build settings and useful diagnostics, even after failure.
echo "::group::Collect diagnostics"
set +e
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -showBuildSettings \
  CODE_SIGNING_ALLOWED=NO \
  2>&1 | tee "$LOG_DIR/build-settings.log"

find "$DERIVED_DATA_DIR" -type f \( -name '*.xcactivitylog' -o -name '*.dia' -o -name '*.log' \) \
  -print > "$LOG_DIR/diagnostic-files.txt" 2>/dev/null

if [[ -d "$DERIVED_DATA_DIR/Logs" ]]; then
  ditto -c -k --sequesterRsrc --keepParent "$DERIVED_DATA_DIR/Logs" "$LOG_DIR/DerivedData-Logs.zip" || true
fi
set -e
echo "::endgroup::"

if [[ $BUILD_STATUS -ne 0 ]]; then
  echo "Build failed with status $BUILD_STATUS. Logs were retained in $LOG_DIR."
  exit "$BUILD_STATUS"
fi

APP_PATH="$(find "$DERIVED_DATA_DIR/Build/Products" -maxdepth 3 -type d -name 'Hashy.app' -path '*iphoneos*' -print -quit)"
if [[ -z "$APP_PATH" || ! -d "$APP_PATH" ]]; then
  echo "Build reported success, but Hashy.app was not found."
  find "$DERIVED_DATA_DIR/Build/Products" -maxdepth 4 -print 2>/dev/null | tee "$LOG_DIR/build-products-tree.txt" || true
  exit 2
fi

echo "Found app: $APP_PATH"
rm -rf "$PAYLOAD_DIR"
mkdir -p "$PAYLOAD_DIR"
ditto "$APP_PATH" "$PAYLOAD_DIR/Hashy.app"

IPA_PATH="$IPA_DIR/Hashy-unsigned.ipa"
rm -f "$IPA_PATH"
(
  cd "$OUTPUT_DIR"
  /usr/bin/zip -qry "$IPA_PATH" Payload
)

# Also preserve the raw app bundle for diagnostics and alternative installation workflows.
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$IPA_DIR/Hashy-unsigned-app.zip"

/usr/bin/codesign -dvvv "$APP_PATH" > "$LOG_DIR/codesign-inspection.log" 2>&1 || true
/usr/bin/file "$APP_PATH/Hashy" > "$LOG_DIR/binary-file-info.log" 2>&1 || true
/usr/bin/du -sh "$APP_PATH" "$IPA_PATH" "$IPA_DIR/Hashy-unsigned-app.zip" | tee "$LOG_DIR/artifact-sizes.log"

cat > "$OUTPUT_DIR/build-result.txt" <<EOF
status=success
app_path=$APP_PATH
ipa_path=$IPA_PATH
configuration=$CONFIGURATION
sdk=iphoneos
scheme=$SCHEME
finished=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
EOF

echo "Unsigned IPA created: $IPA_PATH"
echo "Finished: $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
