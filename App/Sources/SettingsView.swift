import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var account: PhotosAccount
    @EnvironmentObject private var queue: UploadQueue
    @EnvironmentObject private var preferences: BackupPreferences
    @EnvironmentObject private var automaticBackup: AutomaticBackupCoordinator

    let showTutorial: () -> Void
    @State private var confirmDisconnect = false
    @State private var connectionCheckResult: PhotosAccount.VerificationOutcome?
    @State private var verifyMessage: String?
    @State private var isVerifying = false
    private let gpmcURL = URL(string: "https://github.com/xob0t/gpmc")!

    var body: some View {
        NavigationView {
            Form {
                accountSection
                backupSection
                deviceSection
                BackupNotificationSettingsView()
                toolsSection
                aboutSection
            }
            .backupListBackground()
            .navigationTitle("Settings")
            .tint(BackupTheme.blue)
            .confirmationDialog("Disconnect Google Photos?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
                Button("Disconnect", role: .destructive) { Task { await account.disconnect() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("New backups will stop until you connect again. Photos already backed up are not affected.")
            }
        }
        .navigationViewStyle(.stack)
    }

    private var accountSection: some View {
        Section("Google Photos") {
            HStack(alignment: .top, spacing: 12) {
                FeatureIcon(symbol: "person.crop.circle.fill", size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(accountTitle)
                        .font(.headline)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(accountSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(account.status.isUsable ? Color.green : Color.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .layoutPriority(1)
                Spacer()
                Image(systemName: account.status.isUsable ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(account.status.isUsable ? Color.green : Color.orange)
                    .accessibilityLabel(account.status.isUsable ? "Connected" : "Action needed")
            }
            .padding(.vertical, 4)

            if account.status.isUsable {
                Button {
                    connectionCheckResult = nil
                    Task {
                        let result = await account.verify()
                        withAnimation(.easeInOut(duration: 0.2)) {
                            connectionCheckResult = result
                        }
                    }
                } label: {
                    HStack {
                        Text(account.verifying ? "Checking connection…" : "Check connection")
                        Spacer()
                        if account.verifying {
                            ProgressView()
                        } else if connectionCheckResult == .succeeded {
                            Label("Verified", systemImage: "checkmark.circle.fill")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.green)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                }
                    .disabled(account.verifying)
                Button("Disconnect account", role: .destructive) { confirmDisconnect = true }
            } else {
                Button("Connect account") { showTutorial() }
            }

            if case .failed(let reason) = connectionCheckResult, account.status.isUsable {
                Label(reason, systemImage: "exclamationmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if account.status.isUsable, let warning = account.persistenceWarning {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Account saved for this session only", systemImage: "key.slash")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.orange)
                    Text(warning + " The account works for this session but may need to be connected again after relaunch.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }
        }
        .onChange(of: account.status) { status in
            if !status.isUsable { connectionCheckResult = nil }
        }
    }

    private var backupSection: some View {
        Section {
            Toggle("Automatic backup", isOn: $preferences.automaticBackup)
            Picker("Connection", selection: $preferences.connection) {
                ForEach(BackupConnection.allCases) { option in Text(option.title).tag(option) }
            }
            if let reason = queue.networkPauseReason {
                Label(reason, systemImage: "wifi.exclamationmark")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            NavigationLink {
                mediaSettings
            } label: {
                settingsLabel("Photos & videos", symbol: "photo.on.rectangle.angled", detail: "Live Photos and edited originals")
            }
            NavigationLink {
                uploadSettings
            } label: {
                settingsLabel("Upload preferences", symbol: "arrow.up.circle", detail: "Quality, storage and upload speed")
            }
        } header: {
            Text("Backup")
        } footer: {
            Text("Automatically checks your selected albums for new photos. iOS decides when background backups can run.")
        }
    }

    private var mediaSettings: some View {
        Form {
            Section {
                Toggle("Include Live Photo motion", isOn: $preferences.backUpLivePhotoMotion)
            } header: {
                Text("Live Photos")
            } footer: {
                Text("Keeps the short video with each Live Photo so it plays in Google Photos. Adds a few MB per photo, including photos already backed up.")
            }
            Section {
                Toggle("Include unedited originals", isOn: $preferences.backUpOriginals)
            } header: {
                Text("Edited photos & videos")
            } footer: {
                Text("Saves the original as well as your edited version, including items already backed up. This may use more storage, and the versions may appear as separate files.")
            }
            Section {
                DisclosureGroup("More about these options") {
                    Text("Live Photo motion uses storage in the same way as its photo. Once backed up, Google Photos can include the Live Photo when you use Free up space on this iPhone.")
                    Text("Including originals preserves a separate copy. It does not provide reversible edit history in Google Photos.")
                }
                .font(.subheadline)
            }
        }
        .backupListBackground()
        .navigationTitle("Photos & videos")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var uploadSettings: some View {
        Form {
            Section {
                Toggle("Storage Saver", isOn: $preferences.storageSaver)
            } header: {
                Text("Photo quality")
            } footer: {
                Text("Asks Google Photos to reduce file sizes. Leave off to send the original files.")
            }
            Section {
                Toggle("Use Google storage quota", isOn: $preferences.useQuota)
                DisclosureGroup("How storage and quality work") {
                    Text("With this option off, uploads identify as an older Pixel phone so they do not count against Google storage. This relies on an unofficial Google Photos connection.")
                    Text("Google Photos may label these uploads “Storage saver” even when the original file was kept. Check the file size, or Google Photos on the web, for the actual quality.")
                }
                .font(.subheadline)
            } header: {
                Text("Google storage")
            } footer: {
                Text("When off, uploads use the older Pixel storage behavior. Google may change how this works.")
            }
            Section {
                Picker("Uploads at once", selection: $preferences.concurrentUploads) {
                    ForEach(Array(UploadQueue.concurrencyRange), id: \.self) { count in
                        Text(count == 2 ? "2 · Recommended" : count.formatted()).tag(count)
                    }
                }
                DisclosureGroup("About upload speed") {
                    Text("More uploads can finish large backups sooner, but each needs a full-size temporary copy on your iPhone. Higher values use more storage, battery and data at once. Lowering the setting lets uploads already running finish first.")
                }
                .font(.subheadline)
            } header: {
                Text("Upload speed")
            } footer: {
                Text("Two uploads at once is a good balance for most iPhones.")
            }
        }
        .backupListBackground()
        .navigationTitle("Upload preferences")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var deviceSection: some View {
        Section("Device") {
            NavigationLink {
                UnattendedBackupSettingsView(settings: $preferences.admissionSettings)
            } label: {
                settingsLabel("Battery & device care", symbol: "battery.100", detail: "Choose when backups should wait")
            }
            NavigationLink {
                Form {
                    Section {
                        Toggle("Allow Auto-Lock when finished", isOn: $preferences.restoreAutoLockAfterBackup)
                    } header: {
                        Text("Dark screen")
                    } footer: {
                        Text("Allows normal Auto-Lock after a fully scanned backup finishes, even if some items fail. This does not lock the iPhone immediately. Paused or incomplete backups keep the screen awake.")
                    }
                }
                .backupListBackground()
                .navigationTitle("Screen behavior")
                .navigationBarTitleDisplayMode(.inline)
            } label: {
                settingsLabel("Screen behavior", symbol: "moon", detail: "Auto-Lock after a backup")
            }
        }
    }

    private var toolsSection: some View {
        Section("Tools & help") {
            NavigationLink {
                Form { automationSection }
                    .backupListBackground()
                    .navigationTitle("Shortcuts")
                    .navigationBarTitleDisplayMode(.inline)
            } label: {
                settingsLabel("Shortcuts", symbol: "square.stack.3d.up", detail: "Back up with a personal automation")
            }
            NavigationLink {
                BackupSessionHistoryView()
            } label: {
                settingsLabel("Backup history", symbol: "clock.arrow.circlepath")
            }
            NavigationLink {
                StorageUsageView()
            } label: {
                settingsLabel("iPhone storage", symbol: "internaldrive")
            }
            NavigationLink {
                Form {
                    verifySection
                    supportSection
                }
                .backupListBackground()
                .navigationTitle("Help & troubleshooting")
                .navigationBarTitleDisplayMode(.inline)
            } label: {
                settingsLabel("Help & troubleshooting", symbol: "questionmark.circle")
            }
        }
    }

    private var verifySection: some View {
        Section {
            Button {
                runVerification()
            } label: {
                HStack {
                    Label(isVerifying ? "Checking backups…" : "Check backed-up photos", systemImage: "checkmark.icloud")
                    Spacer()
                    if isVerifying { ProgressView() }
                }
            }
            .disabled(!canVerify)
            if let verifyMessage {
                Text(verifyMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Check your backup")
        } footer: {
            Text("Checks your selected albums against Google Photos. Photos deleted from Google Photos are added to the backup again.")
        }
    }

    private var automationSection: some View {
        Section {
            ShortcutsSettingsRows()
            DisclosureGroup("Set up an automation") {
                Text("In Shortcuts, create a personal automation for a time of day, connecting to power, or joining your home Wi-Fi. Set it to run immediately and add the Back Up Photos action.")
                    .font(.subheadline)
            }
            DisclosureGroup("What to expect") {
                Text("Each run has about 30 seconds to find new photos in your selected albums and hand them to iOS for upload. It works even when Automatic backup is off, and respects your connection setting and Pause.")
                Text("Photos stored only in iCloud wait until the app is open. iOS controls when uploads can continue in the background.")
            }
            .font(.subheadline)
        } footer: {
            Text("Use a routine that suits you, such as connecting your iPhone to its charger.")
        }
    }

    private func settingsLabel(_ title: String, symbol: String, detail: String? = nil) -> some View {
        HStack(spacing: 12) {
            FeatureIcon(symbol: symbol, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).foregroundStyle(.primary)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 3)
        }
    }

    private var canVerify: Bool {
        account.status.isUsable && !isVerifying && !preferences.selectedAlbumIDs.isEmpty
    }

    private func runVerification() {
        guard canVerify else { return }
        isVerifying = true
        verifyMessage = nil
        Task {
            let outcome = await automaticBackup.reverifySelectedAlbums()
            isVerifying = false
            verifyMessage = DashboardView.message(for: outcome)
        }
    }

    private var supportSection: some View {
        Section("Support") {
            NavigationLink("Create a support report") { DiagnosticReportView() }
            NavigationLink("Technical details") { DiagnosticsView() }
            Button("Review setup") {
                preferences.resetOnboarding()
            }
        }
    }

    private var aboutSection: some View {
        Section("About") {
            LabeledRow("App", value: "Photos Backup")
            LabeledRow("Version", value: appVersion)
            LabeledRow("iOS", value: UIDevice.current.systemVersion)
            LabeledRow("Open-source credits") {
                Link("GPMC by xob0t", destination: gpmcURL)
            }
        }
    }

    private var accountTitle: String {
        switch account.status {
        case .loading: return "Checking account…"
        case .disconnected: return "Not connected"
        case .connected(let email, _): return email
        case .rejected(let email, _): return email.isEmpty ? "Sign in again" : email
        }
    }

    private var accountSubtitle: String {
        switch account.status {
        case .loading: return "Looking for your saved account"
        case .disconnected: return "Connect to start backing up"
        case .connected(_, let since): return "Connected · \(since.formatted(date: .abbreviated, time: .omitted))"
        case .rejected(_, let reason): return reason
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(version) (\(build))"
    }
}

/// The Shortcuts rows: a way into the Shortcuts app, and the last run, so an
/// automation can be checked without waiting for a problem.
private struct ShortcutsSettingsRows: View {
    @State private var lastRun: AutomaticBackupRunRecord?

    var body: some View {
        Group {
            if #available(iOS 16.0, *) {
                Label("Back Up Photos", systemImage: "square.stack.3d.up.fill")
                Link("Open Shortcuts", destination: URL(string: "shortcuts://")!)
                if let lastRun {
                    AutomaticRunRow(run: lastRun)
                } else {
                    Text("No automation runs yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Label("Requires iOS 16 or later", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { lastRun = AutomaticBackupRunHistory.latest(.shortcut) }
    }
}

/// Presents the in-app Google account connection flow (see AccountConnectView)
/// and runs the token exchange on capture. Shown as a sheet from the dashboard
/// and Settings.
struct ConnectionTutorialView: View {
    @EnvironmentObject private var probe: AccountConnector
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        AccountConnectView(
            onCaptured: { token in
                dismiss()
                Task { await probe.ingestWebToken(token) }
            },
            onCancel: { dismiss() }
        )
    }
}
