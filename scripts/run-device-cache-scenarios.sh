#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HARNESS_BUNDLE_ID="com.lucadias.MihonReader.PerformanceHarness"
NORMAL_BUNDLE_ID="com.lucadias.MihonReader"
RESULTS_DIR="${MIHONREADER_RESULTS_DIR:-${TMPDIR:-/tmp}/mihonreader-cache-$(date +%Y%m%d-%H%M%S)}"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mihonreader-cache.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

if [[ "$HARNESS_BUNDLE_ID" == "$NORMAL_BUNDLE_ID" ]]; then
    echo "Refusing to run with the normal app bundle identifier." >&2
    exit 2
fi

if [[ -e "$RESULTS_DIR" ]]; then
    echo "Results directory already exists; choose a new MIHONREADER_RESULTS_DIR." >&2
    exit 2
fi

DEVICE_JSON="$TMP_DIR/devices.json"
if ! xcrun devicectl list devices --json-output "$DEVICE_JSON" >/dev/null; then
    echo "CoreDevice could not enumerate devices; no provider request or app install was attempted." >&2
    exit 1
fi

python3 - "$DEVICE_JSON" "${MIHONREADER_DEVICE_UDID:-}" > "$TMP_DIR/device-id" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
requested = sys.argv[2]
devices = data.get("result", {}).get("devices", [])
ready = []
for device in devices:
    properties = device.get("properties", {})
    hardware = properties.get("hardware", device.get("hardwareProperties", {}))
    state = properties.get("state", device.get("deviceProperties", {}))
    connection = properties.get("connection", device.get("connectionProperties", {}))
    device_id = hardware.get("udid") or device.get("identifier")
    reality = hardware.get("reality")
    platform = hardware.get("platform")
    boot_state = state.get("bootState")
    connection_state = connection.get("state") or connection.get("tunnelState")
    pairing_state = connection.get("pairingState")
    is_ready = (
        reality == "physical"
        and platform == "iOS"
        and boot_state == "booted"
        and connection_state == "connected"
        and pairing_state in (None, "paired")
    )
    if is_ready and (not requested or requested == device_id):
        ready.append(device_id)

if len(ready) != 1:
    print("Connect and unlock exactly one paired, booted iPhone, or set MIHONREADER_DEVICE_UDID.", file=sys.stderr)
    sys.exit(1)
print(ready[0])
PY

IFS= read -r DEVICE_ID < "$TMP_DIR/device-id"
APPS_JSON="$TMP_DIR/apps.json"
if ! xcrun devicectl device info apps --device "$DEVICE_ID" --json-output "$APPS_JSON" >/dev/null; then
    echo "Could not read the installed app list; no provider request or app install was attempted." >&2
    exit 1
fi
python3 - "$APPS_JSON" "$NORMAL_BUNDLE_ID" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
apps = data.get("result", {}).get("apps", [])
if not any(app.get("bundleIdentifier") == sys.argv[2] for app in apps):
    print("The original MihonReader app was not found on this iPhone; stopping before install.", file=sys.stderr)
    sys.exit(1)
PY

PREFERENCES_PLIST="$TMP_DIR/original-preferences.plist"
if ! xcrun devicectl device copy from \
    --device "$DEVICE_ID" \
    --domain-type appDataContainer \
    --domain-identifier "$NORMAL_BUNDLE_ID" \
    --source "Library/Preferences/$NORMAL_BUNDLE_ID.plist" \
    --destination "$PREFERENCES_PLIST" \
    --quiet; then
    echo "Could not read source preferences; no provider request or app install was attempted." >&2
    exit 1
fi
python3 - "$PREFERENCES_PLIST" "$TMP_DIR/provider-id" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as stream:
    preferences = plistlib.load(stream)
provider = preferences.get("catalog_source") or preferences.get("catalog_last_source")
if not provider:
    pinned = preferences.get("pinned_sources", [])
    provider = pinned[0] if pinned else None
if provider != "nexustoons":
    print("Current or pinned source is not supported by this harness; no provider request was sent.", file=sys.stderr)
    sys.exit(1)
open(sys.argv[2], "w", encoding="utf-8").write(provider + "\n")
PY
IFS= read -r PROVIDER < "$TMP_DIR/provider-id"

case "$PROVIDER" in
    nexustoons)
        CATALOG_URL="https://nexustoons.com/api/mangas?page=1&limit=30&sortBy=views&sortOrder=desc"
        REFERER="https://nexustoons.com/"
        ;;
esac

CATALOG_JSON="$TMP_DIR/catalog.json"
HTTP_STATUS_FILE="$TMP_DIR/http-status"
curl --silent --show-error --connect-timeout 8 --max-time 20 \
    --user-agent 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1' \
    --header 'Accept: application/json, text/plain, */*' \
    --header 'Accept-Language: pt-BR,pt;q=0.9,en;q=0.8' \
    --header "Referer: $REFERER" \
    --output "$CATALOG_JSON" --write-out '%{http_code}\n' "$CATALOG_URL" > "$HTTP_STATUS_FILE"
IFS= read -r HTTP_STATUS < "$HTTP_STATUS_FILE"
if [[ "$HTTP_STATUS" != "200" ]]; then
    echo "Provider preflight returned HTTP $HTTP_STATUS; stopping without retry." >&2
    exit 1
fi

python3 - "$CATALOG_JSON" "$TMP_DIR/chapter-count" <<'PY'
import json
import re
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
safe = [
    item for item in data.get("data", [])
    if not item.get("isNsfw") and not item.get("isSuggestive") and item.get("slug")
]
if not safe:
    print("Provider returned no non-adult candidate; stopping without another request.", file=sys.stderr)
    sys.exit(1)
work = max(safe, key=lambda item: int(item.get("chapterCount") or 0))
slug = work["slug"]
count = int(work.get("chapterCount") or 0)
if count < 1000 or not re.fullmatch(r"[A-Za-z0-9._~-]+", slug):
    print("Provider returned no safe candidate with at least 1,000 chapters; stopping.", file=sys.stderr)
    sys.exit(1)
open(sys.argv[2], "w", encoding="utf-8").write(str(count) + "\n")
PY

IFS= read -r CHAPTER_COUNT < "$TMP_DIR/chapter-count"
printf 'Device ready; provider preflight=HTTP %s; safe high-chapter work available (reported count: %s).\n' "$HTTP_STATUS" "$CHAPTER_COUNT"
mkdir -p "$RESULTS_DIR"

DERIVED_DATA="$RESULTS_DIR/DerivedData"
WARM_RESULT="$RESULTS_DIR/warm-cache.xcresult"
COLD_RESULT="$RESULTS_DIR/cold-cache.xcresult"
LIST_RESULT="$RESULTS_DIR/live-chapter-list.xcresult"
if [[ -e "$WARM_RESULT" || -e "$COLD_RESULT" || -e "$LIST_RESULT" ]]; then
    echo "Result bundles already exist in $RESULTS_DIR; choose a new results directory." >&2
    exit 2
fi

cd "$REPO_ROOT"
xcodebuild build-for-testing \
    -project MangaCademy.xcodeproj \
    -scheme MihonReader \
    -configuration Release \
    -destination "platform=iOS,id=$DEVICE_ID" \
    -derivedDataPath "$DERIVED_DATA" \
    MIHONREADER_BUNDLE_IDENTIFIER="$HARNESS_BUNDLE_ID" \
    ENABLE_TESTABILITY=YES \
    CODE_SIGNING_ALLOWED=YES \
    | tee "$RESULTS_DIR/build.log"

APP_INFO="$DERIVED_DATA/Build/Products/Release-iphoneos/MihonReader.app/Info.plist"
if [[ ! -f "$APP_INFO" ]]; then
    echo "Built app was not found at $APP_INFO; stopping before install." >&2
    exit 1
fi
BUILT_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_INFO")"
if [[ "$BUILT_BUNDLE_ID" != "$HARNESS_BUNDLE_ID" ]]; then
    echo "Built bundle identifier '$BUILT_BUNDLE_ID' is not isolated; stopping before install." >&2
    exit 1
fi

xcodebuild test-without-building \
    -project MangaCademy.xcodeproj \
    -scheme MihonReader \
    -configuration Release \
    -destination "platform=iOS,id=$DEVICE_ID" \
    -derivedDataPath "$DERIVED_DATA" \
    -resultBundlePath "$LIST_RESULT" \
    -only-testing:MihonReaderUITests/MihonReaderUITests/testLiveNexusToonsLongChapterListUsesRealProviderData \
    | tee "$RESULTS_DIR/live-chapter-list.log"

xcodebuild test-without-building \
    -project MangaCademy.xcodeproj \
    -scheme MihonReader \
    -configuration Release \
    -destination "platform=iOS,id=$DEVICE_ID" \
    -derivedDataPath "$DERIVED_DATA" \
    -resultBundlePath "$WARM_RESULT" \
    -only-testing:MihonReaderUITests/MihonReaderUITests/testLiveNexusToonsWarmCacheRetainedAcrossRelaunches \
    | tee "$RESULTS_DIR/warm-cache.log"

xcodebuild test-without-building \
    -project MangaCademy.xcodeproj \
    -scheme MihonReader \
    -configuration Release \
    -destination "platform=iOS,id=$DEVICE_ID" \
    -derivedDataPath "$DERIVED_DATA" \
    -resultBundlePath "$COLD_RESULT" \
    -only-testing:MihonReaderUITests/MihonReaderUITests/testLiveNexusToonsColdCacheClearedBeforeEveryRelaunch \
    | tee "$RESULTS_DIR/cold-cache.log"

printf '\nResults retained at: %s\n' "$RESULTS_DIR"
