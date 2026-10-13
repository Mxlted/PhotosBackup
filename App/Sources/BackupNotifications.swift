import Foundation
import UserNotifications
import SwiftUI

struct BackupNotificationMessage: Equatable, Sendable {
    enum Kind: String, Codable { case completed, failures, account, remoteStorage, localStorage }
    let sessionID: UUID
    let kind: Kind
    var id: String { "backup.\(sessionID.uuidString).\(kind.rawValue)" }
    var title: String {
        switch kind {
        case .completed: return "Backup session complete"
        case .failures: return "Backup finished with failures"
        case .account: return "Backup needs a connection"
        case .remoteStorage: return "Google Photos storage needs attention"
        case .localStorage: return "Backup needs device storage"
        }
    }
    var body: String {
        switch kind {
        case .completed: return "The session's scan and required uploads finished. Open Photos Backup for coverage and the session summary."
        case .failures: return "Some required items could not be backed up. Open Activity to review and retry them."
        case .account: return "Open Settings in Photos Backup to reconnect your account."
        case .remoteStorage: return "Free space in your Google account, then resume backup."
        case .localStorage: return "New media preparation has waited for device storage. Open Photos Backup to review storage."
        }
    }
    var targetTab: Int { kind == .account || kind == .remoteStorage || kind == .localStorage ? 3 : 2 }
}

@MainActor
protocol BackupNotificationDelivering {
    func requestPermission() async -> Bool
    func isAuthorized() async -> Bool
    func deliver(_ message: BackupNotificationMessage) async throws
    func remove(_ identifiers: [String])
}

final class SystemBackupNotifications: NSObject, BackupNotificationDelivering, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    var onOpen: ((UUID, Int) -> Void)?
    override init() { super.init(); center.delegate = self }
    func requestPermission() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }
    func isAuthorized() async -> Bool {
        let status = await center.notificationSettings().authorizationStatus
        return status == .authorized || status == .provisional || status == .ephemeral
    }
    func deliver(_ message: BackupNotificationMessage) async throws {
        let content = UNMutableNotificationContent()
        content.title = message.title; content.body = message.body; content.sound = .default
        content.userInfo = ["session": message.sessionID.uuidString, "tab": message.targetTab]
        try await center.add(UNNotificationRequest(identifier: message.id, content: content, trigger: nil))
    }
    func remove(_ identifiers: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let session = (info["session"] as? String).flatMap(UUID.init(uuidString:))
        let tab = info["tab"] as? Int
        Task { @MainActor [weak self] in
            if let session, let tab { self?.onOpen?(session, tab) }
            completionHandler()
        }
    }
}

/// Stable request IDs plus a durable claim provide at-most-once notices across
/// retries, window callbacks and relaunch. Payloads contain only opaque session IDs.
@MainActor
final class BackupNotificationController: ObservableObject {
    @Published private(set) var permissionDescription = "Notifications are off."
    @Published var destinationTab: Int?
    private let delivery: BackupNotificationDelivering
    private let defaults: UserDefaults
    private let now: () -> Date
    private var activeAccount: String?
    private var activeSession: UUID?
    private var generation = UUID()
    private var localStorageBlockedSince: Date?
    private var storageTimer: Task<Void, Never>?
    private var pendingOpen: (UUID, Int)?
    private var latestSession: BackupSession?
    private var eligibleMessageID: String?
    private var claimed: [String]
    private let claimsKey = "backup.notificationClaims.v1"
    var enabled = false

    init(delivery: BackupNotificationDelivering, defaults: UserDefaults = .standard,
         now: @escaping () -> Date = Date.init) {
        self.delivery = delivery; self.defaults = defaults; self.now = now
        claimed = defaults.stringArray(forKey: claimsKey) ?? []
    }
    func requestPermission() async -> Bool {
        let allowed = await delivery.requestPermission()
        permissionDescription = allowed ? "Session and action-required notifications are allowed."
            : "Notifications are not allowed. You can enable them in iOS Settings; backup still works."
        return allowed
    }
    func refreshPermissionDescription() async {
        permissionDescription = await delivery.isAuthorized()
            ? "Notifications are allowed in iOS Settings."
            : "Notifications are not allowed. Enable them in iOS Settings; backup still works."
    }
    func activate(account: String?, session: UUID?) {
        if account != activeAccount {
            generation = UUID()
            delivery.remove(claimed)
            localStorageBlockedSince = nil
            storageTimer?.cancel(); storageTimer = nil
            destinationTab = nil
        }
        if session != activeSession { storageTimer?.cancel(); storageTimer = nil; localStorageBlockedSince = nil }
        activeAccount = account; activeSession = session
        if account != nil, let pendingOpen {
            self.pendingOpen = nil
            open(session: pendingOpen.0, tab: pendingOpen.1)
        }
    }
    func open(session: UUID, tab: Int) {
        guard [2, 3].contains(tab) else { return }
        guard activeAccount != nil else { pendingOpen = (session, tab); return }
        guard session == activeSession else { return }
        destinationTab = tab
    }
    func consider(_ session: BackupSession?, account: String?, problem: BackupNotificationMessage.Kind? = nil,
                  localStorageBlocked: Bool = false) async {
        activate(account: account, session: session?.id)
        latestSession = session
        guard enabled, account != nil, let session else { storageTimer?.cancel(); storageTimer = nil; return }
        let storageKey = "backup.storageBlockedSince." + session.id.uuidString
        if localStorageBlocked {
            if localStorageBlockedSince == nil {
                let saved = defaults.double(forKey: storageKey)
                localStorageBlockedSince = saved > 0 ? Date(timeIntervalSince1970: saved) : now()
                defaults.set(localStorageBlockedSince?.timeIntervalSince1970, forKey: storageKey)
            }
            if storageTimer == nil, let since = localStorageBlockedSince {
                let seconds = max(0, 15 * 60 - now().timeIntervalSince(since))
                if seconds > 0 {
                    let expected = generation
                    storageTimer = Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                        guard let self, !Task.isCancelled, self.generation == expected,
                              self.activeSession == session.id else { return }
                        await self.consider(self.latestSession, account: self.activeAccount, localStorageBlocked: true)
                    }
                }
            }
        } else {
            localStorageBlockedSince = nil; storageTimer?.cancel(); storageTimer = nil
            defaults.removeObject(forKey: storageKey)
        }
        let kind: BackupNotificationMessage.Kind?
        if let problem { kind = problem }
        else if let since = localStorageBlockedSince, now().timeIntervalSince(since) >= 15 * 60 { kind = .localStorage }
        else if session.outcome == .completed { kind = .completed }
        else if session.outcome == .completedWithFailures { kind = .failures }
        else { kind = nil }
        guard let kind else { eligibleMessageID = nil; return }
        let message = BackupNotificationMessage(sessionID: session.id, kind: kind)
        eligibleMessageID = message.id
        let expectedGeneration = generation
        guard !claimed.contains(message.id), await delivery.isAuthorized(),
              expectedGeneration == generation, activeSession == session.id, enabled, eligibleMessageID == message.id,
              !claimed.contains(message.id) else { return }
        claimed.append(message.id)
        claimed = Array(claimed.suffix(120))
        defaults.set(claimed, forKey: claimsKey)
        do {
            try await delivery.deliver(message)
            if expectedGeneration != generation || activeSession != session.id || eligibleMessageID != message.id { delivery.remove([message.id]) }
        } catch {
            claimed.removeAll { $0 == message.id }
            defaults.set(claimed, forKey: claimsKey)
        }
    }
}

struct BackupNotificationSettingsView: View {
    @EnvironmentObject private var preferences: BackupPreferences
    @EnvironmentObject private var notifications: BackupNotificationController
    var body: some View {
        Section("Notifications") {
            if preferences.backupNotifications {
                Toggle("Backup Session Notifications", isOn: $preferences.backupNotifications)
            } else {
                Button("Enable Backup Notifications") {
                    Task { preferences.backupNotifications = await notifications.requestPermission() }
                }
            }
            Text(notifications.permissionDescription).font(.footnote).foregroundStyle(.secondary)
            Text("One notice for a settled session or a problem needing action. Individual uploads and ordinary network interruptions stay quiet.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .task { await notifications.refreshPermissionDescription() }
    }
}
