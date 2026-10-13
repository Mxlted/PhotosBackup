import Foundation
import Photos

/// Metadata-only PhotoKit reads. No image requests, private size properties or
/// iCloud downloads. Invoked on a detached task with explicit cancellation.
enum BackupScopeReader {
    struct Result: Sendable {
        var sources: [MediaSource] = []
        var assets: [BackupScopeAsset] = []
        var revisions: [String: PhotoLibraryChangeTracker.AssetRevision] = [:]
        var preview = BackupRulesPreview()
        var unavailableCount = 0
        var fullScan = true
        var nextToken: Data?
        var deleted = Set<String>()
        var hasLibraryChanges = false
        var cancelled = false
    }

    static func read(scope: BackupScopeDescriptor, priorToken: Data? = nil, previewOnly: Bool = false) -> Result {
        var result = Result()
        guard scope.canRead else { result.unavailableCount = 1; return result }
        var changedIdentifiers: Set<String>?
        if #available(iOS 16, *) {
            let library = PHPhotoLibrary.shared()
            result.nextToken = try? NSKeyedArchiver.archivedData(withRootObject: library.currentChangeToken,
                                                               requiringSecureCoding: true)
            if let priorToken,
               let token = try? NSKeyedUnarchiver.unarchivedObject(ofClass: PHPersistentChangeToken.self, from: priorToken) {
                do {
                    let changes = try library.fetchPersistentChanges(since: token)
                    var changed = Set<String>()
                    var collectionChanged = false
                    for change in changes {
                        if Task.isCancelled { result.cancelled = true; return result }
                        let assets = try change.changeDetails(for: .asset)
                        changed.formUnion(assets.insertedLocalIdentifiers)
                        changed.formUnion(assets.updatedLocalIdentifiers)
                        result.deleted.formUnion(assets.deletedLocalIdentifiers)
                        if !scope.selectedAlbumIDs.contains(PhotoAlbum.allPhotosID) {
                            let collections = try change.changeDetails(for: .assetCollection)
                            let changedCollections = collections.insertedLocalIdentifiers
                                .union(collections.updatedLocalIdentifiers).union(collections.deletedLocalIdentifiers)
                            collectionChanged = collectionChanged || !Set(scope.selectedAlbumIDs).isDisjoint(with: changedCollections)
                        }
                    }
                    result.hasLibraryChanges = !changed.isEmpty || !result.deleted.isEmpty || collectionChanged
                    if !collectionChanged { changedIdentifiers = changed; result.fullScan = false }
                } catch {
                    // Expired/unavailable persistent history requires a full
                    // current enumeration before its new token may advance.
                    result.fullScan = true
                }
            }
        }

        var seen = Set<String>()
        func append(_ asset: PHAsset) {
            guard seen.insert(asset.localIdentifier).inserted else { return }
            if let changedIdentifiers, !changedIdentifiers.contains(asset.localIdentifier) { return }
            let exclusion = scope.rules.exclusion(for: BackupAssetMetadata(asset))
            result.preview.record(exclusion)
            guard !previewOnly, exclusion == nil else { return }
            // Never advance the revision of an excluded asset. Its old backup
            // remains valid history; broadening rules must still detect edits
            // made while that asset was excluded.
            result.revisions[asset.localIdentifier] = .init(modified: asset.modificationDate,
                                                          hasAdjustments: asset.hasAdjustments)
            let components = MediaComponentPlan.requiredSources(for: asset,
                includeLivePhotoMotion: scope.includeLivePhotoMotion, includeOriginals: scope.includeOriginals)
            result.sources.append(contentsOf: components)
            result.assets.append(BackupScopeAsset(identifier: asset.localIdentifier,
                                                  requiredKeys: Set(components.compactMap(\.backupComponentKey))))
            if asset.modificationDate == nil { result.unavailableCount += 1 }
        }
        func enumerate(_ assets: PHFetchResult<PHAsset>) {
            assets.enumerateObjects { asset, _, stop in
                if Task.isCancelled { result.cancelled = true; stop.pointee = true; return }
                autoreleasepool { append(asset) }
            }
        }
        if scope.selectedAlbumIDs.contains(PhotoAlbum.allPhotosID) {
            if let changedIdentifiers {
                // Bound fetch arguments for a large persistent-change batch.
                let identifiers = Array(changedIdentifiers.subtracting(result.deleted))
                for offset in stride(from: 0, to: identifiers.count, by: 256) {
                    if Task.isCancelled { result.cancelled = true; break }
                    enumerate(PHAsset.fetchAssets(withLocalIdentifiers: Array(identifiers[offset..<min(offset + 256, identifiers.count)]), options: nil))
                }
            } else { enumerate(PHAsset.fetchAssets(with: PhotoAlbumStore.allPhotosOptions())) }
        } else {
            let collections = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: scope.selectedAlbumIDs, options: nil)
            if result.fullScan { result.unavailableCount += max(0, scope.selectedAlbumIDs.count - collections.count) }
            collections.enumerateObjects { collection, _, stop in
                if Task.isCancelled { result.cancelled = true; stop.pointee = true; return }
                enumerate(PHAsset.fetchAssets(in: collection, options: nil))
            }
        }
        return result
    }

    static func preview(scope: BackupScopeDescriptor) async -> BackupRulesPreview? {
        let worker = Task.detached(priority: .userInitiated) { read(scope: scope, previewOnly: true) }
        let result = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
        guard !Task.isCancelled, !result.cancelled else { return nil }
        var preview = result.preview
        preview.missingMetadata += result.unavailableCount
        return preview
    }
}
