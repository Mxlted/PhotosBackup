import Photos
import SwiftUI

/// Requests only a small, locally available thumbnail. A row disappearing
/// cancels its request; neither thumbnails nor search download iCloud originals.
@MainActor
private final class ActivityThumbnailLoader: ObservableObject {
    @Published var image: UIImage?
    private var requestID: PHImageRequestID?
    private var generation = UUID()
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 120
        cache.totalCostLimit = 8 * 1_024 * 1_024
        return cache
    }()

    func load(_ identifier: String?) {
        cancel()
        image = nil
        guard let identifier, MediaLibrary.isReadable else { return }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else { return }
        let cacheKey = "\(identifier):\(asset.modificationDate?.timeIntervalSince1970 ?? 0)" as NSString
        if let cached = Self.cache.object(forKey: cacheKey) { image = cached; return }
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .fastFormat
        options.resizeMode = .fast
        let generation = self.generation
        requestID = PHImageManager.default().requestImage(
            for: asset, targetSize: CGSize(width: 128, height: 128), contentMode: .aspectFill, options: options
        ) { [weak self] image, info in
            guard info?[PHImageCancelledKey] as? Bool != true, let image else { return }
            Task { @MainActor [weak self] in
                guard let self, generation == self.generation else { return }
                Self.cache.setObject(image, forKey: cacheKey, cost: 128 * 128 * 4)
                self.image = image
            }
        }
    }

    func cancel() {
        generation = UUID()
        if let requestID { PHImageManager.default().cancelImageRequest(requestID) }
        requestID = nil
    }

    deinit {
        if let requestID { PHImageManager.default().cancelImageRequest(requestID) }
    }
}

struct ActivityThumbnail: View {
    let source: MediaSource
    let symbol: String
    let tint: Color
    @StateObject private var loader = ActivityThumbnailLoader()

    var body: some View {
        Group {
            if let image = loader.image {
                Image(uiImage: image).resizable().scaledToFill()
                    .frame(width: 42, height: 42).clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 9))
            } else {
                FeatureIcon(symbol: symbol, color: tint, size: 42)
            }
        }
        .accessibilityHidden(true)
        .onAppear { loader.load(source.assetIdentifier) }
        .onChange(of: source.assetIdentifier) { loader.load($0) }
        .onDisappear { loader.cancel() }
    }
}
