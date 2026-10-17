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
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                FeatureIcon(symbol: statusSymbol, color: statusColor, size: 42)
                VStack(alignment: .leading, spacing: 4) {
                    Text(statusTitle).font(.headline)
                    Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 24) {
                countSummary(session.uploadedAssets, title: "Uploaded")
                countSummary(session.duplicateAssets, title: "Already saved")
                Spacer(minLength: 0)
            }

            if !session.failedAssets.isEmpty {
                Label("\(session.failedAssets.count) \(session.failedAssets.count == 1 ? "item needs" : "items need") another try", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.orange)
            }
            if !session.deferredAssets.isEmpty {
                Label("\(session.deferredAssets.count) waiting for iCloud", systemImage: "icloud.and.arrow.down")
                    .foregroundStyle(.secondary)
            }
            if session.hasUnmeasuredOutcomes {
                Text("Some earlier results could not be recovered. These totals may be lower than the actual backup.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            Text(nextStep)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            DisclosureGroup("Backup details") {
                VStack(alignment: .leading, spacing: 9) {
                    if let end = session.finishedAt {
                        Text("Finished \(end.formatted(date: .abbreviated, time: .shortened))")
                    }
                    Text("\(ByteCountFormatter.string(fromByteCount: session.uploadedBytes, countStyle: .file)) uploaded\(session.hasUnmeasuredBytes ? " (some file sizes unavailable)" : "")")
                    Text("\(session.components.count) files confirmed · \(session.pendingComponents) still processing")
                    if !session.unavailableAssets.isEmpty {
                        Text("\(session.unavailableAssets.count) items unavailable")
                    }
                    if !session.stoppedAssets.isEmpty {
                        Text("\(session.stoppedAssets.count) items stopped")
                    }
                    Text("One photo can include several files, such as Live Photo motion or an unedited original. An uploaded photo may still need one of those files to finish.")
                    Text("Times include pauses and time spent in the background. Active upload time is not recorded separately.")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
            }
            .font(.subheadline)
        }
        .padding(.vertical, 8)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func countSummary(_ count: Int, title: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(count.formatted())
                .font(.system(.title2, design: .rounded).weight(.semibold))
                .monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var statusTitle: String {
        switch session.outcome {
        case .scanning: return "Finding photos"
        case .working: return "Backing up"
        case .paused: return "Backup paused"
        case .deferred: return "Waiting for iCloud"
        case .needsAttention: return "Backup needs attention"
        case .incomplete: return "Library check unfinished"
        case .stopped: return "Backup stopped"
        case .completed: return "Backup finished"
        case .completedWithFailures: return "Finished with some issues"
        }
    }

    private var statusSymbol: String {
        switch session.outcome {
        case .completed: return "checkmark.icloud"
        case .needsAttention, .completedWithFailures, .incomplete: return "exclamationmark.circle"
        case .paused, .stopped: return "pause.circle"
        case .deferred: return "icloud.and.arrow.down"
        case .scanning, .working: return "arrow.up.icloud"
        }
    }

    private var statusColor: Color {
        switch session.outcome {
        case .completed: return .green
        case .needsAttention, .completedWithFailures, .incomplete: return .orange
        default: return BackupTheme.blue
        }
    }

    private var nextStep: String {
        switch session.outcome {
        case .completed: return "This backup is finished. Open Backup details on Home to review your selected albums."
        case .completedWithFailures, .needsAttention: return "Check Activity for items to retry, or Settings if your account or storage needs attention."
        case .deferred: return "Keep the app open to download the remaining items from iCloud."
        case .incomplete, .scanning: return "Start a backup from Home to finish checking your selected albums."
        case .paused: return "Backups continue when conditions allow. If you paused the backup yourself, tap Resume."
        case .stopped: return "Start a backup from Home whenever you’re ready."
        case .working: return "Keep the app open to continue, or let iOS resume the backup in the background when available."
        }
    }
}

struct BackupSessionHistoryView: View {
    @EnvironmentObject private var queue: UploadQueue
    @State private var records: [AutomaticBackupRunRecord] = []

    var body: some View {
        List {
            if let session = queue.backupSession {
                Section("Latest backup") {
                    BackupSessionSummaryView(session: session)
                }
            }
            Section("Earlier backups") {
                ForEach(records) { record in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top, spacing: 12) {
                            FeatureIcon(symbol: record.success == true ? "checkmark.icloud" : "clock.arrow.circlepath", size: 36)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(record.startedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.headline)
                                Text(recordStatus(record))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        DisclosureGroup("View details") {
                            VStack(alignment: .leading, spacing: 8) {
                                if let end = record.finishedAt {
                                    Text("Finished \(end.formatted(date: .abbreviated, time: .shortened))")
                                }
                                Text(record.summary ?? "No summary is available yet.")
                                Text("Active upload time and waiting time were not recorded separately.")
                            }
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.top, 6)
                        }
                        .font(.subheadline)
                    }
                    .padding(.vertical, 6)
                }
                if records.isEmpty {
                    Text("Earlier backups will appear here for this account.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                }
            }
        }
        .backupListBackground()
        .navigationTitle("Backup history")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { reload() }
        .onChange(of: queue.backupSession?.id) { _ in reload() }
        .onChange(of: queue.activeAccountScope) { _ in reload() }
    }

    private func recordStatus(_ record: AutomaticBackupRunRecord) -> String {
        if record.success == true { return "Backup finished" }
        if record.finishedAt == nil { return "In progress or unfinished" }
        return "Check details for the result"
    }

    private func reload() {
        records = AutomaticBackupRunHistory.recent().filter {
            $0.accountScope == queue.activeAccountScope && $0.source == .session && $0.id != queue.backupSession?.id
        }
    }
}
