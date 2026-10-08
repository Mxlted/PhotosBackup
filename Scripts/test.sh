#!/bin/bash
# The offline iOS gate used locally and by CI. Keep simulator signing enabled
# so CredentialStoreTests exercises real Keychain access.
set -euo pipefail

usage() {
  echo "Usage: $0 [simulator-uuid]"
  echo "Runs offline tests on the given simulator, or the first available iPhone."
  echo "Saves build.log and Tests.xcresult under build/test-results/run.*."
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
: "${DEVELOPER_DIR:=$(xcode-select -p)}"
export DEVELOPER_DIR

XCODE_MAJOR=$(xcodebuild -version | sed -n 's/^Xcode \([0-9]*\).*/\1/p')
if [ "${XCODE_MAJOR:-0}" -lt 26 ]; then
  echo "Xcode 26 or newer is required. Set DEVELOPER_DIR to a compatible Xcode installation." >&2
  exit 1
fi

SIMULATOR_ID="${1:-}"
if [ -z "$SIMULATOR_ID" ]; then
  # Select a UUID, since device names can repeat across installed runtimes.
  # Consume the entire listing instead of using head (which can trigger SIGPIPE
  # upstream under pipefail). A simctl failure must remain an error.
  SIMULATORS=$(xcrun simctl list devices available)
  SIMULATOR_ID=$(sed -nE '/^[[:space:]]*iPhone /s/.*\(([0-9A-Fa-f-]{36})\).*/\1/p' \
    <<< "$SIMULATORS" | sed -n '1p')
  if [ -z "$SIMULATOR_ID" ]; then
    echo "No available iPhone simulator. Install an iOS runtime in Xcode, or pass a simulator UUID." >&2
    printf '%s\n' "$SIMULATORS" >&2
    exit 1
  fi
fi

xcodegen generate
mkdir -p build/test-results
RESULT_DIR=$(mktemp -d "$PWD/build/test-results/run.XXXXXX")
echo "Testing on simulator $SIMULATOR_ID"
echo "Test artifacts: $RESULT_DIR"

# Explicit exclusion keeps this command offline even if a shell has live-test
# environment variables left over. Live probes use a separate manual command.
# pipefail preserves build/test failures without parsing human-readable output.
xcodebuild test \
  -project PhotosBackup.xcodeproj \
  -scheme PhotosBackup \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -derivedDataPath "$PWD/build/DerivedData" \
  -resultBundlePath "$RESULT_DIR/Tests.xcresult" \
  -skip-testing:PhotosBackupTests/LiveExchangeTests \
  2>&1 | tee "$RESULT_DIR/build.log"
