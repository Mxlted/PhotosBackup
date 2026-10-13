import Foundation
import Combine
import Photos

/// Tracks both PhotoKit history and scanned revisions. History finds backdated
/// imports cheaply; revisions detect edits during full scans, including iOS 15
/// and recovery from expired history. Neither is a claim of upload completion.
@MainActor
final class PhotoLibraryChangeTracker: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    @Published private(set) var libraryRevision: UInt64 = 0
    @Published private(set) var latestManifest: BackupScopeManifest?
    private var coverageTrusted = false
    private let observesLibraryChanges: Bool

    struct Scan {
        let sources: [MediaSource]
        /// Assets whose scanned revision changed or is not yet known. Their
        /// bytes may differ from the recorded backup, so invalidate old queue
        /// state before deduplication.
        let editedSources: [MediaSource]
        let scope: BackupScopeDescriptor?
        let coverage: BackupScopeManifest?
        let fullScan: Bool
        fileprivate let nextState: StoredState?

        fileprivate init(sources: [MediaSource], editedSources: [MediaSource] = [], nextState: StoredState? = nil,
                         scope: BackupScopeDescriptor? = nil, coverage: BackupScopeManifest? = nil, fullScan: Bool = true) {
            self.sources = sources
            self.editedSources = editedSources
            self.nextState = nextState
            self.scope = scope
            self.coverage = coverage
            self.fullScan = fullScan
        }
    }

    fileprivate struct StoredState: Codable {
        let context: String
        let token: Data?
        // Optional to read snapshots from versions that only stored a token.
        let revisions: [String: AssetRevision]?
        var manifest: BackupScopeManifest? = nil
        var scope: BackupScopeDescriptor? = nil
        // Optional for older scan snapshots. A historical manifest must not
        // silently become current after a later empty persistent-change batch.
        var coverageIsCurrent: Bool? = nil
    }

    struct AssetRevision: Codable, Equatable, Sendable {
        let modified: Date?
        let hasAdjustments: Bool
    }

    private let url: URL

    init(url: URL? = nil, observesLibraryChanges: Bool = true) {
        self.observesLibraryChanges = observesLibraryChanges
        if let url {
            self.url = url
        } else {
            self.url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("PhotosBackup", isDirectory: true)
                .appendingPathComponent("photo-library-change-token-v1.json")
        }
        super.init()
        latestManifest = load()?.manifest
        if observesLibraryChanges { PHPhotoLibrary.shared().register(self) }
    }

    deinit { if observesLibraryChanges { PHPhotoLibrary.shared().unregisterChangeObserver(self) } }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak self] in self?.invalidateCoverage() }
    }

    func invalidateCoverage() {
        coverageTrusted = false
        libraryRevision &+= 1
    }

    func scope(selectedAlbumIDs: Set<String>, accountIdentifier: String?, rules: BackupSelectionRules = .init(),
               includeLivePhotoMotion: Bool = false, includeOriginals: Bool = false, authorization: Int) -> BackupScopeDescriptor {
        BackupScopeDescriptor(accountIdentifier: accountIdentifier, selectedAlbumIDs: selectedAlbumIDs, rules: rules,
                              includeLivePhotoMotion: includeLivePhotoMotion, includeOriginals: includeOriginals,
                              authorization: authorization, libraryRevision: libraryRevision)
    }

    func coverage(for scope: BackupScopeDescriptor) -> BackupScopeManifest? {
        guard coverageTrusted, latestManifest?.scope == scope else { return nil }
        return latestManifest
    }

    func lastSuccessfulScan(for scope: BackupScopeDescriptor) -> Date? {
        guard let manifest = latestManifest else { return nil }
        let previous = manifest.scope
        guard previous.accountIdentifier == scope.accountIdentifier, previous.selectedAlbumIDs == scope.selectedAlbumIDs,
              previous.rules == scope.rules, previous.includeLivePhotoMotion == scope.includeLivePhotoMotion,
              previous.includeOriginals == scope.includeOriginals, previous.authorization == scope.authorization else { return nil }
        return manifest.scannedAt
    }

    func requiresFullScan(for scope: BackupScopeDescriptor) -> Bool {
        guard let stored = load(), stored.context == scope.fingerprint,
              stored.revisions != nil, stored.coverageIsCurrent == true,
              stored.manifest?.scope == scope else { return true }
        return false
    }

    /// History only changes the candidates; metadata rules and component planning
    /// are shared with the full scan. All PhotoKit enumeration runs off-main.
    func scan(albums: PhotoAlbumStore, selectedAlbumIDs: Set<String>, accountIdentifier: String?,
              rules: BackupSelectionRules = .init(), includeLivePhotoMotion: Bool = false,
              includeOriginals: Bool = false) async -> Scan {
        await prepareScan(selectedAlbumIDs: selectedAlbumIDs, accountIdentifier: accountIdentifier,
                          rules: rules, includeLivePhotoMotion: includeLivePhotoMotion,
                          includeOriginals: includeOriginals, authorization: albums.authorization.rawValue,
                          forceFullScan: false)
    }

    func scanAll(albums: PhotoAlbumStore, selectedAlbumIDs: Set<String>, accountIdentifier: String?,
                 rules: BackupSelectionRules = .init(), includeLivePhotoMotion: Bool = false,
                 includeOriginals: Bool = false) async -> Scan {
        await prepareScan(selectedAlbumIDs: selectedAlbumIDs, accountIdentifier: accountIdentifier,
                          rules: rules, includeLivePhotoMotion: includeLivePhotoMotion,
                          includeOriginals: includeOriginals, authorization: albums.authorization.rawValue,
                          forceFullScan: true)
    }

    private func prepareScan(selectedAlbumIDs: Set<String>, accountIdentifier: String?, rules: BackupSelectionRules,
                             includeLivePhotoMotion: Bool, includeOriginals: Bool, authorization: Int,
                             forceFullScan: Bool) async -> Scan {
        let descriptor = scope(selectedAlbumIDs: selectedAlbumIDs, accountIdentifier: accountIdentifier,
                               rules: rules, includeLivePhotoMotion: includeLivePhotoMotion,
                               includeOriginals: includeOriginals, authorization: authorization)
        let stored = load()
        let sameContext = stored?.context == descriptor.fingerprint
        let oldToken = sameContext ? stored?.token : nil
        let canUseHistory = !forceFullScan && !requiresFullScan(for: descriptor)
        let reader = Task.detached(priority: .utility) {
            BackupScopeReader.read(scope: descriptor, priorToken: canUseHistory ? oldToken : nil)
        }
        let result = await withTaskCancellationHandler(operation: { await reader.value }, onCancel: { reader.cancel() })
        guard !Task.isCancelled, !result.cancelled, descriptor.libraryRevision == libraryRevision else {
            return Scan(sources: [], scope: descriptor, fullScan: false)
        }
        let manifest = result.fullScan
            ? BackupScopeManifest(scope: descriptor, scannedAt: Date(), assets: result.assets,
                                  excludedCount: result.preview.excluded, unavailableMetadataCount: result.unavailableCount)
            : (result.hasLibraryChanges ? nil : stored?.manifest)
        return makeScan(sources: result.sources, revisions: result.revisions, context: descriptor.fingerprint,
                        nextToken: result.nextToken, fullScan: result.fullScan, deleted: result.deleted,
                        scope: descriptor, manifest: manifest)
    }

    /// The same revision comparison is used by history batches and full scans.
    /// Missing old revisions (including an upgrade) trigger a hash recheck once.
    /// The worker still skips bytes already held by Google.
    func makeScan(sources: [MediaSource], revisions: [String: AssetRevision], context: String,
                  nextToken: Data? = nil, fullScan: Bool = true, deleted: Set<String> = [],
                  scope: BackupScopeDescriptor? = nil, manifest: BackupScopeManifest? = nil) -> Scan {
        let stored = load()
        // Rule, variant and album changes force enumeration without erasing
        // valid completion history for unchanged assets in this same account.
        let sameAccount = scope?.accountIdentifier != nil && stored?.scope?.accountIdentifier == scope?.accountIdentifier
        let previous = stored?.context == context || sameAccount ? stored?.revisions ?? [:] : [:]
        let edited = sources.filter { source in
            guard case .asset(let id) = source else { return false }
            guard let revision = revisions[id], revision.modified != nil else { return true }
            return previous[id] != revision
        }
        // Retain revisions of assets outside the new scope. Advancing those
        // without invalidating their completion would hide edits on re-inclusion.
        // A real PhotoKit deletion still removes the obsolete revision below.
        var next = fullScan && !sameAccount ? revisions : previous.merging(revisions) { _, new in new }
        for id in deleted { next[id] = nil }
        return Scan(sources: sources, editedSources: edited,
                    nextState: StoredState(context: context, token: nextToken, revisions: next, manifest: manifest, scope: scope, coverageIsCurrent: manifest != nil),
                    scope: scope, coverage: manifest, fullScan: fullScan)
    }

    /// Revisions may advance after stale completions have been durably removed.
    /// Only advance history when all sources have durable queue handles. Keeping
    /// the earlier token on a bounded batch finds the rest on the next window.
    @discardableResult
    func commit(_ scan: Scan, advanceToken: Bool = true) -> Bool {
        guard let state = scan.nextState else { return false }
        guard scan.scope == nil || scan.scope?.libraryRevision == libraryRevision else { return false }
        do {
            let previous = load()
            let token = advanceToken ? state.token : (previous?.context == state.context ? previous?.token : nil)
            // An incomplete handoff may advance revision invalidations, but
            // must not replace the last successfully handed-off scope/date.
            let manifest = advanceToken ? (state.manifest ?? previous?.manifest) : previous?.manifest
            let committed = StoredState(context: state.context, token: token, revisions: state.revisions,
                                        manifest: manifest, scope: state.scope,
                                        coverageIsCurrent: advanceToken && state.coverageIsCurrent == true)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(committed).write(to: url, options: .atomic)
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path
            )
            latestManifest = committed.manifest
            coverageTrusted = committed.coverageIsCurrent == true
            return true
        } catch {
            // Keeping the prior token causes harmless re-enqueue attempts; the
            // queue's durable asset-key ledger removes duplicates.
            DiagnosticEventLog.shared.record(
                "library",
                "Could not save the library scan position; the next scan repeats some work: \(error.localizedDescription)",
                level: .warning
            )
            return false
        }
    }

    func reset() {
        try? FileManager.default.removeItem(at: url)
        latestManifest = nil
        coverageTrusted = false
    }

    private func load() -> StoredState? {
        try? JSONDecoder().decode(StoredState.self, from: Data(contentsOf: url))
    }

}
