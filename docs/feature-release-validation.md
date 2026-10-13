# Feature release evidence

Repository: `Mxlted/PhotosBackup`
Baseline: fork `main` at `7d50d99`
Working branch: `codex/backup-health-and-reliability`

This report records the pre-release feature validation before the version bump to
0.4.0 (build 18). Its artifact hash and PR state below describe that earlier handoff;
see the [0.4.0 release](https://github.com/Mxlted/PhotosBackup/releases/tag/0.4.0)
for the published IPA and checksum. No live Google
or private-media testing is included. Implementation commit: `67fb5ea`.
Pull request: [Mxlted/PhotosBackup #2](https://github.com/Mxlted/PhotosBackup/pull/2).

## Eight-feature implementation status

| Feature | Implemented behavior | Verification boundary |
| --- | --- | --- |
| Backup Health | Deduplicated selected-scope coverage, scan freshness, remembered completions, dated remote confirmations, pending/failure/iCloud/unknown counts, missing components, limited-access notice and recovery actions. Reuses discovery metadata. | Synthetic scope and completion tests; real-library coverage and remote retention are not independently verified. |
| Unattended controls | Optional charging, battery floor, heat reduction/pause, and free-storage admission with shared reservations. Queue paths share the same monitor; existing work can finish. Recovery preserves user and network pauses. | Injected power, heat, capacity and clocks; physical-device transitions remain unverified. |
| Local notifications | Explicit permission action, denied-permission handling, settled-session/failure/action-required notices, durable deduplication, and guarded Activity/Settings navigation. | Injected delivery and authorization tests; actual iOS notification delivery remains a device check. |
| Activity browsing | Pending/processing/failed/iCloud/completed filters, local-name search, local-only thumbnails, stable selection and selected-failure retry; existing queue actions retained. | Filter, identity, large-queue and retry tests; device scrolling/accessibility and real thumbnail presentation require manual checks. |
| Originals and edits | Opt-in independent original photo/video components alongside current appearance; optional current/original Live Photo motion; separate Google edit-base compatibility component. Missing required resources fail visibly. | Resource selection, pairing guards and partial recovery tested offline. Identical motion paired to different still versions has an explicit limitation; Google presentation is unverified. |
| Black Screen completion | Optional normal auto-lock restoration after an observed session settles, including a finish with failures; accurate summary and override reacquisition for new work. Existing mode behavior retained. | Completion policy and idle-timer ownership tests; no claim that the app locks a device or guarantees background execution. |
| Selective rules | Shared preview/discovery/coverage evaluator for media types, supported screenshot/recording metadata and capture dates. Changes invalidate scope; broadening forces discovery. | Metadata, overlap, date/DST, invalidation and incremental-scan tests; imported recordings without supported subtypes are not guessed. |
| Session summaries | Durable logical sessions span execution windows/relaunch; assets and components are counted separately, duplicates exclude uploaded bytes, and history remains account-scoped and bounded. | Outcome, overlap, migration and persistence tests. Active-upload and waiting durations are explicitly unavailable. |

Implementation is present for all eight features, and the final offline gates below
passed. The device and server checks in the last column remain unverified.

## Defaults and migration

- Existing preferences retain their stored values. New unattended restrictions,
  originals, notifications, and completion-triggered auto-lock all default **off**.
  Battery minimum `0` means disabled; merely upgrading requests no notification permission.
- Rules default to both photos and videos, no screenshot/recording exclusions and
  no date limits. Existing album selection and already-pending work are retained.
  Explicit picker selections bypass automatic rules; they do not finish an outstanding
  selected-album scan. Picker-only sources cannot claim enabled unknown variants.
- Date selection saves the chosen timezone and absolute boundaries: inclusive first
  day through exclusive start of the day after the last day, including DST changes.
  Missing capture dates are excluded when a date boundary needs that information.
- Existing defaults remain automatic backup on, Wi-Fi only, two concurrent uploads,
  Live Photo motion off, Storage Saver/use-quota options off, and Black Screen status on.
  The current rendered appearance remains the default export behavior.
- Queue snapshot version remains `1`. Optional session/confirmation fields and an
  optional original-component flag preserve old snapshot and completion meanings.
  Legacy completion records receive no invented verification dates. A ledger ahead
  of its snapshot produces explicitly incomplete measurements rather than fabricated totals.
- Rule and variant changes do not delete media or successful history. Edit detection
  invalidates affected current/edit-base/motion records while preserving immutable originals.
  Coverage needs a matching scan after scope/library changes or relaunch.
- Logical summaries reuse the existing 40-record run-history bound. Notification claims
  are bounded to 120 event IDs. Existing account partitions and failed-ledger recovery
  overrides remain in use.

## Shared architecture and completion rules

`BackupScopeDescriptor`, `BackupSelectionRules`, and `MediaComponentPlan` define
the selected account/library/album/rule/variant scope and required media recipes.
Discovery hands work to the existing main-actor `UploadQueue`; export, hashing,
transport and metadata enumeration retain their off-main paths. Durable handoff
precedes scan-history advancement. Coverage never follows from an empty queue.

`BackupSession` joins overlapping work through discovery-owner tokens and component
membership. A complete scan, settled required work and a saved final snapshot are
required before completion is published. Finished with failures is a distinct outcome.
Pauses, incomplete scans, iCloud deferrals, inaccessible assets, credential failures,
expired windows and Stop do not become successful completion. Dashboard, notifications,
Black Screen and summaries reuse these meanings.

`BackupAdmissionPolicy` only admits new preparation. Battery recovery adds five
percentage points; heat recovery requires one minute; warm concurrency is capped at
one. Storage keeps 1 GiB headroom, reserves 2 GiB for unknown sizes or twice a known
estimate, and requires a fresh capacity sample before releasing materialized reservations.
Existing files already consume filesystem capacity. Cleanup retains background-owned
bodies; a missing body requires fresh preparation admission and an execution owner.

Originals use the established exporter, duplicate checks, checkpoints, receipts and
commit pipeline. Original/current stills and motions remain independent obligations.
See [shared semantics](backup-semantics.md) and [media components](media-component-model.md)
for pairing limitations, metadata rules, recovery and privacy details.

## Deterministic regression coverage

| Area | Covered cases | Test suites |
| --- | --- | --- |
| Coverage and selection | Empty queue/unscanned scope, legacy dates, missing motion, distinct assets, account/permission mismatch, unavailable metadata, overlapping albums, rule changes, invalid dates and DST. | `BackupHealthTests`, `BackupSelectionRulesTests`, `PhotoLibraryChangeTrackerTests` |
| Admission and execution | Defaults/migration, charging/battery hysteresis, thermal recovery, concurrent reservations, materialization capacity, unknown sizes, user/network pauses, existing work, missing bodies and idle blocked windows. | `BackupAdmissionPolicyTests`, `BackupAdmissionMonitorTests`, `QueueAdmissionTests`, `BackupExecutionTests` |
| Notifications | Explicit/denied permission, retry/relaunch deduplication, account switch and changed outcome during authorization, quiet incomplete sessions, action notices, stale/cold-start taps, persistent storage and failed delivery. | `BackupNotificationTests` |
| Activity | Filter/search composition, stable IDs and order on large queues, stale selection removal, selected retry and duplicate scheduling protection. | `ActivityBrowserTests`, `MediaComponentPlanTests`, `UploadQueueTests` |
| Media variants | Opt-in component matrix, edited photo/video selection, independent Live Photo variants, old original-flag migration, partial checkpoints, picker limitations and motion duplicate pairing. | `MediaComponentPlanTests`, `MediaExportTests`, `GPMCClientTests` |
| Sessions and Black Screen | Overlapping owners, Stop/late callbacks, incomplete scope joined by manual work, failed durable save, cancelled-row isolation, account-safe dates, relaunch, ledger/snapshot gaps, bytes/assets, and completion followed by new work. | `BackupSessionTests`, `QueueSessionTests`, `BlackScreenBackupTests` |

New regressions use synthetic metadata, memory stores, isolated preferences, temporary
files, injected interfaces and explicit completion signals. No arbitrary test sleeps,
real accounts, private Photos assets or single-use credentials are needed.

## Review-driven corrections

- Idle admission-blocked background runs return their opportunity instead of waiting
  for expiration; admitted running work retains its execution ownership.
- Missing staged background bodies cannot bypass admission or trigger export during
  a transfer-delivery-only window.
- Completion publication follows successful snapshot persistence; stale cancelled
  rows, invalidated discovery owners and cross-account callbacks cannot settle another session.
- Notification eligibility is rechecked after asynchronous authorization/delivery;
  stale session outcomes and account changes cannot emit a valid completion action.
- Original/current motion pairing validates the intended still; unavailable rendered
  or required variant resources fail explicitly rather than becoming false success.
- Scope invalidation, incomplete manual/album handoffs and ledger/snapshot gaps retain
  their uncertainty instead of producing full coverage or invented measurements.

Review-driven corrections above have regression coverage. A fresh independent full
review reported no remaining actionable P1/P2 findings; its final focused review of
scan-date retention also reported no actionable findings.

## Validation and delivery evidence

| Gate | Verified result |
| --- | --- |
| Baseline `swift test` | **PASS: 8 tests**, baseline `7d50d99`. |
| Baseline signed app gate | **PASS: 261 tests on iOS 26.5**, `build/test-results/run.9K5D4i`. |
| Final `swift test` | **PASS: 8 tests, 0 failures**, `build/test-results/core-release.log`. |
| Final signed `Scripts/test.sh` on iOS 26.5 | **PASS: 346 tests, 0 failures**; simulator `F772E0AA-D62A-4DD3-BA91-65EB47B61BAC`; `build/test-results/run.QkoIQH/Tests.xcresult`. |
| Final signed `Scripts/test.sh` on iOS 27 | **PASS: 346 tests, 0 failures**; simulator `3CF19406-594E-40CF-99F5-8AE858C6322C`; `build/test-results/run.p11mWd/Tests.xcresult`. |
| Final diff/staged-path checks and `AGENTS.md` exclusion | **PASS**; only intended paths staged, `git diff --check` clean, and `git ls-files -- AGENTS.md` empty after the implementation commit. Rechecked for the report commit. |
| Final unsigned `./Scripts/make-ipa.sh` | **PASS**, `build/ipa-release.log`; new `build/PhotosBackup.ipa` is 3,206,724 bytes; ZIP integrity passed and privacy manifest is present. |
| Fork delivery | Implementation `67fb5ea` pushed on `codex/backup-health-and-reliability`; [PR #2](https://github.com/Mxlted/PhotosBackup/pull/2) targets fork `main` and remains unmerged. The report is a separate documentation commit. |
| Hosted CI | **PASS: 8 core and 346 signed app tests, 0 failures**, Xcode 26.3 on iOS 18.5 (iPhone 16 Pro), [run 38452805017](https://github.com/Mxlted/PhotosBackup/actions/runs/38452805017), implementation plus report at `1131b81`. The subsequent documentation-only commit records this evidence. Local final gates used Xcode 27. |

Signed simulator tests include real simulator Keychain coverage. The unsigned IPA
is a separate packaging artifact and is not evidence that signed tests passed.
IPA modification time: `2026-10-13T19:06:27.475529Z` (UTC). SHA-256:
`bba25da554120a273a37dafa26064e5ba63a3a0d863498dea733c17177c1f523`.
Bundle `com.g8row.photosbackup`, version `0.3.9`, build `17`, and minimum iOS `15`
are unchanged. Final builds emitted no new Swift warnings. Existing missing iPad
icon/orientation warnings and the SDK XCTest dylib's newer deployment warning remain.
Home, Backup Health, Settings, Unattended Backup and Activity's empty state were
inspected using XcodeBuildMCP without accounts and without granting Photos access.
Screenshots are retained under `build/qa/`; this is not a full VoiceOver/Dynamic Type
or populated-library UI audit. An intermediate run exposed two stale nonexistent-file
fixtures after the missing-body guard; real temporary fixtures fixed them. A simulator
Busy preflight failure was inspected before retrying; the final runs above passed.

There is no locally installed runtime older than iOS 26.5; hosted CI additionally
passed on iOS 18.5. Deployment remains iOS 15, whose runtime behavior is unverified.
No physical-device power/thermal, real
notification delivery, iCloud download, background opportunity or Live Photo camera/editor
combination is established by these simulator gates. Google original/edit grouping,
quota behavior and live pairing have not been tested. Active and waiting durations
remain unavailable; very large unknown media can exceed the storage reservation.

## 0.4.0 release preparation

The subsequent version bump sets marketing version `0.4.0` and build `18`, without
changing the bundle identity, signing configuration, or deployment target. The
versioned app passed all **346 signed offline tests** on iOS 26.5; see
`build/test-results/run.pjleFS/Tests.xcresult`.

`./Scripts/make-ipa.sh` produced a fresh local IPA; ZIP integrity, privacy manifest,
bundle identity, version `0.4.0`, build `18`, and minimum iOS `15.0` were verified.
Local Xcode 27 artifact: 3,206,725 bytes; SHA-256
`55edb26848786af329ae4f2d3c970004e11a1da5accea0dfe5c3cc4b7b48eb6d`. Build log: `build/ipa-0.4.0.log`.
The published release workflow builds separately with Xcode 26.3; its attached
checksum is authoritative for that downloaded IPA and may differ from this local build.
