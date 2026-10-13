import Foundation
import Photos

/// One component vocabulary for discovery, coverage and durable queue keys.
/// A current appearance, original and either motion are independently durable.
/// The Google edit base has its existing, separate recognition purpose.
enum MediaComponentPlan {
    static func requiredSources(identifier: String, mediaType: PHAssetMediaType,
                                hasAdjustments: Bool, isLivePhoto: Bool, hasEditBase: Bool,
                                includeLivePhotoMotion: Bool, includeOriginals: Bool) -> [MediaSource] {
        var sources: [MediaSource] = [.asset(localIdentifier: identifier)]
        if mediaType == .image && isLivePhoto && includeLivePhotoMotion {
            sources.append(.livePhotoMotion(localIdentifier: identifier))
        }
        if mediaType == .image && hasAdjustments && hasEditBase {
            sources.append(.editBase(localIdentifier: identifier))
        }
        if hasAdjustments && includeOriginals && (mediaType == .image || mediaType == .video) {
            sources.append(.original(localIdentifier: identifier))
            if mediaType == .image && isLivePhoto && includeLivePhotoMotion {
                sources.append(.originalMotion(localIdentifier: identifier))
            }
        }
        return sources
    }

    static func requiredSources(for asset: PHAsset, includeLivePhotoMotion: Bool,
                                includeOriginals: Bool) -> [MediaSource] {
        requiredSources(identifier: asset.localIdentifier, mediaType: asset.mediaType,
                        hasAdjustments: asset.hasAdjustments,
                        isLivePhoto: asset.mediaSubtypes.contains(.photoLive),
                        hasEditBase: MediaExporter.hasEditBase(asset),
                        includeLivePhotoMotion: includeLivePhotoMotion, includeOriginals: includeOriginals)
    }
}

extension MediaSource {
    var assetIdentifier: String? {
        switch self {
        case .asset(let id), .livePhotoMotion(let id), .editBase(let id),
             .original(let id), .originalMotion(let id): return id
        case .file, .picked: return nil
        }
    }

    var backupComponentKey: String? {
        switch self {
        case .asset(let id): return "asset:" + id
        case .livePhotoMotion(let id): return "motion:" + id
        case .editBase(let id): return "editbase:" + id
        case .original(let id): return "original:" + id
        case .originalMotion(let id): return "originalmotion:" + id
        case .file(let url): return "file:" + url.standardizedFileURL.path
        case .picked: return nil
        }
    }
}
