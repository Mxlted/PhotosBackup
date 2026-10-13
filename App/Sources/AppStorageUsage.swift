import Foundation
import WebKit

struct AppStorageSnapshot: Equatable, Sendable {
    let stagedUploads: Int64
    let backupRecords: Int64
    let transferResults: Int64
    let caches: Int64
    var availableForStaging: Int64? = nil

    var appManaged: Int64 { stagedUploads + backupRecords + transferResults }
    var total: Int64 { appManaged + caches }
}

enum AppStorageUsage {
    static func measure() async -> AppStorageSnapshot {
        await Task.detached(priority: .utility) {
            let files = FileManager.default
            let support = files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let records = support.appendingPathComponent("PhotosBackup", isDirectory: true)
            let results = records.appendingPathComponent("BackgroundUploadResults", isDirectory: true)
            let caches = files.urls(for: .cachesDirectory, in: .userDomainMask)[0]

            return AppStorageSnapshot(
                stagedUploads: size(of: MediaExporter.root, excluding: []),
                backupRecords: size(of: records, excluding: [results]),
                transferResults: size(of: results, excluding: []),
                caches: size(of: caches, excluding: []),
                availableForStaging: availableCapacityOnCurrentVolume()
            )
        }.value
    }

    /// Shared by admission control and Storage reporting. The filesystem's
    /// available bytes already exclude all existing staged upload bodies.
    static func availableCapacity() async -> Int64? {
        await Task.detached(priority: .utility) { availableCapacityOnCurrentVolume() }.value
    }

    private static func availableCapacityOnCurrentVolume() -> Int64? {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        guard let values = try? root.resourceValues(forKeys: [
            .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey
        ]) else { return nil }
        let reported = [values.volumeAvailableCapacity.map(Int64.init),
                        values.volumeAvailableCapacityForImportantUsage].compactMap { $0 }
        // Prefer the conservative figure if the important-usage estimate also
        // includes purgeable system data that has not actually been reclaimed.
        return reported.filter { $0 >= 0 }.min()
    }

    /// Removes data that has no durable owner. Pending upload bodies and their
    /// results remain because deleting either can force a large retransmission.
    /// Main actor because WebKit's data store may only be used there.
    @MainActor
    static func cleanUp(retaining files: Set<URL>, transferIDs: Set<UUID>) async {
        await MediaExporter().purge(excluding: files)
        await BackgroundFileUploadTransport.shared.purgeResults(excluding: transferIDs)
        URLCache.shared.removeAllCachedResponses()
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().removeData(
                ofTypes: [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache],
                modifiedSince: .distantPast
            ) {
                continuation.resume()
            }
        }
    }

    private static func size(of root: URL, excluding excludedRoots: Set<URL>) -> Int64 {
        let root = root.standardizedFileURL
        guard FileManager.default.fileExists(atPath: root.path) else { return 0 }
        let excluded = Set(excludedRoots.map(\.standardizedFileURL))
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileAllocatedSizeKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var bytes: Int64 = 0
        for case let url as URL in enumerator {
            let standardized = url.standardizedFileURL
            if excluded.contains(standardized) {
                enumerator.skipDescendants()
                continue
            }
            guard let values = try? standardized.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            bytes += Int64(values.fileAllocatedSize ?? values.fileSize ?? 0)
        }
        return bytes
    }
}
