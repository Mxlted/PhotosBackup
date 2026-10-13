import Combine
import XCTest
@testable import PhotosBackup

@MainActor
final class QueuePersistenceRecoveryTests: XCTestCase {
    private let account = "test-account"
    private let source = MediaSource.asset(localIdentifier: "edited-photo")
    private let relatedKeys: Set<String> = ["asset:edited-photo", "motion:edited-photo", "editbase:edited-photo"]

    private func queue(_ store: UploadQueuePersisting) -> UploadQueue {
        let queue = UploadQueue(worker: { _, _, _, _, _ in .uploaded(mediaKey: "verified") },
                                persistence: store)
        queue.setNetworkAccess(allowed: false)
        queue.activateAccount(account)
        return queue
    }

    func testFailedInvalidationCannotResurrectCompletionsAcrossRelaunches() throws {
        let store = FailingLedgerStore(account: account, keys: relatedKeys)
        store.ledger["other-account"] = ["asset:other-photo"]
        let first = queue(store)
        XCTAssertEqual(first.completedSourceKeys, relatedKeys)
        store.failRemoval = true

        XCTAssertEqual(first.reverify([source]).enqueued, 1)
        XCTAssertTrue(first.completedSourceKeys.isEmpty)
        XCTAssertNotNil(first.persistenceWarning)
        XCTAssertEqual(store.snapshot?.completionLedgerOverrides?[account], [])
        XCTAssertEqual(store.ledger[account], relatedKeys, "Simulate a ledger that could not be rewritten")

        let second = queue(store)
        XCTAssertTrue(second.completedSourceKeys.isEmpty)
        XCTAssertEqual(second.items.map(\.source), [source], "The pending edit must survive the stale ledger")
        XCTAssertNotNil(second.persistenceWarning)
        XCTAssertEqual(store.snapshot?.completionLedgerOverrides?[account], [])

        store.failRemoval = false
        let recovered = queue(store)
        XCTAssertTrue(recovered.completedSourceKeys.isEmpty)
        XCTAssertEqual(recovered.items.map(\.source), [source])
        XCTAssertNil(recovered.persistenceWarning)
        XCTAssertNil(store.snapshot?.completionLedgerOverrides)
        XCTAssertEqual(store.ledger[account], [])
        XCTAssertEqual(store.ledger["other-account"], ["asset:other-photo"])
    }

    func testFailedCompletionAppendUsesSnapshotUntilLedgerRecovers() async {
        let store = FailingLedgerStore(account: account, keys: [])
        let first = queue(store)
        store.failAppend = true
        let completed = expectation(description: "Verified upload recorded in memory")
        let observation = first.$completedSourceKeys.dropFirst().sink { keys in
            if keys.contains("asset:edited-photo") { completed.fulfill() }
        }
        first.enqueue([source])
        first.setNetworkAccess(allowed: true)
        await fulfillment(of: [completed], timeout: 2)
        first.flushPendingWrites()
        withExtendedLifetime(observation) {}
        XCTAssertEqual(store.snapshot?.completionLedgerOverrides?[account], ["asset:edited-photo"])

        let second = queue(store)
        XCTAssertEqual(second.completedSourceKeys, ["asset:edited-photo"])
        XCTAssertTrue(second.items.isEmpty)
        XCTAssertNotNil(second.persistenceWarning)

        store.failAppend = false
        let recovered = queue(store)
        XCTAssertEqual(recovered.completedSourceKeys, ["asset:edited-photo"])
        XCTAssertEqual(store.ledger[account], ["asset:edited-photo"])
        XCTAssertNil(store.snapshot?.completionLedgerOverrides)
        XCTAssertEqual(store.snapshot?.completedSourceKeys, [])
    }

    func testFailedInvalidationSurvivesAccountSwitchAndRelaunch() {
        let store = FailingLedgerStore(account: account, keys: relatedKeys)
        let first = queue(store)
        store.failRemoval = true
        first.reverify([source])
        first.activateAccount("other-account")
        XCTAssertEqual(store.snapshot?.accountIdentifier, "other-account")
        XCTAssertEqual(store.snapshot?.completionLedgerOverrides?[account], [])

        // Reopen while the second account is active, then reconnect the first.
        let reopened = UploadQueue(worker: { _, _, _, _, _ in .uploaded(mediaKey: "verified") },
                                   persistence: store)
        reopened.setNetworkAccess(allowed: false)
        reopened.activateAccount("other-account")
        reopened.activateAccount(account)
        XCTAssertTrue(reopened.completedSourceKeys.isEmpty)
        XCTAssertEqual(reopened.enqueue([source], skippingExisting: true).count, 1)

        store.failRemoval = false
        let recovered = queue(store)
        XCTAssertTrue(recovered.completedSourceKeys.isEmpty)
        XCTAssertEqual(store.ledger[account], [])
    }

    func testUnsavedInvalidationSurvivesAccountSwitchUntilDiskRecovers() {
        let store = FailingLedgerStore(account: account, keys: relatedKeys)
        let first = queue(store)
        store.failRemoval = true
        store.failSave = true
        first.reverify([source])
        first.activateAccount("other-account")
        XCTAssertEqual(store.snapshot?.accountIdentifier, account, "Both snapshot writes failed")

        store.failSave = false
        first.enqueue([.asset(localIdentifier: "other-photo")])
        XCTAssertEqual(store.snapshot?.accountIdentifier, "other-account")
        XCTAssertEqual(store.snapshot?.completionLedgerOverrides?[account], [])
        let restored = queue(store)
        XCTAssertTrue(restored.completedSourceKeys.isEmpty)
        XCTAssertEqual(restored.enqueue([source], skippingExisting: true).count, 1)
    }

    func testFileLedgerRepairPreservesOtherAccountsAndRemovesFallback() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileUploadQueuePersistence(url: directory.appendingPathComponent("queue.json"))
        try store.recordCompletedSourceKeys(Array(relatedKeys), for: account)
        try store.recordCompletedSourceKey("asset:other", for: "other-account")
        try store.save(UploadQueueSnapshot(version: 1, accountIdentifier: account, items: [],
                                           completedSourceKeys: ["asset:retained"],
                                           completionLedgerOverrides: [account: ["asset:retained"]]))
        let restored = queue(store)
        XCTAssertEqual(restored.completedSourceKeys, ["asset:retained"])
        XCTAssertEqual(try store.loadCompletedSourceKeys(for: account), ["asset:retained"])
        XCTAssertEqual(try store.loadCompletedSourceKeys(for: "other-account"), ["asset:other"])
        XCTAssertNil(try store.load()?.completionLedgerOverrides)
    }

    func testInvalidatingAnExistingFallbackUpdatesBothCopiesBeforeLedgerFailure() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileUploadQueuePersistence(url: directory.appendingPathComponent("queue.json"))
        try store.save(UploadQueueSnapshot(version: 1, accountIdentifier: account, items: [],
                                           completedSourceKeys: ["asset:edited-photo", "asset:retained"],
                                           completionLedgerOverrides: [account: ["asset:edited-photo", "asset:retained"]]))
        // A directory in place of the ledger causes its read to fail, after
        // the snapshot invalidation has already been saved atomically.
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("completed-sources-v1.log"), withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.removeCompletedSourceKeys(["asset:edited-photo"], for: account))

        let restored = queue(store)
        XCTAssertEqual(restored.completedSourceKeys, ["asset:retained"])
        XCTAssertEqual(try store.load()?.completionLedgerOverrides?[account], ["asset:retained"])
        XCTAssertEqual(restored.enqueue([source], skippingExisting: true).count, 1)
    }

    func testAuthoritativeSnapshotRestoresEvenWhenLedgerCannotBeRead() {
        let store = FailingLedgerStore(account: account, keys: relatedKeys)
        store.snapshot = UploadQueueSnapshot(version: 1, accountIdentifier: account, items: [],
                                            completedSourceKeys: ["asset:another-photo"],
                                            completionLedgerOverrides: [account: ["asset:another-photo"]])
        store.failRead = true
        let restored = queue(store)
        XCTAssertEqual(restored.completedSourceKeys, ["asset:another-photo"])
        XCTAssertNotNil(restored.persistenceWarning)
        XCTAssertEqual(store.snapshot?.completionLedgerOverrides?[account], ["asset:another-photo"])
    }

    func testLegacySnapshotStillCombinesItsCompletionsWithTheLedger() throws {
        let data = Data(#"{"version":1,"accountIdentifier":"test-account","items":[],"completedSourceKeys":["asset:legacy"]}"#.utf8)
        let legacy = try JSONDecoder().decode(UploadQueueSnapshot.self, from: data)
        XCTAssertNil(legacy.completionLedgerOverrides)
        let store = FailingLedgerStore(account: account, keys: ["asset:newer"])
        store.snapshot = legacy
        XCTAssertEqual(queue(store).completedSourceKeys, ["asset:legacy", "asset:newer"])
    }
}

private final class FailingLedgerStore: UploadQueuePersisting {
    var snapshot: UploadQueueSnapshot?
    var ledger: [String: Set<String>]
    var failRemoval = false
    var failAppend = false
    var failRead = false
    var failSave = false
    var storesCompletionLedgerSeparately: Bool { true }

    init(account: String, keys: Set<String>) {
        ledger = [account: keys]
        snapshot = UploadQueueSnapshot(version: 1, accountIdentifier: account, items: [], completedSourceKeys: [])
    }

    func load() throws -> UploadQueueSnapshot? { snapshot }
    func save(_ snapshot: UploadQueueSnapshot) throws {
        if failSave { throw CocoaError(.fileWriteOutOfSpace) }
        self.snapshot = snapshot
    }
    func loadCompletedSourceKeys(for accountIdentifier: String) throws -> [String] {
        if failRead { throw CocoaError(.fileReadNoPermission) }
        return Array(ledger[accountIdentifier] ?? [])
    }
    func recordCompletedSourceKey(_ key: String, for accountIdentifier: String) throws {
        if failAppend { throw CocoaError(.fileWriteOutOfSpace) }
        ledger[accountIdentifier, default: []].insert(key)
    }
    func removeCompletedSourceKeys(_ keys: Set<String>, for accountIdentifier: String) throws {
        if failRemoval { throw CocoaError(.fileWriteOutOfSpace) }
        ledger[accountIdentifier, default: []].subtract(keys)
    }
}
