# Backup scope, components, sessions, and recovery

## Shared meanings

- **Selected scope:** the connected account, currently accessible Photos library,
  selected albums, metadata rules, Live Photo motion option, and originals option.
  Albums overlap; asset identifiers are deduplicated before counting or enqueueing.
- **Required components:** current appearance, optional current motion, the existing
  Google edit-base compatibility resource when applicable, and optional original
  still/video plus original motion for edited Live Photos. See
  [the media model](media-component-model.md). A remembered still alone cannot
  establish coverage when a required companion is missing.
- **Scan completion:** metadata enumeration and all candidate handoffs have been
  committed durably for the same unchanged scope. Background batches remain
  incomplete when their 250-component admission bound leaves candidates behind.
- **Remembered completion:** an account-specific local ledger entry. Legacy entries
  remain usable but carry no fabricated remote-confirmation dates.
- **Remote confirmation:** a successful Google upload/finalization or validated
  duplicate lookup. A compatibility no-op does not create a remote confirmation,
  so an all-components confirmation date can remain unknown despite local completion.
  The dashboard shows the most recent component confirmation and, only when all
  required components have dates, the oldest of those dates. Neither is continuous
  monitoring of remote retention.
- **Logical session:** overlapping work joins one session until its discovery and
  component work settle. The session persists in the version-1 queue snapshot and
  spans app execution windows and relaunches. Stopping invalidates discovery owners,
  so a late scan cannot restart stopped work. A later explicit batch starts another
  session. A discovered, already-tracked failure remains a session obligation;
  unrelated old finished rows do not contaminate a new manual batch. An explicit
  picker batch can define a session limited to those selections. If it joins an
  unfinished selected-album session, completing the picker batch cannot clear the
  outstanding scope scan; Back Up Now must complete that scan.
- **Complete:** all discovery owners have handed off successfully, every required
  session component has settled, and the final snapshot saved. **Finished with
  failures** is a separate settled outcome with unresolved failures. **Paused**,
  **waiting for iCloud**, **scan incomplete**, **action required**, and **stopped by
  you** are not successful outcomes. Unavailable assets require another scope scan.

## Coverage and rules

Backup Health reuses metadata collected by discovery; upload progress never starts
another PhotoKit enumeration. Derived counts are computed away from the main actor
and coalesced. Coverage becomes unknown after an account, album, rule, variant,
permission, or library change, or after relaunch until a matching scan runs. The
last successful matching scan remains historical information. Persisted invalidation
prevents an empty incremental history batch from making an old manifest current.
The scan timestamp advances only after complete durable handoff. It does not prove
that the handed-off uploads have finished.
Album-row counts retain their existing meaning: remembered current appearances
within that album, without applying rules or requiring optional companions. Use
Backup Health for the deduplicated, rule-filtered component coverage.

Rules default to both photos and videos, with no exclusions or date limits.
Screenshots and screen recordings use supported PhotoKit subtypes; imported media
without those subtypes is not guessed from its filename. Date ranges include both
chosen calendar days: inclusive start, exclusive start of the following day. The
saved timezone is fixed after travel, including daylight-saving transitions. Missing
capture dates are excluded only when a date boundary requires one; unavailable
revision metadata prevents a full coverage claim.

The preview, full discovery, incremental discovery, and health manifest use the same
rule evaluator. Previews are cancellable metadata reads and download no media.
Explicit picker selections bypass automatic rules. Readable selections snapshot
their required components before upload. Picker-only copies cannot establish
enabled originals or motion; with either option on, they fail with a Photos-access
recovery instruction instead of claiming complete variants. With both options off,
a picker copy can back up its current appearance. Applying rules keeps already
queued work; use Activity's Stop if it is unwanted. Broadening rules forces a fresh
scan. Edits made while an asset is excluded are checked when it is included again.
No rule or variant preference deletes local media, remote media, or valid completion
history. Legacy edit and motion backfills now flow through scoped discovery.

## Optional unattended controls

All new admission restrictions default off. Charging-only and minimum-battery
controls admit new preparation; a five-point battery recovery band avoids oscillation.
The warm-device option caps concurrency at one in fair thermal conditions, waits
for serious/critical heat to recover, and requires a minute of cooling before
resuming. Already admitted work keeps its execution owner and can finish.

Free-storage protection uses a shared filesystem capacity sample, 1 GiB headroom,
and serialized reservations for concurrent staging. Unknown PhotoKit sizes reserve
2 GiB; known estimates reserve twice their size for intermediate copies. This is
conservative admission, not an absolute maximum file size: an unusually large item
can exceed the estimate. Capacity is refreshed before releasing a reservation after
materialization. Existing staged files already consume filesystem capacity and are
not subtracted twice. Background-transfer-owned files remain protected from cleanup.
A missing staged body needs a new preparation admission; a transfer-delivery-only
window cannot silently re-export it.

Recovery never clears user Pause or Stop. Network restrictions remain enforced at
both the queue and transport. Home, Activity, and Black Screen details show blocked
or reduced-speed conditions. iOS determines execution opportunities and may expire
any background window; these settings promise neither exact schedules nor continuous
execution.

## Notifications and Black Screen Mode

Notifications default off. Settings' Enable Backup Notifications button requests iOS
permission; a denial leaves backup usable. Notices are limited to a settled session,
a finish with failures, rejected credentials, exhausted remote storage, or a pending
preparation blocked on local storage for 15 minutes. Ordinary network interruptions
and individual uploads do not notify.

An injected delivery interface, stable session/event request IDs, and bounded durable
claims deduplicate notices across retries and relaunch. Claims are saved before
requesting delivery (at-most-once intent; a process termination in this narrow gap
can suppress a notice). Authorization and delivery completions recheck current
account, session, and decision. Notification payloads contain only opaque session IDs
and navigation destinations. Taps route to Activity or Settings; obsolete account or
session taps are ignored. There is no server, remote polling, or extra execution grant.

Black Screen Mode retains its existing dim moving display, fully black option,
tap-to-reveal controls, and scene-aware idle timer. Restore Auto-Lock After Completion
defaults off. When enabled, a session observed running in the mode releases its idle
inhibition on completion **or completion with failures**. It remains in the mode and
shows the accurate summary on return. Completion is for that session's work:
a standalone picker batch does not establish selected-album coverage. Pauses,
account changes, interrupted scans, and expired windows do not trigger this. New work reacquires the override while visible
and active. Exit/scene changes restore the prior idle-timer value. The app does not
lock the device or adjust brightness.

## Activity and session summaries

Activity offers pending, processing, failed, iCloud, and completed filters, a search
of the locally displayed name, and stable-ID selected-failure retry. Browsing never
changes queue state. Filtering is cancellable and off-main; rows render lazily.
Small thumbnails are local-only, cancel offscreen, and use a bounded cache. Sources
without a local thumbnail show placeholders. Existing individual retry, retry-all,
pause, stop, and clear-finished actions remain.

Session summaries distinguish assets from components and exclude duplicate bytes
from measured uploads. An asset with one uploaded component and another duplicate
counts as uploaded once. Distinct confirmed component attempts can accumulate
measured bytes without counting the same asset twice. Unknown sizes are labeled. If the completion ledger survives a lost snapshot update, summaries label the recovered totals as known results only rather than inventing outcomes.
Active-upload and waiting durations are currently **unavailable**; elapsed wall time
includes iOS suspension and is not presented as active work. Aggregate summaries
share the bounded diagnostic run history; only the active account's logical-session
entries are shown in session history. Old execution-window records remain readable.
Exported summaries contain aggregate counts, outcomes, and measured bytes, without
account addresses, media names, identifiers, credentials, or request URLs.

## Persistence and platform limits

Optional fields extend queue snapshot version 1: session state and new confirmation
dates. Optional original flags extend existing asset records; old records retain their
meaning. Existing completion-ledger recovery overrides, account isolation, preparation
markers, request retry ownership, and background receipts remain in place. User
preferences with no saved value use the old selection/export behavior.

Supported deployment remains iOS 15 with Swift 5 language mode. Shortcuts need iOS 16
and continued processing needs iOS 26. Tests use memory stores, temporary files,
injected delivery/power/capacity, explicit signals, and synthetic metadata. No live
Google tests or private Photos library access are part of validation. Actual Google
original/edit presentation, physical-device power/thermal behavior, and background
opportunities remain device checks, not simulator guarantees.
