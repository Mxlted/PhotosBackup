import SwiftUI

struct BackupHealthView: View {
    let snapshot: BackupHealthSnapshot
    var onScan: () -> Void

    var body: some View {
        Form {
            Section("Selected Backup Scope") {
                Text("\(snapshot.scope.selectedAlbumIDs.count) selected albums")
                Text(snapshot.scope.rules.summary).font(.subheadline).foregroundStyle(.secondary)
                Text(snapshot.scope.includeLivePhotoMotion ? "Live Photo motion required" : "Live Photo still images")
                Text(snapshot.scope.includeOriginals ? "Edited assets also require original versions" : "Current appearance only")
                if snapshot.scope.isLimited {
                    Label("Limited Photos access", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text("Coverage includes only the accessible photos and videos you allowed. It does not cover your entire library.").font(.footnote)
                }
            }
            Section("Coverage") {
                if let included = snapshot.includedCount {
                    count("Matching accessible assets", included)
                    count("Remembered complete", snapshot.rememberedCompletions)
                    count("Pending", snapshot.pending)
                    count("Failed", snapshot.failed)
                    count("Waiting for iCloud", snapshot.deferred)
                    count("Unknown or missing work", snapshot.unknown ?? 0)
                    count("Excluded by rules", snapshot.excludedCount ?? 0)
                    if snapshot.incompleteComponents > 0 {
                        Text("\(snapshot.incompleteComponents) assets have a remembered current image or video but still need required components, such as Live Photo motion, an original, or a Google Photos edit base.")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                } else {
                    Text("Coverage unknown — scan required")
                    Text("An empty queue does not establish coverage. Account, album, rules, media settings or Photos-access changes require a matching scan.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("Freshness") {
                date("Last successful scope scan", snapshot.lastSuccessfulScan)
                date("Every required component confirmed since", snapshot.verifiedThrough)
                date("Most recent component confirmation", snapshot.mostRecentRemoteConfirmation)
                Text("Remembered completion is local history. Confirmation means Google acknowledged an upload or duplicate lookup at that time; it is not a continuous check. Older records have no verification timestamp.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Next Action") {
                Text(snapshot.nextAction)
                Button("Scan Selected Albums", action: onScan)
                    .disabled(!snapshot.scope.canRead || snapshot.scope.accountIdentifier == nil || snapshot.scope.selectedAlbumIDs.isEmpty)
            }
        }
        .navigationTitle("Backup Health")
    }

    private func count(_ title: String, _ value: Int) -> some View {
        HStack { Text(title); Spacer(); Text(value.formatted()).foregroundStyle(.secondary) }
            .accessibilityElement(children: .combine)
    }

    private func date(_ title: String, _ value: Date?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            if let value { Text(value.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
            else { Text("Not known").font(.caption).foregroundStyle(.secondary) }
        }
    }
}
