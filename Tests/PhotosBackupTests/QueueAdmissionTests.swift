import Combine
import XCTest
@testable import PhotosBackup

@MainActor
final class QueueAdmissionTests: XCTestCase {
    func testUnattendedPauseEndsIdleBackgroundWaitWithoutConsumingWindow() async {
        let monitor = makeMonitor(settings: .init(onlyWhileCharging: true), power: { .battery })
        let queue = UploadQueue(worker: { _, _, _, _, _ in
            XCTFail("Charging-only rule must not admit work on battery")
            return .uploaded(mediaKey: "fixture")
        })
        queue.installAdmissionMonitor(monitor)
        queue.enqueue([.asset(localIdentifier: "fixture")])
        let ended = expectation(description: "An idle admission block returns the execution opportunity")
        let waiting = Task {
            let settled = await queue.waitUntilSettled()
            XCTAssertFalse(settled, "A policy pause is not successful completion")
            ended.fulfill()
        }
        defer { waiting.cancel(); queue.cancelAll() }
        await fulfillment(of: [ended], timeout: 2)
    }

    func testChargingRecoveryStartsPendingWorkWithoutExplicitResume() async {
        var power = BackupAdmissionEnvironment.Power.battery
        let monitor = makeMonitor(settings: .init(onlyWhileCharging: true), power: { power })
        let started = expectation(description: "Recovered condition admits the queued upload")
        let queue = UploadQueue(worker: { _, _, _, _, _ in
            started.fulfill()
            return .uploaded(mediaKey: "fixture")
        })
        queue.installAdmissionMonitor(monitor)
        queue.enqueue([.asset(localIdentifier: "fixture")])
        XCTAssertEqual(queue.runningCount, 0)
        XCTAssertEqual(queue.items.first?.state, .queued)
        XCTAssertNotNil(queue.admissionPauseReason)
        power = .charging
        await monitor.refresh()
        await fulfillment(of: [started], timeout: 2)
        queue.cancelAll()
    }

    func testRecoveryPreservesUserPauseAndNetworkRestriction() async {
        var power = BackupAdmissionEnvironment.Power.battery
        let monitor = makeMonitor(settings: .init(onlyWhileCharging: true), power: { power })
        let started = expectation(description: "Explicit resume plus network recovery admits work")
        let queue = UploadQueue(worker: { _, _, _, _, _ in
            started.fulfill()
            return .uploaded(mediaKey: "fixture")
        })
        queue.installAdmissionMonitor(monitor)
        queue.pauseAfterCurrentUploads()
        queue.setNetworkAccess(allowed: false, pauseReason: "Waiting for Wi-Fi")
        queue.enqueue([.asset(localIdentifier: "fixture")])
        let recovered = expectation(description: "Queue observes policy recovery")
        let observation = queue.$admissionPauseReason.dropFirst().filter { $0 == nil }.prefix(1)
            .sink { _ in recovered.fulfill() }
        defer { observation.cancel(); queue.cancelAll() }
        power = .charging
        await monitor.refresh()
        await fulfillment(of: [recovered], timeout: 2)
        XCTAssertTrue(queue.isUserPaused)
        XCTAssertEqual(queue.runningCount, 0)
        XCTAssertEqual(queue.networkPauseReason, "Waiting for Wi-Fi")
        queue.resumeUserPausedUploads()
        XCTAssertEqual(queue.runningCount, 0)
        queue.setNetworkAccess(allowed: true)
        await fulfillment(of: [started], timeout: 2)
    }

    func testAdmissionChangeDoesNotCancelStartedWork() async {
        var power = BackupAdmissionEnvironment.Power.charging
        let monitor = makeMonitor(settings: .init(onlyWhileCharging: true), power: { power })
        let gate = AdmissionUploadGate()
        let started = expectation(description: "First upload started")
        let queue = UploadQueue(worker: { _, _, _, _, _ in
            started.fulfill()
            return try await gate.wait()
        }, maxConcurrent: 1)
        queue.installAdmissionMonitor(monitor)
        queue.enqueue([.asset(localIdentifier: "first"), .asset(localIdentifier: "second")])
        await fulfillment(of: [started], timeout: 2)
        let paused = expectation(description: "Queue observes charger removal")
        let observation = queue.$admissionPauseReason.dropFirst().compactMap { $0 }.prefix(1)
            .sink { _ in paused.fulfill() }
        defer { observation.cancel(); queue.cancelAll() }
        power = .battery
        await monitor.refresh()
        await fulfillment(of: [paused], timeout: 2)
        XCTAssertEqual(queue.runningCount, 1)
        let finished = expectation(description: "Already running upload finishes")
        let completion = queue.$items.filter { $0.first?.state == .done }.prefix(1)
            .sink { _ in finished.fulfill() }
        defer { completion.cancel() }
        await gate.resolve(.success(.uploaded(mediaKey: "fixture")))
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(queue.items.last?.state, .queued)
        XCTAssertEqual(queue.runningCount, 0)
    }

    func testWarmConcurrencyLimitRecoversWithoutStoppingFirstWorker() async {
        var thermal = BackupAdmissionEnvironment.Thermal.fair
        let monitor = BackupAdmissionMonitor(settings: .init(reduceWhenHot: true),
                                             environment: { .init(power: .charging, batteryPercent: 90,
                                                                  thermal: thermal, availableBytes: nil) },
                                             capacity: { nil })
        let firstStarted = expectation(description: "First worker starts while warm")
        let secondStarted = expectation(description: "Second worker starts after cooling")
        let first = AdmissionUploadGate()
        let second = AdmissionUploadGate()
        let queue = UploadQueue(worker: { _, source, _, _, _ in
            if source == .asset(localIdentifier: "first") {
                firstStarted.fulfill()
                return try await first.wait()
            }
            secondStarted.fulfill()
            return try await second.wait()
        }, maxConcurrent: 2)
        queue.installAdmissionMonitor(monitor)
        queue.enqueue([.asset(localIdentifier: "first"), .asset(localIdentifier: "second")])
        await fulfillment(of: [firstStarted], timeout: 2)
        XCTAssertEqual(queue.runningCount, 1)
        XCTAssertEqual(queue.items.last?.state, .queued)
        thermal = .nominal
        await monitor.refresh()
        await fulfillment(of: [secondStarted], timeout: 2)
        XCTAssertEqual(queue.runningCount, 2)
        queue.cancelAll()
    }

    func testBackgroundReceiptCanFinishWhileNewPreparationWaits() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let prepared = PreparedUpload(uploadURL: URL(string: "https://example.com/upload")!,
                                      hash: Data(repeating: 1, count: 20), filename: "fixture.jpg",
                                      modified: Date(timeIntervalSince1970: 1), byteCount: 1, receipt: Data([1]))
        let checkpoint = UploadCheckpoint(filePath: file.path, filename: "fixture.jpg",
                                          modified: prepared.modified, byteCount: 1, temporary: true,
                                          prepared: prepared, continuesAfterProcessExit: true)
        let persistence = MemoryUploadQueuePersistence(snapshot: .init(
            version: UploadQueueSnapshot.version, accountIdentifier: "fixture-account",
            items: [
                .init(id: UUID(), source: .asset("fresh"), name: "Fresh", byteCount: 0,
                      attempts: 0, failureReason: nil, failureRetryable: false),
                .init(id: UUID(), source: .asset("prepared"), name: "Prepared", byteCount: 1,
                      attempts: 1, failureReason: nil, failureRetryable: false, checkpoint: checkpoint)
            ], completedSourceKeys: []))
        let committed = expectation(description: "Existing background upload can commit")
        let monitor = makeMonitor(settings: .init(onlyWhileCharging: true), power: { .battery })
        let queue = UploadQueue(worker: { _, source, restored, _, _ in
            XCTAssertEqual(source, .asset(localIdentifier: "prepared"))
            XCTAssertEqual(restored, checkpoint)
            committed.fulfill()
            return .uploaded(mediaKey: "fixture")
        }, persistence: persistence)
        queue.installAdmissionMonitor(monitor)
        queue.activateAccount("fixture-account")
        await fulfillment(of: [committed], timeout: 2)
        XCTAssertEqual(queue.items.first?.state, .queued)
        queue.cancelAll()
    }

    func testMissingBackgroundBodyCannotBypassAdmissionOrDeliveryOnlyWindow() {
        for deliveryOnly in [false, true] {
            let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let prepared = PreparedUpload(uploadURL: URL(string: "https://example.com/upload")!,
                                          hash: Data(repeating: 1, count: 20), filename: "fixture.jpg",
                                          modified: Date(timeIntervalSince1970: 1), byteCount: 1, receipt: nil)
            let checkpoint = UploadCheckpoint(filePath: missing.path, filename: "fixture.jpg",
                                              modified: prepared.modified, byteCount: 1, temporary: true,
                                              prepared: prepared, continuesAfterProcessExit: true)
            let persistence = MemoryUploadQueuePersistence(snapshot: .init(
                version: UploadQueueSnapshot.version, accountIdentifier: "fixture-account",
                items: [.init(id: UUID(), source: .asset("missing-body"), name: "Fixture", byteCount: 1,
                              attempts: 1, failureReason: nil, failureRetryable: false, checkpoint: checkpoint)],
                completedSourceKeys: []))
            let queue = UploadQueue(worker: { _, _, _, _, _ in .uploaded(mediaKey: "fixture") }, persistence: persistence)
            let monitor = makeMonitor(settings: .init(onlyWhileCharging: !deliveryOnly), power: { .battery })
            queue.installAdmissionMonitor(monitor)
            if deliveryOnly { queue.noteBackgroundTransferCompletionsPending() }
            queue.activateAccount("fixture-account")
            XCTAssertEqual(queue.runningCount, 0, "Missing body needs new preparation admission and an execution owner")
            XCTAssertEqual(queue.items.first?.state, .queued)
            XCTAssertEqual(queue.items.first?.checkpoint, checkpoint, "Keep recovery context until a valid preparation window")
            queue.cancelAll()
        }
    }

    private func makeMonitor(settings: BackupAdmissionSettings,
                             power: @escaping () -> BackupAdmissionEnvironment.Power) -> BackupAdmissionMonitor {
        BackupAdmissionMonitor(settings: settings,
                               environment: { .init(power: power(), batteryPercent: 90,
                                                    thermal: .nominal, availableBytes: nil) },
                               capacity: { nil })
    }
}

private actor AdmissionUploadGate {
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
