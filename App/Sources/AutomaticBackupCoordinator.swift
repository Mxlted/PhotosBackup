import BackgroundTasks
import Combine
import Foundation
import OSLog
import Photos
import UIKit

/// Owns opportunistic automatic-backup runs in both foreground and system
/// background execution windows. iOS decides when a processing request runs;
/// every invocation submits its successor so the work remains recurring.
@MainActor
final class AutomaticBackupCoordinator: ObservableObject {
    /// The processing task's identifier as this install declares it. SideStore
    /// renames the bundle when it signs the app and rewrites the identifiers in
    /// `BGTaskSchedulerPermittedIdentifiers` to match
    /// (`…photosbackup.background-backup` → `…photosbackup.<TEAMID>.background-backup`);
    /// registering the build-time name there was rejected as "not advertised in
    /// the application's Info.plist" (seen on device, 2026-09-19).
    nonisolated static let taskIdentifier: String = resolveTaskIdentifier(
        permitted: Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? []
    )
    nonisolated static let builtTaskIdentifier = "com.g8row.photosbackup.background-backup"

    nonisolated static func resolveTaskIdentifier(permitted: [String]) -> String {
        permitted.first { $0.hasSuffix(".background-backup") && !$0.hasSuffix("*") } ?? builtTaskIdentifier
    }
    private nonisolated static let logger = Logger(subsystem: "com.g8row.photosbackup", category: "automatic-backup")

    /// How many sources one background enqueue pass may append. This bounds
    /// *memory*, not how much a window uploads — the queue is durable, so
    /// anything a window cannot finish simply waits for the next one. The old
    /// value of 25 meant a window that iOS might only grant once a day could
    /// never let the queue saturate, and so could never advance the change
    /// token either.
    ///
    /// The foreground has no equivalent cap. Paging it meant the queue only
    /// ever showed a slice of the work, so the count the manual buttons
    /// reported was a slice too, and any condition that ended the paging loop
    /// early stranded the rest of the selection off-queue. In the foreground
    /// the whole selection goes in at once and the queue's own concurrency
    /// limit decides how much of it runs.
    private static let backgroundBatchLimit = 250

    /// The earliest start the processing request asks for. An eligibility
    /// date, not a timer: iOS picks the actual moment, usually much later.
    private static let processingRequestDelay: TimeInterval = 15 * 60

    /// The whole Back Up Photos action, scan included, has to fit in the
    /// roughly 30 seconds iOS gives an App Intent. Past that iOS terminates the
    /// process and Shortcuts reports the action as failed. This leaves time to
    /// requeue unfinished work and return the dialog.
    static let shortcutBudget: TimeInterval = 22

    /// When the pending processing request was submitted, so the log can say
    /// how long iOS took to honour it.
    static let lastRequestSubmittedKey = "diagnostics.scheduler.lastSubmittedAt"

    private let photos: PhotosStack
    private let account: PhotosAccount
    private let queue: UploadQueue
    private let preferences: BackupPreferences
    private let albums: PhotoAlbumStore
    private let network: NetworkPolicyMonitor
    private let libraryChanges: PhotoLibraryChangeTracker
    private let execution: BackupExecutionController
    let admission: BackupAdmissionMonitor
    let notifications: BackupNotificationController
    private var healthObservation: AnyCancellable?
    private var queueObservation: AnyCancellable?
    private var healthTask: Task<Void, Never>?
    @Published private(set) var health: BackupHealthSnapshot?

    private var selectedScope: BackupScopeDescriptor {
        libraryChanges.scope(selectedAlbumIDs: preferences.selectedAlbumIDs,
            accountIdentifier: account.status.email, rules: preferences.selectionRules,
            includeLivePhotoMotion: preferences.backUpLivePhotoMotion,
            includeOriginals: preferences.backUpOriginals,
            authorization: PHPhotoLibrary.authorizationStatus(for: .readWrite).rawValue)
    }

    func refreshHealth() {
        healthTask?.cancel()
        let scope = selectedScope
        let manifest = libraryChanges.coverage(for: scope)
        let scannedAt = libraryChanges.lastSuccessfulScan(for: scope)
        let completed = queue.completedSourceKeys
        let items = queue.items
        let confirmations = queue.remoteConfirmations
        healthTask = Task { @MainActor [weak self] in
            let worker = Task.detached(priority: .utility) {
                BackupHealthSnapshot(scope: scope, manifest: manifest, lastSuccessfulScan: scannedAt,
                    completedKeys: completed, items: items, remoteConfirmations: confirmations)
            }
            let value = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            guard let self, !Task.isCancelled, self.selectedScope == scope else { return }
            self.health = value
        }
        updateNotifications()
    }

    private func updateNotifications() {
        let storageBlocked = (admission.decision.blocker == .localStorage || admission.decision.blocker == .storageUnavailable)
            && !queue.isUserPaused && queue.items.contains { $0.state == .queued && $0.checkpoint == nil }
            && queue.backupSession?.outcome.isComplete != true
        notifications.enabled = preferences.backupNotifications
        Task { await notifications.consider(queue.backupSession, account: queue.activeAccountScope,
                                            problem: queue.attentionProblem, localStorageBlocked: storageBlocked) }
    }

    func admissionPreferencesDidChange() {
        admission.updateSettings(preferences.admissionSettings)
        refreshHealth()
    }

    private var registered = false
    private var ranForegroundBackup = false
    private var isForeground: Bool { execution.isForeground }
    private var shouldRunAfterActivation = false
    private var backgroundOperation: Task<Void, Never>?
    private var backgroundRunID: UUID?
    private var foregroundOperation: Task<Void, Never>?
    private var foregroundRunID: UUID?
    /// The scheduling outcome last written to the event log. `updateSchedule`
    /// runs on every background transition, and logging each resubmission would
    /// push the entries a report needs out of the timeline.
    private var loggedScheduleState: String?
    /// iOS 26 and later: the continued-processing task that keeps the queue
    /// running after the app leaves the foreground. Typed loosely because the
    /// type itself needs iOS 26.
    private var continuedSession: AnyObject?
    private var continuedObservation: AnyCancellable?
    /// A refused or expired request is not retried for a minute, so a queue
    /// that changes every second does not resubmit every second.
    private var continuedRetryAfter: Date?
    /// The run-history record of the time spent in the background under it.
    private var continuedRun: (id: UUID, settledBefore: Int)?
#if DEBUG
    @Published private(set) var debugSimulationStatus = "Ready"
    static let lldbSimulationCommand = "e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@\"\(taskIdentifier)\"]"
    /// The run's OSLog output goes to the system log, not to this screen. On a
    /// simulator this streams it; on a device use Console.app and filter by the
    /// same subsystem.
    static let logStreamCommand = "xcrun simctl spawn booted log stream --level debug --predicate 'subsystem == \"com.g8row.photosbackup\"'"
#endif

    init(photos: PhotosStack,
         account: PhotosAccount,
         queue: UploadQueue,
         preferences: BackupPreferences,
         albums: PhotoAlbumStore,
         network: NetworkPolicyMonitor,
         libraryChanges: PhotoLibraryChangeTracker? = nil) {
        self.photos = photos
        self.account = account
        self.queue = queue
        self.preferences = preferences
        self.albums = albums
        self.network = network
        self.libraryChanges = libraryChanges ?? PhotoLibraryChangeTracker()
        self.execution = BackupExecutionController(queue: queue)
        self.admission = BackupAdmissionMonitor(settings: preferences.admissionSettings)
        let delivery = SystemBackupNotifications()
        self.notifications = BackupNotificationController(delivery: delivery)
        delivery.onOpen = { [weak notifications] session, tab in notifications?.open(session: session, tab: tab) }
        queue.installAdmissionMonitor(admission)
        admission.start()
        queue.onSessionChange = { [weak self] _ in self?.updateNotifications() }
        healthObservation = self.libraryChanges.$libraryRevision.dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.queue.invalidateSessionScope()
                self.backupConfigurationDidChange()
            }
        }
        queueObservation = queue.objectWillChange
            .throttle(for: .seconds(1), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in Task { @MainActor [weak self] in self?.refreshHealth() } }
        refreshHealth()
        queue.followUpSources = { [weak self] source in
            self?.followUps(after: source) ?? []
        }
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) { setUpContinuedBackup() }
        #endif

        registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier,
            using: nil
        ) { [weak self] task in
            guard let task = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            // iOS expects an expiration handler promptly, and the hop to the
            // main actor below can be delayed by whatever it is already doing.
            // Install a handler that works before `begin` runs, then let
            // `begin` replace it with one that can also cancel the operation.
            let window = BackgroundWindow()
            task.expirationHandler = { window.expire() }
            Task { @MainActor [weak self] in self?.begin(task, window: window) }
        }
        let declared = (Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? [])
            .joined(separator: ", ")
        if !registered {
            DiagnosticEventLog.shared.record(
                "scheduler",
                "Could not register the background task handler for \(Self.taskIdentifier), so iOS cannot start background backups in this build; Info.plist declares \(declared)",
                level: .error
            )
        } else {
            DiagnosticEventLog.shared.record("scheduler", "Registered the background task handler for \(Self.taskIdentifier); Info.plist declares \(declared)")
        }
    }

    func start() async {
        execution.setForeground(UIApplication.shared.applicationState == .active)
        await photos.start()
        await admission.refresh()
        refreshHealth()
        applyNetworkPolicy()
        updateSchedule()
        runForegroundBackupIfNeeded()
        refreshContinuedBackup()
    }

    func networkDidChange() {
        applyNetworkPolicy()
        runForegroundBackupIfNeeded()
    }

    func connectionPreferenceDidChange() {
        applyNetworkPolicy()
        runForegroundBackupIfNeeded()
    }

    func backupConfigurationDidChange() {
        queue.invalidateSessionScope()
        refreshHealth()
        cancelForegroundScan()
        ranForegroundBackup = false
        updateSchedule()
        runForegroundBackupIfNeeded()
    }

    func accountDidChange() {
        cancelForegroundScan()
        ranForegroundBackup = false
        queue.activateAccount(account.status.email)
        notifications.activate(account: queue.activeAccountScope, session: queue.backupSession?.id)
        refreshHealth()
        updateSchedule()
        runForegroundBackupIfNeeded()
    }

    func livePhotoMotionPreferenceDidChange() {
        queue.options.requiresVariantMetadata = preferences.backUpOriginals || preferences.backUpLivePhotoMotion
        backupConfigurationDidChange()
    }
    func originalPreferenceDidChange() { livePhotoMotionPreferenceDidChange() }

    /// Explicit picker batches bypass album rules but snapshot all readable
    /// required components before starting their first upload.
    func enqueueManualSelection(_ sources: [MediaSource]) async {
        guard !sources.isEmpty else { return }
        let owner = queue.beginDiscovery(requiresCompleteScope: false)
        var complete = false
        defer { queue.endDiscovery(owner, complete: complete) }
        let scope = selectedScope
        let worker = Task.detached(priority: .userInitiated) { () -> ([MediaSource], Bool) in
            var planned: [MediaSource] = []
            var readable = true
            for source in sources {
                guard !Task.isCancelled else { return ([], false) }
                if case .asset(let id) = source {
                    if let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject {
                        planned += MediaComponentPlan.requiredSources(for: asset,
                            includeLivePhotoMotion: scope.includeLivePhotoMotion, includeOriginals: scope.includeOriginals)
                    } else { planned.append(source); readable = false }
                } else { planned.append(source) }
            }
            return (planned, readable)
        }
        let plan = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
        guard !Task.isCancelled, queue.ownsDiscovery(owner), scope == selectedScope else { return }
        queue.reverify(plan.0)
        complete = plan.1 && queue.persistenceWarning == nil
    }

    /// What else has to back up once this row's source is in the account: a
    /// Live Photo's motion, which is committed onto the still, and the version
    /// a Google Photos edit was applied on, which that app checks.
    ///
    /// Both answers come from one library fetch. This runs on the main actor
    /// as every row finishes, so a full-library backup pays for it once per
    /// item, and asking for the asset twice doubled that for no gain.
    private func followUps(after source: MediaSource) -> [MediaSource] {
        // A motion or edit-base row is itself a follow-up and has none of its
        // own. Checked before the fetch, which is the expensive part.
        guard let identifier = source.assetIdentifier,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else { return [] }
        switch source {
        case .asset:
            return MediaComponentPlan.requiredSources(for: asset,
                includeLivePhotoMotion: preferences.backUpLivePhotoMotion, includeOriginals: preferences.backUpOriginals)
                .filter { $0 != source && { if case .originalMotion = $0 { return false }; return true }($0) }
        case .original where preferences.backUpOriginals && preferences.backUpLivePhotoMotion && asset.mediaSubtypes.contains(.photoLive):
            return [.originalMotion(localIdentifier: identifier)]
        default: return []
        }
    }

    // Full scoped discovery now handles legacy edit rechecks and missing
    // companions together. Independent all-account backfills would bypass rules.

    func applicationDidEnterBackground() {
        cancelForegroundScan()
        execution.setForeground(false)
        let continuing = continuesInBackground
        if continuing {
            // iOS keeps the app running under the continued task, so the work
            // carries on, at a load a background process can hold.
            queue.setMaxConcurrent(min(preferences.concurrentUploads, ContinuedBackupPolicy.backgroundConcurrencyLimit))
            AppSessionTracker.note(.backgroundWork)
            beginContinuedRun()
        }
        if execution.hasExecutionTime { AppSessionTracker.note(.backgroundWork) }
        queue.flushPendingWrites()
        shouldRunAfterActivation = true
        updateSchedule()
        let transferring = queue.runningBackgroundTransferCount
        DiagnosticEventLog.shared.record(
            "lifecycle",
            "Left the app with \(queue.activeCount) unfinished, \(transferring) transferring in iOS"
                + (continuing ? "; iOS keeps the backup running in the background"
                    : queue.activeCount > transferring ? "; the rest waits for a background window or the next launch" : "")
        )
        DiagnosticEventLog.shared.flush()
    }

    func applicationDidBecomeActive() {
        execution.setForeground(true)
        refreshHealth()
        Task { await admission.refresh() }
        finishContinuedRun(success: true, ending: "the app was opened")
        queue.setMaxConcurrent(preferences.concurrentUploads)
        if shouldRunAfterActivation {
            shouldRunAfterActivation = false
            ranForegroundBackup = false
        }
        DiagnosticEventLog.shared.record(
            "lifecycle",
            "Opened the app; \(queue.activeCount) unfinished, \(queue.failedCount) failed"
        )
        runForegroundBackupIfNeeded()
        refreshContinuedBackup()
    }

    func applyNetworkPolicy() {
        photos.setCellularUploadsAllowed(preferences.connection == .wifiAndCellular)
        let decision = preferences.connection.decision(for: network.status)
        queue.setNetworkAccess(allowed: decision.allowsUploads, pauseReason: decision.pauseReason)
    }

    func updateSchedule() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
        guard registered else {
            noteSchedule("unregistered", "No background window requested: the task handler is not registered", level: .error)
            return
        }
        if let blocker = scheduleBlocker {
            noteSchedule("blocked: \(blocker)", "No background window requested: \(blocker)")
            return
        }

        let request = BGProcessingTaskRequest(identifier: Self.taskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = preferences.admissionSettings.onlyWhileCharging
        request.earliestBeginDate = Date(timeIntervalSinceNow: Self.processingRequestDelay)
        do {
            try BGTaskScheduler.shared.submit(request)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastRequestSubmittedKey)
            Self.logger.info("Scheduled the next automatic-backup processing request")
            noteSchedule(
                "scheduled",
                "Requested a background processing window: earliest in 15 minutes, with a network connection. iOS chooses the actual time, often overnight while charging."
            )
        } catch {
            let explanation = Self.explainSchedulingError(error)
            Self.logger.error("Could not schedule automatic backup: \(explanation, privacy: .public)")
            noteSchedule("failed: \(explanation)", "Could not request a background window: \(explanation)", level: .error)
        }
    }

    private func noteSchedule(_ state: String, _ message: String, level: DiagnosticEvent.Level = .info) {
        guard loggedScheduleState != state else { return }
        loggedScheduleState = state
        DiagnosticEventLog.shared.record("scheduler", message, level: level)
    }

    /// `BGTaskScheduler`'s error codes, in terms of what the user can change.
    static func explainSchedulingError(_ error: Error) -> String {
        guard let code = (error as? BGTaskScheduler.Error)?.code else { return error.localizedDescription }
        switch code {
        case .unavailable:
            return "background tasks are unavailable — Background App Refresh is off for this app or the whole device, or this is the Simulator"
        case .tooManyPendingTaskRequests:
            return "iOS already holds too many pending requests from this app"
        case .notPermitted:
            return "this build does not declare the task identifier in its Info.plist, or background activity is turned off for this app"
        #if compiler(>=6.2)
        case .immediateRunIneligible:
            // A continued-processing request asked to run now or not at all.
            return "iOS is too busy to start it right now"
        #endif
        @unknown default:
            return error.localizedDescription
        }
    }

    /// Why automatic backup cannot run, in the user's terms, or nil when it can.
    /// One source of truth so a refused run can say which condition stopped it
    /// instead of reporting a bare failure.
    var scheduleBlocker: String? { backupBlocker(requiringAutomaticBackup: true) }

    /// A Shortcuts automation is the user asking for a run, like Back Up Now,
    /// so it does not require the Automatic Backup switch. That also lets
    /// someone who wants backups only at a time of their choosing turn the
    /// switch off and schedule the shortcut instead.
    private func backupBlocker(requiringAutomaticBackup: Bool) -> String? {
        if !preferences.completedOnboarding { return "Onboarding is not finished" }
        if requiringAutomaticBackup, !preferences.automaticBackup { return "Automatic Backup is turned off" }
        if preferences.selectedAlbumIDs.isEmpty { return "No albums are selected" }
        if !account.status.isUsable {
            // Before the first unlock after a restart, the Keychain item holding
            // the credential cannot be read, so the account looks disconnected.
            return UIApplication.shared.isProtectedDataAvailable
                ? "No Google account is connected"
                : "No Google account is available — if the iPhone has not been unlocked since it restarted, the saved account cannot be read yet"
        }
        return nil
    }

    private var shouldSchedule: Bool { scheduleBlocker == nil }

    /// The conditions a run starts under. Recorded with every run, because
    /// "why did iOS run it then" and "why did it do so little" are mostly
    /// answered by these.
    func executionContext() -> String {
        var parts: [String] = []
        switch UIApplication.shared.applicationState {
        case .active: parts.append("app open")
        case .inactive: parts.append("app inactive")
        case .background: parts.append("app in background")
        @unknown default: parts.append("app state unknown")
        }
        parts.append("network \(network.status.diagnosticLabel)")
        parts.append(DiagnosticProcessInfo.batteryDescription())
        if ProcessInfo.processInfo.isLowPowerModeEnabled { parts.append("Low Power Mode on") }
        let thermal = ProcessInfo.processInfo.thermalState
        if thermal != .nominal { parts.append("thermal \(DiagnosticProcessInfo.thermal(thermal))") }
        if !UIApplication.shared.isProtectedDataAvailable { parts.append("device locked") }
        return parts.joined(separator: "; ")
    }

    private func runForegroundBackupIfNeeded() {
        guard isForeground,
              !ranForegroundBackup,
              shouldSchedule,
              !queue.isUserPaused,
              account.status.isUsable,
              preferences.connection.decision(for: network.status).allowsUploads else { return }

        ranForegroundBackup = true
        let runID = UUID()
        foregroundRunID = runID
        foregroundOperation = Task { @MainActor [weak self] in
            guard let self else { return }
            let completedBefore = self.queue.completedSourceCount
            let run = AutomaticBackupRunHistory.started(.foreground, context: self.executionContext())
            if let result = await self.discoverSelection(full: true) {
                await self.performForegroundBackup(result.scan.sources)
            } else { self.ranForegroundBackup = false }
            if self.foregroundRunID == runID {
                self.foregroundOperation = nil
                self.foregroundRunID = nil
            }
            self.finishForegroundRun(run, completedBefore: completedBefore)
        }
    }

    private func finishForegroundRun(_ run: UUID, completedBefore: Int) {
        let completed = max(0, queue.completedSourceCount - completedBefore)
        let summary: String
        if Task.isCancelled {
            summary = "interrupted when the app left the foreground or the selection changed"
        } else if !albums.canRead {
            summary = "no photo library access (\(DiagnosticReportBuilder.photoAuthorization()))"
        } else {
            summary = "backed up \(completed); \(queue.failedCount) failed; \(queue.activeCount) unfinished"
                + (queue.pauseReason.map { "; paused: \($0)" } ?? "")
        }
        AutomaticBackupRunHistory.finished(
            run,
            success: !Task.isCancelled && queue.backupSession?.outcome == .completed,
            summary: summary
        )
    }

    /// All scan paths invalidate the same revisions before deduplication and
    /// commit their baseline only after the queue has persisted the changes.
    /// The scan owns completion across every await and the durable queue handoff.
    /// Overlapping windows release only their own token; any incomplete scan keeps
    /// this logical session incomplete until a later complete discovery succeeds.
    private func discoverSelection(full: Bool, reverify: Bool = false, limit: Int? = nil)
        async -> (scan: PhotoLibraryChangeTracker.Scan, outcome: UploadQueue.EnqueueOutcome, released: Int)? {
        let owner = queue.beginDiscovery()
        var complete = false
        defer { queue.endDiscovery(owner, complete: complete); refreshHealth() }
        let scope = selectedScope
        await admission.refresh()
        await albums.refresh()
        guard albums.canRead, !Task.isCancelled, queue.ownsDiscovery(owner), scope == selectedScope else { return nil }
        let scan: PhotoLibraryChangeTracker.Scan
        if full {
            scan = await libraryChanges.scanAll(albums: albums, selectedAlbumIDs: preferences.selectedAlbumIDs,
                accountIdentifier: account.status.email, rules: preferences.selectionRules,
                includeLivePhotoMotion: preferences.backUpLivePhotoMotion, includeOriginals: preferences.backUpOriginals)
        } else {
            scan = await libraryChanges.scan(albums: albums, selectedAlbumIDs: preferences.selectedAlbumIDs,
                accountIdentifier: account.status.email, rules: preferences.selectionRules,
                includeLivePhotoMotion: preferences.backUpLivePhotoMotion, includeOriginals: preferences.backUpOriginals)
        }
        guard !Task.isCancelled, queue.ownsDiscovery(owner), scope == selectedScope, scan.scope == scope else { return nil }
        let released = queue.retryRetryableFailures()
        queue.invalidateChangedSources(scan.editedSources)
        if reverify { _ = queue.reverify(scan.sources, limit: limit) }
        let outcome = queue.enqueueReportingLimit(scan.sources, skippingExisting: true, limit: limit)
        if queue.persistenceWarning == nil {
            let committed = libraryChanges.commit(scan, advanceToken: !outcome.reachedLimit)
            complete = committed && !outcome.reachedLimit && scan.coverage != nil
                && scan.coverage?.unavailableMetadataCount == 0
        }
        return (scan, outcome, released)
    }

    /// Hand the selection to the queue and wait while it drains.
    ///
    /// `manual` runs are the user asking right now, so they are not gated on
    /// `shouldSchedule`. That gate includes "Automatic Backup is turned off" —
    /// which Stop Backup sets — so honouring it here meant a manual run enqueued
    /// one page and then found the loop condition already false, leaving the
    /// rest of the album unqueued until the user tapped again.
    private func performForegroundBackup(_ sources: [MediaSource], manual: Bool = false) async {
        // Same reasoning as the background window: earlier transport failures
        // are invisible to the scan and nothing else releases them.
        queue.retryRetryableFailures()
        guard isForeground, !Task.isCancelled, account.status.isUsable,
              manual || shouldSchedule, !isPausedForAnyReason else { return }
        queue.enqueue(sources, skippingExisting: true)
        // The scan already enqueued these sources. Even if dedup accepts no
        // additional rows, the run must wait for the existing work to settle.
        // iCloud-only rows do not hold a foreground run open indefinitely.
        while queue.hasWorkableItems {
            if Task.isCancelled || !isForeground || !account.status.isUsable
                || !(manual || shouldSchedule)
                || queue.haltReason != nil || isPausedForAnyReason { return }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    /// Any condition that stops the queue starting new work. Polling past one
    /// of these makes no progress and only keeps the main actor awake.
    private var isPausedForAnyReason: Bool {
        queue.isUserPaused || queue.networkPauseReason != nil || queue.systemPauseReason != nil || queue.admissionPauseReason != nil
    }

    /// The result of a manual "Back Up Now" or "Re-check Backups", so the UI can
    /// say what happened instead of leaving a button that appears to do nothing.
    enum ManualRunOutcome: Equatable {
        case noLibraryAccess
        case noAlbumsSelected
        case nothingToDo
        case started(count: Int)
        case rechecking(count: Int)
    }

    /// "Back Up Now". Queues the entire selection, so the count reported back is
    /// everything this run will attempt rather than the size of a first page.
    func backUpSelectedAlbumsNow() async -> ManualRunOutcome {
        guard !preferences.selectedAlbumIDs.isEmpty else { return noteManual(.manual, .noAlbumsSelected) }
        guard let result = await discoverSelection(full: true) else { return noteManual(.manual, .noLibraryAccess) }
        let total = result.outcome.accepted.count + result.released
        guard total > 0 else { return noteManual(.manual, .nothingToDo) }
        startForegroundRun(result.scan.sources, source: .manual)
        return .started(count: total)
    }

    /// "Re-check Backups". Forgets remembered completions for the selection and
    /// re-enqueues it; the worker's hash lookup settles anything still in the
    /// cloud without re-uploading it.
    func reverifySelectedAlbums() async -> ManualRunOutcome {
        guard !preferences.selectedAlbumIDs.isEmpty else { return noteManual(.recheck, .noAlbumsSelected) }
        // Count is the current queue after reverify; individual components are explicit.
        guard let result = await discoverSelection(full: true, reverify: true) else { return noteManual(.recheck, .noLibraryAccess) }
        let total = queue.activeCount
        guard total > 0 else { return noteManual(.recheck, .nothingToDo) }
        startForegroundRun(result.scan.sources, source: .recheck)
        return .rechecking(count: total)
    }

    /// Log a manual run that did not start, with the reason the user was shown.
    private func noteManual(_ source: AutomaticBackupRunSource, _ outcome: ManualRunOutcome) -> ManualRunOutcome {
        let reason: String
        switch outcome {
        case .noAlbumsSelected: reason = "no albums are selected"
        case .noLibraryAccess: reason = "the photo library cannot be read (\(DiagnosticReportBuilder.photoAuthorization()))"
        case .nothingToDo: reason = "everything selected is already backed up or queued"
        case .started, .rechecking: return outcome
        }
        DiagnosticEventLog.shared.record(
            "run",
            "\(source.rawValue) did not start: \(reason)",
            level: outcome == .nothingToDo ? .info : .warning
        )
        return outcome
    }

    /// Take over the foreground loop for a manually started run, so the queue
    /// keeps draining without the user tapping again.
    private func startForegroundRun(_ sources: [MediaSource], source: AutomaticBackupRunSource) {
        cancelForegroundScan()
        ranForegroundBackup = true
        let runID = UUID()
        foregroundRunID = runID
        let completedBefore = queue.completedSourceCount
        let run = AutomaticBackupRunHistory.started(source, context: executionContext())
        foregroundOperation = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performForegroundBackup(sources, manual: true)
            if self.foregroundRunID == runID {
                self.foregroundOperation = nil
                self.foregroundRunID = nil
            }
            self.finishForegroundRun(run, completedBefore: completedBefore)
        }
    }

    private func cancelForegroundScan() {
        foregroundOperation?.cancel()
        foregroundOperation = nil
        foregroundRunID = nil
    }

    private func begin(_ task: BGProcessingTask, window: BackgroundWindow) {
        guard !window.isExpired else {
            task.expirationHandler = nil
            task.setTaskCompleted(success: false)
            updateSchedule()
            return
        }
        Self.logger.info("Beginning an iOS background-processing window")
        let submitted = UserDefaults.standard.double(forKey: Self.lastRequestSubmittedKey)
        let waited = submitted > 0
            ? " \(Self.describeInterval(Date().timeIntervalSince1970 - submitted)) after it was requested"
            : ""
        DiagnosticEventLog.shared.record("scheduler", "iOS started a background processing window\(waited)")
        AppSessionTracker.note(.backgroundWork)
        let run = AutomaticBackupRunHistory.started(.backgroundProcessing, context: executionContext())
        let startedAt = Date()
        let previousRunID = backgroundRunID
        let executionID = execution.begin(.processing, foreground: UIApplication.shared.applicationState == .active)
        backgroundRunID = executionID
        // Install the new owner before releasing an older one. Its cancelled
        // operation may finish later, but can only release its own window.
        if let previousRunID { execution.end(previousRunID) }
        // Log the resubmission below even though its state has not changed:
        // it is what shows the chain of windows continues.
        loggedScheduleState = nil
        updateSchedule()
        backgroundOperation?.cancel()

        let operation = Task { @MainActor [weak self, weak task] in
            guard let self else {
                task?.setTaskCompleted(success: false)
                return
            }
            let report = await self.performBackgroundBackup()
            AutomaticBackupRunHistory.finished(run, success: report.success, summary: report.summary)
            self.execution.end(executionID)
            if !self.execution.hasExecutionTime { AppSessionTracker.note(.background) }
            // iOS may suspend the process as soon as the task completes.
            DiagnosticEventLog.shared.flush()
            task?.expirationHandler = nil
            task?.setTaskCompleted(success: report.success)
            Self.logger.info("Background-processing window finished; success=\(report.success)")
            if self.backgroundRunID == executionID {
                self.backgroundOperation = nil
                self.backgroundRunID = nil
            }
        }
        backgroundOperation = operation
        let expire: @Sendable () -> Void = { [weak self] in
            let elapsed = Int(Date().timeIntervalSince(startedAt).rounded())
            Self.logger.notice("iOS expired the background-processing window; requeuing unfinished uploads")
            DiagnosticEventLog.shared.record(
                "scheduler",
                "iOS ended the background processing window after \(elapsed) s; unfinished work stays queued",
                level: .warning
            )
            operation.cancel()
            Task { @MainActor [weak self] in
                // Expiration releases only this window. Foreground work,
                // another processing window or a Shortcut may still own time.
                self?.execution.end(executionID)
            }
        }
        task.expirationHandler = expire
        // iOS may already have expired the window while this hop was queued.
        window.adopt(expire)
    }

    static func describeInterval(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded())
        if total < 90 { return "\(total) s" }
        let minutes = total / 60
        if minutes < 90 { return "\(minutes) min" }
        let hours = minutes / 60
        if hours < 48 { return "\(hours) h \(minutes % 60) min" }
        return "\(hours / 24) days"
    }

    /// The outcome of one window, with the reason attached. `success` is what
    /// iOS is told; `summary` is what a human reads in Diagnostics and the log.
    struct BackgroundRunReport {
        let success: Bool
        let summary: String
    }

    /// Scan, queue, and wait for what can finish.
    ///
    /// - Parameters:
    ///   - settlementDeadline: stop waiting for uploads at this time even if
    ///     iOS has not ended the window. Unfinished work stays queued.
    ///   - requiresAutomaticBackup: false for runs the user asked for.
    ///   - waitsForUploads: false when the app is open and the foreground
    ///     carries on with the queue anyway.
    private func performBackgroundBackup(settlementDeadline: Date? = nil,
                                         requiresAutomaticBackup: Bool = true,
                                         waitsForUploads: Bool = true) async -> BackgroundRunReport {
        func interruption() -> BackgroundRunReport? {
            if Task.isCancelled {
                return .init(success: true, summary: "The execution window ended; unfinished work stays queued")
            }
            if let settlementDeadline, Date() >= settlementDeadline {
                return .init(success: true, summary: "The execution budget ended; unfinished work stays queued")
            }
            return nil
        }
        if let report = interruption() { return finish(report) }
        await photos.start()
        if let report = interruption() { return finish(report) }
        _ = await network.waitForInitialStatus()
        if let report = interruption() { return finish(report) }
        applyNetworkPolicy()

        // A user pause is durable and must not be bypassed by a scheduled run.
        guard !queue.isUserPaused else {
            return finish(.init(success: true, summary: "Paused by you — no work started"))
        }

        if let blocker = backupBlocker(requiringAutomaticBackup: requiresAutomaticBackup) {
            return finish(.init(success: false, summary: blocker))
        }
        let decision = preferences.connection.decision(for: network.status)
        guard decision.allowsUploads else {
            return finish(.init(success: false,
                                summary: decision.pauseReason ?? "The connection policy does not allow uploads"))
        }

        let failuresBefore = queue.failedCount
        guard let discovery = await discoverSelection(full: false, limit: Self.backgroundBatchLimit) else {
            return finish(.init(success: false, summary: "The scope could not be scanned; unfinished work remains queued"))
        }
        let scan = discovery.scan
        let outcome = discovery.outcome
        let released = discovery.released
        if let report = interruption() { return finish(report) }

        let backedUpBefore = queue.completedSourceCount
        let settled: Bool
        if waitsForUploads {
            settled = await queue.waitUntilSettled(until: settlementDeadline)
        } else {
            settled = true
        }
        let uploaded = max(0, queue.completedSourceCount - backedUpBefore)
        let newFailures = queue.failedCount - failuresBefore
        var parts: [String] = []
        if released > 0 { parts.append("retried \(released) earlier failure\(released == 1 ? "" : "s")") }
        parts.append("enqueued \(outcome.accepted.count)")
        if waitsForUploads { parts.append("backed up \(uploaded)") }
        // Report the standing failure count, not just this run's delta: a queue
        // that is entirely stuck reads as "nothing happened" otherwise.
        if queue.failedCount > 0 {
            parts.append(newFailures > 0
                ? "\(queue.failedCount) failed (\(newFailures) new)"
                : "\(queue.failedCount) still failing")
        }
        if queue.deferredForICloudCount > 0 {
            parts.append("\(queue.deferredForICloudCount) waiting on iCloud")
        }
        if outcome.reachedLimit { parts.append("more to scan next window") }
        // Say why zero, rather than leaving the reader to guess.
        if outcome.accepted.isEmpty, uploaded == 0, queue.failedCount == 0 {
            parts.append(scan.sources.isEmpty
                ? "no library changes since the last scan"
                : "everything in the selection is already backed up")
        }
        if !waitsForUploads, !queue.isIdle { parts.append("uploads continue in the app") }

        if let halt = queue.haltReason {
            return finish(.init(success: false, summary: "Stopped: \(halt)"))
        }
        if !settled {
            // Expiration, the deadline or a policy pause ends the wait, but the
            // work remains durably queued for the next opportunity. Report
            // success unless the credential halted or new failures appeared,
            // otherwise iOS backs off a window that did everything it could.
            let outOfTime = settlementDeadline.map { Date() >= $0 } == true
            let reason = queue.pauseReason ?? (outOfTime ? "time ran out" : "iOS ended the window")
            let handedOff = queue.runningBackgroundTransferCount
            parts.append("deferred — \(reason)")
            if handedOff > 0 { parts.append("\(handedOff) still transferring in iOS") }
            return finish(.init(success: newFailures == 0, summary: parts.joined(separator: " · ")))
        }
        return finish(.init(success: newFailures == 0, summary: parts.joined(separator: " · ")))
    }

    /// The Back Up Photos shortcut. A Shortcuts automation is a real execution
    /// opportunity, but a short one: iOS gives an App Intent about 30 seconds.
    /// Spend it scanning and preparing work, then leave file PUTs with the
    /// background URL session. Unprepared work stays queued for the next
    /// shortcut, processing window, or foreground launch.
    func performShortcutBackup() async -> BackgroundRunReport {
        let startedAt = Date()
        // Two runs over one queue would each requeue the other's work as they
        // ended. The window already scans for new photos.
        if execution.hasPreparationWindow {
            DiagnosticEventLog.shared.record(
                "shortcut",
                "Back Up Photos ran during another backup window, so it left the work to that window"
            )
            return BackgroundRunReport(
                success: true,
                summary: "A background backup is already running and will include new photos."
            )
        }
        let appActive = UIApplication.shared.applicationState == .active
        let run = AutomaticBackupRunHistory.started(.shortcut, context: executionContext())
        let executionID = execution.begin(.processing, foreground: appActive)
        defer {
            execution.end(executionID)
            if !execution.hasExecutionTime { AppSessionTracker.note(.background) }
            DiagnosticEventLog.shared.flush()
        }
        if !appActive {
            AppSessionTracker.note(.backgroundWork)
        }
        updateSchedule()
        let report = await performBackgroundBackup(
            settlementDeadline: startedAt.addingTimeInterval(Self.shortcutBudget),
            requiresAutomaticBackup: false,
            waitsForUploads: !appActive
        )
        // Releasing this action's window only suspends preparation when no
        // foreground, processing or continued task acquired time meanwhile.
        AutomaticBackupRunHistory.finished(run, success: report.success, summary: report.summary)
        return report
    }

    private func finish(_ report: BackgroundRunReport) -> BackgroundRunReport {
        if report.success {
            Self.logger.info("Automatic backup run: \(report.summary, privacy: .public)")
        } else {
            Self.logger.notice("Automatic backup run did not complete: \(report.summary, privacy: .public)")
        }
        return report
    }

    func diagnosticSnapshot() async -> AutomaticBackupDiagnosticSnapshot {
        let requests: [BGTaskRequest] = await withCheckedContinuation { continuation in
            BGTaskScheduler.shared.getPendingTaskRequests { continuation.resume(returning: $0) }
        }
        let summaries = requests.map { request in
            let processing = request as? BGProcessingTaskRequest
            return AutomaticBackupDiagnosticSnapshot.Request(
                identifier: request.identifier,
                kind: processing == nil ? "app-refresh" : "processing",
                earliestBeginDate: request.earliestBeginDate,
                requiresNetwork: processing?.requiresNetworkConnectivity,
                requiresPower: processing?.requiresExternalPower
            )
        }
        let submitted = UserDefaults.standard.double(forKey: Self.lastRequestSubmittedKey)
        return AutomaticBackupDiagnosticSnapshot(
            handlerRegistered: registered,
            appConsideredForeground: isForeground,
            foregroundOperationActive: foregroundOperation != nil,
            backgroundOperationActive: backgroundOperation != nil,
            scheduleBlocker: scheduleBlocker,
            networkStatus: network.status.diagnosticLabel,
            pendingRequests: summaries,
            lastRequestSubmittedAt: submitted > 0 ? Date(timeIntervalSince1970: submitted) : nil
        )
    }

    /// Called from the background URL-session delegate before iOS receives its
    /// relaunch completion handler. It restores the queue and lets completed
    /// PUT receipts reach the small commit RPC.
    func handleBackgroundURLSessionEvents() async {
        let run = AutomaticBackupRunHistory.started(.backgroundTransfer, context: executionContext())
        let appActive = UIApplication.shared.applicationState == .active
        if !appActive, !continuesInBackground, !execution.hasPreparationWindow {
            AppSessionTracker.note(.backgroundWork)
            // Pause before installing the transfer-only owner and restoring
            // the queue, so nothing starts before the real policy is applied.
            queue.setNetworkAccess(allowed: false, pauseReason: "Restoring background transfers")
        }
        let executionID = execution.begin(.transferDelivery, foreground: appActive)
        defer {
            execution.end(executionID)
            if !execution.hasExecutionTime { AppSessionTracker.note(.background) }
        }
        await photos.start()
        let completedBefore = queue.completedSourceCount
        _ = await network.waitForInitialStatus()
        applyNetworkPolicy()
        execution.setForeground(UIApplication.shared.applicationState == .active)
        await queue.waitUntilBackgroundTransfersHandled()
        execution.setForeground(UIApplication.shared.applicationState == .active)
        let confirmed = max(0, queue.completedSourceCount - completedBefore)
        AutomaticBackupRunHistory.finished(
            run,
            success: queue.haltReason == nil && queue.failedCount == 0,
            summary: "confirmed \(confirmed) with Google; \(queue.failedCount) failed; \(queue.activeCount) unfinished"
                + (queue.haltReason.map { "; stopped: \($0)" } ?? "")
        )
    }

#if DEBUG
    func simulateRun() {
        guard !execution.hasPreparationWindow else { return }
        debugSimulationStatus = "Running…"
        let run = AutomaticBackupRunHistory.started(.debugSimulation, context: executionContext())
        let executionID = execution.begin(.processing)
        backgroundRunID = executionID
        queue.setICloudDownloadsAllowed(false)
        backgroundOperation = Task { @MainActor [weak self] in
            guard let self else { return }
            let report = await self.performBackgroundBackup()
            self.debugSimulationStatus = report.summary
            AutomaticBackupRunHistory.finished(run, success: report.success, summary: report.summary)
            if self.isForeground { self.queue.setICloudDownloadsAllowed(true) }
            self.execution.end(executionID)
            if self.backgroundRunID == executionID {
                self.backgroundOperation = nil
                self.backgroundRunID = nil
            }
        }
    }
#endif
}

// MARK: - Continued backup (iOS 26)

extension AutomaticBackupCoordinator {
    /// True while a continued-processing task iOS has started keeps the app
    /// running in the background. A request iOS has not started yet does not
    /// count: leaving the app then has to hand over as it always did.
    var continuesInBackground: Bool {
        #if compiler(>=6.2)
        guard #available(iOS 26.0, *), let session = continuedSession as? ContinuedBackupSession else { return false }
        return session.isRunning
        #else
        return false
        #endif
    }

    #if compiler(>=6.2)
    @available(iOS 26.0, *)
    private func setUpContinuedBackup() {
        let session = ContinuedBackupSession()
        session.onExpired = { [weak self] in self?.continuedBackupExpired() }
        session.onStarted = { [weak self] in self?.continuedBackupStarted() }
        continuedSession = session
        // At most once a second: start a task when work appears while the app
        // is open, move its progress, and end it once the queue cannot move.
        continuedObservation = queue.objectWillChange
            .throttle(for: .seconds(1), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshContinuedBackup() }
            }
    }
    #endif

    private func queueCanMoveOnItsOwn(ignoringSystemPause: Bool = false) -> Bool {
        // Admission controls must not release execution time owned by work already admitted.
        if queue.admissionPauseReason != nil && queue.runningCount > 0 { return true }
        return ContinuedBackupPolicy.shouldContinue(
            hasWorkableItems: queue.hasWorkableItems,
            userPaused: queue.isUserPaused,
            halted: queue.haltReason != nil,
            networkPaused: queue.networkPauseReason != nil || queue.admissionPauseReason != nil,
            systemPaused: !ignoringSystemPause && queue.systemPauseReason != nil
        )
    }

    func refreshContinuedBackup() {
        #if compiler(>=6.2)
        guard #available(iOS 26.0, *), let session = continuedSession as? ContinuedBackupSession else { return }
        if session.isOverdue {
            continuedRetryAfter = Date().addingTimeInterval(60)
            DiagnosticEventLog.shared.record(
                "scheduler",
                "iOS accepted the request to keep the backup running but did not start it; trying again later",
                level: .warning
            )
            execution.setContinuedProcessing(false)
            session.finish()
            return
        }
        if session.isActive {
            // Leaving the foreground pauses preparation until the submitted
            // task actually starts. That pause must not cancel its own pending
            // execution grant; adoption will resume the queue.
            guard queueCanMoveOnItsOwn(ignoringSystemPause: !session.isRunning) else {
                return endContinuedBackup(session)
            }
            let progress = ContinuedBackupProgress(settledSinceStart: queue.settledRowCount - session.settledAtStart,
                                                   unfinished: queue.activeCount)
            let waiting = queue.rateLimitPauseReason == nil ? nil : "Waiting: Google asked the app to slow down"
            session.update(progress, subtitle: progress.subtitle(waitingFor: waiting))
            return
        }
        // iOS accepts the request only from the app in the foreground.
        guard UIApplication.shared.applicationState == .active, queueCanMoveOnItsOwn(),
              account.status.isUsable else { return }
        if let retryAfter = continuedRetryAfter, Date() < retryAfter { return }
        let permitted = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? []
        let prefixes = ContinuedBackupPolicy.identifierPrefixes(bundleIdentifier: Bundle.main.bundleIdentifier,
                                                                permitted: permitted)
        guard !prefixes.isEmpty else { return }
        let progress = ContinuedBackupProgress(settledSinceStart: 0, unfinished: queue.activeCount)
        var refusals: [String] = []
        for prefix in prefixes {
            do {
                try session.start(prefix: prefix, settledNow: queue.settledRowCount, subtitle: progress.subtitle(waitingFor: nil))
                continuedRetryAfter = nil
                DiagnosticEventLog.shared.record(
                    "scheduler",
                    "Asked iOS to keep the backup running if the app leaves the foreground, as \(prefix)*; \(queue.activeCount) unfinished"
                        + (refusals.isEmpty ? "" : "; refused first: " + refusals.joined(separator: "; "))
                )
                return
            } catch {
                refusals.append("\(prefix)*: \(Self.explainSchedulingError(error))")
            }
        }
        continuedRetryAfter = Date().addingTimeInterval(60)
        DiagnosticEventLog.shared.record(
            "scheduler",
            "iOS would not keep the backup running in the background (\(refusals.joined(separator: "; "))). It continues while the app is open",
            level: .warning
        )
        #endif
    }

    #if compiler(>=6.2)
    @available(iOS 26.0, *)
    private func endContinuedBackup(_ session: ContinuedBackupSession) {
        let idle = queue.backupSession?.outcome == .completed
        let reason = idle ? "nothing is left to back up" : (queue.pauseReason ?? "nothing can move on its own")
        finishContinuedRun(success: idle, ending: reason)
        DiagnosticEventLog.shared.record("scheduler", "Ended the background continuation: \(reason)")
        execution.setContinuedProcessing(false)
        if !execution.hasExecutionTime { AppSessionTracker.note(.background) }
        // iOS may suspend the app as soon as it hears the task is over.
        DiagnosticEventLog.shared.flush()
        session.finish()
    }
    #endif

    /// iOS normally starts the task while the app is open. If it started it
    /// only after the app left, take up the background settings now.
    private func continuedBackupStarted() {
        execution.setContinuedProcessing(true)
        guard UIApplication.shared.applicationState == .background else { return }
        queue.setMaxConcurrent(min(preferences.concurrentUploads, ContinuedBackupPolicy.backgroundConcurrencyLimit))
        AppSessionTracker.note(.backgroundWork)
        beginContinuedRun()
    }

    /// Runs before iOS is told the task is over; unfinished work is requeued
    /// the same way as when a processing window expires.
    private func continuedBackupExpired() {
        continuedRetryAfter = Date().addingTimeInterval(60)
        var lastItem = "no item had finished yet"
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), let finished = (continuedSession as? ContinuedBackupSession)?.lastItemFinishedAt {
            lastItem = "the last item finished \(Int(Date().timeIntervalSince(finished).rounded())) s earlier"
        }
        #endif
        DiagnosticEventLog.shared.record(
            "scheduler",
            "iOS ended the background continuation — Stop in the Live Activity, or iOS needed the CPU, memory or temperature headroom back; \(lastItem); \(DiagnosticProcessInfo.thermal(ProcessInfo.processInfo.thermalState)) thermal state. Unfinished work stays queued",
            level: .warning
        )
        finishContinuedRun(success: false, ending: "iOS ended it")
        execution.setContinuedProcessing(false)
        if !execution.hasExecutionTime { AppSessionTracker.note(.background) }
        DiagnosticEventLog.shared.flush()
    }

    private func beginContinuedRun() {
        guard continuedRun == nil else { return }
        let id = AutomaticBackupRunHistory.started(.continued, context: executionContext())
        continuedRun = (id, queue.settledRowCount)
    }

    private func finishContinuedRun(success: Bool, ending: String) {
        guard let run = continuedRun else { return }
        continuedRun = nil
        let settled = max(0, queue.settledRowCount - run.settledBefore)
        AutomaticBackupRunHistory.finished(
            run.id,
            success: success,
            summary: "finished \(settled) item\(settled == 1 ? "" : "s"); \(queue.failedCount) failed; \(queue.activeCount) unfinished; ended because \(ending)"
        )
    }
}

/// Bridges the gap between a `BGProcessingTask` arriving on a system queue and
/// the coordinator taking it over on the main actor. An expiration that lands
/// inside that gap is remembered and replayed to the real handler.
final class BackgroundWindow: @unchecked Sendable {
    private let lock = NSLock()
    private var expired = false
    private var handler: (@Sendable () -> Void)?

    var isExpired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return expired
    }

    func expire() {
        lock.lock()
        expired = true
        let handler = self.handler
        lock.unlock()
        handler?()
    }

    func adopt(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        self.handler = handler
        let alreadyExpired = expired
        lock.unlock()
        if alreadyExpired { handler() }
    }
}
