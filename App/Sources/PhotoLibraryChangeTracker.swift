import Foundation
import Photos

/// Tracks both PhotoKit history and scanned revisions. History finds backdated
/// imports cheaply; revisions detect edits during full scans, including iOS 15
/// and recovery from expired history. Neither is a claim of upload completion.
@MainActor
final class PhotoLibraryChangeTracker {
    struct Scan {
        let sources: [MediaSource]
        /// Assets whose scanned revision changed or is not yet known. Their
        /// bytes may differ from the recorded backup, so invalidate old queue
        /// state before deduplication.
        let editedSources: [MediaSource]
        fileprivate let nextState: StoredState?

        fileprivate init(sources: [MediaSource], editedSources: [MediaSource] = [], nextState: StoredState? = nil) {
            self.sources = sources
            self.editedSources = editedSources
            self.nextState = nextState
        }
    }

    fileprivate struct StoredState: Codable {
        let context: String
        let token: Data?
        // Optional to read snapshots from versions that only stored a token.
        let revisions: [String: AssetRevision]?
    }

    struct AssetRevision: Codable, Equatable, Sendable {
        let modified: Date?
        let hasAdjustments: Bool
    }

    private let url: URL

    init(url: URL? = nil) {
        if let url {
            self.url = url
        } else {
            self.url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("PhotosBackup", isDirectory: true)
                .appendingPathComponent("photo-library-change-token-v1.json")
        }
    }

    func scan(albums: PhotoAlbumStore, selectedAlbumIDs: Set<String>, accountIdentifier: String?) -> Scan {
        let context = Self.context(selectedAlbumIDs, accountIdentifier)
        guard #available(iOS 16, *) else {
            let sources = albums.sourcesSynchronously(for: selectedAlbumIDs)
            DiagnosticEventLog.shared.record(
                "library",
                "Scanned the selected albums in full (iOS 15 keeps no change history): \(sources.count) items"
            )
            return makeScan(sources: sources, revisions: Self.readRevisions(sources), context: context)
        }

        let library = PHPhotoLibrary.shared()
        let current = library.currentChangeToken
        let nextToken = archive(current)
        guard let stored = load(), stored.context == context,
              stored.revisions != nil,
              let data = stored.token, let token = unarchive(data) else {
            let sources = albums.sourcesSynchronously(for: selectedAlbumIDs)
            let why = load() == nil
                ? "no earlier scan to compare with"
                : "the album selection or account changed since the last scan"
            DiagnosticEventLog.shared.record(
                "library",
                "Scanned the selected albums in full (\(why)): \(sources.count) items"
            )
            return makeScan(sources: sources, revisions: Self.readRevisions(sources),
                            context: context, nextToken: nextToken)
        }

        do {
            let changes = try library.fetchPersistentChanges(since: token)
            var inserted = Set<String>()
            var updated = Set<String>()
            var deleted = Set<String>()
            var selectedCollectionChanged = false
            for change in changes {
                let assetDetails = try change.changeDetails(for: .asset)
                inserted.formUnion(assetDetails.insertedLocalIdentifiers)
                updated.formUnion(assetDetails.updatedLocalIdentifiers)
                deleted.formUnion(assetDetails.deletedLocalIdentifiers)
                if !selectedAlbumIDs.contains(PhotoAlbum.allPhotosID) {
                    let collectionDetails = try change.changeDetails(for: .assetCollection)
                    let changedCollections = collectionDetails.insertedLocalIdentifiers
                        .union(collectionDetails.updatedLocalIdentifiers)
                    if !selectedAlbumIDs.isDisjoint(with: changedCollections) {
                        selectedCollectionChanged = true
                    }
                }
            }
            // An asset can appear in both sets across a batch of changes; a new
            // asset is not an edit, so insertion wins.
            updated.subtract(inserted)
            let sources = selectedCollectionChanged
                ? albums.sourcesSynchronously(for: selectedAlbumIDs)
                : albums.sources(for: selectedAlbumIDs, matching: inserted.union(updated))
            DiagnosticEventLog.shared.record(
                "library",
                selectedCollectionChanged
                    ? "A selected album changed, so the selection was rescanned in full: \(sources.count) items"
                    : "Read the library's change history: \(inserted.count) added, \(updated.count) edited; \(sources.count) in the selected albums"
            )
            return makeScan(sources: sources, revisions: Self.readRevisions(sources),
                            context: context, nextToken: nextToken,
                            fullScan: selectedCollectionChanged, deleted: deleted)
        } catch {
            // Expired/unavailable history requires one correctness-first current
            // scan, after which the fresh token becomes the new baseline.
            let sources = albums.sourcesSynchronously(for: selectedAlbumIDs)
            DiagnosticEventLog.shared.record(
                "library",
                "The library's change history was unavailable (\(error.localizedDescription)), so the selection was scanned in full: \(sources.count) items",
                level: .warning
            )
            return makeScan(sources: sources, revisions: Self.readRevisions(sources),
                            context: context, nextToken: nextToken)
        }
    }

    /// Foreground and manual runs retain a full selection for their progress
    /// counts. Capture the token BEFORE reading assets so edits arriving during
    /// the scan remain visible in the next history batch.
    func scanAll(albums: PhotoAlbumStore, selectedAlbumIDs: Set<String>, accountIdentifier: String?) async -> Scan {
        let context = Self.context(selectedAlbumIDs, accountIdentifier)
        let token: Data?
        if #available(iOS 16, *) { token = archive(PHPhotoLibrary.shared().currentChangeToken) }
        else { token = nil }
        let sources = await albums.sources(for: selectedAlbumIDs)
        let revisions = await Task.detached(priority: .utility) { Self.readRevisions(sources) }.value
        return makeScan(sources: sources, revisions: revisions, context: context, nextToken: token)
    }

    private static func context(_ albumIDs: Set<String>, _ account: String?) -> String {
        ([account?.lowercased() ?? ""] + albumIDs.sorted()).joined(separator: "\u{1F}")
    }

    private nonisolated static func readRevisions(_ sources: [MediaSource]) -> [String: AssetRevision] {
        let identifiers = sources.compactMap { source -> String? in
            if case .asset(let id) = source { return id }
            return nil
        }
        var revisions: [String: AssetRevision] = [:]
        PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil).enumerateObjects { asset, _, _ in
            revisions[asset.localIdentifier] = AssetRevision(modified: asset.modificationDate,
                                                             hasAdjustments: asset.hasAdjustments)
        }
        return revisions
    }

    /// The same revision comparison is used by history batches and full scans.
    /// Missing old revisions (including an upgrade) trigger a hash recheck once.
    /// The worker still skips bytes already held by Google.
    func makeScan(sources: [MediaSource], revisions: [String: AssetRevision], context: String,
                  nextToken: Data? = nil, fullScan: Bool = true, deleted: Set<String> = []) -> Scan {
        let stored = load()
        let previous = stored?.context == context ? stored?.revisions ?? [:] : [:]
        let edited = sources.filter { source in
            guard case .asset(let id) = source else { return false }
            guard let revision = revisions[id], revision.modified != nil else { return true }
            return previous[id] != revision
        }
        var next = fullScan ? revisions : previous.merging(revisions) { _, new in new }
        for id in deleted { next[id] = nil }
        return Scan(sources: sources, editedSources: edited,
                    nextState: StoredState(context: context, token: nextToken, revisions: next))
    }

    /// Revisions may advance after stale completions have been durably removed.
    /// Only advance history when all sources have durable queue handles. Keeping
    /// the earlier token on a bounded batch finds the rest on the next window.
    func commit(_ scan: Scan, advanceToken: Bool = true) {
        guard let state = scan.nextState else { return }
        do {
            let previous = load()
            let token = advanceToken ? state.token : (previous?.context == state.context ? previous?.token : nil)
            let committed = StoredState(context: state.context, token: token, revisions: state.revisions)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(committed).write(to: url, options: .atomic)
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path
            )
        } catch {
            // Keeping the prior token causes harmless re-enqueue attempts; the
            // queue's durable asset-key ledger removes duplicates.
            DiagnosticEventLog.shared.record(
                "library",
                "Could not save the library scan position; the next scan repeats some work: \(error.localizedDescription)",
                level: .warning
            )
        }
    }

    func reset() { try? FileManager.default.removeItem(at: url) }

    private func load() -> StoredState? {
        try? JSONDecoder().decode(StoredState.self, from: Data(contentsOf: url))
    }

    @available(iOS 16, *)
    private func archive(_ token: PHPersistentChangeToken) -> Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
    }

    @available(iOS 16, *)
    private func unarchive(_ data: Data) -> PHPersistentChangeToken? {
        try? NSKeyedUnarchiver.unarchivedObject(ofClass: PHPersistentChangeToken.self, from: data)
    }
}
