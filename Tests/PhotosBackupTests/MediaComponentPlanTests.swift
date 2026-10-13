import Combine
import Photos
import XCTest
@testable import PhotosBackup

final class MediaComponentPlanTests: XCTestCase {
    private func plan(type: PHAssetMediaType = .image, edited: Bool = true, live: Bool = false,
                      base: Bool = false, motion: Bool = false, originals: Bool = true) -> [MediaSource] {
        MediaComponentPlan.requiredSources(identifier: "fixture", mediaType: type, hasAdjustments: edited,
            isLivePhoto: live, hasEditBase: base, includeLivePhotoMotion: motion, includeOriginals: originals)
    }

    func testOriginalsAreOptInAndUneditedAssetsNeedOneVersion() {
        XCTAssertEqual(plan(originals: false), [.asset(localIdentifier: "fixture")])
        XCTAssertEqual(plan(edited: false), [.asset(localIdentifier: "fixture")])
        XCTAssertEqual(plan(type: .video, edited: false), [.asset(localIdentifier: "fixture")])
        XCTAssertEqual(plan(type: .unknown), [.asset(localIdentifier: "fixture")])
    }

    func testEditedPhotosAndVideosRequireAnIndependentOriginal() {
        for type in [PHAssetMediaType.image, .video] {
            XCTAssertEqual(plan(type: type), [.asset(localIdentifier: "fixture"), .original(localIdentifier: "fixture")])
        }
    }

    func testLivePhotoOriginalAndCurrentMotionAreIndependentRequiredComponents() {
        let sources = plan(live: true, base: true, motion: true)
        XCTAssertEqual(sources.compactMap(\.backupComponentKey),
                       ["asset:fixture", "motion:fixture", "editbase:fixture", "original:fixture", "originalmotion:fixture"])
        XCTAssertEqual(plan(live: true, motion: false).count, 2)
        XCTAssertEqual(plan(edited: false, live: true, motion: true).count, 2)
        XCTAssertEqual(plan(type: .video, live: true, base: true, motion: true).count, 2)
    }

    func testOldItemWithoutOriginalFlagRetainsItsMeaning() throws {
        let item = PersistedUploadItem(id: UUID(), source: .asset("fixture"), name: "Local",
            byteCount: 0, attempts: 0, failureReason: nil, failureRetryable: false, motion: true)
        let encoded = try JSONEncoder().encode(item)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("original"))
        XCTAssertEqual(try JSONDecoder().decode(PersistedUploadItem.self, from: encoded).mediaSource,
                       .livePhotoMotion(localIdentifier: "fixture"))
    }

    func testOriginalMotionCheckpointSurvivesPartialCompletionRelaunch() throws {
        let checkpoint = UploadCheckpoint(filePath: "/tmp/fixture-motion", filename: "motion.mov",
            modified: Date(timeIntervalSince1970: 10), byteCount: 200, temporary: true,
            prepared: nil, pairedStillHash: Data(repeating: 7, count: 20))
        let item = PersistedUploadItem(id: UUID(), source: .asset("fixture"), name: "Local original motion",
            byteCount: 200, attempts: 1, failureReason: nil, failureRetryable: false,
            checkpoint: checkpoint, motion: true, original: true)
        let restored = try JSONDecoder().decode(PersistedUploadItem.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(restored.mediaSource, .originalMotion(localIdentifier: "fixture"))
        XCTAssertEqual(restored.checkpoint?.pairedStillHash, checkpoint.pairedStillHash)
        XCTAssertEqual(restored.checkpoint?.filePath, checkpoint.filePath)
    }

    func testPickerOnlySelectionExplicitlyRefusesUnknownRequiredVariants() async {
        let uploader = PhotosUploader(exporter: MediaExporter(), client: { nil })
        var options = UploadOptions()
        options.requiresVariantMetadata = true
        do {
            _ = try await uploader.worker()(UUID(), .picked(PickedItem(NSItemProvider())), nil, options, { _ in })
            XCTFail("Required variants cannot be inferred from a picker-only copy")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("only a rendered copy"))
        }
    }

    @MainActor
    func testOriginalComponentsRestoreWithoutChangingCompletedCurrentAppearance() {
        let persistence = MemoryUploadQueuePersistence()
        let queue = UploadQueue(worker: { _, _, _, _, _ in .uploaded(mediaKey: "fixture") }, persistence: persistence)
        queue.setNetworkAccess(allowed: false)
        queue.activateAccount("fixture-account")
        queue.enqueue([.original(localIdentifier: "fixture"), .originalMotion(localIdentifier: "fixture")], skippingExisting: true)
        let restored = UploadQueue(worker: { _, _, _, _, _ in .uploaded(mediaKey: "fixture") }, persistence: persistence)
        restored.setNetworkAccess(allowed: false)
        restored.activateAccount("fixture-account")
        XCTAssertEqual(restored.items.map(\.source), queue.items.map(\.source))
        XCTAssertEqual(restored.completedSourceCount, 0)
        XCTAssertEqual(persistence.snapshot?.items.map(\.original), [true, true])
        restored.activateAccount("different-fixture-account")
        XCTAssertTrue(restored.items.isEmpty)
    }

    @MainActor
    func testSelectedRetryIgnoresDisappearedAndAlreadyReleasedRows() {
        let first = UUID(), second = UUID()
        let persisted = [first, second].map {
            PersistedUploadItem(id: $0, source: .asset($0.uuidString), name: "Local", byteCount: 0,
                                attempts: 3, failureReason: "Try again", failureRetryable: true)
        }
        let persistence = MemoryUploadQueuePersistence(snapshot: UploadQueueSnapshot(version: 1,
            accountIdentifier: "fixture-account", items: persisted, completedSourceKeys: []))
        let queue = UploadQueue(worker: { _, _, _, _, _ in .uploaded(mediaKey: "fixture") }, persistence: persistence)
        queue.setNetworkAccess(allowed: false)
        queue.activateAccount("fixture-account")
        XCTAssertEqual(queue.retrySelectedFailed([first, UUID()]), 1)
        XCTAssertEqual(queue.retrySelectedFailed([first]), 0)
        XCTAssertEqual(queue.items[0].state, .queued)
        XCTAssertTrue(ActivityFilter.failed.includes(queue.items[1].state))
        XCTAssertEqual(queue.items.count, 2)
    }
}
