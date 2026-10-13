import CryptoKit
import Foundation
import Photos

struct BackupScopeDescriptor: Codable, Equatable, Sendable {
    let accountIdentifier: String?
    let selectedAlbumIDs: [String]
    let rules: BackupSelectionRules
    let includeLivePhotoMotion: Bool
    let includeOriginals: Bool
    let authorization: Int
    let libraryRevision: UInt64

    init(accountIdentifier: String?, selectedAlbumIDs: Set<String>, rules: BackupSelectionRules = .init(),
         includeLivePhotoMotion: Bool = false, includeOriginals: Bool = false,
         authorization: Int, libraryRevision: UInt64 = 0) {
        let normalized = accountIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.accountIdentifier = normalized.flatMap { $0.isEmpty ? nil : $0 }
        self.selectedAlbumIDs = selectedAlbumIDs.sorted()
        self.rules = rules
        self.includeLivePhotoMotion = includeLivePhotoMotion
        self.includeOriginals = includeOriginals
        self.authorization = authorization
        self.libraryRevision = libraryRevision
    }

    var fingerprint: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = (try? encoder.encode(self)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    var isLimited: Bool { authorization == PHAuthorizationStatus.limited.rawValue }
    var canRead: Bool { isLimited || authorization == PHAuthorizationStatus.authorized.rawValue }
}

struct BackupScopeAsset: Codable, Equatable, Sendable {
    let identifier: String
    let requiredKeys: Set<String>
}

/// A completed metadata enumeration, never evidence of a remote backup by
/// itself. Only the tracker commits this after durable queue handoff.
struct BackupScopeManifest: Codable, Equatable, Sendable {
    let scope: BackupScopeDescriptor
    let scannedAt: Date
    let assets: [BackupScopeAsset]
    let excludedCount: Int
    let unavailableMetadataCount: Int
}

struct BackupHealthSnapshot: Equatable, Sendable {
    let scope: BackupScopeDescriptor
    let lastSuccessfulScan: Date?
    let includedCount: Int?
    let excludedCount: Int?
    let rememberedCompletions: Int
    let pending: Int
    let failed: Int
    let deferred: Int
    /// Nil means that the selected scope has not been fully enumerated.
    let unknown: Int?
    let incompleteComponents: Int
    /// The oldest confirmation across every required component; nil if any
    /// component is unconfirmed. Legacy ledger entries have no invented date.
    let verifiedThrough: Date?
    let mostRecentRemoteConfirmation: Date?

    init(scope: BackupScopeDescriptor, manifest: BackupScopeManifest?, lastSuccessfulScan: Date? = nil,
         completedKeys: Set<String>, items: [UploadItem], remoteConfirmations: [String: Date] = [:]) {
        self.scope = scope
        self.lastSuccessfulScan = lastSuccessfulScan ?? (manifest?.scope == scope ? manifest?.scannedAt : nil)
        guard let manifest, manifest.scope == scope, scope.canRead else {
            includedCount = nil; excludedCount = nil
            rememberedCompletions = 0; pending = 0; failed = 0; deferred = 0; unknown = nil
            incompleteComponents = 0; verifiedThrough = nil; mostRecentRemoteConfirmation = nil
            return
        }
        self.includedCount = Set(manifest.assets.map(\.identifier)).count
        self.excludedCount = manifest.excludedCount
        let states = Dictionary(items.compactMap { item in
            item.source.backupComponentKey.map { ($0, item.state) }
        }, uniquingKeysWith: { old, new in old.isFinished ? new : old })
        var complete = 0, pending = 0, failed = 0, deferred = 0
        var unknown = manifest.unavailableMetadataCount, incomplete = 0
        var confirmationDates: [Date] = []
        var everyComponentConfirmed = manifest.unavailableMetadataCount == 0
        // Be defensive against older or injected manifests with overlapping albums.
        var seen = Set<String>()
        for asset in manifest.assets where seen.insert(asset.identifier).inserted {
            if Task.isCancelled { break }
            let missing = asset.requiredKeys.subtracting(completedKeys)
            if missing.isEmpty && !asset.requiredKeys.isEmpty { complete += 1 }
            else {
                if completedKeys.contains("asset:" + asset.identifier) { incomplete += 1 }
                let missingStates = missing.compactMap { states[$0] }
                if missingStates.contains(where: { if case .failed = $0 { return true }; return false }) { failed += 1 }
                else if missingStates.contains(.waitingForICloud) { deferred += 1 }
                else if missingStates.contains(where: { !$0.isFinished }) { pending += 1 }
                else { unknown += 1 }
            }
            for key in asset.requiredKeys {
                if let date = remoteConfirmations[key], completedKeys.contains(key) { confirmationDates.append(date) }
                else { everyComponentConfirmed = false }
            }
        }
        self.rememberedCompletions = complete
        self.pending = pending; self.failed = failed; self.deferred = deferred; self.unknown = unknown
        self.incompleteComponents = incomplete
        self.verifiedThrough = everyComponentConfirmed ? confirmationDates.min() : nil
        self.mostRecentRemoteConfirmation = confirmationDates.max()
    }

    var hasCompleteLocalCoverage: Bool {
        includedCount != nil && unknown == 0 && pending == 0 && failed == 0 && deferred == 0
    }

    var nextAction: String {
        if scope.accountIdentifier == nil { return "Connect your Google account to check this scope." }
        if !scope.canRead { return "Allow Photos access to check the selected albums." }
        if scope.selectedAlbumIDs.isEmpty { return "Select albums to define your backup scope." }
        if includedCount == nil { return "Scan the selected albums to establish coverage." }
        if failed > 0 { return "Review failed items in Activity and retry when the problem is resolved." }
        if deferred > 0 { return "Keep the app open with an allowed connection to download deferred iCloud items." }
        if pending > 0 { return "Continue backup; required components are still pending." }
        if (unknown ?? 0) > 0 { return "Scan again to queue missing components or resolve unavailable metadata." }
        if includedCount == 0 { return "No accessible items match these albums and rules." }
        return "The required components are remembered locally. Re-check Backups to confirm them with Google again."
    }
}
