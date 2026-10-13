import Combine
import XCTest
@testable import PhotosBackup

final class BackupSessionTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 10_000)

    func testEmptyQueueDoesNotCompleteUnknownOrActiveScan() {
        var session = BackupSession(now: start, scanComplete: false)
        evaluate(&session)
        XCTAssertEqual(session.outcome, .incomplete)
        XCTAssertNil(session.finishedAt)
        evaluate(&session, discovering: true)
        XCTAssertEqual(session.outcome, .scanning)
        XCTAssertNil(session.finishedAt)
        session.scanComplete = true
        evaluate(&session)
        XCTAssertEqual(session.outcome, .completed)
        XCTAssertEqual(session.finishedAt, start.addingTimeInterval(1))
    }

    func testPauseHaltDeferredAndPersistenceFailureCannotClaimSuccess() {
        var session = BackupSession(now: start, scanComplete: true)
        evaluate(&session, paused: true)
        XCTAssertEqual(session.outcome, .paused)
        XCTAssertNil(session.finishedAt)
        evaluate(&session, halted: true)
        XCTAssertEqual(session.outcome, .needsAttention)
        evaluate(&session, durable: false)
        XCTAssertEqual(session.outcome, .needsAttention)
        evaluate(&session, pending: 1, deferred: ["asset:deferred"])
        XCTAssertEqual(session.outcome, .deferred)
        XCTAssertNil(session.finishedAt)
        XCTAssertEqual(session.deferredAssets.count, 1)
    }

    func testFailuresRemainAccurateAfterRowsAreCleared() {
        var session = BackupSession(now: start, scanComplete: true)
        evaluate(&session, failed: ["asset:failed"])
        XCTAssertEqual(session.outcome, .completedWithFailures)
        evaluate(&session)
        XCTAssertEqual(session.outcome, .completedWithFailures)
        XCTAssertEqual(session.failedAssets.count, 1)
        XCTAssertFalse(session.summary.contains("asset:failed"))
    }

    func testAssetAndComponentCountsAndBytesDoNotDoubleCountDuplicates() throws {
        var session = BackupSession(now: start, scanComplete: true)
        session.components = [
            "rendered": .init(asset: "asset:one", uploaded: true, bytes: 100),
            "motion": .init(asset: "asset:one", uploaded: true, bytes: 200),
            "original": .init(asset: "asset:one", uploaded: false, bytes: 300),
            "other": .init(asset: "asset:two", uploaded: false, bytes: 400),
            "unmeasured": .init(asset: "asset:three", uploaded: true, bytes: nil)
        ]
        XCTAssertEqual(session.uploadedAssets, 2)
        XCTAssertEqual(session.duplicateAssets, 1)
        XCTAssertEqual(session.uploadedBytes, 300)
        XCTAssertTrue(session.hasUnmeasuredBytes)
        XCTAssertEqual(session.components.count, 5)
        XCTAssertFalse(session.summary.contains("asset:"))
        XCTAssertEqual(try JSONDecoder().decode(BackupSession.self, from: JSONEncoder().encode(session)), session)
    }

    func testStoppedWorkIsNotCompletionWithFailures() {
        var session = BackupSession(now: start, scanComplete: true)
        evaluate(&session, cancelled: ["asset:cancelled"])
        XCTAssertEqual(session.outcome, .stopped)
        XCTAssertFalse(session.outcome.isComplete)
        XCTAssertNotNil(session.finishedAt)
    }

    func testBlackScreenWaitsForObservedSessionAndReacquiresForNewWork() {
        var policy = BlackScreenCompletionPolicy()
        var old = BackupSession(now: start, scanComplete: true)
        evaluate(&old)
        policy.update(session: old, hasNewWork: false)
        XCTAssertFalse(policy.shouldRestoreAutoLock, "Opening the mode after old completion stays awake")
        var current = BackupSession(now: start, scanComplete: false)
        evaluate(&current, discovering: true)
        policy.update(session: current, hasNewWork: false)
        XCTAssertFalse(policy.shouldRestoreAutoLock, "Transient empty queue during scan stays awake")
        current.scanComplete = true
        evaluate(&current, paused: true)
        policy.update(session: current, hasNewWork: false)
        XCTAssertFalse(policy.shouldRestoreAutoLock)
        evaluate(&current, failed: ["asset:failed"])
        policy.update(session: current, hasNewWork: false)
        XCTAssertTrue(policy.shouldRestoreAutoLock, "Finished-with-failures is a settled outcome")
        policy.update(session: current, hasNewWork: true)
        XCTAssertFalse(policy.shouldRestoreAutoLock, "New work reacquires the display override")
        policy.resetForAccountChange()
        XCTAssertNil(policy.observedSession)
        XCTAssertFalse(policy.shouldRestoreAutoLock)
    }

    private func evaluate(_ session: inout BackupSession, discovering: Bool = false, pending: Int = 0,
                          failed: Set<String> = [], deferred: Set<String> = [], cancelled: Set<String> = [],
                          paused: Bool = false, halted: Bool = false, durable: Bool = true) {
        session.evaluate(discovering: discovering, pending: pending, failed: failed, deferred: deferred,
                         cancelled: cancelled, paused: paused, halted: halted, durable: durable,
                         now: start.addingTimeInterval(1))
    }
}

@MainActor
final class QueueSessionTests: XCTestCase {
    func testStopInvalidatesDiscoveryOwnershipBeforeReplacementSession() {
        let queue = UploadQueue(worker: { _, _, _, _, _ in .uploaded(mediaKey: "fixture") })
        queue.activateAccount("fixture-account")
        let oldOwner = queue.beginDiscovery()
        let oldSession = queue.backupSession?.id
        queue.cancelAll()
        XCTAssertFalse(queue.isDiscovering)
        XCTAssertEqual(queue.backupSession?.outcome, .stopped)
        let newOwner = queue.beginDiscovery()
        let newSession = queue.backupSession?.id
        XCTAssertNotEqual(oldSession, newSession)
        queue.endDiscovery(oldOwner, complete: true)
        XCTAssertTrue(queue.isDiscovering)
        XCTAssertEqual(queue.backupSession?.outcome, .scanning)
        queue.endDiscovery(newOwner, complete: true)
        XCTAssertEqual(queue.backupSession?.id, newSession)
        XCTAssertEqual(queue.backupSession?.outcome, .completed)
    }

    func testInvalidatingOtherAccountDoesNotRemoveActiveAccountsRemoteDates() {
        let verified = Date(timeIntervalSince1970: 1_000)
        let snapshot = UploadQueueSnapshot(version: UploadQueueSnapshot.version,
            accountIdentifier: "account-b", items: [], completedSourceKeys: ["asset:shared"],
            completionLedgerOverrides: ["account-a": ["asset:shared"]],
            remoteConfirmations: ["asset:shared": verified])
        let updated = snapshot.removingCompletions(["asset:shared"], for: "account-a")
        XCTAssertEqual(updated.completionLedgerOverrides?["account-a"], [])
        XCTAssertEqual(updated.completedSourceKeys, ["asset:shared"])
        XCTAssertEqual(updated.remoteConfirmations, ["asset:shared": verified])
        let ownInvalidation = updated.removingCompletions(["asset:shared"], for: "account-b")
        XCTAssertTrue(ownInvalidation.completedSourceKeys.isEmpty)
        XCTAssertTrue(ownInvalidation.remoteConfirmations?.isEmpty == true)
    }

    func testOldCancelledRowDoesNotContaminateNewLogicalSession() async throws {
        let queue = UploadQueue(worker: { _, _, _, _, _ in .uploaded(mediaKey: "fixture") },
                                persistence: MemoryUploadQueuePersistence())
        queue.activateAccount("fixture-account")
        queue.pauseAfterCurrentUploads()
        let cancelled = try XCTUnwrap(queue.enqueue([.asset(localIdentifier: "old")]).first)
        queue.cancel(cancelled)
        let oldID = queue.backupSession?.id
        XCTAssertEqual(queue.backupSession?.outcome, .stopped)
        queue.resumeUserPausedUploads()
        let completed = expectation(description: "New session settles independently")
        let observer = queue.$backupSession.compactMap { $0 }.filter { $0.outcome == .completed }.prefix(1)
            .sink { _ in completed.fulfill() }
        defer { observer.cancel(); queue.cancelAll() }
        queue.enqueue([.asset(localIdentifier: "new")])
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertNotEqual(queue.backupSession?.id, oldID)
        XCTAssertTrue(queue.backupSession?.stoppedAssets.isEmpty == true)
        XCTAssertEqual(queue.backupSession?.uploadedAssets, 1)
        XCTAssertTrue(queue.items.contains { $0.id == cancelled && $0.state == .cancelled })
    }

    func testFailedFinalSnapshotCannotPublishCompletionBeforeDurableSave() {
        let store = SessionSnapshotStore()
        let queue = UploadQueue(worker: { _, _, _, _, _ in .uploaded(mediaKey: "fixture") }, persistence: store)
        queue.activateAccount("fixture-account")
        let owner = queue.beginDiscovery()
        var published: [BackupSession.Outcome] = []
        let observer = queue.$backupSession.compactMap { $0?.outcome }.sink { published.append($0) }
        defer { observer.cancel() }
        store.failSaves = true
        queue.endDiscovery(owner, complete: true)
        XCTAssertEqual(queue.backupSession?.outcome, .needsAttention)
        XCTAssertNotNil(queue.persistenceWarning)
        XCTAssertFalse(published.contains(where: \.isComplete))
        XCTAssertEqual(store.snapshot?.backupSession?.outcome, .scanning)
        store.failSaves = false
        let recovery = queue.beginDiscovery()
        queue.endDiscovery(recovery, complete: true)
        XCTAssertEqual(queue.backupSession?.outcome, .completed)
        XCTAssertEqual(store.snapshot?.backupSession?.outcome, .completed)
    }

    func testOverlappingDiscoveriesNeedAllOwnersAndCompleteHandoff() {
        let queue = UploadQueue(worker: { _, _, _, _, _ in .uploaded(mediaKey: "fixture") })
        queue.activateAccount("fixture-account")
        let first = queue.beginDiscovery()
        let second = queue.beginDiscovery()
        let id = queue.backupSession?.id
        queue.endDiscovery(first, complete: false)
        XCTAssertEqual(queue.backupSession?.outcome, .scanning)
        queue.endDiscovery(first, complete: true)
        XCTAssertTrue(queue.isDiscovering, "Repeated release cannot consume another owner")
        queue.endDiscovery(second, complete: true)
        XCTAssertEqual(queue.backupSession?.outcome, .incomplete)
        XCTAssertNil(queue.backupSession?.finishedAt)
        let recovery = queue.beginDiscovery()
        queue.endDiscovery(recovery, complete: true)
        XCTAssertEqual(queue.backupSession?.id, id)
        XCTAssertEqual(queue.backupSession?.outcome, .completed)
    }

    func testManualDiscoveryCannotFinishAnIncompleteSelectedScope() {
        let queue = UploadQueue(worker: { _, _, _, _, _ in .uploaded(mediaKey: "unused") })
        queue.activateAccount("fixture-account")
        let selection = queue.beginDiscovery()
        queue.endDiscovery(selection, complete: false)
        let manual = queue.beginDiscovery(requiresCompleteScope: false)
        queue.endDiscovery(manual, complete: true)
        XCTAssertEqual(queue.backupSession?.outcome, .incomplete)
        XCTAssertEqual(queue.backupSession?.scopeScanOutstanding, true)
        let fullScope = queue.beginDiscovery()
        queue.endDiscovery(fullScope, complete: true)
        XCTAssertEqual(queue.backupSession?.outcome, .completed)
    }

    func testOldSnapshotDoesNotInventVerificationTimeOrSession() throws {
        let data = Data(#"{"version":1,"accountIdentifier":"fixture-account","items":[],"completedSourceKeys":["asset:legacy"]}"#.utf8)
        let snapshot = try JSONDecoder().decode(UploadQueueSnapshot.self, from: data)
        XCTAssertNil(snapshot.remoteConfirmations)
        XCTAssertNil(snapshot.backupSession)
        let queue = UploadQueue(worker: { _, _, _, _, _ in .uploaded(mediaKey: "fixture") },
                                persistence: MemoryUploadQueuePersistence(snapshot: snapshot))
        queue.activateAccount("fixture-account")
        XCTAssertTrue(queue.completedSourceKeys.contains("asset:legacy"))
        XCTAssertTrue(queue.remoteConfirmations.isEmpty)
        XCTAssertNil(queue.backupSession)
    }

    func testRelaunchOfPartialOriginalAndLivePhotoPreservesLogicalSessionAndCounts() async {
        let verifiedAt = Date(timeIntervalSince1970: 100)
        var session = BackupSession(now: verifiedAt, scanComplete: true)
        session.components["asset:shared"] = .init(asset: "asset:shared", uploaded: true, bytes: 100)
        session.pendingComponents = 2
        let snapshot = UploadQueueSnapshot(version: UploadQueueSnapshot.version,
            accountIdentifier: "fixture-account", items: [
                .init(id: UUID(), source: .asset("shared"), name: "Original", byteCount: 250,
                      attempts: 0, failureReason: nil, failureRetryable: false, original: true),
                .init(id: UUID(), source: .asset("shared"), name: "Motion", byteCount: 350,
                      attempts: 0, failureReason: nil, failureRetryable: false, motion: true)
            ], completedSourceKeys: ["asset:shared"], isUserPaused: true,
            backupSession: session, remoteConfirmations: ["asset:shared": verifiedAt])
        let store = MemoryUploadQueuePersistence(snapshot: snapshot)
        let queue = UploadQueue(worker: { _, _, _, _, _ in .alreadyBackedUp(mediaKey: "fixture") }, persistence: store)
        queue.activateAccount("fixture-account")
        XCTAssertEqual(queue.backupSession?.id, session.id)
        XCTAssertEqual(queue.backupSession?.outcome, .paused)
        XCTAssertEqual(queue.items.count, 2)
        XCTAssertEqual(queue.remoteConfirmations["asset:shared"], verifiedAt)
        let completed = expectation(description: "All restored components settle")
        let observer = queue.$backupSession.compactMap { $0 }.filter { $0.outcome == .completed }.prefix(1)
            .sink { _ in completed.fulfill() }
        defer { observer.cancel(); queue.cancelAll() }
        queue.resumeUserPausedUploads()
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(queue.backupSession?.id, session.id)
        XCTAssertEqual(queue.backupSession?.components.count, 3)
        XCTAssertEqual(queue.backupSession?.uploadedAssets, 1)
        XCTAssertEqual(queue.backupSession?.duplicateAssets, 0)
        XCTAssertEqual(queue.backupSession?.uploadedBytes, 100)
    }

    func testUnavailableAssetCannotTurnAnEmptyQueueIntoSuccessfulSession() async {
        let queue = UploadQueue(worker: { _, _, _, _, _ in throw MediaExporter.Failure.missingAsset },
                                persistence: MemoryUploadQueuePersistence())
        queue.activateAccount("fixture-account")
        let owner = queue.beginDiscovery()
        let missing = expectation(description: "Unavailable source keeps session incomplete")
        let observer = queue.$backupSession.compactMap { $0 }.filter { !$0.unavailableAssets.isEmpty }.prefix(1)
            .sink { _ in missing.fulfill() }
        queue.enqueue([.asset(localIdentifier: "unavailable")])
        queue.endDiscovery(owner, complete: true)
        await fulfillment(of: [missing], timeout: 2)
        XCTAssertTrue(queue.items.isEmpty)
        XCTAssertEqual(queue.backupSession?.outcome, .incomplete)
        XCTAssertNil(queue.backupSession?.finishedAt)
        observer.cancel()
    }

    func testLedgerAheadOfSnapshotLabelsUnmeasuredRecoveryOutcomes() {
        let itemID = UUID()
        var session = BackupSession(scanComplete: true)
        session.itemIDs = [itemID]
        let snapshot = UploadQueueSnapshot(version: 1, accountIdentifier: "fixture-account",
            items: [.init(id: itemID, source: .asset("completed-during-crash"), name: "Fixture",
                          byteCount: 150, attempts: 1, failureReason: nil, failureRetryable: false)],
            completedSourceKeys: ["asset:completed-during-crash"], backupSession: session)
        let queue = UploadQueue(worker: { _, _, _, _, _ in .uploaded(mediaKey: "unused") },
                                persistence: MemoryUploadQueuePersistence(snapshot: snapshot))
        queue.activateAccount("fixture-account")
        XCTAssertTrue(queue.items.isEmpty)
        XCTAssertEqual(queue.backupSession?.hasUnmeasuredOutcomes, true)
        XCTAssertTrue(queue.backupSession?.summary.contains("known results only") == true)
        XCTAssertEqual(queue.backupSession?.uploadedBytes, 0)
    }

    func testOldDiscoveryCallbackCannotCompleteReplacementAccountSession() {
        let queue = UploadQueue(worker: { _, _, _, _, _ in .uploaded(mediaKey: "fixture") })
        queue.activateAccount("account-one")
        let oldOwner = queue.beginDiscovery()
        let oldSession = queue.backupSession?.id
        queue.activateAccount("account-two")
        let newOwner = queue.beginDiscovery()
        let newSession = queue.backupSession?.id
        XCTAssertNotEqual(oldSession, newSession)
        queue.endDiscovery(oldOwner, complete: true)
        XCTAssertTrue(queue.isDiscovering)
        XCTAssertEqual(queue.backupSession?.outcome, .scanning)
        queue.endDiscovery(newOwner, complete: true)
        XCTAssertEqual(queue.backupSession?.id, newSession)
        XCTAssertEqual(queue.backupSession?.outcome, .completed)
    }
}

private final class SessionSnapshotStore: UploadQueuePersisting {
    var snapshot: UploadQueueSnapshot?
    var failSaves = false
    func load() throws -> UploadQueueSnapshot? { snapshot }
    func save(_ snapshot: UploadQueueSnapshot) throws {
        if failSaves { throw CocoaError(.fileWriteOutOfSpace) }
        self.snapshot = snapshot
    }
}
