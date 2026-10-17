import SwiftUI

/// Queue history cannot prove that the current album selection was scanned.
struct DashboardBackupStatus {
    let title: String
    let detail: String

    init(accountUsable: Bool, pauseReason: String?, remaining: Int, failed: Int,
         completed: Int, hasSelectedAlbums: Bool) {
        if !accountUsable {
            title = "Connect to back up"
            detail = "Keep a copy of your photos and videos in Google Photos."
        } else if let pauseReason {
            title = "Backup paused"
            detail = pauseReason
        } else if remaining > 0 {
            title = "Backing up…"
            detail = "\(remaining) items remaining"
        } else if failed > 0 {
            title = "Backup needs attention"
            detail = "\(failed) items failed — open Activity to retry"
        } else {
            title = completed > 0 ? "No uploads waiting" : "Ready to back up"
            detail = hasSelectedAlbums
                ? "No pending uploads. Use Back Up Now to check your selected albums."
                : "Choose albums to protect"
        }
    }
}

struct DashboardView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var account: PhotosAccount
    @EnvironmentObject private var queue: UploadQueue
    @EnvironmentObject private var preferences: BackupPreferences
    @EnvironmentObject private var albums: PhotoAlbumStore
    @EnvironmentObject private var automaticBackup: AutomaticBackupCoordinator

    let onConnect: () -> Void
    let onAccount: () -> Void
    let onBlackScreen: () -> Void
    let onAlbums: () -> Void
    let onActivity: () -> Void
    @State private var showPicker = false
    @State private var showingStopBackupConfirmation = false
    @State private var manualRunMessage: String?
    @State private var isStartingManualRun = false

    private var selectedAlbums: [PhotoAlbum] {
        albums.albums.filter { preferences.selectedAlbumIDs.contains($0.id) }
    }

    var body: some View {
        NavigationView {
            ScrollView {
                LazyVStack(spacing: 20) {
                    accountBanner
                    backupHero
                    if let manualRunMessage {
                        Label(manualRunMessage, systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                    }
                    folderSummary
                    if !queue.items.isEmpty { recentActivity }
                    backupTools
                }
                .frame(maxWidth: 640)
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity)
            }
            .background(BackupTheme.background)
            .navigationTitle("Photos Backup")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    accountToolbarItem
                }
            }
            .sheet(isPresented: $showPicker) {
                PhotoPicker { sources in enqueue(sources) }.ignoresSafeArea()
            }
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
            .onAppear {
                albums.refreshInBackground()
                refreshBackedUpCounts()
            }
            .onChange(of: preferences.selectedAlbumIDs) { _ in refreshBackedUpCounts() }
            .onChange(of: albums.albums) { _ in refreshBackedUpCounts() }
            .onChange(of: queue.completedSourceKeys) { _ in refreshBackedUpCounts() }
        }
        .navigationViewStyle(.stack)
    }

    /// Photos picked by hand are checked against Google even when the app
    /// remembers them as backed up: picking one is how someone asks "is this
    /// really backed up?", and the hash lookup settles it without re-uploading
    /// anything Google already has.
    private func enqueue(_ sources: [MediaSource]) {
        guard !sources.isEmpty else { return }
        Task { await automaticBackup.enqueueManualSelection(sources) }
    }

    @ViewBuilder private var accountBanner: some View {
        switch account.status {
        case .loading:
            banner(color: .blue, symbol: "hourglass", title: "Checking your account", message: "Just a moment…")
        case .disconnected:
            EmptyView()
        case .connected:
            if let warning = account.persistenceWarning {
                banner(color: .orange, symbol: "key.slash", title: "Sign-in isn’t saved", message: warning, showsChevron: false)
            }
        case .rejected(_, let reason):
            Button(action: onConnect) {
                banner(color: .red, symbol: "exclamationmark.arrow.circlepath", title: "Sign in again", message: reason, showsChevron: true)
            }
            .buttonStyle(.plain)
        }
    }

    private var backupHero: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 8) {
                Image(systemName: "cloud")
                Text("GOOGLE PHOTOS").tracking(1.4)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(BackupTheme.blue)
            .accessibilityElement(children: .combine)

            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(backupStatus.title)
                        .font(.system(.title2, design: .rounded).weight(.bold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(backupStatus.detail)
                        .font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if !dynamicTypeSize.isAccessibilitySize {
                    ZStack {
                        Circle().fill(heroTint.opacity(0.08))
                        if !queue.isIdle && account.status.isUsable {
                            Circle().stroke(heroTint.opacity(0.12), lineWidth: 4)
                            Circle().trim(from: 0, to: heroProgress)
                                .stroke(heroTint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                        }
                        Image(systemName: heroSymbol)
                            .font(.system(size: 25, weight: .medium))
                            .foregroundStyle(heroTint)
                    }
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
                }
            }

            if account.status.isUsable {
                HStack(alignment: .top, spacing: 8) {
                    metric(value: queue.completedSourceCount.formatted(), label: "Backed up")
                    metric(value: queue.activeCount.formatted(), label: "Remaining")
                    metric(value: queue.failedCount.formatted(), label: "Need attention")
                }
                .padding(.vertical, 16)
                .background(BackupTheme.background.opacity(0.7),
                            in: RoundedRectangle(cornerRadius: 16))
            }

            if queue.pauseReason == nil, let reason = queue.admissionStatusReason {
                Label(reason, systemImage: "pause.circle")
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            primaryAction

            if account.status.isUsable {
                Button { showPicker = true } label: {
                    Label("Choose individual photos", systemImage: "photo.badge.plus")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(BackupTheme.blue)
                .padding(.top, -14)
            }

            if !queue.isIdle || queue.isUserPaused {
                HStack(spacing: 10) {
                    if queue.isUserPaused {
                        Button {
                            queue.resumeUserPausedUploads()
                        } label: {
                            Label("Resume", systemImage: "play.circle")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(BackupTheme.blue)
                        .disabled(!account.status.isUsable)
                    } else if queue.pauseReason == nil {
                        Button {
                            queue.pauseAfterCurrentUploads()
                        } label: {
                            Label("Pause", systemImage: "pause.circle")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(BackupTheme.blue)
                        .accessibilityHint("Lets uploads in progress finish, then holds the remaining queue")
                    }

                    if !queue.isIdle {
                        Button(role: .destructive) {
                            showingStopBackupConfirmation = true
                        } label: {
                            Label("Stop", systemImage: "stop.circle")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    }
                }
            }
        }
        .backupCard(padding: 22)
    }

    @ViewBuilder private var primaryAction: some View {
        if !account.status.isUsable {
            Button(action: onConnect) {
                Label("Connect Google Photos", systemImage: "person.crop.circle.badge.plus")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(account.status == .loading)
        } else if selectedAlbums.isEmpty {
            Button(action: onAlbums) {
                Label("Choose Albums", systemImage: "rectangle.stack.badge.plus")
            }
            .buttonStyle(PrimaryButtonStyle())
        } else {
            Button(action: backUpSelectedAlbums) {
                Label(isStartingManualRun ? "Checking albums…" : "Back Up Now",
                      systemImage: "arrow.up.circle")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(isStartingManualRun || queue.isUserPaused)
        }
    }

    private var backupTools: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let health = automaticBackup.health {
                NavigationLink {
                    BackupHealthView(snapshot: health, onScan: {
                        Task { _ = await automaticBackup.backUpSelectedAlbumsNow() }
                    })
                } label: {
                    detailLink(symbol: "checkmark.shield", title: "Backup details",
                               subtitle: health.scope.isLimited ? "Limited Photos access · Review coverage" : "What’s saved and what needs a check")
                }
                .buttonStyle(.plain)
                Divider().padding(.leading, 48)
            }
            NavigationLink { BackupSessionHistoryView() } label: {
                detailLink(symbol: "clock.arrow.circlepath", title: "Backup history",
                           subtitle: "A summary of your recent backups")
            }
            .buttonStyle(.plain)
            Divider().padding(.leading, 48)
            DisclosureGroup {
                BlackScreenBackupControls(onStart: onBlackScreen)
                    .padding(.top, 12)
            } label: {
                HStack(spacing: 12) {
                    FeatureIcon(symbol: "moon", size: 36)
                    Text("Long backups").font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                }
                .frame(minHeight: 44)
            }
            .tint(BackupTheme.blue)
        }
        .backupCard()
    }

    private func detailLink(symbol: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            FeatureIcon(symbol: symbol, size: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    private var folderSummary: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Your albums").font(.headline)
                Spacer()
                Button("Manage", action: onAlbums)
                    .font(.subheadline.weight(.medium))
                    .frame(minHeight: 44)
            }
            if selectedAlbums.isEmpty {
                Text("Choose the albums you’d like to keep in Google Photos. You can change your selection anytime.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(Array(selectedAlbums.prefix(4).enumerated()), id: \.element.id) { index, album in
                    if index > 0 { Divider().padding(.leading, 54) }
                    HStack(spacing: 12) {
                        FeatureIcon(symbol: album.symbol, size: 42)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(album.title).font(.subheadline.weight(.semibold))
                            Text(progressLabel(for: album)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "photo.on.rectangle")
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                }
                if selectedAlbums.count > 4 {
                    Text("+ \(selectedAlbums.count - 4) more albums")
                        .font(.footnote.weight(.semibold)).foregroundStyle(BackupTheme.blue)
                }
            }
        }
        .backupCard()
    }

    private var recentActivity: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent uploads").font(.headline)
                Spacer()
                Button("View all", action: onActivity)
                    .font(.subheadline.weight(.medium)).frame(minHeight: 44)
            }
            ForEach(Array(queue.items.suffix(3).reversed())) { item in
                HStack(spacing: 12) {
                    ActivityThumbnail(source: item.source, symbol: symbol(item.state), tint: tint(item.state))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).font(.subheadline.weight(.medium)).lineLimit(1)
                        Text(item.state.label).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
        }
        .backupCard()
    }

    private var accountToolbarItem: some View {
        Button(action: onAccount) {
            ZStack {
                Circle().fill(account.status.isUsable ? BackupTheme.blue : Color.secondary.opacity(0.18))
                Image(systemName: account.status.isUsable ? "person.fill" : "person.crop.circle.badge.exclamationmark")
                    .font(.caption.weight(.bold)).foregroundStyle(account.status.isUsable ? .white : .secondary)
            }
            .frame(width: 32, height: 32)
            .frame(width: 44, height: 44)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(account.status.isUsable ? "Account connected" : "Account not connected")
        .accessibilityHint("Opens account settings")
    }

    private func banner(color: Color, symbol: String, title: String, message: String, showsChevron: Bool = false) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.title3).foregroundStyle(color).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if showsChevron { Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary) }
        }
        .padding(14)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func metric(value: String, label: String) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.system(.title2, design: .rounded).weight(.semibold).monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    private var backupStatus: DashboardBackupStatus {
        DashboardBackupStatus(accountUsable: account.status.isUsable, pauseReason: queue.pauseReason,
                              remaining: queue.activeCount, failed: queue.failedCount,
                              completed: queue.completedSourceCount, hasSelectedAlbums: !selectedAlbums.isEmpty)
    }

    private var heroProgress: Double {
        if !account.status.isUsable || queue.pauseReason != nil { return 0.18 }
        return queue.isIdle ? 1 : max(queue.overallFraction, 0.04)
    }

    private var heroTint: Color {
        if !account.status.isUsable || queue.pauseReason != nil { return .orange }
        if queue.failedCount > 0 { return .red }
        return BackupTheme.blue
    }

    private var heroSymbol: String {
        if !account.status.isUsable { return "link" }
        if queue.pauseReason != nil { return "pause.fill" }
        if queue.failedCount > 0 { return "exclamationmark" }
        return queue.isIdle ? "cloud" : "arrow.up"
    }

    private func progressLabel(for album: PhotoAlbum) -> String {
        guard let backedUp = albums.backedUpCounts[album.id] else {
            return "\(album.count.formatted()) items"
        }
        return "\(backedUp.formatted()) of \(album.count.formatted()) backed up"
    }

    private func refreshBackedUpCounts() {
        albums.refreshBackedUpCounts(for: preferences.selectedAlbumIDs,
                                     isBackedUp: queue.backedUpAssetLookup())
    }

    private func backUpSelectedAlbums() {
        guard !isStartingManualRun else { return }
        isStartingManualRun = true
        manualRunMessage = nil
        Task {
            let outcome = await automaticBackup.backUpSelectedAlbumsNow()
            isStartingManualRun = false
            manualRunMessage = Self.message(for: outcome)
        }
    }

    static func message(for outcome: AutomaticBackupCoordinator.ManualRunOutcome) -> String {
        switch outcome {
        case .noLibraryAccess: return "Allow photo access in Settings to back up your albums."
        case .noAlbumsSelected: return "Choose albums in the Albums tab first."
        case .nothingToDo: return "Everything in your selected albums is already backed up."
        case .started(let count): return "Backing up \(count.formatted()) items. Watch progress in Activity."
        case .rechecking(let count): return "Re-checking \(count.formatted()) items against Google Photos."
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
