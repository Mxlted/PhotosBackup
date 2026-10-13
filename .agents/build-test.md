# Build & Test

## Prerequisites

- macOS + Xcode 26+ + iOS Simulator runtime (CI pins Xcode 26.3), XcodeGen 2.40+ (`brew install xcodegen`), iOS 15.0+

## Generate (always first — .xcodeproj is generated)

```sh
xcodegen generate
open PhotosBackup.xcodeproj
```

Signed device build: set `DEVELOPMENT_TEAM` in `project.yml`, regenerate, let Xcode manage signing.

XcodeBuildMCP is preferred when available: discover its simulator build/test
commands with `xcodebuildmcp simulator --help`. The shared script below is the complete local and CI gate. Simulator tests use local signing for Keychain
coverage; do not disable signing for that test run.

## Build (simulator, unsigned)

```sh
xcodebuild \
  -project PhotosBackup.xcodeproj \
  -scheme PhotosBackup \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## Test (offline — default gate)

```sh
swift test                         # fast protocol-core suite on macOS
./Scripts/test.sh                   # full signed offline simulator suite
./Scripts/test.sh <simulator-uuid>  # select a particular installed runtime
```

The script regenerates the Xcode project, explicitly excludes live tests, and
keeps logs/result bundles under `build/test-results/run.*`. New Swift test files
are included by XcodeGen. Discover installed simulator UUIDs with
`xcodebuildmcp simulator list --enabled true` or `xcrun simctl list devices available`.
Use explicit project, scheme, and simulator arguments for focused MCP runs.

Recovery tests use temporary persistence stores, injected sessions, and explicit
completion signals; they do not exercise a real Google account or Photos library.
An iOS 26+ run does not validate the iOS 15–25 compatibility paths. Run an older
supported runtime when installed, and report that gap otherwise.

## Live tests (opt-in, contacts Google — never run by default)

```sh
TEST_RUNNER_GPMC_LIVE=1 \
xcodebuild ... test \
  -only-testing:PhotosBackupTests/LiveExchangeTests/testInvalidTokenIsRejectedByGoogleNotByUs

TEST_RUNNER_GPMC_LIVE=1 \
TEST_RUNNER_GPMC_OAUTH_TOKEN=oauth_XXXX \
xcodebuild ... test \
  -only-testing:PhotosBackupTests/LiveExchangeTests/testFullExchangeWithRealToken
```

`TEST_RUNNER_GPMC_OAUTH_TOKEN` must be a fresh single-use token. Never commit tokens.

CI tests and releases use the same Xcode 26.3 pin. The release workflow calls
the installation-feed workflow only after uploading the IPA.

## IPA (SideStore sideload)

```sh
./Scripts/make-ipa.sh
# output: build/PhotosBackup.ipa
# override Xcode location only if needed:
DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer ./Scripts/make-ipa.sh
```
