import Combine
import XCTest
@testable import PhotosBackup

/// Holds an upload at an explicit boundary, including cancellation before the
/// continuation is installed. No test relies on a preparation or retry sleep.
private actor ExecutionUploadGate {
    private var continuation: CheckedContinuation<UploadOutcome, Error>?
    private var result: Result<UploadOutcome, Error>?

    func wait() async throws -> UploadOutcome {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if let result { continuation.resume(with: result) }
                else { self.continuation = continuation }
            }
        } onCancel: {
            Task { await self.resolve(.failure(CancellationError())) }
        }
    }

    func resolve(_ result: Result<UploadOutcome, Error>) {
        guard self.result == nil else { return }
        self.result = result
        continuation?.resume(with: result)
        continuation = nil
    }
}

@MainActor
final class BackupExecutionTests: XCTestCase {
    private let source = MediaSource.asset(localIdentifier: "fixture-asset")

    private func completion(of queue: UploadQueue, state: UploadItem.State) -> (XCTestExpectation, AnyCancellable) {
        let reached = expectation(description: "Queue reached \(state)")
        let observation = queue.$items
            .filter { $0.first?.state == state }
            .prefix(1)
            .sink { _ in reached.fulfill() }
        return (reached, observation)
    }

    private func blockedQueue(gate: ExecutionUploadGate, started: XCTestExpectation) -> UploadQueue {
        UploadQueue(worker: { _, _, _, _, _ in
            started.fulfill()
            let result = try await gate.wait()
            try Task.checkCancellation()
            return result
        }, maxConcurrent: 1)
    }

    func testProcessingExpirationAfterOpeningTheAppPreservesTheForegroundUpload() async {
        let gate = ExecutionUploadGate()
        let started = expectation(description: "Upload started")
        let queue = blockedQueue(gate: gate, started: started)
        let execution = BackupExecutionController(queue: queue)
        let window = execution.begin(.processing, foreground: false)
        queue.enqueue([source])
        await fulfillment(of: [started], timeout: 2)

        execution.setForeground(true)
        execution.end(window)
        XCTAssertNil(queue.systemPauseReason)
        XCTAssertTrue(queue.options.allowsICloudDownload)
        let (finished, observation) = completion(of: queue, state: .done)
        defer { observation.cancel(); queue.cancelAll() }
        await gate.resolve(.success(.uploaded(mediaKey: "fixture-key")))
        await fulfillment(of: [finished], timeout: 2)
    }

    func testEndingAShortcutDoesNotCancelAnOverlappingProcessingWindow() async {
        let gate = ExecutionUploadGate()
        let started = expectation(description: "Upload started")
        let queue = blockedQueue(gate: gate, started: started)
        let execution = BackupExecutionController(queue: queue)
        let shortcut = execution.begin(.processing, foreground: false)
        queue.enqueue([source])
        await fulfillment(of: [started], timeout: 2)
        let processing = execution.begin(.processing)

        execution.end(shortcut)
        // A cancelled operation can also return after its expiration handler.
        // Releasing it twice must not consume a replacement's window.
        execution.end(shortcut)
        XCTAssertNil(queue.systemPauseReason)
        let (finished, observation) = completion(of: queue, state: .done)
        defer { observation.cancel(); queue.cancelAll() }
        await gate.resolve(.success(.uploaded(mediaKey: "fixture-key")))
        await fulfillment(of: [finished], timeout: 2)
        execution.end(processing)
        XCTAssertNotNil(queue.systemPauseReason)
    }

    func testTransferDeliveryDuringProcessingDoesNotRestrictOrStopItsUpload() async {
        let gate = ExecutionUploadGate()
        let started = expectation(description: "Upload started")
        let queue = blockedQueue(gate: gate, started: started)
        let execution = BackupExecutionController(queue: queue)
        let processing = execution.begin(.processing, foreground: false)
        queue.enqueue([source])
        await fulfillment(of: [started], timeout: 2)

        let delivery = execution.begin(.transferDelivery)
        execution.end(delivery)
        XCTAssertNil(queue.systemPauseReason)
        let (finished, observation) = completion(of: queue, state: .done)
        defer { observation.cancel(); queue.cancelAll(); execution.end(processing) }
        await gate.resolve(.success(.uploaded(mediaKey: "fixture-key")))
        await fulfillment(of: [finished], timeout: 2)
    }

    func testAProcessingWindowCanPrepareAfterContinuedProcessingExpires() async {
        let started = expectation(description: "Processing window starts an upload")
        let queue = UploadQueue(worker: { _, _, _, options, _ in
            XCTAssertFalse(options.allowsICloudDownload)
            started.fulfill()
            return .uploaded(mediaKey: "fixture-key")
        })
        let execution = BackupExecutionController(queue: queue)
        execution.setContinuedProcessing(true)
        execution.setForeground(false)
        let processing = execution.begin(.processing)
        execution.setContinuedProcessing(false)
        XCTAssertNil(queue.systemPauseReason)
        queue.enqueue([source])
        let (finished, observation) = completion(of: queue, state: .done)
        defer { observation.cancel(); queue.cancelAll(); execution.end(processing) }
        await fulfillment(of: [started, finished], timeout: 2)
    }

    func testLeavingTheAppDuringAProcessingWindowKeepsItsPreparationGuardArmed() {
        let markers = MemoryPreparationMarkers()
        let queue = UploadQueue(worker: { _, _, _, _, _ in throw CancellationError() },
                                preparationMarkers: markers)
        let execution = BackupExecutionController(queue: queue)
        let processing = execution.begin(.processing)
        execution.setForeground(false)
        let ids = queue.enqueue([source])
        XCTAssertNil(queue.systemPauseReason)
        XCTAssertEqual(markers.ids, Set(ids))
        execution.end(processing)
        XCTAssertTrue(markers.ids.isEmpty)
        XCTAssertNotNil(queue.systemPauseReason)
        queue.cancelAll()
    }

    func testTheLastPreparationWindowRequeuesExportsWhileTransferDeliveryRemainsOpen() async {
        let gate = ExecutionUploadGate()
        let started = expectation(description: "Export started")
        let queue = blockedQueue(gate: gate, started: started)
        let execution = BackupExecutionController(queue: queue)
        let processing = execution.begin(.processing, foreground: false)
        queue.enqueue([source])
        await fulfillment(of: [started], timeout: 2)
        let delivery = execution.begin(.transferDelivery)
        let (requeued, observation) = completion(of: queue, state: .queued)
        defer { observation.cancel(); queue.cancelAll() }

        execution.end(processing)
        await fulfillment(of: [requeued], timeout: 2)
        XCTAssertEqual(queue.runningCount, 0)
        XCTAssertNil(queue.systemPauseReason, "Prepared transfers still have a delivery window")
        XCTAssertEqual(queue.items.first?.state, .queued, "Delivery cannot restart a fresh export")
        execution.end(delivery)
        XCTAssertNotNil(queue.systemPauseReason)
    }

    func testTransferOnlyRestorationStartsPreparedWorkAndLeavesFreshExportsQueued() async {
        let prepared = PreparedUpload(uploadURL: URL(string: "https://example.com/upload")!,
                                      hash: Data(repeating: 1, count: 20), filename: "fixture.jpg",
                                      modified: Date(timeIntervalSince1970: 1), byteCount: 1,
                                      receipt: Data([1]))
        let checkpoint = UploadCheckpoint(filePath: "/tmp/execution-fixture.jpg", filename: "fixture.jpg",
                                          modified: prepared.modified, byteCount: 1, temporary: true,
                                          prepared: prepared, continuesAfterProcessExit: true)
        let persistence = MemoryUploadQueuePersistence(snapshot: UploadQueueSnapshot(
            version: UploadQueueSnapshot.version, accountIdentifier: "fixture-account",
            items: [
                PersistedUploadItem(id: UUID(), source: .asset("fresh"), name: "Fresh", byteCount: 0,
                                    attempts: 0, failureReason: nil, failureRetryable: false),
                PersistedUploadItem(id: UUID(), source: .asset("prepared"), name: "Prepared", byteCount: 1,
                                    attempts: 1, failureReason: nil, failureRetryable: false, checkpoint: checkpoint),
            ], completedSourceKeys: []))
        let committed = expectation(description: "Prepared work handled")
        let queue = UploadQueue(worker: { _, source, restored, _, _ in
            XCTAssertEqual(source, .asset(localIdentifier: "prepared"))
            XCTAssertEqual(restored, checkpoint)
            committed.fulfill()
            return .uploaded(mediaKey: "fixture-key")
        }, persistence: persistence)
        let execution = BackupExecutionController(queue: queue)
        let delivery = execution.begin(.transferDelivery, foreground: false)
        queue.activateAccount("fixture-account")
        await fulfillment(of: [committed], timeout: 2)
        XCTAssertEqual(queue.items.first?.state, .queued)
        execution.end(delivery)
        XCTAssertNotNil(queue.systemPauseReason)
        queue.cancelAll()
    }

    func testAccountRestorationCannotResumeAfterItsExecutionWindowExpired() async {
        let persistence = MemoryUploadQueuePersistence(snapshot: UploadQueueSnapshot(
            version: UploadQueueSnapshot.version, accountIdentifier: "fixture-account",
            items: [PersistedUploadItem(id: UUID(), source: .asset("fixture-asset"), name: "Fixture",
                                        byteCount: 0, attempts: 0, failureReason: nil, failureRetryable: false)],
            completedSourceKeys: []))
        let queue = UploadQueue(worker: { _, _, _, _, _ in .uploaded(mediaKey: "fixture-key") },
                                persistence: persistence)
        let execution = BackupExecutionController(queue: queue)
        let processing = execution.begin(.processing, foreground: false)
        execution.end(processing)
        queue.activateAccount("fixture-account")
        XCTAssertNotNil(queue.systemPauseReason)
        XCTAssertEqual(queue.items.first?.state, .queued)
        XCTAssertEqual(queue.runningCount, 0)

        let (finished, observation) = completion(of: queue, state: .done)
        defer { observation.cancel(); queue.cancelAll() }
        execution.setForeground(true)
        await fulfillment(of: [finished], timeout: 2)
    }

    func testAnAccountHaltEndsSettlementWithoutWaitingForWindowExpiration() async {
        for kind in [GPMCError.Kind.credentialRejected, .storageFull] {
            let halted = expectation(description: "Queue halted")
            let queue = UploadQueue(worker: { _, _, _, _, _ in
                throw GPMCError(kind: kind, message: "Fixture account needs attention")
            })
            let haltObservation = queue.$haltReason.compactMap { $0 }.prefix(1).sink { _ in halted.fulfill() }
            queue.enqueue([source])
            await fulfillment(of: [halted], timeout: 2)

            let returned = expectation(description: "Settlement stopped for the account halt")
            let wait = Task {
                let settled = await queue.waitUntilSettled()
                XCTAssertFalse(settled)
                returned.fulfill()
            }
            await fulfillment(of: [returned], timeout: 2)
            wait.cancel()
            haltObservation.cancel()
            queue.cancelAll()
        }
    }

    func testExpirationBeforeMainActorHandoffIsRemembered() {
        let window = BackgroundWindow()
        XCTAssertFalse(window.isExpired)
        window.expire()
        XCTAssertTrue(window.isExpired)
        let expired = expectation(description: "Early expiration replayed")
        window.adopt { expired.fulfill() }
        wait(for: [expired], timeout: 1)
    }
}
