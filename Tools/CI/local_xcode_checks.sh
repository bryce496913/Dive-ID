#!/usr/bin/env bash
# The Xcode checks GitHub CI no longer runs, for a Mac with Xcode (run before merging app changes).
#
#   Tools/CI/local_xcode_checks.sh            # settings, builds, instrumentation, unit + UI tests
#   Tools/CI/local_xcode_checks.sh --no-ui    # skip the UI-test target (faster)
#   SIMULATOR_ID=<udid> Tools/CI/local_xcode_checks.sh
#
# 1. Resolves Debug, Release and Internal settings with xcodebuild and validates them
#    (validate_xcode_settings.py: DEBUG/DIVEID_INTERNAL boundaries, optimization, bundle IDs).
# 2. Builds Debug for testing, then runs the unit-test target (and the UI-test target).
# 3. Builds Release and Internal, and checks the first-use instrumentation is absent from
#    Release and present in Debug and Internal (check_internal_instrumentation.py).
# Builds go to a temporary DerivedData directory that is removed at the end; logs stay in
# it only on failure, and its path is printed. Nothing is signed, installed or uploaded.
set -o pipefail  # no -u: macOS bash 3.2 treats an empty array as unbound

cd "$(dirname "$0")/../.."
RUN_UI=1
[ "${1:-}" = "--no-ui" ] && RUN_UI=0
WORK="$(mktemp -d "${TMPDIR:-/tmp}/diveid-local-checks.XXXXXX")"
FAILED=()

step() { echo; echo "== $1"; }
run() {  # run NAME COMMAND...: log to $WORK/NAME.log, record a failure without stopping
  local name="$1"; shift
  if "$@" > "$WORK/$name.log" 2>&1; then echo "   ok: $name"; else echo "   FAILED: $name (log: $WORK/$name.log)"; FAILED+=("$name"); fi
}

step "Toolchain"
xcodebuild -version | head -1

if [ -z "${SIMULATOR_ID:-}" ]; then
  SIMULATOR_ID="$(xcrun simctl list devices available --json | python3 -c '
import json, re, sys
candidates = []
for runtime, entries in json.load(sys.stdin)["devices"].items():
    match = re.search(r"iOS[- ](\d+)[-.](\d+)", runtime)
    if not match:
        continue
    for device in entries:
        if device.get("isAvailable") and device.get("name", "").startswith("iPhone") and "SE" not in device["name"]:
            candidates.append((tuple(map(int, match.groups())), device["name"], device["udid"]))
candidates.sort(reverse=True)
print(candidates[0][2] if candidates else "")')"
fi
if [ -z "$SIMULATOR_ID" ]; then echo "No available iPhone simulator; set SIMULATOR_ID." >&2; exit 1; fi
DEST="platform=iOS Simulator,id=$SIMULATOR_ID"
echo "Simulator: $SIMULATOR_ID"

step "Build settings"
for config in Debug Release Internal; do
  run "settings-$config" bash -c "xcodebuild -project DiveID.xcodeproj -alltargets -configuration $config -sdk iphonesimulator \
    -showBuildSettings -json > '$WORK/settings-$config.json' && python3 Tools/CI/validate_xcode_settings.py '$WORK/settings-$config.json' $config"
done

COMMON=(-project DiveID.xcodeproj -scheme DiveID -destination "$DEST" CODE_SIGNING_ALLOWED=NO)

step "Debug build and tests"
run build-for-testing xcodebuild "${COMMON[@]}" -derivedDataPath "$WORK/debug" build-for-testing
if [[ ! " ${FAILED[*]} " =~ " build-for-testing " ]]; then
  run unit-tests xcodebuild "${COMMON[@]}" -derivedDataPath "$WORK/debug" -parallel-testing-enabled NO test-without-building -only-testing:DiveIDTests
  [ "$RUN_UI" = 1 ] && run ui-tests xcodebuild "${COMMON[@]}" -derivedDataPath "$WORK/debug" -parallel-testing-enabled NO test-without-building -only-testing:DiveIDUITests
fi

step "Release and Internal builds"
run release-build xcodebuild "${COMMON[@]}" -configuration Release -derivedDataPath "$WORK/release" build
run internal-build xcodebuild "${COMMON[@]}" -configuration Internal -derivedDataPath "$WORK/internal" build

step "Instrumentation boundary"
APPS=("$WORK/release/Build/Products/Release-iphonesimulator/DiveID.app"
      "$WORK/internal/Build/Products/Internal-iphonesimulator/DiveID.app"
      "$WORK/debug/Build/Products/Debug-iphonesimulator/DiveID.app")
if [ -d "${APPS[0]}" ] && [ -d "${APPS[1]}" ] && [ -d "${APPS[2]}" ]; then
  run instrumentation-release python3 Tools/CI/check_internal_instrumentation.py --expect absent "${APPS[0]}"
  run instrumentation-internal python3 Tools/CI/check_internal_instrumentation.py --expect present "${APPS[1]}"
  run instrumentation-debug python3 Tools/CI/check_internal_instrumentation.py --expect present "${APPS[2]}"
else
  echo "   skipped: a build failed"; FAILED+=("instrumentation")
fi

echo
if [ ${#FAILED[@]} -eq 0 ]; then
  rm -rf "$WORK"
  echo "All local Xcode checks passed. Temporary build directory removed."
  exit 0
fi
# Keep only the logs and settings needed to diagnose the failure; drop the build products.
rm -rf "$WORK/debug" "$WORK/release" "$WORK/internal"
echo "FAILED: ${FAILED[*]}"
echo "Logs kept in $WORK (delete it when done)."
exit 1
