import SwiftUI

struct BackupRulesView: View {
    @EnvironmentObject private var preferences: BackupPreferences
    @EnvironmentObject private var albums: PhotoAlbumStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft = BackupSelectionRules()
    @State private var preview: BackupRulesPreview?
    @State private var isPreviewing = false

    private var previewScope: BackupScopeDescriptor {
        BackupScopeDescriptor(accountIdentifier: nil, selectedAlbumIDs: preferences.selectedAlbumIDs,
                              rules: draft, authorization: albums.authorization.rawValue)
    }

    var body: some View {
        Form {
            Section {
                Picker("Include", selection: $draft.media) {
                    ForEach(BackupSelectionRules.Media.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Exclude Screenshots", isOn: $draft.excludeScreenshots)
                Toggle("Exclude Screen Recordings", isOn: $draft.excludeScreenRecordings)
            } footer: {
                Text("Uses Photos' media types. Imported recordings without that subtype remain included; filenames are never used to guess.")
            }
            Section {
                Toggle("First Capture Day", isOn: Binding(get: { draft.startDate != nil }, set: {
                    if $0 { draft.setFirstDay(Date()) } else { draft.startDate = nil }
                }))
                if draft.startDate != nil {
                    DatePicker("From", selection: Binding(get: { draft.startDate ?? Date() }, set: { draft.setFirstDay($0) }), displayedComponents: .date)
                }
                Toggle("Last Capture Day", isOn: Binding(get: { draft.endDateExclusive != nil }, set: {
                    if $0 { draft.setLastDay(Date()) } else { draft.endDateExclusive = nil }
                }))
                if let end = draft.endDateExclusive {
                    DatePicker("Through", selection: Binding(get: { end.addingTimeInterval(-1) }, set: { draft.setLastDay($0) }), displayedComponents: .date)
                }
                if !draft.isValid { Text("The last day must be on or after the first day.").foregroundStyle(.red) }
            } footer: {
                Text("Both chosen days are included, using \(draft.timeZoneIdentifier). This timezone stays fixed after travel. Items without a capture date are excluded when a date boundary is set.")
            }
            .environment(\.timeZone, draft.calendar.timeZone)
            Section("Preview of Selected Albums") {
                if isPreviewing { ProgressView("Counting accessible items…") }
                else if let preview {
                    Label("\(preview.included) included", systemImage: "checkmark.circle")
                    Label("\(preview.excluded) excluded", systemImage: "line.3.horizontal.decrease.circle")
                    if preview.missingMetadata > 0 {
                        Text("\(preview.missingMetadata) items have unavailable or unsupported metadata.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if albums.isLimited { Text("Limited Photos access: this preview covers only the items you allowed.").foregroundStyle(.orange) }
                if preferences.selectedAlbumIDs.isEmpty { Text("Select albums to preview their contents.").foregroundStyle(.secondary) }
            }
            Section {
                Button("Apply Rules") {
                    preferences.selectionRules = draft
                    dismiss()
                }
                .disabled(!draft.isValid || preview == nil || isPreviewing)
            } footer: {
                Text("Rules apply to future selected-album discovery. Work already queued is retained; stop it in Activity if needed. Explicit photo-picker selections bypass rules. Changes require a new scope scan; successful backup history and media are kept.")
            }
        }
        .navigationTitle("Backup Rules")
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
}
