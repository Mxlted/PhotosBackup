import Foundation
import UIKit

/// One process-wide monitor feeds every queue execution path. It only controls
/// admission; it never acquires execution ownership or changes a user pause.
@MainActor
final class BackupAdmissionMonitor: ObservableObject {
    @Published private(set) var decision = BackupAdmissionDecision.allowed
    @Published private(set) var environment: BackupAdmissionEnvironment
    private(set) var settings: BackupAdmissionSettings
    var onDecisionChange: ((BackupAdmissionDecision) -> Void)?

    private struct Reservation {
        let token: UUID
        let bytes: Int64
        var releaseRequested = false
    }
    private var reservations: [UUID: Reservation] = [:]
    private var policy = BackupAdmissionPolicy()
    private var requestedBytes = BackupAdmissionPolicy.unknownItemReservation
    private let readEnvironment: () -> BackupAdmissionEnvironment
    private let readCapacity: @Sendable () async -> Int64?
    private let now: () -> Date
    private let notifications: NotificationCenter
    private var observers: [NSObjectProtocol] = []
    private var refreshTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var started = false

    init(settings: BackupAdmissionSettings = .init(),
         environment: (() -> BackupAdmissionEnvironment)? = nil,
         capacity: @escaping @Sendable () async -> Int64? = { await AppStorageUsage.availableCapacity() },
         now: @escaping () -> Date = Date.init,
         notifications: NotificationCenter = .default) {
        self.settings = settings
        let environment = environment ?? { BackupAdmissionMonitor.deviceEnvironment() }
        self.readEnvironment = environment
        self.readCapacity = capacity
        self.now = now
        self.notifications = notifications
        self.environment = environment()
        evaluate()
    }

    var reservedBytes: Int64 { BackupAdmissionPolicy.saturatedSum(reservations.values.map(\.bytes)) }

    func start() {
        guard !started else { return }
        started = true
        UIDevice.current.isBatteryMonitoringEnabled = true
        // Apple requires an initial read before registering thermal changes.
        _ = ProcessInfo.processInfo.thermalState
        for name in [UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification,
                     ProcessInfo.thermalStateDidChangeNotification, UIApplication.didBecomeActiveNotification] {
            observers.append(notifications.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in await self?.refresh() }
            })
        }
        updateTimer()
        Task { await refresh() }
    }

    func updateSettings(_ settings: BackupAdmissionSettings) {
        self.settings = settings
        evaluate()
        updateTimer()
        Task { await refresh() }
    }

    /// Used before each new export. The main actor serializes competing queue
    /// admissions, so two workers cannot spend the same capacity reservation.
    /// Repeated admission for the same item is idempotent.
    @discardableResult
    func reservePreparation(id: UUID, estimatedBytes: Int64? = nil) -> Bool {
        if let existing = reservations[id], !existing.releaseRequested { return true }
        requestedBytes = BackupAdmissionPolicy.reservationBytes(estimatedBytes: estimatedBytes)
        evaluate()
        guard decision.allowsNewPreparation else { return false }
        reservations[id] = Reservation(token: UUID(), bytes: requestedBytes)
        // Publish the condition for the *next* export without denying the one
        // whose reservation has just been granted.
        evaluate()
        return true
    }

    /// Release after export has produced its durable checkpoint, or after a
    /// failed/cancelled preparation has stopped writing. A fresh disk sample is
    /// required before the reservation is dropped: otherwise the old free-space
    /// sample and a newly written file could admit too much concurrent work.
    func releaseReservation(id: UUID) {
        guard reservations[id] != nil else { return }
        if !settings.protectFreeStorage {
            reservations[id] = nil
            evaluate()
            return
        }
        reservations[id]?.releaseRequested = true
        Task { await refresh() }
    }

    /// A caller may await this when an execution window begins. Sampling is
    /// bounded, coalesced, off the main actor for filesystem work, and testable.
    func refresh() async {
        if let refreshTask {
            await refreshTask.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.refreshTask = nil }
            repeat {
                let releases = self.reservations.filter { $0.value.releaseRequested }.mapValues(\.token)
                let available: Int64?
                if self.settings.protectFreeStorage || !releases.isEmpty {
                    available = await self.readCapacity()
                } else {
                    available = self.environment.availableBytes
                }
                guard !Task.isCancelled else { return }
                var next = self.readEnvironment()
                next.availableBytes = available
                self.environment = next
                for (id, token) in releases where self.reservations[id]?.token == token {
                    self.reservations[id] = nil
                }
                self.evaluate()
                // A release arriving during the capacity read needs a sample
                // taken after its file stopped growing, not the older sample.
            } while self.reservations.values.contains(where: \.releaseRequested)
        }
        refreshTask = task
        await task.value
    }

    private func evaluate() {
        let next = policy.evaluate(settings: settings, environment: environment,
                                   reservedBytes: reservedBytes, requestedBytes: requestedBytes, now: now())
        guard next != decision else { return }
        decision = next
        // Never re-enter UploadQueue.pump while it is reserving a new worker.
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.onDecisionChange?(self.decision)
        }
    }

    private func updateTimer() {
        timerTask?.cancel()
        timerTask = nil
        guard started, settings.isEnabled else { return }
        timerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                // Local condition recovery only; no network polling and no new
                // background execution request. iOS suspends this with the app.
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }

    private static func deviceEnvironment() -> BackupAdmissionEnvironment {
        let device = UIDevice.current
        let power: BackupAdmissionEnvironment.Power
        switch device.batteryState {
        case .charging, .full: power = .charging
        case .unplugged: power = .battery
        default: power = .unknown
        }
        let thermal: BackupAdmissionEnvironment.Thermal
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = .nominal
        case .fair: thermal = .fair
        case .serious: thermal = .serious
        case .critical: thermal = .critical
        @unknown default: thermal = .unknown
        }
        let level = device.batteryLevel
        return BackupAdmissionEnvironment(power: power,
                                          batteryPercent: level >= 0 ? Int((level * 100).rounded()) : nil,
                                          thermal: thermal, availableBytes: nil)
    }

    deinit {
        timerTask?.cancel()
        refreshTask?.cancel()
        for observer in observers { notifications.removeObserver(observer) }
    }
}
