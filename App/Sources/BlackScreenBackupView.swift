import SwiftUI
import UIKit

/// Owns the idle-timer override only while this screen is visible and active.
/// Inactive scenes (Control Center, calls, app switching) relinquish it too.
@MainActor
final class BlackScreenAwakeSession: ObservableObject {
    private let readIdleTimer: () -> Bool
    private let writeIdleTimer: (Bool) -> Void
    private var previousValue: Bool?

    convenience init() {
        self.init(readIdleTimer: { UIApplication.shared.isIdleTimerDisabled },
                  writeIdleTimer: { UIApplication.shared.isIdleTimerDisabled = $0 })
    }

    init(readIdleTimer: @escaping () -> Bool, writeIdleTimer: @escaping (Bool) -> Void) {
        self.readIdleTimer = readIdleTimer
        self.writeIdleTimer = writeIdleTimer
    }

    func update(isVisible: Bool, isActive: Bool) {
        if isVisible && isActive {
            guard previousValue == nil else { return }
            previousValue = readIdleTimer()
            writeIdleTimer(true)
        } else if let previousValue {
            writeIdleTimer(previousValue)
            self.previousValue = nil
        }
    }
}

/// Describe the queue, without claiming that every selected album was scanned.
struct BlackScreenBackupStatus {
    let title: String
    let detail: String

    init(accountUsable: Bool, pauseReason: String?, remaining: Int, failed: Int, waitingForICloud: Int) {
        if !accountUsable {
            title = "Connect to back up"
            detail = "Exit black screen to connect your Google Photos account."
        } else if let pauseReason {
            title = "Backup paused"
            detail = pauseReason
        } else if remaining > 0 {
            title = "Backing up"
            detail = waitingForICloud > 0
                ? "Some items need to download from iCloud. Keep this app open."
                : "Preparing, checking, and uploading your queued items."
        } else if failed > 0 {
            title = "Backup needs attention"
            detail = "Exit black screen and open Activity to review failed uploads."
        } else {
            title = "Queue is clear"
            detail = "No pending uploads. You can start a backup from Home or Activity."
        }
    }
}

struct BlackScreenBackupControls: View {
    let onStart: () -> Void
    @State private var showTips = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onStart) {
                Label("Black Screen Mode", systemImage: "moon.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(BackupTheme.blue)
            .accessibilityHint("Shows dim backup progress and prevents auto-lock while the app stays open")

            Text("Keeps this app awake while queued uploads continue, with dim text on a black screen.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Button("Tips for Long Backups") { showTips = true }
                .font(.footnote.weight(.medium))
                .frame(minHeight: 44)
                .buttonStyle(.plain)
                .foregroundStyle(BackupTheme.blue)
        }
        .sheet(isPresented: $showTips) { BackupSessionTipsView() }
    }
}

struct BlackScreenBackupView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var account: PhotosAccount
    @EnvironmentObject private var queue: UploadQueue
    @StateObject private var awakeSession = BlackScreenAwakeSession()
    @State private var isVisible = false

    private let textColor = Color(white: 0.55)
    private let secondaryTextColor = Color(white: 0.48)

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()
                // A slow, nonanimated shift avoids leaving text on exactly the
                // same pixels throughout a long session. No per-frame timer.
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 28) {
                            statusSummary
                            metrics

                            if queue.activeCount > 0 {
                                Text("Current queue: \(queue.overallFraction.formatted(.percent.precision(.fractionLength(0))))")
                                    .font(.footnote.monospacedDigit())
                            }

                            if let warning = queue.persistenceWarning {
                                Text(warning)
                                    .font(.footnote)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            VStack(spacing: 12) {
                                Text("App stays awake until you exit this mode.\nKeep Photos Backup open and your phone unlocked.")
                                    .font(.footnote)
                                    .foregroundStyle(secondaryTextColor)
                                Button("Exit Black Screen") { dismiss() }
                                    .font(.body.weight(.medium))
                                    .frame(minHeight: 44)
                                    .padding(.horizontal, 18)
                                    .overlay(Capsule().stroke(Color(white: 0.2), lineWidth: 1))
                                    .buttonStyle(.plain)
                                    .accessibilityHint("Returns to the app without stopping backup")
                            }
                        }
                        .frame(maxWidth: 420)
                        .padding(32)
                        .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                        .offset(shift(at: context.date))
                    }
                }
            }
        }
        .foregroundStyle(textColor)
        .multilineTextAlignment(.center)
        .preferredColorScheme(.dark)
        .statusBar(hidden: true)
        .backupSystemOverlaysHidden()
        .interactiveDismissDisabled()
        .onAppear {
            isVisible = true
            updateAwakeSession()
        }
        .onChange(of: scenePhase) { _ in updateAwakeSession() }
        .onDisappear {
            isVisible = false
            updateAwakeSession()
        }
    }

    private var statusSummary: some View {
        let status = BlackScreenBackupStatus(accountUsable: account.status.isUsable,
                                             pauseReason: queue.pauseReason,
                                             remaining: queue.activeCount,
                                             failed: queue.failedCount,
                                             waitingForICloud: queue.deferredForICloudCount)
        return VStack(spacing: 12) {
            Text("BLACK SCREEN MODE")
                .font(.caption.weight(.medium))
                .tracking(2)
                .foregroundStyle(secondaryTextColor)
            Text(status.title).font(.title2.weight(.medium))
            Text(status.detail)
                .font(.subheadline)
                .foregroundStyle(secondaryTextColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var metrics: some View {
        VStack(spacing: 16) {
            metric("Backed up · account total", value: queue.completedSourceCount)
            metric("In queue", value: queue.activeCount)
            metric("Needs attention", value: queue.failedCount)
        }
        .font(.body.monospacedDigit())
    }

    private func metric(_ label: String, value: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label).multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            Text(value.formatted()).fontWeight(.medium)
        }
        .accessibilityElement(children: .combine)
    }

    private func shift(at date: Date) -> CGSize {
        guard !reduceMotion else { return .zero }
        switch Int(date.timeIntervalSinceReferenceDate / 60) % 4 {
        case 0: return CGSize(width: -6, height: -6)
        case 1: return CGSize(width: 6, height: -6)
        case 2: return CGSize(width: 6, height: 6)
        default: return CGSize(width: -6, height: 6)
        }
    }

    private func updateAwakeSession() {
        awakeSession.update(isVisible: isVisible, isActive: scenePhase == .active)
    }
}

private extension View {
    @ViewBuilder func backupSystemOverlaysHidden() -> some View {
        if #available(iOS 16.0, *) {
            persistentSystemOverlays(.hidden)
        } else {
            self
        }
    }
}

private struct BackupSessionTipsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                Section("Before you leave") {
                    tip("Start the backup first", "Use Back Up Now or queue photos, then enter Black Screen Mode. It keeps the app awake even when the queue is paused or finished; exit the mode to restore normal auto-lock.")
                    tip("Use power and reliable Wi-Fi", "Plug in your phone, use a strong Wi-Fi connection, and leave it on a cool, uncovered surface. Lower screen brightness in Control Center if needed. Black pixels save display power on OLED screens; the phone remains on and unlocked.")
                    tip("Avoid power and data restrictions", "For a large backup, turn off Low Power Mode and Low Data Mode for the network you use. These settings can restrict background activity and iCloud Photos updates.")
                }
                Section("Reduce interruptions") {
                    tip("Use a Focus", "Turn on Do Not Disturb or a custom Focus to silence unwanted notifications. Focus controls interruptions; it does not reserve processing power for this app.")
                    tip("Pause competing transfers", "Pause large downloads, streaming, and other photo backup apps while this backup runs. You can temporarily turn off Background App Refresh for unrelated apps in iOS Settings. iOS manages other processes; this app cannot stop them or claim exclusive priority.")
                    tip("Optional: Guided Access", "Settings → Accessibility → Guided Access can keep the phone in one app. Set its Display Auto-Lock to Never for this session. Learn how to end the session before starting; Apple says emergency calls and Crash Detection are unavailable during Guided Access.")
                    Link("Apple’s Guided Access instructions", destination: URL(string: "https://support.apple.com/en-us/111795")!)
                }
                Section("If progress slows") {
                    tip("Keep the phone cool", "Heat can reduce performance. Avoid direct sun and covering the phone. If it warms up, reduce Simultaneous Uploads in Settings; more concurrent uploads are not always faster.")
                    tip("Check Activity", "Network pauses, account issues, and failed uploads still need attention. Black Screen Mode shows their status, but does not bypass them. Locking the phone or switching apps ends the foreground session; background backup follows the usual iOS limits.")
                }
            }
            .navigationTitle("Long Backups")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func tip(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(detail).font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
