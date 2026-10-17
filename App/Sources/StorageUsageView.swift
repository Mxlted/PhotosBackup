import SwiftUI

struct StorageUsageView: View {
    @EnvironmentObject private var queue: UploadQueue
    @State private var snapshot: AppStorageSnapshot?
    @State private var isCleaning = false
    @State private var didCleanUp = false

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        FeatureIcon(symbol: "internaldrive", size: 44)
                        Text("Local backup data")
                            .font(.headline)
                    }
                    if let snapshot {
                        Text(snapshot.total.formatted(.byteCount(style: .file)))
                            .font(.system(.largeTitle, design: .rounded).weight(.semibold))
                            .foregroundStyle(BackupTheme.blue)
                    } else {
                        ProgressView("Calculating storage…")
                    }
                    Text("Temporary upload files and records stored on this iPhone.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            }

            Section("Storage breakdown") {
                storageRow("Waiting to upload", bytes: snapshot?.stagedUploads)
                storageRow("Backup history", bytes: snapshot?.backupRecords)
                storageRow("Transfer records", bytes: snapshot?.transferResults)
                storageRow("Temporary caches", bytes: snapshot?.caches)
            }

            Section {
                HStack {
                    Text("Available on this iPhone")
                    Spacer()
                    Text(snapshot?.availableForStaging.map { $0.formatted(.byteCount(style: .file)) } ?? "Unavailable")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            } footer: {
                Text("These amounts describe local data, not your Google Photos storage.")
            }

            Section {
                Button {
                    cleanUp()
                } label: {
                    HStack {
                        Label(isCleaning ? "Cleaning up…" : "Clean up unused data", systemImage: "sparkles")
                        Spacer()
                        if isCleaning { ProgressView() }
                    }
                    .padding(.vertical, 3)
                }
                .disabled(isCleaning)
                if didCleanUp {
                    Label("Cleanup complete", systemImage: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.green)
                        .accessibilityAddTraits(.updatesFrequently)
                }
            } footer: {
                Text("Clears unused temporary files. Keeps pending uploads, your connected account and backup history.")
            }

            Section {
                DisclosureGroup("Why backups use local storage") {
                    Text("Pending uploads keep a full-size copy until Google confirms the backup. Large videos can temporarily use significant space.")
                    Text("Backup history is a small record of photos already backed up for each account. It prevents the same photos from being uploaded again after every scan.")
                }
                DisclosureGroup("What cleanup removes") {
                    Text("Removes caches, old transfer records, and upload copies no longer needed by the queue. Files still needed for an active or pending upload stay on this iPhone.")
                }
            }
            .font(.subheadline)
        }
        .backupListBackground()
        .navigationTitle("iPhone storage")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
        .refreshable { await refresh() }
    }

    @ViewBuilder
    private func storageRow(_ title: String, bytes: Int64?) -> some View {
        HStack(spacing: 16) {
            Text(title)
            Spacer()
            if let bytes {
                Text(bytes.formatted(.byteCount(style: .file)))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
            } else {
                ProgressView()
            }
        }
    }

    private func cleanUp() {
        guard !isCleaning else { return }
        isCleaning = true
        didCleanUp = false
        let files = queue.retainedStagingURLs
        let transferIDs = queue.retainedTransferIDs
        let before = snapshot?.total
        Task {
            await AppStorageUsage.cleanUp(retaining: files, transferIDs: transferIDs)
            await refresh()
            if let before, let after = snapshot?.total {
                DiagnosticEventLog.shared.record(
                    "storage",
                    "Cleaned up unused data; freed \(DiagnosticProcessInfo.bytes(max(0, before - after)))"
                )
            }
            isCleaning = false
            didCleanUp = true
        }
    }

    private func refresh() async {
        snapshot = await AppStorageUsage.measure()
    }
}
