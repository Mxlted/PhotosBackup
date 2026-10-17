import Photos
import SwiftUI
import UIKit

struct OnboardingView: View {
    @EnvironmentObject private var account: PhotosAccount
    @EnvironmentObject private var log: ProbeLog
    @EnvironmentObject private var probe: AccountConnector
    @EnvironmentObject private var preferences: BackupPreferences
    @EnvironmentObject private var albums: PhotoAlbumStore
    @Environment(\.openURL) private var openURL

    @State private var step = 0
    @State private var appeared = false
    @State private var showingConnect = false

    private let gpmcURL = URL(string: "https://github.com/xob0t/gpmc")!
    private let pageCount = 7

    var body: some View {
        ZStack {
            BackupTheme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                TabView(selection: $step) {
                    welcome.tag(0)
                    connectAccount.tag(1)
                    connectionCheck.tag(2)
                    permission.tag(3)
                    chooseFolders.tag(4)
                    connectionPreference.tag(5)
                    complete.tag(6)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.easeInOut(duration: 0.25), value: step)
            }
        }
        .tint(BackupTheme.blue)
        .fullScreenCover(isPresented: $showingConnect) {
            AccountConnectView(
                onCaptured: { token in
                    showingConnect = false
                    withAnimation { step = 2 }
                    Task { await probe.ingestWebToken(token) }
                },
                onCancel: { showingConnect = false }
            )
        }
        .onAppear {
            guard !appeared else { return }
            appeared = true
            albums.refreshInBackground()
        }
        .onChange(of: account.status) { status in
            guard step == 2, status.isUsable else { return }
            advanceAfterVerifiedConnection()
        }
        .onChange(of: log.steps) { _ in
            guard step == 2 else { return }
            advanceAfterVerifiedConnection()
        }
    }

    private var topBar: some View {
        VStack(spacing: 12) {
            HStack {
                Button { withAnimation { step -= 1 } } label: {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                }
                .disabled(step == 0)
                .opacity(step == 0 ? 0 : 1)
                .accessibilityLabel("Back")
                Spacer()
                Text("Set up Photos Backup")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(step + 1) of \(pageCount)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44)
            }
            ProgressView(value: Double(step + 1), total: Double(pageCount))
                .tint(BackupTheme.blue)
                .accessibilityLabel("Setup progress")
                .accessibilityValue("Step \(step + 1) of \(pageCount)")
        }
        .padding(.horizontal, 24)
        .padding(.top, 4)
    }

    private var welcome: some View {
        onboardingPage(
            artwork: AnyView(
                ZStack {
                    Circle().fill(BackupTheme.blue.opacity(0.05)).frame(width: 204, height: 204)
                    Circle().fill(BackupTheme.blue.opacity(0.07)).frame(width: 156, height: 156)
                    AppMark(size: 96)
                }
            ),
            eyebrow: "Welcome",
            title: "Your photos, backed up.",
            message: "Keep a copy of the moments that matter in Google Photos. Choose your albums, then let Photos Backup take it from there.",
            primaryTitle: "Get started",
            primaryAction: next,
            notice: "Experimental Google Photos connection. Google may change or interrupt access.",
            credit: "Built with GPMC by xob0t"
        )
    }

    private var permission: some View {
        onboardingPage(
            artwork: AnyView(
                ZStack {
                    Circle().fill(BackupTheme.blue.opacity(0.07)).frame(width: 196, height: 196)
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 78, weight: .medium))
                        .foregroundStyle(BackupTheme.blue)
                }
            ),
            eyebrow: "Photo access",
            title: "Your library, your choice",
            message: "Allow photo access to choose albums and individual photos. Only the items you choose to back up are sent to Google Photos.",
            primaryTitle: permissionButtonTitle,
            primaryAction: {
                Task {
                    if albums.authorization == .notDetermined {
                        await albums.requestAccess()
                        if albums.canRead { next() }
                    } else if albums.canRead {
                        next()
                    } else {
                        openAppSettings()
                    }
                }
            },
            secondaryTitle: albums.authorization == .denied || albums.authorization == .restricted ? "Continue without access" : nil,
            secondaryAction: next
        )
    }

    private var connectAccount: some View {
        onboardingPage(
            artwork: AnyView(
                ZStack {
                    Circle().fill(BackupTheme.blue.opacity(0.07)).frame(width: 196, height: 196)
                    Image(systemName: "person.badge.key.fill")
                        .font(.system(size: 74, weight: .medium))
                        .foregroundStyle(BackupTheme.blue)
                }
            ),
            eyebrow: "Your Google account",
            title: "Sign in with Google",
            message: "Choose the Google account where your backups will live. Sign in in the next window, then tap I agree.",
            primaryTitle: "Connect Google account",
            primaryAction: { showingConnect = true }
        )
    }

    private var connectionCheck: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 28)
                    ZStack {
                        Circle().fill(connectionTint.opacity(0.07)).frame(width: 196, height: 196)
                        Circle().stroke(connectionTint.opacity(0.18), lineWidth: 8).frame(width: 154, height: 154)
                        if probe.running {
                            ProgressView().controlSize(.large).tint(connectionTint).scaleEffect(1.35)
                        } else {
                            Image(systemName: connectionVerified ? "checkmark.icloud.fill" : connectionFailed ? "exclamationmark.icloud.fill" : "iphone.and.arrow.forward")
                                .font(.system(size: 72, weight: .medium)).foregroundStyle(connectionTint)
                        }
                    }
                    Spacer(minLength: 28)
                    Text(connectionEyebrow).font(.subheadline.weight(.semibold)).foregroundStyle(connectionTint)
                    Text(connectionTitle).font(.system(.largeTitle, design: .rounded).weight(.semibold)).multilineTextAlignment(.center).padding(.top, 9)
                    Text(connectionMessage).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(3).padding(.top, 12)
                    Spacer(minLength: 28)
                    if !connectionVerified {
                        Button(probe.running ? "Checking…" : (connectionFailed ? "Try again" : "Check again")) {
                            if connectionFailed { showingConnect = true } else { verifyConnection() }
                        }
                        .buttonStyle(PrimaryButtonStyle()).disabled(probe.running)
                        if !probe.running {
                            Button("Use a different account") { showingConnect = true }
                                .font(.headline)
                                .frame(minHeight: 44)
                                .padding(.top, 8)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
                .frame(minHeight: geometry.size.height)
            }
            .hiddenScrollIndicators()
        }
        .onAppear { verifyConnection() }
    }

    private var chooseFolders: some View {
        VStack(spacing: 0) {
            VStack(spacing: 7) {
                Text("Your albums").font(.subheadline.weight(.semibold)).foregroundStyle(BackupTheme.blue)
                Text("Choose your albums").font(.system(.largeTitle, design: .rounded).weight(.semibold)).multilineTextAlignment(.center)
                Text("Pick the albums to back up. You can change these anytime.")
                    .font(.body).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)

            Group {
                if albums.canRead {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(albums.albums) { album in
                                AlbumSelectionRow(album: album, isSelected: preferences.selectedAlbumIDs.contains(album.id)) {
                                    preferences.toggle(albumID: album.id)
                                }
                            }
                            if albums.isLoading {
                                ProgressView("Loading albums…")
                                    .padding(.vertical, 24)
                            } else if albums.albums.isEmpty {
                                EmptyState(symbol: "photo.on.rectangle", title: "No albums yet", message: "Add photos to your library, then choose albums from the Albums tab.")
                            }
                        }
                        .padding(20)
                    }
                } else {
                    EmptyState(symbol: "photo.badge.exclamationmark", title: "Photo access is off", message: "You can choose albums later after allowing photo access in Settings.")
                    Spacer()
                }
            }

            VStack(spacing: 10) {
                Button(preferences.selectedAlbumIDs.isEmpty ? "Choose later" : "Continue") { next() }
                    .buttonStyle(PrimaryButtonStyle())
                Text(preferences.selectedAlbumIDs.isEmpty ? "You can choose albums later" : "\(preferences.selectedAlbumIDs.count) \(preferences.selectedAlbumIDs.count == 1 ? "album" : "albums") selected")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding(20)
        }
    }

    private var connectionPreference: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 30)
                    FeatureIcon(symbol: "wifi", size: 76)
                    Text("Back up on your terms")
                        .font(.system(.largeTitle, design: .rounded).weight(.semibold)).multilineTextAlignment(.center).padding(.top, 24)
                    Text("Choose the connection that works for you.")
                        .font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.top, 10)

                    VStack(spacing: 12) {
                        ForEach(BackupConnection.allCases) { option in
                            Button { preferences.connection = option } label: {
                                HStack(spacing: 14) {
                                    FeatureIcon(symbol: option == .wifiOnly ? "wifi" : "antenna.radiowaves.left.and.right", size: 44)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(option.title).font(.headline).foregroundStyle(.primary)
                                        Text(option.detail).font(.subheadline).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: preferences.connection == option ? "checkmark.circle.fill" : "circle")
                                        .font(.title3).foregroundStyle(preferences.connection == option ? BackupTheme.blue : .secondary)
                                }
                                .backupCard(padding: 18)
                                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(preferences.connection == option ? BackupTheme.blue.opacity(0.6) : .clear, lineWidth: 1.5))
                            }
                            .buttonStyle(CardButtonStyle())
                            .accessibilityAddTraits(preferences.connection == option ? .isSelected : [])
                        }
                    }
                    .padding(.top, 28)

                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Automatic backup", isOn: $preferences.automaticBackup)
                            .font(.subheadline.weight(.semibold))
                        Text("Checks your selected albums for new photos. iOS controls when backups can run in the background.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .backupCard(padding: 18)
                    .padding(.top, 18)
                    Spacer(minLength: 28)
                    Button("Continue") { next() }.buttonStyle(PrimaryButtonStyle())
                }
                .padding(24)
                .frame(minHeight: geometry.size.height)
            }
            .hiddenScrollIndicators()
        }
    }

    private var complete: some View {
        onboardingPage(
            artwork: AnyView(
                ZStack {
                    Circle().fill(Color.green.opacity(0.08)).frame(width: 196, height: 196)
                    Image(systemName: "checkmark.icloud.fill")
                        .font(.system(size: 86, weight: .medium))
                        .foregroundStyle(.green)
                }
            ),
            eyebrow: "All set",
            title: "You’re ready to begin",
            message: completionMessage,
            primaryTitle: "Open Photos Backup",
            primaryAction: finish
        )
    }

    private func onboardingPage(
        artwork: AnyView,
        eyebrow: String,
        title: String,
        message: String,
        primaryTitle: String,
        primaryAction: @escaping () -> Void,
        secondaryTitle: String? = nil,
        secondaryAction: @escaping () -> Void = {},
        notice: String? = nil,
        credit: String? = nil
    ) -> some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 28)
                    artwork
                    Spacer(minLength: 28)
                    Text(eyebrow).font(.subheadline.weight(.semibold)).foregroundStyle(BackupTheme.blue)
                    Text(title).font(.system(.largeTitle, design: .rounded).weight(.semibold)).multilineTextAlignment(.center).padding(.top, 9)
                    Text(message).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(3).padding(.top, 12)
                    if let notice {
                        Text(notice)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(14)
                            .frame(maxWidth: .infinity)
                            .background(BackupTheme.secondaryBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .padding(.top, 20)
                    }
                    Spacer(minLength: 28)
                    Button(primaryTitle, action: primaryAction).buttonStyle(PrimaryButtonStyle())
                    if let secondaryTitle {
                        Button(secondaryTitle, action: secondaryAction)
                            .font(.headline)
                            .frame(minHeight: 44)
                            .padding(.top, 8)
                    }
                    if let credit {
                        Link(credit, destination: gpmcURL)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.secondary)
                            .frame(minHeight: 44)
                            .padding(.top, 4)
                            .accessibilityHint("Opens the GPMC project on GitHub")
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
                .frame(minHeight: geometry.size.height)
            }
            .hiddenScrollIndicators()
        }
    }

    private var permissionButtonTitle: String {
        switch albums.authorization {
        case .authorized, .limited: return "Continue"
        case .denied, .restricted: return "Open Settings"
        default: return "Allow photo access"
        }
    }

    private var completionMessage: String {
        guard account.status.isUsable else {
            return "Connect your Google account from Home when you’re ready to begin."
        }
        let count = preferences.selectedAlbumIDs.count
        guard count > 0 else {
            return "Your Google account is connected. Choose albums from the Albums tab whenever you’re ready."
        }
        if preferences.automaticBackup {
            return "Your Google account is connected and automatic backup is on for \(count) \(count == 1 ? "album" : "albums")."
        }
        return "Your Google account is connected and \(count) \(count == 1 ? "album is" : "albums are") selected. Start a backup whenever you’re ready."
    }

    private func next() { withAnimation { step = min(pageCount - 1, step + 1) } }
    private func finish() { preferences.completedOnboarding = true }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }

    private var connectionFailed: Bool {
        logState(ProbeLog.masterToken) == .failed || logState(ProbeLog.photosToken) == .failed || logState(ProbeLog.readAccess) == .failed
    }

    private var connectionVerified: Bool {
        guard account.status.isUsable else { return false }
        // A fresh handoff must pass the Photos read check. A restored account
        // has no in-memory exchange result, so its successful credential
        // restoration is sufficient and Settings still offers Verify.
        return probe.lastResult == nil || logState(ProbeLog.readAccess) == .passed
    }

    private var connectionTint: Color {
        if connectionVerified { return .green }
        if connectionFailed { return .orange }
        return BackupTheme.blue
    }

    private var connectionEyebrow: String {
        if connectionVerified { return "Account connected" }
        if connectionFailed { return "Connection needs attention" }
        return probe.running ? "Connecting to Google Photos" : "Your Google account"
    }

    private var connectionTitle: String {
        if connectionVerified { return "You’re connected" }
        if connectionFailed { return "Let’s try that again" }
        return probe.running ? "Checking your account…" : "Finish connecting"
    }

    private var connectionMessage: String {
        if connectionVerified { return "Your Google Photos account is ready. Next, choose what you’d like to back up." }
        if connectionFailed {
            return "We couldn’t finish connecting to Google Photos. Try signing in again, then tap I agree."
        }
        return probe.running
            ? "Making sure your account can connect to Google Photos."
            : "Sign in and tap I agree in the next window to finish connecting."
    }

    private func logState(_ id: String) -> ProbeStep.State? {
        probe.log.steps.first(where: { $0.id == id })?.state
    }

    private func verifyConnection() {
        if account.status.isUsable {
            Task { await account.verify() }
        }
    }

    private func advanceAfterVerifiedConnection() {
        guard connectionVerified else { return }
        Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            if step == 2, connectionVerified { withAnimation { step = 3 } }
        }
    }
}

struct AlbumSelectionRow: View {
    let album: PhotoAlbum
    let isSelected: Bool
    var backedUpCount: Int? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                FeatureIcon(symbol: album.symbol, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(album.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3).foregroundStyle(isSelected ? BackupTheme.blue : .secondary)
            }
            .backupCard(padding: 16)
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(isSelected ? BackupTheme.blue.opacity(0.55) : .clear, lineWidth: 1.5))
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(CardButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(isSelected ? "Deselect album" : "Select album")
    }

    private var detail: String {
        guard let backedUpCount else { return "\(album.count.formatted()) items" }
        if backedUpCount >= album.count, album.count > 0 { return "All \(album.count.formatted()) backed up" }
        return "\(backedUpCount.formatted()) of \(album.count.formatted()) backed up"
    }
}
