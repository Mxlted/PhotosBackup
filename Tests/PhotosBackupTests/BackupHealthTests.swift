import Photos
import XCTest
@testable import PhotosBackup

final class BackupHealthTests: XCTestCase {
    private let scope = BackupScopeDescriptor(accountIdentifier: "account", selectedAlbumIDs: ["album"], includeLivePhotoMotion: true, authorization: PHAuthorizationStatus.authorized.rawValue)
    private let date = Date(timeIntervalSince1970: 100)

    private func manifest(_ assets: [BackupScopeAsset], unavailable: Int = 0) -> BackupScopeManifest {
        .init(scope: scope, scannedAt: date, assets: assets, excludedCount: 3, unavailableMetadataCount: unavailable)
    }

    func testEmptyQueueNeverEstablishesUnscannedCoverage() {
        let health = BackupHealthSnapshot(scope: scope, manifest: nil, completedKeys: ["asset:photo"], items: [])
        XCTAssertNil(health.includedCount)
        XCTAssertNil(health.unknown)
        XCTAssertFalse(health.hasCompleteLocalCoverage)
        XCTAssertNil(health.verifiedThrough)
    }

    func testLegacyCompletionsHaveNoInventedVerificationTimestamp() {
        let health = BackupHealthSnapshot(scope: scope, manifest: manifest([.init(identifier: "a", requiredKeys: ["asset:a"])]),
                                          completedKeys: ["asset:a"], items: [])
        XCTAssertTrue(health.hasCompleteLocalCoverage)
        XCTAssertEqual(health.lastSuccessfulScan, date)
        XCTAssertNil(health.mostRecentRemoteConfirmation)
        XCTAssertNil(health.verifiedThrough)
    }

    func testMissingMotionIsIncompleteEvenWithRememberedStillAndEmptyQueue() {
        let health = BackupHealthSnapshot(scope: scope, manifest: manifest([.init(identifier: "a", requiredKeys: ["asset:a", "motion:a"])]),
                                          completedKeys: ["asset:a"], items: [], remoteConfirmations: ["asset:a": date])
        XCTAssertEqual(health.rememberedCompletions, 0)
        XCTAssertEqual(health.incompleteComponents, 1)
        XCTAssertEqual(health.unknown, 1)
        XCTAssertFalse(health.hasCompleteLocalCoverage)
        XCTAssertNil(health.verifiedThrough)
        XCTAssertEqual(health.mostRecentRemoteConfirmation, date)
    }

    func testAllRequiredComponentsDetermineOldestFullScopeConfirmation() {
        let earlier = Date(timeIntervalSince1970: 50)
        let health = BackupHealthSnapshot(scope: scope, manifest: manifest([.init(identifier: "a", requiredKeys: ["asset:a", "motion:a", "original:a"])]),
            completedKeys: ["asset:a", "motion:a", "original:a"], items: [],
            remoteConfirmations: ["asset:a": earlier, "motion:a": date, "original:a": date])
        XCTAssertTrue(health.hasCompleteLocalCoverage)
        XCTAssertEqual(health.verifiedThrough, earlier)
        XCTAssertEqual(health.rememberedCompletions, 1)
    }

    func testCountsUseDistinctAssetsAndRequiredComponentsOnly() {
        var failed = UploadItem(source: .livePhotoMotion(localIdentifier: "a")); failed.state = .failed(reason: "test", retryable: true)
        var deferred = UploadItem(source: .asset(localIdentifier: "b")); deferred.state = .waitingForICloud
        let pending = UploadItem(source: .asset(localIdentifier: "c"))
        let unrelated = UploadItem(source: .asset(localIdentifier: "outside"))
        let asset = BackupScopeAsset(identifier: "a", requiredKeys: ["asset:a", "motion:a"])
        let health = BackupHealthSnapshot(scope: scope, manifest: manifest([asset, asset,
            .init(identifier: "b", requiredKeys: ["asset:b"]), .init(identifier: "c", requiredKeys: ["asset:c"])]),
            completedKeys: ["asset:a"], items: [failed, deferred, pending, unrelated])
        XCTAssertEqual(health.includedCount, 3)
        XCTAssertEqual(health.failed, 1)
        XCTAssertEqual(health.deferred, 1)
        XCTAssertEqual(health.pending, 1)
        XCTAssertEqual(health.unknown, 0)
    }

    func testDifferentAccountOrPermissionCannotReuseCoverage() {
        let stored = manifest([.init(identifier: "a", requiredKeys: ["asset:a"])])
        let other = BackupScopeDescriptor(accountIdentifier: "other", selectedAlbumIDs: ["album"], authorization: 3)
        let limited = BackupScopeDescriptor(accountIdentifier: "account", selectedAlbumIDs: ["album"], authorization: 4)
        for next in [other, limited] {
            let health = BackupHealthSnapshot(scope: next, manifest: stored, completedKeys: ["asset:a"], items: [])
            XCTAssertNil(health.includedCount)
            XCTAssertNil(health.lastSuccessfulScan)
            XCTAssertFalse(health.hasCompleteLocalCoverage)
        }
        XCTAssertTrue(limited.isLimited)
    }

    func testUnavailableMetadataPreventsFalseCompletion() {
        let health = BackupHealthSnapshot(scope: scope, manifest: manifest([], unavailable: 1), completedKeys: [], items: [])
        XCTAssertFalse(health.hasCompleteLocalCoverage)
        XCTAssertEqual(health.unknown, 1)
        XCTAssertNil(health.verifiedThrough)
    }
}
