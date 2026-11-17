#!/bin/bash
# The offline iOS gate used locally and by CI. Keep simulator signing enabled
# so CredentialStoreTests exercises real Keychain access.
set -euo pipefail

usage() {
  echo "Usage: $0 [simulator-uuid]"
  echo "Runs offline tests on the given simulator, or an iPhone matching Xcode's SDK."
  echo "Saves phase logs and result bundles under build/test-results/run.*."
}

if [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi
if [ "$#" -gt 1 ]; then
  usage >&2
  exit 2
fi

cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null || { echo "xcodegen not found" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 not found" >&2; exit 1; }
: "${DEVELOPER_DIR:=$(xcode-select -p)}"
export DEVELOPER_DIR

XCODE_MAJOR=$(xcodebuild -version | sed -n 's/^Xcode \([0-9]*\).*/\1/p')
if [ "${XCODE_MAJOR:-0}" -lt 26 ]; then
  echo "Xcode 26 or newer is required. Set DEVELOPER_DIR to a compatible Xcode installation." >&2
  exit 1
fi

SIMULATOR_ID="${1:-}"
mkdir -p build/test-results
RESULT_DIR=$(mktemp -d "$PWD/build/test-results/run.XXXXXX")
echo "Test artifacts: $RESULT_DIR"
SDK_VERSION=$(xcrun --sdk iphonesimulator --show-sdk-version)
xcrun simctl list devices available --json > "$RESULT_DIR/simulators.json"
if [ -z "$SIMULATOR_ID" ]; then
  SIMULATOR_ID=$(python3 Scripts/select-simulator.py --sdk "$SDK_VERSION" < "$RESULT_DIR/simulators.json")
fi

echo "Testing on simulator $SIMULATOR_ID"
collect_failure_logs() {
  local result=$?
  trap - EXIT
  if [ "$result" -ne 0 ]; then
    echo "Test gate failed (exit $result). Collecting simulator diagnostics."
    python3 Scripts/run-bounded.py --timeout 20 --label "Simulator state" \
      xcrun simctl list devices --json > "$RESULT_DIR/simulator-state.log" 2>&1 || true
    python3 Scripts/run-bounded.py --timeout 20 --label "Test-host logs" \
      xcrun simctl spawn "$SIMULATOR_ID" log show --last 5m --style compact \
      --predicate 'process == "testmanagerd" OR process == "PhotosBackup" OR process == "SpringBoard"' \
      > "$RESULT_DIR/simulator-system.log" 2>&1 || true
  fi
  exit "$result"
}
trap collect_failure_logs EXIT

# Make simulator readiness a visible, bounded phase instead of letting test
# launch wait silently after compilation. -b also handles an already booted sim.
python3 Scripts/run-bounded.py --timeout 180 --label "Simulator boot" \
  xcrun simctl bootstatus "$SIMULATOR_ID" -b 2>&1 | tee "$RESULT_DIR/boot.log"

xcodegen generate
DESTINATION="platform=iOS Simulator,id=$SIMULATOR_ID,arch=$(uname -m)"
COMMON_ARGS=(
  -project PhotosBackup.xcodeproj
  -scheme PhotosBackup
  -destination "$DESTINATION"
  -destination-timeout 60
  -derivedDataPath "$PWD/build/DerivedData"
)

python3 Scripts/run-bounded.py --timeout 600 --label "Test build" \
  xcodebuild build-for-testing "${COMMON_ARGS[@]}" \
  -resultBundlePath "$RESULT_DIR/Build.xcresult" 2>&1 | tee "$RESULT_DIR/build.log"

# Explicit exclusion keeps this command offline even if a shell has live-test
# environment variables left over. Live probes use a separate manual command.
# pipefail preserves build/test failures without parsing human-readable output.
python3 Scripts/run-bounded.py --timeout 300 --label "Simulator tests" \
  xcodebuild test-without-building "${COMMON_ARGS[@]}" \
  -parallel-testing-enabled NO \
  -maximum-concurrent-test-simulator-destinations 1 \
  -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 \
  -maximum-test-execution-time-allowance 120 \
  -resultBundlePath "$RESULT_DIR/Tests.xcresult" \
  -skip-testing:PhotosBackupTests/LiveExchangeTests \
  2>&1 | tee "$RESULT_DIR/tests.log"
