import SwiftUI

struct BackupHealthView: View {
    let snapshot: BackupHealthSnapshot
    var onScan: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                overview
                nextStep
                if snapshot.includedCount != nil { coverage }
                scope
                confirmationDetails
            }
            .padding(20)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .background(BackupTheme.background.ignoresSafeArea())
        .navigationTitle("Backup Status")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                FeatureIcon(symbol: "checkmark.shield", size: 44)
                Spacer()
                StatusPill(text: statusTitle, symbol: statusSymbol, color: statusColor)
            }
            if let included = snapshot.includedCount {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(snapshot.rememberedCompletions.formatted()) of \(included.formatted()) items")
                        .font(.title2.weight(.semibold))
                    Text("Recorded in your backup history")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if included > 0 {
                    ProgressView(value: Double(snapshot.rememberedCompletions), total: Double(included))
                        .tint(BackupTheme.blue)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Check your selected albums")
                        .font(.title2.weight(.semibold))
                    Text("A scan shows what’s backed up and what still needs attention.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Text("Based on your last scan and this device’s backup history. This is not a live check of Google Photos.")
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .backupCard()
    }

    private var nextStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeading(title: "What’s next")
            Text(nextAction).font(.subheadline).foregroundStyle(.secondary)
            Button("Scan Selected Albums", action: onScan)
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!snapshot.scope.canRead || snapshot.scope.accountIdentifier == nil || snapshot.scope.selectedAlbumIDs.isEmpty)
        }
        .backupCard()
    }

    private var coverage: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeading(title: "In your selected albums", subtitle: "Photos and videos that match your backup settings.")
            count("In backup history", snapshot.rememberedCompletions, symbol: "checkmark.circle", color: .green)
            count("Waiting to finish", snapshot.pending, symbol: "arrow.up.circle", color: BackupTheme.blue)
            count("Needs attention", snapshot.failed, symbol: "exclamationmark.circle", color: .orange)
            count("Waiting for iCloud", snapshot.deferred, symbol: "icloud.and.arrow.down", color: .secondary)
            count("Needs another scan", snapshot.unknown ?? 0, symbol: "arrow.triangle.2.circlepath", color: .secondary)
            if snapshot.incompleteComponents > 0 {
                Divider()
                Text("\(snapshot.incompleteComponents.formatted()) items still need an additional file, such as Live Photo motion or an original version.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .backupCard()
    }

    private var scope: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeading(title: "What’s included")
            Label("\(snapshot.scope.selectedAlbumIDs.count) selected albums", systemImage: "rectangle.stack")
                .font(.subheadline.weight(.medium))
            Text(snapshot.scope.rules.summary).font(.subheadline).foregroundStyle(.secondary)
            if snapshot.scope.isLimited {
                Label("Limited photo access", systemImage: "exclamationmark.triangle")
                    .font(.subheadline.weight(.medium)).foregroundStyle(.orange)
                Text("Only the photos and videos you’ve allowed are included. This does not cover your entire library.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            DisclosureGroup("Included versions") {
                VStack(alignment: .leading, spacing: 10) {
                    Text(snapshot.scope.includeLivePhotoMotion ? "Live Photos include their motion clips." : "Live Photos include the still image only.")
                    Text(snapshot.scope.includeOriginals ? "Edited photos and videos also include their original versions." : "Photos and videos use their current appearance.")
                    if let excluded = snapshot.excludedCount {
                        Text("\(excluded.formatted()) items excluded by your backup rules.")
                    }
                }
                .font(.footnote).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 10)
            }
            .font(.subheadline)
        }
        .backupCard()
    }

    private var confirmationDetails: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeading(title: "Last checked")
            date("Album scan", snapshot.lastSuccessfulScan)
            DisclosureGroup("Confirmation details") {
                VStack(alignment: .leading, spacing: 16) {
                    date("All required files confirmed since", snapshot.verifiedThrough)
                    date("Most recent file confirmed", snapshot.mostRecentRemoteConfirmation)
                    Text("A confirmation means Google acknowledged an upload or found an existing copy at that time. It is not a continuous check. Older backup records may not have a confirmation date.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("Changes to your account, albums, rules, media settings, or photo access need a new scan. An empty activity list alone does not mean every item is backed up.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 12)
            }
            .font(.subheadline)
        }
        .backupCard()
    }

    private var statusTitle: String {
        if snapshot.includedCount == nil { return "Scan needed" }
        if snapshot.failed > 0 || (snapshot.unknown ?? 0) > 0 { return "Needs attention" }
        if snapshot.pending > 0 || snapshot.deferred > 0 { return "In progress" }
        return "Scan complete"
    }

    private var statusSymbol: String {
        if snapshot.includedCount == nil { return "magnifyingglass" }
        if snapshot.failed > 0 || (snapshot.unknown ?? 0) > 0 { return "exclamationmark.circle" }
        if snapshot.pending > 0 || snapshot.deferred > 0 { return "clock" }
        return "checkmark"
    }

    private var statusColor: Color {
        snapshot.failed > 0 || (snapshot.unknown ?? 0) > 0 ? .orange : BackupTheme.blue
    }

    private var nextAction: String {
        if snapshot.scope.accountIdentifier == nil { return "Connect your Google account to check your backup." }
        if !snapshot.scope.canRead { return "Allow photo access to check your selected albums." }
        if snapshot.scope.selectedAlbumIDs.isEmpty { return "Choose the albums you want to back up." }
        if snapshot.includedCount == nil { return "Scan your selected albums to see what still needs backing up." }
        if snapshot.failed > 0 { return "Open Activity to review items that couldn’t be backed up and try them again." }
        if snapshot.deferred > 0 { return "Keep the app open on an allowed connection while waiting items download from iCloud." }
        if snapshot.pending > 0 { return "Your backup still has items to finish. Check Activity for progress." }
        if (snapshot.unknown ?? 0) > 0 { return "Scan again to find missing files and check items that weren’t available." }
        if snapshot.includedCount == 0 { return "No accessible photos or videos match these albums and backup rules." }
        return "These items are recorded as backed up. In Settings, use Check backed-up photos to confirm them with Google again."
    }

    private func count(_ title: String, _ value: Int, symbol: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color).frame(width: 22)
            Text(title)
            Spacer()
            Text(value.formatted()).fontWeight(.semibold).monospacedDigit()
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }

    private func date(_ title: String, _ value: Date?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline)
            if let value {
                Text(value.formatted(date: .abbreviated, time: .shortened))
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                Text("Not yet recorded").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}
