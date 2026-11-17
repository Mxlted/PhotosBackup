import XCTest
@testable import PhotosBackup

@MainActor
final class QueueWriteCoalescingTests: XCTestCase {
    private final class Store: UploadQueuePersisting {
        var snapshot: UploadQueueSnapshot?
        var saves = 0
        var storesCompletionLedgerSeparately: Bool { true }
        func load() throws -> UploadQueueSnapshot? { snapshot }
        func save(_ snapshot: UploadQueueSnapshot) throws { self.snapshot = snapshot; saves += 1 }
    }

    func testOrdinaryProgressIsBatchedButSuspensionAndCheckpointsFlushImmediately() async throws {
        let store = Store()
        let described = expectation(description: "ordinary progress emitted")
        let checkpointed = expectation(description: "checkpoint persisted")
        let gate = SleepGate()
        let checkpoint = UploadCheckpoint(filePath: "/fixture/body.jpg", filename: "body.jpg", modified: Date(),
                                          byteCount: 32, temporary: false, prepared: nil)
        let queue = UploadQueue(worker: { _, _, _, _, emit in
            for index in 0..<8 {
                await emit(.described(name: "Update \(index)", byteCount: Int64(index)))
                await Task.yield()
            }
            described.fulfill()
            await gate.sleep(1)
            await emit(.checkpoint(checkpoint))
            checkpointed.fulfill()
            try await Task.sleep(nanoseconds: 10_000_000_000)
            throw CancellationError()
        }, persistence: store)
        queue.activateAccount("person@example.com")
        queue.enqueue([.asset(localIdentifier: "photo")])
        let initialSaves = store.saves
        await fulfillment(of: [described], timeout: 2)
        XCTAssertEqual(store.saves, initialSaves, "a burst of progress should not rewrite the whole queue")
        queue.flushPendingWrites()
        XCTAssertEqual(store.snapshot?.items.first?.name, "Update 7")
        XCTAssertEqual(store.saves, initialSaves + 1)
        gate.open()
        await fulfillment(of: [checkpointed], timeout: 2)
        XCTAssertEqual(store.snapshot?.items.first?.checkpoint, checkpoint)
        XCTAssertEqual(store.saves, initialSaves + 2, "the checkpoint must reach disk before the worker continues")
        queue.cancelAll()
    }
}
