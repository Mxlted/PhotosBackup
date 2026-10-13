import Foundation
import CryptoKit
import SwiftUI

/// A logical batch spans execution windows. Only a complete discovery handoff
/// and settled required components can close it. An execution window is not a batch.
struct BackupSession: Codable, Equatable, Identifiable, Sendable {
    enum Outcome: String, Codable, Sendable {
        case scanning, working, paused, deferred, needsAttention, incomplete, stopped
        case completed, completedWithFailures
        var isComplete: Bool { self == .completed || self == .completedWithFailures }
        var title: String {
            switch self {
            case .scanning: return "Scanning selected scope"
            case .working: return "Backup in progress"
            case .paused: return "Backup paused"
            case .deferred: return "Waiting for iCloud"
            case .needsAttention: return "Action required"
            case .incomplete: return "Scan incomplete"
            case .stopped: return "Stopped by you"
            case .completed: return "Session complete"
            case .completedWithFailures: return "Finished with failures"
            }
        }
    }
    struct Component: Codable, Equatable, Sendable {
        let asset: String
        let uploaded: Bool
        let bytes: Int64?
    }
    let id: UUID
    let startedAt: Date
    var finishedAt: Date?
    var scanComplete: Bool
    var scopeScanOutstanding = false
    var outcome: Outcome = .working
    var components: [String: Component] = [:]
    var itemIDs: Set<UUID> = []
    /// Counts are assets; required component failures may overlap an uploaded asset.
    var failedAssets: Set<String> = []
    var deferredAssets: Set<String> = []
    var stoppedAssets: Set<String> = []
    var unavailableAssets: Set<String> = []
    var pendingComponents = 0
    var hasUnmeasuredOutcomes = false
    var wasStopped = false

    init(id: UUID = UUID(), now: Date = Date(), scanComplete: Bool) {
        self.id = id; startedAt = now; self.scanComplete = scanComplete
    }
    var uploadedAssets: Int { Set(components.values.filter(\.uploaded).map(\.asset)).count }
    var duplicateAssets: Int {
        Set(components.values.filter { !$0.uploaded }.map(\.asset))
            .subtracting(Set(components.values.filter(\.uploaded).map(\.asset))).count
    }
    var uploadedBytes: Int64 { components.values.filter(\.uploaded).reduce(0) { $0 + max(0, $1.bytes ?? 0) } }
    var hasUnmeasuredBytes: Bool { components.values.contains { $0.uploaded && $0.bytes == nil } }
    var nextAction: String {
        switch outcome {
        case .completed: return "This session is settled. Check Backup Health for the selected library's coverage."
        case .completedWithFailures, .needsAttention: return "Open Activity to review failures, or Settings to recover the account or storage."
        case .deferred: return "Keep the app open to download deferred items from iCloud."
        case .incomplete, .scanning: return "Run Back Up Now to finish scanning the current selection."
        case .paused: return "Backup resumes when the pause condition clears; a user pause needs Resume."
        case .stopped: return "Start Back Up Now when you are ready."
        case .working: return "Keep the app open or allow iOS to provide another execution window."
        }
    }
    var summary: String {
        "\(outcome.title)\(hasUnmeasuredOutcomes ? " (known results only; some outcomes unavailable after recovery)" : ""): \(uploadedAssets) assets uploaded, \(duplicateAssets) already present, \(failedAssets.count) failed, \(deferredAssets.count) deferred, \(unavailableAssets.count) unavailable; \(components.count) components confirmed; \(uploadedBytes) measured upload bytes\(hasUnmeasuredBytes ? " (some sizes unavailable)" : "")."
    }
    mutating func evaluate(discovering: Bool, pending: Int, failed: Set<String>, deferred: Set<String>,
                           cancelled: Set<String>, paused: Bool, halted: Bool, durable: Bool, now: Date) {
        // Keep failure/deferred counts after Clear Finished; retries explicitly remove them.
        failedAssets.formUnion(failed); deferredAssets = deferred
        stoppedAssets.formUnion(cancelled); pendingComponents = pending
        if wasStopped || !stoppedAssets.isEmpty { outcome = .stopped }
        else if halted || !durable { outcome = .needsAttention }
        else if paused { outcome = .paused }
        else if discovering { outcome = .scanning }
        else if !scanComplete || !unavailableAssets.isEmpty { outcome = .incomplete }
        else if pending > 0 { outcome = deferred.isEmpty ? .working : .deferred }
        else { outcome = failedAssets.isEmpty ? .completed : .completedWithFailures }
        finishedAt = outcome.isComplete || outcome == .stopped ? (finishedAt ?? now) : nil
    }
    /// Hashes are local account partitions, never displayed in exported summaries.
    static func accountScope(_ account: String) -> String {
        SHA256.hash(data: Data(account.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}

struct BackupSessionSummaryView: View {
    let session: BackupSession
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(session.outcome.title).font(.headline)
            Text("Started \(session.startedAt.formatted(date: .abbreviated, time: .shortened))")
            if let end = session.finishedAt { Text("Finished \(end.formatted(date: .abbreviated, time: .shortened))") }
            if session.hasUnmeasuredOutcomes {
                Text("Known results only: some completed outcomes were unavailable after recovery. Totals may be higher.").foregroundStyle(.orange)
            }
            Text("\(session.uploadedAssets) assets uploaded · \(session.duplicateAssets) already present")
            Text("\(session.failedAssets.count) failed · \(session.deferredAssets.count) deferred · \(session.pendingComponents) components pending")
            Text("\(ByteCountFormatter.string(fromByteCount: session.uploadedBytes, countStyle: .file)) uploaded\(session.hasUnmeasuredBytes ? " measured (some sizes unavailable)" : "")")
            Text("Active upload and waiting durations are unavailable; elapsed time includes suspension.")
                .foregroundStyle(.secondary)
            Text(session.nextAction).foregroundStyle(.secondary)
        }.font(.subheadline).fixedSize(horizontal: false, vertical: true)
    }
}

struct BackupSessionHistoryView: View {
    @EnvironmentObject private var queue: UploadQueue
    @State private var records: [AutomaticBackupRunRecord] = []
    var body: some View {
        List {
            if let session = queue.backupSession {
                Section("Current or latest session") { BackupSessionSummaryView(session: session) }
            }
            Section("Recent sessions") {
                ForEach(records) { record in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(record.startedAt.formatted(date: .abbreviated, time: .shortened)).font(.headline)
                        if let end = record.finishedAt {
                            Text("Finished \(end.formatted(date: .abbreviated, time: .shortened))")
                        } else { Text("Incomplete or in progress") }
                        Text(record.summary ?? "In progress")
                        Text(record.success == true ? "Check Backup Health for current coverage." : "Review Activity and run Back Up Now to continue.")
                        Text("Active and waiting duration unavailable.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if records.isEmpty { Text("No earlier session summaries for this account.").foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Backup Sessions")
        .onAppear { reload() }
        .onChange(of: queue.backupSession?.id) { _ in reload() }
        .onChange(of: queue.activeAccountScope) { _ in reload() }
    }
    private func reload() {
        records = AutomaticBackupRunHistory.recent().filter {
            $0.accountScope == queue.activeAccountScope && $0.source == .session && $0.id != queue.backupSession?.id
        }
    }
}
