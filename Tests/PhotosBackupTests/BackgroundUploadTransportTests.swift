import XCTest
@testable import PhotosBackup

final class BackgroundUploadTransportTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func transport(directory: URL, session: BackgroundSessionStub) -> BackgroundFileUploadTransport {
        BackgroundFileUploadTransport(resultsDirectory: directory) { _, _, queue in
            session.didCreate(on: queue)
            return session
        }
    }

    private func deliver(_ receipt: Data, id: UUID, to transport: BackgroundFileUploadTransport) {
        let task = BackgroundTaskStub(id: id)
        transport.urlSession(.shared, dataTask: task, didReceive: receipt)
        transport.urlSession(.shared, task: task, didCompleteWithError: nil)
    }

    func testCompletedReceiptSurvivesRelaunchWithoutAnotherPUT() async throws {
        let directory = try directory()
        let id = UUID()
        let receipt = Data([1, 2, 3])
        let initial = transport(directory: directory, session: BackgroundSessionStub())
        deliver(receipt, id: id, to: initial)

        let session = BackgroundSessionStub()
        let restored = transport(directory: directory, session: session)
        let result = try await restored.upload(URLRequest(url: BackgroundTaskStub.url),
                                              fromFile: directory.appendingPathComponent("missing-body"),
                                              transferID: id, progress: { _, _ in })
        XCTAssertEqual(result.data, receipt)
        XCTAssertEqual((result.response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(session.creationCount, 0, "a durable receipt needs no URLSession task")
        await restored.forget(transferID: id)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testReceiptArrivingDuringTaskEnumerationDoesNotStartADuplicatePUT() async throws {
        let directory = try directory()
        let file = directory.appendingPathComponent("body")
        try Data([9]).write(to: file)
        let enumerating = expectation(description: "task enumeration started")
        let session = BackgroundSessionStub(enumerating: enumerating)
        let transport = transport(directory: directory, session: session)
        let id = UUID()
        let pending = Task {
            try await transport.upload(URLRequest(url: BackgroundTaskStub.url), fromFile: file,
                                       transferID: id, progress: { _, _ in })
        }
        await fulfillment(of: [enumerating], timeout: 2)
        let receipt = Data([4, 5, 6])
        deliver(receipt, id: id, to: transport)
        let result = try await pending.value
        XCTAssertEqual(result.data, receipt)

        // The completed task is absent from a snapshot delivered later. This
        // used to start a second PUT after the caller had already received it.
        session.finishEnumeration(with: [])
        await session.drainDelegateQueue()
        XCTAssertEqual(session.uploadCount, 0)
        await transport.forget(transferID: id)
    }

    func testConcurrentFirstAccessCreatesOneSession() async throws {
        let session = BackgroundSessionStub()
        let transport = transport(directory: try directory(), session: session)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask { _ = await transport.diagnosticSnapshot() }
            }
        }
        XCTAssertEqual(session.creationCount, 1)
    }

    func testCancellationDuringTaskEnumerationDoesNotStartAPUT() async throws {
        let directory = try directory()
        let file = directory.appendingPathComponent("body")
        try Data([9]).write(to: file)
        let enumerating = expectation(description: "task enumeration started")
        let session = BackgroundSessionStub(enumerating: enumerating)
        let transport = transport(directory: directory, session: session)
        let pending = Task {
            try await transport.upload(URLRequest(url: BackgroundTaskStub.url), fromFile: file,
                                       transferID: UUID(), progress: { _, _ in })
        }
        await fulfillment(of: [enumerating], timeout: 2)
        pending.cancel()
        do {
            _ = try await pending.value
            XCTFail("expected cancellation without waiting for task enumeration")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        // Deliver both the initial lookup and cancellation's lookup only after
        // the caller was released. Neither may submit the file to URLSession.
        session.finishEnumeration(with: [])
        await session.drainDelegateQueue()
        XCTAssertEqual(session.uploadCount, 0)
    }

    func testRelaunchCompletionWaitsForReceiptDrainEvenWhenDrainerIsInstalledLater() async throws {
        let session = BackgroundSessionStub()
        let transport = transport(directory: try directory(), session: session)
        let finished = expectation(description: "UIKit completion")
        let drainStarted = expectation(description: "receipt drain started")
        let gate = DrainGate()
        let completionState = CompletionState()
        transport.handleEvents {
            completionState.finish()
            finished.fulfill()
        }
        transport.urlSessionDidFinishEvents(forBackgroundURLSession: .shared)
        XCTAssertFalse(completionState.isFinished)
        transport.setEventsDrainer {
            await gate.wait(started: drainStarted)
        }
        await fulfillment(of: [drainStarted], timeout: 2)
        XCTAssertFalse(completionState.isFinished)
        await gate.release()
        await fulfillment(of: [finished], timeout: 2)
    }
}

private final class BackgroundSessionStub: BackgroundUploadSession, @unchecked Sendable {
    private let lock = NSLock()
    private let enumerating: XCTestExpectation?
    private var enumerations: [@Sendable ([URLSessionTask]) -> Void] = []
    private var reportedEnumeration = false
    private var delegateQueue: OperationQueue?
    private var creations = 0
    private var uploads = 0

    init(enumerating: XCTestExpectation? = nil) { self.enumerating = enumerating }

    var creationCount: Int { lock.lock(); defer { lock.unlock() }; return creations }
    var uploadCount: Int { lock.lock(); defer { lock.unlock() }; return uploads }

    func didCreate(on queue: OperationQueue) {
        lock.lock()
        creations += 1
        delegateQueue = queue
        lock.unlock()
    }

    func getAllTasks(completionHandler: @escaping @Sendable ([URLSessionTask]) -> Void) {
        guard let enumerating else { completionHandler([]); return }
        lock.lock()
        enumerations.append(completionHandler)
        let shouldReport = !reportedEnumeration
        reportedEnumeration = true
        lock.unlock()
        if shouldReport { enumerating.fulfill() }
    }

    func finishEnumeration(with tasks: [URLSessionTask]) {
        lock.lock()
        let completions = enumerations
        enumerations = []
        lock.unlock()
        for completion in completions { completion(tasks) }
    }

    func uploadTask(with request: URLRequest, fromFile fileURL: URL) -> URLSessionUploadTask {
        lock.lock()
        uploads += 1
        lock.unlock()
        return BackgroundTaskStub(id: UUID())
    }

    func drainDelegateQueue() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            let queue = delegateQueue
            lock.unlock()
            queue!.addOperation { continuation.resume() }
        }
    }
}

private final class BackgroundTaskStub: URLSessionUploadTask, @unchecked Sendable {
    static let url = URL(string: "https://example.com/upload")!
    private let id: UUID
    init(id: UUID) { self.id = id; super.init() }
    override var taskDescription: String? { get { id.uuidString } set {} }
    override var response: URLResponse? {
        HTTPURLResponse(url: Self.url, statusCode: 200, httpVersion: nil, headerFields: nil)
    }
    override func resume() {}
    override func cancel() {}
}

private actor DrainGate {
    private var continuation: CheckedContinuation<Void, Never>?
    func wait(started: XCTestExpectation) async {
        await withCheckedContinuation {
            continuation = $0
            started.fulfill()
        }
    }
    func release() { continuation?.resume(); continuation = nil }
}

private final class CompletionState: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }
    func finish() { lock.lock(); finished = true; lock.unlock() }
}
