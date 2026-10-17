import SwiftUI

struct BackupRulesView: View {
    @EnvironmentObject private var preferences: BackupPreferences
    @EnvironmentObject private var albums: PhotoAlbumStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var draft = BackupSelectionRules()
    @State private var preview: BackupRulesPreview?
    @State private var isPreviewing = false

    private var previewScope: BackupScopeDescriptor {
        BackupScopeDescriptor(accountIdentifier: nil, selectedAlbumIDs: preferences.selectedAlbumIDs,
                              rules: draft, authorization: albums.authorization.rawValue)
    }

    private var timeZoneName: String {
        draft.calendar.timeZone.localizedName(for: .generic, locale: .current) ?? draft.timeZoneIdentifier
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Fine-tune what’s included from your selected albums.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                mediaPreferences
                datePreferences
                previewCard
                detailsCard
            }
            .padding(20)
        }
        .background(BackupTheme.background)
        .navigationTitle("What to Back Up")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                Button("Save Preferences") {
                    preferences.selectionRules = draft
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!draft.isValid || preview == nil || isPreviewing)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .background(BackupTheme.background)
        }
        .onAppear { draft = preferences.selectionRules }
        .task(id: previewScope.fingerprint) {
            preview = nil
            guard draft.isValid else { isPreviewing = false; return }
            isPreviewing = true
            let result = await BackupScopeReader.preview(scope: previewScope)
            guard !Task.isCancelled else { return }
            preview = result
            isPreviewing = false
        }
    }

    private var mediaPreferences: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(title: "Photos & videos")
            VStack(spacing: 16) {
                if dynamicTypeSize > .large {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Include")
                        mediaPicker
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    HStack(spacing: 8) {
                        Text("Include").fixedSize()
                        Spacer(minLength: 0)
                        mediaPicker
                            .fixedSize()
                            .layoutPriority(1)
                    }
                }
                Divider()
                Toggle("Skip screenshots", isOn: $draft.excludeScreenshots)
                Divider()
                Toggle("Skip screen recordings", isOn: $draft.excludeScreenRecordings)
            }
            .font(.subheadline)
            .tint(BackupTheme.blue)
            .backupCard()
        }
    }

    private var mediaPicker: some View {
        Picker("Include", selection: $draft.media) {
            ForEach(BackupSelectionRules.Media.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.menu)
        .labelsHidden()
    }

    private var datePreferences: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(title: "Date range", subtitle: "Include all dates, or choose when photos were taken.")
            VStack(alignment: .leading, spacing: 16) {
                Toggle("Set a start date", isOn: Binding(get: { draft.startDate != nil }, set: {
                    if $0 { draft.setFirstDay(Date()) } else { draft.startDate = nil }
                }))
                if draft.startDate != nil {
                    DatePicker("From", selection: Binding(get: { draft.startDate ?? Date() }, set: { draft.setFirstDay($0) }), displayedComponents: .date)
                }
                Divider()
                Toggle("Set an end date", isOn: Binding(get: { draft.endDateExclusive != nil }, set: {
                    if $0 { draft.setLastDay(Date()) } else { draft.endDateExclusive = nil }
                }))
                if let end = draft.endDateExclusive {
                    DatePicker("Through", selection: Binding(get: { end.addingTimeInterval(-1) }, set: { draft.setLastDay($0) }), displayedComponents: .date)
                }
                if !draft.isValid {
                    Label("Choose an end date on or after the start date.", systemImage: "exclamationmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                } else if draft.startDate != nil || draft.endDateExclusive != nil {
                    Text("The start and end days are both included.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.subheadline)
            .tint(BackupTheme.blue)
            .environment(\.timeZone, draft.calendar.timeZone)
            .backupCard()
        }
    }

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(title: "Preview", subtitle: "Based on your selected albums.")
            VStack(alignment: .leading, spacing: 16) {
                if preferences.selectedAlbumIDs.isEmpty {
                    Label("Choose albums to see what will be included.", systemImage: "rectangle.stack")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else if !draft.isValid {
                    Text("Update the date range to see your preview.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else if isPreviewing {
                    ProgressView("Checking your albums…")
                        .font(.subheadline)
                } else if let preview {
                    HStack(alignment: .top, spacing: 24) {
                        previewCount(preview.included, title: "Included", symbol: "checkmark.circle", color: BackupTheme.blue)
                        Divider()
                        previewCount(preview.excluded, title: "Skipped", symbol: "minus.circle", color: .secondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    if preview.missingMetadata > 0 {
                        Text("\(preview.missingMetadata.formatted()) items couldn’t be fully checked because their details are missing or unsupported.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                if albums.isLimited {
                    Label("This preview includes only the photos you’ve allowed access to.", systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .backupCard()
        }
    }

    private func previewCount(_ count: Int, title: String, symbol: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(count.formatted())
                .font(.title2.weight(.semibold))
                .monospacedDigit()
            Label(title, systemImage: symbol)
                .font(.caption.weight(.medium))
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var detailsCard: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 14) {
                Text("Changes apply the next time your selected albums are checked. Photos already waiting to upload stay in Activity, where you can stop them.")
                Text("Photos you add manually are always included. Your existing backups and backup history are kept.")
                Text("Screenshots and screen recordings are identified by Photos. Imported recordings may still be included if Photos doesn’t recognize them.")
                Text("Dates use \(timeZoneName), even when you travel. Photos without a capture date are skipped when a date range is set.")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 12)
        } label: {
            Label("How these preferences work", systemImage: "info.circle")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
        }
        .tint(BackupTheme.blue)
        .backupCard(padding: 16)
    }
}
