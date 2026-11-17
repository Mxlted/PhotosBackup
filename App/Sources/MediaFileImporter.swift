import Foundation
import Combine
import UniformTypeIdentifiers

/// Store a relative identity, not the app container's absolute path, which
/// can change when iOS updates or restores the app.
struct ImportedMediaFile: Codable, Equatable, Sendable {
    let id: UUID
    let filename: String
    let byteCount: Int64
    let modified: Date

    var directory: URL { MediaExporter.root.appendingPathComponent(id.uuidString, isDirectory: true) }
    var url: URL { directory.appendingPathComponent((filename as NSString).lastPathComponent) }
}

enum MediaFileImporter {
    /// Storage cleanup can run while a provider copy is still being imported.
    /// Protect that directory for its in-process lifetime, even if cleanup
    /// took its queue snapshot just before enqueue. On relaunch the persisted
    /// queue supplies the retained files instead.
    private final class ImportProtection: @unchecked Sendable {
        let lock = NSLock()
        var directories: Set<URL> = []
    }
    private static let protection = ImportProtection()

    private static func stage(named name: String) throws -> URL {
        protection.lock.lock()
        defer { protection.lock.unlock() }
        let destination = try MediaExporter.stage(named: name)
        protection.directories.insert(destination.standardizedFileURL.deletingLastPathComponent())
        return destination
    }

    static func releaseProtection(_ file: ImportedMediaFile) {
        protection.lock.lock()
        defer { protection.lock.unlock() }
        protection.directories.remove(file.directory.standardizedFileURL)
    }

    static func removeIfUnprotected(_ directory: URL) {
        protection.lock.lock()
        defer { protection.lock.unlock() }
        guard !protection.directories.contains(directory.standardizedFileURL) else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    enum Failure: LocalizedError {
        case unsupported
        case empty

        var errorDescription: String? {
            switch self {
            case .unsupported: return "Choose a photo or video file."
            case .empty: return "This file is empty."
            }
        }
    }

    static func importFile(_ source: URL) async throws -> ImportedMediaFile {
        let work = Task.detached(priority: .userInitiated) { try copy(source) }
        return try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
    }

    private static func copy(_ source: URL) throws -> ImportedMediaFile {
        try Task.checkCancellation()
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var result: Result<ImportedMediaFile, Error>?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { readable in
            result = Result {
                try Task.checkCancellation()
                let values = try readable.resourceValues(forKeys: [
                    .isRegularFileKey, .isSymbolicLinkKey, .contentTypeKey, .fileSizeKey, .contentModificationDateKey
                ])
                let type = values.contentType ?? UTType(filenameExtension: source.pathExtension)
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                      type?.conforms(to: .image) == true || type?.conforms(to: .movie) == true else {
                    throw Failure.unsupported
                }
                guard let size = values.fileSize, size > 0 else { throw Failure.empty }
                let destination = try stage(named: source.lastPathComponent)
                do {
                    try FileManager.default.copyItem(at: readable, to: destination)
                    try FileManager.default.setAttributes(
                        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                        ofItemAtPath: destination.path)
                    try Task.checkCancellation()
                    return ImportedMediaFile(id: UUID(uuidString: destination.deletingLastPathComponent().lastPathComponent)!,
                        filename: destination.lastPathComponent, byteCount: Int64(size),
                        modified: values.contentModificationDate ?? Date())
                } catch {
                    protection.lock.lock()
                    protection.directories.remove(destination.standardizedFileURL.deletingLastPathComponent())
                    protection.lock.unlock()
                    try? FileManager.default.removeItem(at: destination.deletingLastPathComponent())
                    throw error
                }
            }
        }
        if let result { return try result.get() }
        throw coordinationError ?? CocoaError(.fileReadUnknown) as NSError
    }

    static func discard(_ file: ImportedMediaFile) async {
        await Task.detached(priority: .utility) {
            releaseProtection(file)
            removeIfUnprotected(file.directory)
        }.value
    }
}

/// One file is copied and durably queued at a time, so a failed provider read
/// doesn't discard the rest of a selection. Discovery ownership prevents a
/// delayed copy from adding work after Stop or an account change.
@MainActor
final class FileImportController: ObservableObject {
    @Published private(set) var progress: String?
    @Published var notice: String?
    private let importer: @Sendable (URL) async throws -> ImportedMediaFile
    private var copyTask: Task<ImportedMediaFile, Error>?
    private var cancelled = false

    init(importer: @escaping @Sendable (URL) async throws -> ImportedMediaFile = { try await MediaFileImporter.importFile($0) }) {
        self.importer = importer
    }

    func importFiles(_ urls: [URL], into queue: UploadQueue) async {
        guard !urls.isEmpty, progress == nil, queue.activeAccountScope != nil else { return }
        let owner = queue.beginDiscovery(requiresCompleteScope: false)
        var complete = false
        var failures: [String] = []
        notice = nil
        cancelled = false
        defer {
            copyTask = nil
            progress = nil
            queue.endDiscovery(owner, complete: complete)
        }
        for (index, url) in urls.enumerated() {
            guard !Task.isCancelled, !cancelled, queue.ownsDiscovery(owner) else { return }
            progress = "Importing file \(index + 1) of \(urls.count)…"
            do {
                let importer = self.importer
                let work = Task { try await importer(url) }
                copyTask = work
                let file = try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
                copyTask = nil
                guard !Task.isCancelled, !cancelled, queue.ownsDiscovery(owner) else {
                    await MediaFileImporter.discard(file)
                    return
                }
                queue.enqueue([.importedFile(file)], skippingExisting: true)
            } catch is CancellationError { return }
            catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        complete = failures.isEmpty && queue.persistenceWarning == nil
        if !failures.isEmpty {
            let detail = failures.prefix(5).joined(separator: "\n\n")
            notice = "Couldn’t import \(failures.count) of \(urls.count) files. Any other selected files were added to Activity.\n\n" + detail
                + (failures.count > 5 ? "\n\nAnd \(failures.count - 5) more." : "")
        }
    }

    func cancel() {
        guard progress != nil else { return }
        cancelled = true
        progress = "Cancelling import…"
        copyTask?.cancel()
    }
}
