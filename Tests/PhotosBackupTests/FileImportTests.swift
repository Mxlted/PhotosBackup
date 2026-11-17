import XCTest
@testable import PhotosBackup

@MainActor
final class FileImportTests: XCTestCase {
    private func source(_ name: String = "photo.jpg", data: Data = Data(repeating: 7, count: 2048)) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return url
    }

    private func imported(_ source: URL) async throws -> ImportedMediaFile {
        let file = try await MediaFileImporter.importFile(source)
        addTeardownBlock { await MediaFileImporter.discard(file) }
        return file
    }

    private func queue(store: UploadQueuePersisting? = nil, worker: UploadWorker? = nil) -> UploadQueue {
        let queue = UploadQueue(worker: worker ?? WorkerScript([]).worker(), maxAttempts: 1, persistence: store)
        queue.setNetworkAccess(allowed: false)
        queue.activateAccount("files@example.com")
        return queue
    }

    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition(), file: file, line: line)
    }

    func testImportCopiesBytesNameAndDateWithoutChangingTheSource() async throws {
        let source = try source("Holiday.MOV")
        let date = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: source.path)
        let first = try await imported(source)
        let second = try await imported(source)
        XCTAssertNotEqual(first.url, second.url, "same filenames must not overwrite an earlier selection")
        XCTAssertEqual(first.filename, "Holiday.MOV")
        XCTAssertEqual(first.byteCount, 2048)
        XCTAssertEqual(first.modified.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(try Data(contentsOf: first.url), try Data(contentsOf: source))
        let exported = try await MediaExporter().export(.importedFile(first))
        XCTAssertEqual(exported.filename, first.filename)
        XCTAssertFalse(exported.temporary, "queue ownership must survive checkpoint cleanup on a retry")
        await MediaFileImporter.discard(first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.url.path))
    }

    func testUnsupportedEmptyMissingAndDirectorySelectionsAreRejected() async throws {
        let pdf = try source("document.pdf")
        let empty = try source("empty.jpg", data: Data())
        let missing = pdf.deletingLastPathComponent().appendingPathComponent("missing.jpg")
        for url in [pdf, empty, missing, pdf.deletingLastPathComponent()] {
            do {
                let file = try await MediaFileImporter.importFile(url)
                await MediaFileImporter.discard(file)
                XCTFail("Unexpectedly imported \(url.lastPathComponent)")
            } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        }
    }

    func testPendingFileRestoresWithoutACheckpointAndSurvivesStorageCleanup() async throws {
        let file = try await imported(source())
        let store = MemoryUploadQueuePersistence()
        let first = queue(store: store)
        first.enqueue([.importedFile(file)])
        let data = try JSONEncoder().encode(XCTUnwrap(store.snapshot))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(MediaExporter.root.path),
                       "source identity must survive an app container path change")
        let decoded = try JSONDecoder().decode(UploadQueueSnapshot.self, from: data)
        MediaFileImporter.releaseProtection(file) // Model a new process.
        let restored = queue(store: MemoryUploadQueuePersistence(snapshot: decoded))
        XCTAssertEqual(restored.items.first?.source, .importedFile(file))
        XCTAssertEqual(restored.items.first?.name, file.filename)
        XCTAssertEqual(restored.items.first?.byteCount, file.byteCount)
        XCTAssertEqual(restored.retainedStagingURLs, [file.url])
        await MediaExporter().purge(excluding: restored.retainedStagingURLs)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
    }

    func testFailureRetainsImportedBytesForRetryThenCompletionRemovesOnlyTheCopy() async throws {
        let source = try source()
        let file = try await imported(source)
        let script = WorkerScript([.fail(GPMCError(kind: .server(503), message: "Try later")),
                                   .succeed(.uploaded(mediaKey: "key"))])
        let queue = queue(worker: script.worker())
        let id = queue.enqueue([.importedFile(file)])[0]
        queue.setNetworkAccess(allowed: true)
        await eventually { queue.failedCount == 1 }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
        XCTAssertTrue(queue.retainedStagingURLs.contains(file.url))
        queue.retry(id)
        await eventually { queue.items.first?.state == .done && !FileManager.default.fileExists(atPath: file.url.path) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testClearAndStopRemoveQueuedCopiesBeforeTheyHaveCheckpoints() async throws {
        for stop in [false, true] {
            let file = try await imported(source())
            let queue = queue()
            let id = queue.enqueue([.importedFile(file)])[0]
            if stop { queue.cancelAll() }
            else {
                queue.cancel(id)
                XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
                queue.clearFinished()
            }
            await eventually { !FileManager.default.fileExists(atPath: file.url.path) }
            XCTAssertTrue(queue.items.isEmpty)
        }
    }

    func testPartialSelectionQueuesReadableFilesAndReportsFailures() async throws {
        let store = MemoryUploadQueuePersistence()
        let queue = queue(store: store)
        let controller = FileImportController()
        await controller.importFiles([try source(), try source("unsupported.pdf")], into: queue)
        XCTAssertEqual(queue.items.count, 1)
        XCTAssertEqual(store.snapshot?.items.count, 1)
        XCTAssertTrue(controller.notice?.contains("1 of 2") == true)
        XCTAssertNil(controller.progress)
        XCTAssertFalse(queue.isDiscovering)
        XCTAssertFalse(queue.backupSession?.scanComplete ?? true)
        queue.cancelAll()
    }

    func testStopOrAccountSwitchDuringCopyCannotQueueIntoANewSession() async throws {
        for switchAccount in [false, true] {
            let file = try await imported(source())
            let queue = queue()
            let controller = FileImportController { _ in
                await MainActor.run {
                    if switchAccount { queue.activateAccount("other@example.com") }
                    else { queue.cancelAll() }
                }
                return file
            }
            await controller.importFiles([try source()], into: queue)
            XCTAssertTrue(queue.items.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.path))
            XCTAssertNil(controller.progress)
        }
    }

    func testFilesDoNotClaimPhotosLibraryComponentsOrCoverage() async throws {
        let file = try await imported(source())
        let source = MediaSource.importedFile(file)
        XCTAssertNil(source.assetIdentifier)
        XCTAssertEqual(source.backupComponentKey, "import:" + file.id.uuidString)
        let queue = queue()
        let scopeOwner = queue.beginDiscovery()
        queue.endDiscovery(scopeOwner, complete: false)
        let controller = FileImportController { _ in file }
        await controller.importFiles([try self.source()], into: queue)
        XCTAssertFalse(queue.backupSession?.scanComplete ?? true)
        XCTAssertTrue(queue.backupSession?.scopeScanOutstanding == true)
        queue.cancelAll()
    }

    func testCleanupCannotDeleteACopyAwaitingItsQueueHandoff() async throws {
        let file = try await imported(source())
        await MediaExporter().purge()
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
        let queue = queue()
        queue.enqueue([.importedFile(file)])
        // A cleanup that started before enqueue may still have an empty snapshot.
        await MediaExporter().purge()
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
        queue.cancelAll()
        await eventually { !FileManager.default.fileExists(atPath: file.url.path) }
    }

    func testCancelImportDiscardsALateCopyWithoutStoppingPreviouslyQueuedWork() async throws {
        let file = try await imported(source())
        let queue = queue()
        queue.enqueue([.asset(localIdentifier: "previous")])
        let started = expectation(description: "copy started")
        let controller = FileImportController { _ in
            started.fulfill()
            // A provider may finish its copy even after cancellation.
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            return file
        }
        let task = Task { await controller.importFiles([try! self.source()], into: queue) }
        await fulfillment(of: [started], timeout: 2)
        controller.cancel()
        await task.value
        XCTAssertEqual(queue.items.map(\.source), [.asset(localIdentifier: "previous")])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.path))
        XCTAssertNil(controller.progress)
    }
}
