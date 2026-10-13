import Foundation
import Photos

/// The single metadata evaluator used by automatic discovery, previews and
/// coverage. Explicit picker selections intentionally bypass these rules.
struct BackupSelectionRules: Codable, Equatable, Sendable {
    enum Media: String, Codable, CaseIterable, Identifiable, Sendable {
        case photosAndVideos, photos, videos
        var id: String { rawValue }
        var title: String {
            switch self {
            case .photosAndVideos: return "Photos & Videos"
            case .photos: return "Photos Only"
            case .videos: return "Videos Only"
            }
        }
    }

    var media: Media = .photosAndVideos
    var excludeScreenshots = false
    var excludeScreenRecordings = false
    /// Absolute boundaries: start is inclusive; end is exclusive. The UI saves
    /// whole calendar days in the chosen timezone, including DST transitions.
    var startDate: Date? = nil
    var endDateExclusive: Date? = nil
    var timeZoneIdentifier: String = TimeZone.current.identifier

    var isValid: Bool {
        guard let startDate, let endDateExclusive else { return true }
        return startDate < endDateExclusive
    }

    var summary: String {
        var parts = [media.title]
        if excludeScreenshots { parts.append("no screenshots") }
        if excludeScreenRecordings { parts.append("no screen recordings") }
        if startDate != nil || endDateExclusive != nil { parts.append("capture date range") }
        return parts.joined(separator: " · ")
    }

    enum Exclusion: String, Codable, CaseIterable, Sendable {
        case unsupportedMedia, mediaType, screenshot, screenRecording, captureDate, missingCaptureDate, invalidDateRange
    }

    func exclusion(for metadata: BackupAssetMetadata) -> Exclusion? {
        guard isValid else { return .invalidDateRange }
        guard metadata.media == .photo || metadata.media == .video else { return .unsupportedMedia }
        if (media == .photos && metadata.media != .photo) || (media == .videos && metadata.media != .video) {
            return .mediaType
        }
        if excludeScreenshots && metadata.isScreenshot { return .screenshot }
        if excludeScreenRecordings && metadata.isScreenRecording { return .screenRecording }
        if startDate != nil || endDateExclusive != nil {
            guard let captured = metadata.captureDate else { return .missingCaptureDate }
            if let startDate, captured < startDate { return .captureDate }
            if let endDateExclusive, captured >= endDateExclusive { return .captureDate }
        }
        return nil
    }

    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    mutating func setFirstDay(_ date: Date) { startDate = calendar.startOfDay(for: date) }
    mutating func setLastDay(_ date: Date) {
        endDateExclusive = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))
    }
}

struct BackupAssetMetadata: Equatable, Sendable {
    enum Media: Sendable { case photo, video, unsupported }
    let identifier: String
    let media: Media
    let isScreenshot: Bool
    let isScreenRecording: Bool
    let captureDate: Date?

    init(identifier: String, media: Media, isScreenshot: Bool = false,
         isScreenRecording: Bool = false, captureDate: Date? = nil) {
        self.identifier = identifier
        self.media = media
        self.isScreenshot = isScreenshot
        self.isScreenRecording = isScreenRecording
        self.captureDate = captureDate
    }

    init(_ asset: PHAsset) {
        identifier = asset.localIdentifier
        media = asset.mediaType == .image ? .photo : (asset.mediaType == .video ? .video : .unsupported)
        isScreenshot = asset.mediaSubtypes.contains(.photoScreenshot)
        isScreenRecording = asset.mediaSubtypes.contains(.videoScreenRecording)
        captureDate = asset.creationDate
    }
}

struct BackupRulesPreview: Equatable, Sendable {
    var included = 0
    var excluded = 0
    var missingMetadata = 0

    static func evaluate(_ assets: [BackupAssetMetadata], rules: BackupSelectionRules) -> Self {
        var preview = Self()
        var seen = Set<String>()
        for asset in assets where seen.insert(asset.identifier).inserted {
            preview.record(rules.exclusion(for: asset))
        }
        return preview
    }

    mutating func record(_ exclusion: BackupSelectionRules.Exclusion?) {
        if let exclusion {
            excluded += 1
            if exclusion == .missingCaptureDate || exclusion == .unsupportedMedia { missingMetadata += 1 }
        } else { included += 1 }
    }
}
