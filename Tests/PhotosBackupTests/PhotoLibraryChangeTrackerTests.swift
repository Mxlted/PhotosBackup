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
        return (PhotoLibraryChangeTracker(url: url), url)
    }

    private func revision(_ time: Double) -> PhotoLibraryChangeTracker.AssetRevision {
        .init(modified: Date(timeIntervalSince1970: time), hasAdjustments: true)
    }

    func testFullScanDetectsAnEditAfterRelaunchWithoutChangeHistory() {
        let (tracker, url) = tracker()
        let first = tracker.makeScan(sources: [source], revisions: ["photo": revision(1)], context: context)
        XCTAssertEqual(first.editedSources, [source], "unknown revisions must be checked once")
        tracker.commit(first)

        let restored = PhotoLibraryChangeTracker(url: url)
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
        let next = PhotoLibraryChangeTracker(url: url).makeScan(sources: sources, revisions: new, context: context)
        XCTAssertTrue(next.editedSources.isEmpty)
        restored.invalidateChangedSources(next.editedSources)
        XCTAssertEqual(restored.enqueueReportingLimit(next.sources, skippingExisting: true, limit: 2).accepted.count, 1)
        XCTAssertEqual(Array(restored.items.prefix(2).map(\.id)), originalIDs)
        XCTAssertEqual(restored.items.count, 3)
    }
}
