import XCTest
@testable import PhotosBackup

@MainActor
final class PhotoLibraryChangeTrackerTests: XCTestCase {
    private let context = "person@example.com\u{1F}album"
    private let source = MediaSource.asset(localIdentifier: "photo")

    private func tracker() -> (PhotoLibraryChangeTracker, URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("changes.json")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return (PhotoLibraryChangeTracker(url: url, observesLibraryChanges: false), url)
    }

    private func revision(_ time: Double) -> PhotoLibraryChangeTracker.AssetRevision {
        .init(modified: Date(timeIntervalSince1970: time), hasAdjustments: true)
    }

    func testFullScanDetectsAnEditAfterRelaunchWithoutChangeHistory() {
        let (tracker, url) = tracker()
        let first = tracker.makeScan(sources: [source], revisions: ["photo": revision(1)], context: context)
        XCTAssertEqual(first.editedSources, [source], "unknown revisions must be checked once")
        tracker.commit(first)

        let restored = PhotoLibraryChangeTracker(url: url, observesLibraryChanges: false)
        XCTAssertTrue(restored.makeScan(sources: [source], revisions: ["photo": revision(1)],
                                        context: context).editedSources.isEmpty)
        XCTAssertEqual(restored.makeScan(sources: [source], revisions: ["photo": revision(2)],
                                         context: context).editedSources, [source])
    }

    func testUncommittedScanDoesNotHideAnEdit() {
        let (tracker, _) = tracker()
        tracker.commit(tracker.makeScan(sources: [source], revisions: ["photo": revision(1)], context: context))
        _ = tracker.makeScan(sources: [source], revisions: ["photo": revision(2)], context: context)
        XCTAssertEqual(tracker.makeScan(sources: [source], revisions: ["photo": revision(2)],
                                        context: context).editedSources, [source])
    }

    func testAccountOrSelectionChangeCannotReuseAnotherBaseline() {
        let (tracker, _) = tracker()
        tracker.commit(tracker.makeScan(sources: [source], revisions: ["photo": revision(1)], context: context))
        for next in ["other@example.com\u{1F}album", "person@example.com\u{1F}other-album"] {
            XCTAssertEqual(tracker.makeScan(sources: [source], revisions: ["photo": revision(1)],
                                            context: next).editedSources, [source])
        }
    }

    func testOldTokenOnlySnapshotRechecksExistingAssets() throws {
        let (tracker, url) = tracker()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let legacy: [String: String] = ["context": context, "token": Data([1]).base64EncodedString()]
        try JSONEncoder().encode(legacy).write(to: url)
        let scan = tracker.makeScan(sources: [source], revisions: ["photo": revision(1)], context: context)
        XCTAssertEqual(scan.editedSources, [source])
        tracker.commit(scan)
        XCTAssertTrue(tracker.makeScan(sources: [source], revisions: ["photo": revision(1)],
                                       context: context).editedSources.isEmpty)
    }

    func testPartialBatchRemembersInvalidationButDoesNotAdvanceHistory() throws {
        let (tracker, url) = tracker()
        tracker.commit(tracker.makeScan(sources: [source], revisions: ["photo": revision(1)],
                                        context: context, nextToken: Data([1])))
        let changed = tracker.makeScan(sources: [source], revisions: ["photo": revision(2)],
                                        context: context, nextToken: Data([2]), fullScan: false)
        tracker.commit(changed, advanceToken: false)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(json["token"] as? String, Data([1]).base64EncodedString())
        XCTAssertTrue(tracker.makeScan(sources: [source], revisions: ["photo": revision(2)],
                                       context: context, fullScan: false).editedSources.isEmpty,
                      "a bounded rescan must not repeatedly cancel the same revision")
    }

    func testIncrementalScanKeepsUnchangedRevisionsAndDropsDeletedOnes() {
        let (tracker, _) = tracker()
        let other = MediaSource.asset(localIdentifier: "other")
        tracker.commit(tracker.makeScan(sources: [source, other], revisions: ["photo": revision(1), "other": revision(1)],
                                        context: context))
        tracker.commit(tracker.makeScan(sources: [source], revisions: ["photo": revision(2)], context: context,
                                        fullScan: false))
        XCTAssertTrue(tracker.makeScan(sources: [other], revisions: ["other": revision(1)],
                                       context: context, fullScan: false).editedSources.isEmpty)
        tracker.commit(tracker.makeScan(sources: [], revisions: [:], context: context,
                                        fullScan: false, deleted: ["other"]))
        XCTAssertEqual(tracker.makeScan(sources: [other], revisions: ["other": revision(1)],
                                        context: context, fullScan: false).editedSources, [other])
    }

    func testUnknownModificationDateIsNotTreatedAsProofOfAnUnchangedAsset() {
        let (tracker, _) = tracker()
        let unknown = PhotoLibraryChangeTracker.AssetRevision(modified: nil, hasAdjustments: false)
        tracker.commit(tracker.makeScan(sources: [source], revisions: ["photo": unknown], context: context))
        XCTAssertEqual(tracker.makeScan(sources: [source], revisions: ["photo": unknown],
                                        context: context).editedSources, [source])
    }

    func testBoundedScanDoesNotLoseUnqueuedEditsOrRestartQueuedOnes() {
        let (tracker, url) = tracker()
        let sources = (0..<3).map { MediaSource.asset(localIdentifier: "photo-\($0)") }
        let old = Dictionary(uniqueKeysWithValues: (0..<3).map { ("photo-\($0)", revision(1)) })
        let new = Dictionary(uniqueKeysWithValues: (0..<3).map { ("photo-\($0)", revision(2)) })
        tracker.commit(tracker.makeScan(sources: sources, revisions: old, context: context))

        let persistence = MemoryUploadQueuePersistence()
        let queue = UploadQueue(worker: WorkerScript([]).worker(), persistence: persistence)
        queue.setNetworkAccess(allowed: false)
        queue.activateAccount("person@example.com")
        let scan = tracker.makeScan(sources: sources, revisions: new, context: context)
        queue.invalidateChangedSources(scan.editedSources)
        let batch = queue.enqueueReportingLimit(scan.sources, skippingExisting: true, limit: 2)
        XCTAssertTrue(batch.reachedLimit)
        tracker.commit(scan, advanceToken: false)
        let originalIDs = queue.items.map(\.id)

        let restored = UploadQueue(worker: WorkerScript([]).worker(), persistence: persistence)
        restored.setNetworkAccess(allowed: false)
        restored.activateAccount("person@example.com")
        let next = PhotoLibraryChangeTracker(url: url, observesLibraryChanges: false).makeScan(sources: sources, revisions: new, context: context)
        XCTAssertTrue(next.editedSources.isEmpty)
        restored.invalidateChangedSources(next.editedSources)
        XCTAssertEqual(restored.enqueueReportingLimit(next.sources, skippingExisting: true, limit: 2).accepted.count, 1)
        XCTAssertEqual(Array(restored.items.prefix(2).map(\.id)), originalIDs)
        XCTAssertEqual(restored.items.count, 3)
    }
}

@MainActor
final class BackupScopePersistenceTests: XCTestCase {
    private func tracker() -> (PhotoLibraryChangeTracker, URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("changes.json")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return (PhotoLibraryChangeTracker(url: url, observesLibraryChanges: false), url)
    }

    private func descriptor(_ tracker: PhotoLibraryChangeTracker, account: String = "account", rules: BackupSelectionRules = .init()) -> BackupScopeDescriptor {
        tracker.scope(selectedAlbumIDs: ["album"], accountIdentifier: account, rules: rules, authorization: 3)
    }

    private func scan(_ tracker: PhotoLibraryChangeTracker, scope: BackupScopeDescriptor) -> PhotoLibraryChangeTracker.Scan {
        let manifest = BackupScopeManifest(scope: scope, scannedAt: Date(timeIntervalSince1970: 100),
                                           assets: [.init(identifier: "a", requiredKeys: ["asset:a"])],
                                           excludedCount: 0, unavailableMetadataCount: 0)
        return tracker.makeScan(sources: [.asset(localIdentifier: "a")],
                                revisions: ["a": .init(modified: Date(timeIntervalSince1970: 1), hasAdjustments: false)],
                                context: scope.fingerprint, scope: scope, manifest: manifest)
    }

    func testCoverageRequiresCommittedCompleteHandoffAndRevalidationAfterRelaunch() {
        let (tracker, url) = tracker()
        let scope = descriptor(tracker)
        let prepared = scan(tracker, scope: scope)
        XCTAssertNil(tracker.coverage(for: scope))
        XCTAssertTrue(tracker.commit(prepared, advanceToken: false))
        XCTAssertNil(tracker.coverage(for: scope), "a bounded incomplete handoff cannot claim scanned coverage")
        XCTAssertNil(tracker.lastSuccessfulScan(for: scope), "an incomplete first handoff has no successful scan date")
        XCTAssertTrue(tracker.commit(prepared))
        XCTAssertNotNil(tracker.coverage(for: scope))
        let relaunched = PhotoLibraryChangeTracker(url: url, observesLibraryChanges: false)
        XCTAssertNil(relaunched.coverage(for: scope), "Photos access/history must be checked again")
        XCTAssertEqual(relaunched.lastSuccessfulScan(for: scope), Date(timeIntervalSince1970: 100))
    }

    func testIncompleteHandoffPreservesPreviousSuccessfulScanDateAfterRelaunch() {
        let (tracker, url) = tracker()
        let scope = descriptor(tracker)
        XCTAssertTrue(tracker.commit(scan(tracker, scope: scope)))
        let newer = BackupScopeManifest(scope: scope, scannedAt: Date(timeIntervalSince1970: 200),
                                         assets: [], excludedCount: 0, unavailableMetadataCount: 0)
        let partial = tracker.makeScan(sources: [], revisions: [:], context: scope.fingerprint,
                                       scope: scope, manifest: newer)
        XCTAssertTrue(tracker.commit(partial, advanceToken: false))
        XCTAssertNil(tracker.coverage(for: scope))
        XCTAssertEqual(tracker.lastSuccessfulScan(for: scope), Date(timeIntervalSince1970: 100))
        let restored = PhotoLibraryChangeTracker(url: url, observesLibraryChanges: false)
        XCTAssertEqual(restored.lastSuccessfulScan(for: scope), Date(timeIntervalSince1970: 100))
        XCTAssertTrue(restored.requiresFullScan(for: scope))
    }

    func testIncrementalChangesPersistCoverageInvalidationAndRequireFullScanAfterRelaunch() {
        let (tracker, url) = tracker()
        let scope = descriptor(tracker)
        tracker.commit(scan(tracker, scope: scope))
        XCTAssertFalse(tracker.requiresFullScan(for: scope))
        // Incremental discovery found a new asset, so its old full manifest
        // no longer describes the whole current selection.
        let delta = tracker.makeScan(sources: [.asset(localIdentifier: "new")],
            revisions: ["new": .init(modified: Date(timeIntervalSince1970: 2), hasAdjustments: false)],
            context: scope.fingerprint, nextToken: Data([2]), fullScan: false, scope: scope)
        XCTAssertTrue(tracker.commit(delta))
        XCTAssertNil(tracker.coverage(for: scope))
        XCTAssertTrue(tracker.requiresFullScan(for: scope))
        let restored = PhotoLibraryChangeTracker(url: url, observesLibraryChanges: false)
        XCTAssertTrue(restored.requiresFullScan(for: scope), "an empty next history batch cannot promote the stale manifest")
        XCTAssertNil(restored.coverage(for: scope))
        XCTAssertEqual(restored.lastSuccessfulScan(for: scope), Date(timeIntervalSince1970: 100), "historical scan date remains available")
    }

    func testPhotoLibraryChangeDuringScanRejectsCommitAndInvalidatesCoverage() {
        let (tracker, _) = tracker()
        let scope = descriptor(tracker)
        let prepared = scan(tracker, scope: scope)
        XCTAssertTrue(tracker.commit(prepared))
        tracker.invalidateCoverage()
        XCTAssertNil(tracker.coverage(for: scope))
        XCTAssertFalse(tracker.commit(prepared))
        XCTAssertNotEqual(descriptor(tracker).fingerprint, scope.fingerprint)
    }

    func testChangingRulesPreservesKnownRevisionAndExistingBackupHistory() {
        let (tracker, _) = tracker()
        let first = descriptor(tracker)
        tracker.commit(scan(tracker, scope: first))
        var rules = BackupSelectionRules(); rules.excludeScreenshots = true
        let narrower = descriptor(tracker, rules: rules)
        let changed = scan(tracker, scope: narrower)
        XCTAssertTrue(changed.editedSources.isEmpty, "rule changes alone must not invalidate completed bytes")
        XCTAssertNil(tracker.coverage(for: narrower))
        tracker.commit(changed)
        let broader = descriptor(tracker)
        XCTAssertTrue(scan(tracker, scope: broader).editedSources.isEmpty)
        XCTAssertNotNil(tracker.coverage(for: narrower))
    }

    func testExcludedAssetRevisionDoesNotAdvanceAndHideEditsWhenRulesBroaden() {
        let (tracker, _) = tracker()
        let originalScope = descriptor(tracker)
        tracker.commit(scan(tracker, scope: originalScope))
        var rules = BackupSelectionRules(); rules.media = .videos
        let narrower = descriptor(tracker, rules: rules)
        // The photo is excluded: discovery must not submit its new revision.
        tracker.commit(tracker.makeScan(sources: [], revisions: [:], context: narrower.fingerprint,
                                        scope: narrower))
        let broader = descriptor(tracker)
        let edited = tracker.makeScan(sources: [.asset(localIdentifier: "a")],
            revisions: ["a": .init(modified: Date(timeIntervalSince1970: 2), hasAdjustments: true)],
            context: broader.fingerprint, scope: broader)
        XCTAssertEqual(edited.editedSources, [.asset(localIdentifier: "a")])
        let unchanged = scan(tracker, scope: broader)
        XCTAssertTrue(unchanged.editedSources.isEmpty, "an unchanged excluded asset retains its valid history")
    }

    func testAccountChangeNeverReusesAnotherAccountsRevisionOrCoverage() {
        let (tracker, _) = tracker()
        tracker.commit(scan(tracker, scope: descriptor(tracker)))
        let other = descriptor(tracker, account: "other")
        XCTAssertEqual(scan(tracker, scope: other).editedSources, [.asset(localIdentifier: "a")])
        XCTAssertNil(tracker.coverage(for: other))
        XCTAssertNil(tracker.lastSuccessfulScan(for: other))
    }

    func testRuleChangeDuringIncrementalBatchRequiresItsOwnFullBaseline() {
        let (tracker, url) = tracker()
        let first = descriptor(tracker)
        tracker.commit(scan(tracker, scope: first))
        var rules = BackupSelectionRules(); rules.media = .videos
        let changed = descriptor(tracker, rules: rules)
        let partial = tracker.makeScan(sources: [], revisions: [:], context: changed.fingerprint,
                                       nextToken: Data([9]), fullScan: false, scope: changed)
        tracker.commit(partial, advanceToken: false)
        XCTAssertNil(tracker.coverage(for: changed))
        XCTAssertNil(PhotoLibraryChangeTracker(url: url, observesLibraryChanges: false).coverage(for: changed))
    }
}
