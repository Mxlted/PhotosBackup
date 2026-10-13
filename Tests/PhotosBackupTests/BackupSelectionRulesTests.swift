import Photos
import XCTest
@testable import PhotosBackup

final class BackupSelectionRulesTests: XCTestCase {
    func testDefaultsIncludePhotosVideosAndScreenCapturesWithoutDates() {
        let assets: [BackupAssetMetadata] = [
            .init(identifier: "photo", media: .photo, isScreenshot: true),
            .init(identifier: "video", media: .video, isScreenRecording: true)
        ]
        XCTAssertEqual(BackupRulesPreview.evaluate(assets, rules: .init()),
                       BackupRulesPreview(included: 2, excluded: 0, missingMetadata: 0))
    }

    func testSupportedSubtypesAndMediaTypesShareOneEvaluator() {
        var rules = BackupSelectionRules()
        rules.excludeScreenshots = true
        rules.excludeScreenRecordings = true
        XCTAssertEqual(rules.exclusion(for: .init(identifier: "a", media: .photo, isScreenshot: true)), .screenshot)
        XCTAssertEqual(rules.exclusion(for: .init(identifier: "b", media: .video, isScreenRecording: true)), .screenRecording)
        XCTAssertNil(rules.exclusion(for: .init(identifier: "c", media: .video)), "unmarked imports cannot be guessed from filenames")
        rules.media = .photos
        XCTAssertEqual(rules.exclusion(for: .init(identifier: "b", media: .video)), .mediaType)
        rules.media = .videos
        XCTAssertEqual(rules.exclusion(for: .init(identifier: "a", media: .photo)), .mediaType)
        XCTAssertEqual(rules.exclusion(for: .init(identifier: "u", media: .unsupported)), .unsupportedMedia)
    }

    func testDateBoundariesAreInclusiveStartExclusiveEndAndMissingDateIsExcluded() {
        var rules = BackupSelectionRules()
        rules.startDate = Date(timeIntervalSince1970: 100)
        rules.endDateExclusive = Date(timeIntervalSince1970: 200)
        func exclusion(_ time: Double?) -> BackupSelectionRules.Exclusion? {
            rules.exclusion(for: .init(identifier: "a", media: .photo, captureDate: time.map(Date.init(timeIntervalSince1970:))))
        }
        XCTAssertEqual(exclusion(99), .captureDate)
        XCTAssertNil(exclusion(100))
        XCTAssertNil(exclusion(199))
        XCTAssertEqual(exclusion(200), .captureDate)
        XCTAssertEqual(exclusion(nil), .missingCaptureDate)
    }

    func testWholeCaptureDayUsesStoredTimezoneAcrossDaylightSaving() throws {
        var rules = BackupSelectionRules()
        rules.timeZoneIdentifier = "America/New_York"
        let day = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-03-08T12:00:00Z"))
        rules.setFirstDay(day)
        rules.setLastDay(day)
        XCTAssertEqual(try XCTUnwrap(rules.endDateExclusive).timeIntervalSince(try XCTUnwrap(rules.startDate)), 23 * 3600)
        let restored = try JSONDecoder().decode(BackupSelectionRules.self, from: JSONEncoder().encode(rules))
        XCTAssertEqual(restored, rules)
        XCTAssertEqual(restored.calendar.timeZone.identifier, "America/New_York")
    }

    func testInvalidDateRangeCannotAdmitAssets() {
        var rules = BackupSelectionRules()
        rules.startDate = Date(timeIntervalSince1970: 200)
        rules.endDateExclusive = Date(timeIntervalSince1970: 100)
        XCTAssertFalse(rules.isValid)
        XCTAssertEqual(rules.exclusion(for: .init(identifier: "a", media: .photo, captureDate: Date())), .invalidDateRange)
    }

    func testPreviewDeduplicatesOverlappingAlbumsAndDoesNotMutateRules() {
        let photo = BackupAssetMetadata(identifier: "a", media: .photo)
        let video = BackupAssetMetadata(identifier: "b", media: .video)
        var rules = BackupSelectionRules()
        rules.media = .photos
        let before = rules
        let preview = BackupRulesPreview.evaluate([photo, video, photo], rules: rules)
        XCTAssertEqual(preview.included, 1)
        XCTAssertEqual(preview.excluded, 1)
        XCTAssertEqual(rules, before)
    }

    func testScopeFingerprintTracksEveryCoverageDimension() {
        let base = BackupScopeDescriptor(accountIdentifier: "ACCOUNT", selectedAlbumIDs: ["a", "b"], authorization: PHAuthorizationStatus.authorized.rawValue)
        XCTAssertEqual(base.fingerprint, BackupScopeDescriptor(accountIdentifier: "account", selectedAlbumIDs: ["b", "a"], authorization: PHAuthorizationStatus.authorized.rawValue).fingerprint)
        var rules = BackupSelectionRules(); rules.excludeScreenshots = true
        let variants = [
            BackupScopeDescriptor(accountIdentifier: "other", selectedAlbumIDs: ["a", "b"], authorization: 3),
            BackupScopeDescriptor(accountIdentifier: "account", selectedAlbumIDs: ["a"], authorization: 3),
            BackupScopeDescriptor(accountIdentifier: "account", selectedAlbumIDs: ["a", "b"], rules: rules, authorization: 3),
            BackupScopeDescriptor(accountIdentifier: "account", selectedAlbumIDs: ["a", "b"], includeLivePhotoMotion: true, authorization: 3),
            BackupScopeDescriptor(accountIdentifier: "account", selectedAlbumIDs: ["a", "b"], includeOriginals: true, authorization: 3),
            BackupScopeDescriptor(accountIdentifier: "account", selectedAlbumIDs: ["a", "b"], authorization: 4),
            BackupScopeDescriptor(accountIdentifier: "account", selectedAlbumIDs: ["a", "b"], authorization: 3, libraryRevision: 1)
        ]
        for variant in variants { XCTAssertNotEqual(base.fingerprint, variant.fingerprint) }
    }
}
