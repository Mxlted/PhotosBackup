import Combine
import SwiftUI

struct UploadsView: View {
    @EnvironmentObject private var account: PhotosAccount
    @EnvironmentObject private var queue: UploadQueue
    @EnvironmentObject private var preferences: BackupPreferences
    @EnvironmentObject private var automaticBackup: AutomaticBackupCoordinator
    let onBlackScreen: () -> Void
    @State private var showPicker = false
    @State private var showingStopBackupConfirmation = false
    @State private var inspectedFailure: FailureDetail?
    @State private var filter: ActivityFilter = .all
    @State private var search = ""
    @State private var selectingFailures = false
    @State private var selectedFailures: Set<UUID> = []
    @StateObject private var browser = ActivityBrowser()

    /// A failed row's full text, snapshotted when it is tapped. The row itself
    /// can be retried or cleared while the sheet is open.
    private struct FailureDetail: Identifiable {
        let id: UUID
        let name: String
        let reason: String
    }

    var body: some View {
        NavigationView {
            List {
                if !queue.items.isEmpty { overviewSection }
                manualBackupSection
                if let reason = queue.pauseReason { pausedSection(reason) }
                else if let reason = queue.admissionStatusReason {
                    Section {
                        Label("Waiting to continue", systemImage: "clock")
                            .font(.subheadline.weight(.semibold))
                        Text(reason).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let warning = queue.persistenceWarning { persistenceWarningSection(warning) }
                if queue.items.isEmpty { emptySection }
                else {
                    browsingSection
                    activitySection
                }
                Section {
                    BlackScreenBackupControls(onStart: onBlackScreen)
                        .padding(.vertical, 4)
                }
                if !queue.items.isEmpty { activityHelpSection }
            }
            .listStyle(.insetGrouped)
            .backupListBackground()
            .navigationTitle("Activity")
            .searchable(text: $search, prompt: "Search photos and videos")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !queue.items.isEmpty {
                        Menu { queueManagementActions } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityLabel("Backup actions")
                    }
                }
            }
            .sheet(isPresented: $showPicker) {
                PhotoPicker { sources in enqueue(sources) }.ignoresSafeArea()
            }
            .sheet(item: $inspectedFailure) { failure in failureSheet(failure) }
            .confirmationDialog(
                "Stop all backups?",
                isPresented: $showingStopBackupConfirmation,
                titleVisibility: .visible
            ) {
                Button("Stop Backup", role: .destructive) { stopBackup() }
                Button("Keep Backing Up", role: .cancel) {}
            } message: {
                Text(stopBackupMessage)
            }
        }
        .navigationViewStyle(.stack)
        .onReceive(queue.$items.throttle(for: .milliseconds(300), scheduler: RunLoop.main, latest: true)) { items in
            browser.refresh(items, filter: filter, search: search)
        }
        .onChange(of: filter) { _ in refreshBrowser() }
        .onChange(of: search) { _ in refreshBrowser() }
        .onChange(of: browser.failedIDs) { selectedFailures.formIntersection($0) }
        .onDisappear { browser.stop() }
    }

    /// Photos picked by hand are checked against Google even when the app
    /// remembers them as backed up: picking one is how someone asks "is this
    /// really backed up?", and the hash lookup settles it without re-uploading
    /// anything Google already has.
    private func enqueue(_ sources: [MediaSource]) {
        guard !sources.isEmpty else { return }
        Task { await automaticBackup.enqueueManualSelection(sources) }
    }

    private var overviewSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    FeatureIcon(symbol: queue.isIdle ? "tray" : "arrow.up.circle", size: 44)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(activityTitle).font(.title3.weight(.semibold))
                        Text(activitySubtitle).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                if !queue.isIdle {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: queue.overallFraction).tint(BackupTheme.blue)
                        Text("\(queue.overallFraction.formatted(.percent.precision(.fractionLength(0)))) of current backup")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                HStack(spacing: 0) {
                    activityMetric("Remaining", value: queue.activeCount, color: BackupTheme.blue)
                    Spacer(minLength: 12)
                    activityMetric("Backed up", value: browser.counts[.completed, default: 0], color: .primary)
                    Spacer(minLength: 12)
                    activityMetric("Attention", value: queue.failedCount, color: queue.failedCount > 0 ? .orange : .secondary)
                }
            }
            .backupCard()
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }
    }

    private var activityTitle: String {
        if queue.pauseReason != nil { return "Backup is paused" }
        if queue.activeCount > 0 { return "Your backup is in progress" }
        if queue.failedCount > 0 { return "A few items need attention" }
        return "No uploads waiting"
    }

    private var activitySubtitle: String {
        if queue.pauseReason != nil { return "Your progress is here when you’re ready." }
        if queue.activeCount > 0 { return "Follow your photos and videos below." }
        if queue.failedCount > 0 { return "Open an item below to see what happened." }
        return "Review your recent activity below."
    }

    private func activityMetric(_ title: String, value: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value.formatted()).font(.title2.weight(.semibold)).monospacedDigit().foregroundStyle(color)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var manualBackupSection: some View {
        Section {
            Button { showPicker = true } label: {
                HStack(spacing: 12) {
                    FeatureIcon(symbol: "photo.badge.plus", size: 42)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Add photos or videos").font(.headline).foregroundStyle(.primary)
                        Text("Choose up to 50 items to back up").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "plus.circle.fill")
                        .font(.title3).foregroundStyle(BackupTheme.blue)
                }
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .disabled(!account.status.isUsable)
        } footer: {
            if !account.status.isUsable { Text("Connect a Google Photos account before starting a backup.") }
        }
    }

    private func pausedSection(_ reason: String) -> some View {
        Section {
            Label("Backup Paused", systemImage: "pause.circle.fill").foregroundStyle(.orange)
            Text(reason).font(.footnote).foregroundStyle(.secondary)
            if queue.haltReason != nil {
                Button("Resume Backup") { queue.resume() }.disabled(!account.status.isUsable)
            } else if queue.isUserPaused {
                Button("Resume Backup") { queue.resumeUserPausedUploads() }
                    .disabled(!account.status.isUsable)
            }
        }
    }

    @ViewBuilder
    private var queueManagementActions: some View {
        Group {
            if queue.activeCount > 0 || queue.isUserPaused {
                if queue.isUserPaused {
                    Button {
                        queue.resumeUserPausedUploads()
                    } label: {
                        Label("Resume Backup", systemImage: "play.circle")
                    }
                    .disabled(!account.status.isUsable)
                } else if queue.pauseReason == nil {
                    Button {
                        queue.pauseAfterCurrentUploads()
                    } label: {
                        Label("Pause After Current Uploads", systemImage: "pause.circle")
                    }
                }

                if queue.activeCount > 0 {
                    Button(role: .destructive) {
                        showingStopBackupConfirmation = true
                    } label: {
                        Label("Stop Backup", systemImage: "stop.circle")
                    }
                }
            }

            if queue.failedCount > 0 {
                Button {
                    queue.retryAllFailed()
                } label: {
                    Label("Retry Items Needing Attention", systemImage: "arrow.clockwise.circle")
                }
            }

            if queue.hasFinishedItems {
                Button {
                    queue.clearFinished()
                } label: {
                    Label("Clear Finished Activity", systemImage: "checkmark.circle")
                }
            }
        }
    }

    private func persistenceWarningSection(_ warning: String) -> some View {
        Section {
            Label("Progress couldn’t be saved", systemImage: "externaldrive.badge.exclamationmark")
                .font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
            Text(warning).font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var emptySection: some View {
        Section {
            EmptyState(symbol: "tray", title: "No backup activity", message: "Photos you back up manually or from selected albums will appear here.")
                .listRowBackground(Color.clear)
        }
    }

    private var activitySection: some View {
        Section {
            if browser.rows.isEmpty {
                Text("No matching photos or videos.").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(browser.rows) { item in activityRow(item) }
        } header: {
            HStack {
                Text("Recent activity")
                Spacer()
                Text("\(browser.rows.count) of \(browser.overallCount)")
            }
        } footer: {
            if queue.deferredForICloudCount > 0 {
                Text("\(queue.deferredForICloudCount) items need to download from iCloud first. Keep the app open to finish them.")
            }
        }
    }

    private func refreshBrowser() { browser.refresh(queue.items, filter: filter, search: search) }

    private var browsingSection: some View {
        Section {
            Picker("Show", selection: $filter) {
                ForEach(ActivityFilter.allCases) { category in
                    Text("\(filterTitle(category)) (\(browser.counts[category, default: 0]))").tag(category)
                }
            }
            if queue.failedCount > 0 {
                Toggle("Select items needing attention", isOn: $selectingFailures)
                    .onChange(of: selectingFailures) { if !$0 { selectedFailures.removeAll() } }
            }
            if selectingFailures {
                Button("Select All Shown") {
                    selectedFailures = Set(browser.rows.filter { ActivityFilter.failed.includes($0.state) }.map(\.id))
                }
                Button("Retry Selected (\(selectedFailures.count))") {
                    queue.retrySelectedFailed(selectedFailures)
                    selectedFailures.removeAll()
                }
                .disabled(selectedFailures.isEmpty || !account.status.isUsable)
            }
        }
    }

    private var activityHelpSection: some View {
        Section {
            DisclosureGroup("About this activity") {
                Text("Each row is a file. Live Photo motion and original versions can appear separately, so this count may be higher than your number of photos.")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("Filters and search only change this list. Photos you choose manually are included even when they don’t match your automatic backup rules.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .font(.subheadline)
        }
    }

    private func filterTitle(_ filter: ActivityFilter) -> String {
        switch filter {
        case .all: return "All activity"
        case .pending: return "Waiting"
        case .processing: return "In progress"
        case .failed: return "Needs attention"
        case .iCloud: return "Waiting for iCloud"
        case .completed: return "Backed up"
        }
    }

    private var stopBackupMessage: String {
        if preferences.automaticBackup {
            return "Uploads in progress will be cancelled, the queue will be cleared, and Automatic Backup will be turned off. Photos already backed up are not affected."
        }
        return "Uploads in progress will be cancelled and the queue will be cleared. Photos already backed up are not affected."
    }

    private func stopBackup() {
        preferences.automaticBackup = false
        queue.cancelAll()
    }

    private func activityRow(_ item: UploadItem) -> some View {
        HStack(spacing: 12) {
            if selectingFailures && ActivityFilter.failed.includes(item.state) {
                Button {
                    if !selectedFailures.insert(item.id).inserted { selectedFailures.remove(item.id) }
                } label: {
                    Image(systemName: selectedFailures.contains(item.id) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(BackupTheme.blue)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("\(selectedFailures.contains(item.id) ? "Deselect" : "Select") \(item.name)")
                .accessibilityValue(selectedFailures.contains(item.id) ? "Selected" : "Not selected")
            }
            if case .failed(let reason, _) = item.state {
                Button {
                    inspectedFailure = FailureDetail(id: item.id, name: item.name, reason: reason)
                } label: {
                    activityRowContent(item)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityHint("Opens the full error message and retry options")
            } else {
                activityRowContent(item)
                    .accessibilityElement(children: .combine)
            }
        }
        .padding(.vertical, 8)
        .swipeActions {
            if item.state.isFinished {
                if item.state != .done && item.state != .alreadyBackedUp {
                    Button("Retry") { queue.retry(item.id) }.tint(BackupTheme.blue)
                }
            } else {
                Button("Cancel", role: .destructive) { queue.cancel(item.id) }
            }
        }
    }

    private func activityRowContent(_ item: UploadItem) -> some View {
        HStack(spacing: 12) {
            ActivityThumbnail(source: item.source, symbol: symbol(item.state), tint: tint(item.state))
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(item.name).font(.subheadline.weight(.medium)).lineLimit(2).truncationMode(.middle)
                    Spacer()
                    if item.byteCount > 0 {
                        Text(item.byteCount.formatted(.byteCount(style: .file)))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if case .failed = item.state {
                    Label("Needs attention · View details", systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.orange)
                } else {
                    Text(item.state.label).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                if let fraction = item.state.fraction, item.state.isWorking {
                    ProgressView(value: fraction).tint(BackupTheme.blue)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The whole reason, selectable and copyable. A support report is only as
    /// good as the text the reporter can actually get out of the app.
    private func failureSheet(_ failure: FailureDetail) -> some View {
        NavigationView {
            List {
                Section("Item") { Text(failure.name).font(.subheadline) }
                Section("What happened") {
                    Text(failure.reason)
                        .font(.footnote)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Section {
                    Button {
                        UIPasteboard.general.string = "\(failure.name)\n\(failure.reason)"
                    } label: {
                        Label("Copy Details", systemImage: "doc.on.doc")
                    }
                    Button {
                        queue.retry(failure.id)
                        inspectedFailure = nil
                    } label: {
                        Label("Retry This Item", systemImage: "arrow.clockwise")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .backupListBackground()
            .navigationTitle("Upload Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { inspectedFailure = nil }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func symbol(_ state: UploadItem.State) -> String {
        switch state {
        case .done, .alreadyBackedUp: return "checkmark"
        case .failed: return "exclamationmark"
        case .cancelled: return "xmark"
        case .queued, .waitingToRetry, .waitingForICloud: return "clock"
        default: return "arrow.up"
        }
    }

    private func tint(_ state: UploadItem.State) -> Color {
        switch state {
        case .done, .alreadyBackedUp: return .green
        case .failed: return .red
        case .cancelled, .waitingToRetry, .waitingForICloud: return .orange
        default: return BackupTheme.blue
        }
    }
}
