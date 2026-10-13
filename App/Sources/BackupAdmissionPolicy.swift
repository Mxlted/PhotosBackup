import Foundation

/// Admission rules only. They never cancel work which already owns a staged
/// file or replace the user's pause, network policy, or execution-window owner.
struct BackupAdmissionSettings: Codable, Equatable, Sendable {
    var onlyWhileCharging = false
    /// Zero disables the battery rule. A five-point recovery band prevents
    /// repeated starts near the boundary; charging bypasses the battery floor.
    var minimumBatteryPercent = 0
    var reduceWhenHot = false
    var protectFreeStorage = false

    init(onlyWhileCharging: Bool = false, minimumBatteryPercent: Int = 0,
         reduceWhenHot: Bool = false, protectFreeStorage: Bool = false) {
        self.onlyWhileCharging = onlyWhileCharging
        self.minimumBatteryPercent = min(90, max(0, minimumBatteryPercent))
        self.reduceWhenHot = reduceWhenHot
        self.protectFreeStorage = protectFreeStorage
    }

    private enum CodingKeys: String, CodingKey {
        case onlyWhileCharging, minimumBatteryPercent, reduceWhenHot, protectFreeStorage
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            onlyWhileCharging: try values.decodeIfPresent(Bool.self, forKey: .onlyWhileCharging) ?? false,
            minimumBatteryPercent: try values.decodeIfPresent(Int.self, forKey: .minimumBatteryPercent) ?? 0,
            reduceWhenHot: try values.decodeIfPresent(Bool.self, forKey: .reduceWhenHot) ?? false,
            protectFreeStorage: try values.decodeIfPresent(Bool.self, forKey: .protectFreeStorage) ?? false
        )
    }

    var isEnabled: Bool {
        onlyWhileCharging || minimumBatteryPercent > 0 || reduceWhenHot || protectFreeStorage
    }
}

struct BackupAdmissionEnvironment: Equatable, Sendable {
    enum Power: Equatable, Sendable { case charging, battery, unknown }
    enum Thermal: Equatable, Sendable { case nominal, fair, serious, critical, unknown }
    var power: Power
    /// Nil represents unavailable device information, never an invented charge.
    var batteryPercent: Int?
    var thermal: Thermal
    /// Current filesystem free capacity already accounts for existing staged
    /// files, including files retained by background PUTs. Do not subtract those
    /// files a second time. In-progress reservations are subtracted separately.
    var availableBytes: Int64?
}

struct BackupAdmissionDecision: Equatable, Sendable {
    enum Blocker: String, Equatable, Sendable {
        case charging, battery, powerUnavailable, heat, localStorage, storageUnavailable
    }
    var allowsNewPreparation: Bool
    var concurrencyLimit: Int?
    var reason: String?
    var blocker: Blocker?
    var storageBlockedSince: Date?

    static let allowed = BackupAdmissionDecision(allowsNewPreparation: true,
                                                concurrencyLimit: nil, reason: nil,
                                                blocker: nil, storageBlockedSince: nil)
}

/// Small deterministic state machine; device sampling and scheduling live in
/// the monitor. All time is supplied by its caller, including the recovery hold.
struct BackupAdmissionPolicy {
    static let gibibyte: Int64 = 1_073_741_824
    static let storageHeadroom = gibibyte
    /// PhotoKit does not expose a supported byte-size property before export.
    /// This is deliberately a conservative reservation, not a promised maximum.
    static let unknownItemReservation = 2 * gibibyte
    static let storageRecoveryMargin = gibibyte / 4
    static let thermalRecoveryInterval: TimeInterval = 60

    private var batteryBlocked = false
    private var thermalBlocked = false
    private var thermalRecoveredAt: Date?
    private var storageBlocked = false
    private(set) var storageBlockedSince: Date?

    mutating func evaluate(settings: BackupAdmissionSettings,
                           environment: BackupAdmissionEnvironment,
                           reservedBytes: Int64 = 0,
                           requestedBytes: Int64 = unknownItemReservation,
                           now: Date) -> BackupAdmissionDecision {
        let minimum = min(90, max(0, settings.minimumBatteryPercent))
        if minimum == 0 || environment.power == .charging {
            batteryBlocked = false
        } else if let percent = environment.batteryPercent, (0...100).contains(percent) {
            batteryBlocked = percent < minimum + (batteryBlocked ? 5 : 0)
        } else {
            batteryBlocked = true
        }

        if !settings.reduceWhenHot {
            thermalBlocked = false
            thermalRecoveredAt = nil
        } else if environment.thermal == .serious || environment.thermal == .critical {
            thermalBlocked = true
            thermalRecoveredAt = nil
        } else if thermalBlocked {
            // Unknown thermal state cannot prove recovery from a known hot one.
            if environment.thermal == .unknown {
                thermalRecoveredAt = nil
            } else {
                if thermalRecoveredAt == nil { thermalRecoveredAt = now }
                if let recovered = thermalRecoveredAt,
                   now.timeIntervalSince(recovered) >= Self.thermalRecoveryInterval {
                    thermalBlocked = false
                    thermalRecoveredAt = nil
                }
            }
        }

        if settings.protectFreeStorage {
            let needed = Self.saturatedSum([
                max(0, reservedBytes), max(0, requestedBytes), Self.storageHeadroom,
                storageBlocked ? Self.storageRecoveryMargin : 0
            ])
            storageBlocked = environment.availableBytes.map { $0 < needed } ?? true
            if storageBlocked {
                if storageBlockedSince == nil { storageBlockedSince = now }
            } else { storageBlockedSince = nil }
        } else {
            storageBlocked = false
            storageBlockedSince = nil
        }

        func blocked(_ blocker: BackupAdmissionDecision.Blocker, _ reason: String) -> BackupAdmissionDecision {
            BackupAdmissionDecision(allowsNewPreparation: false, concurrencyLimit: nil,
                                    reason: reason, blocker: blocker, storageBlockedSince: storageBlockedSince)
        }
        if settings.onlyWhileCharging, environment.power != .charging {
            return blocked(environment.power == .unknown ? .powerUnavailable : .charging,
                           environment.power == .unknown ? "Waiting for charging information" : "Waiting for a charger")
        }
        if batteryBlocked {
            return blocked(environment.batteryPercent == nil ? .powerUnavailable : .battery,
                           environment.batteryPercent == nil
                           ? "Waiting for battery information"
                           : "Waiting for battery to reach \(minimum + 5)% or a charger")
        }
        if thermalBlocked {
            return blocked(.heat, "Waiting for the device to cool down")
        }
        if storageBlocked {
            return blocked(environment.availableBytes == nil ? .storageUnavailable : .localStorage,
                           environment.availableBytes == nil
                           ? "Waiting to check available local storage"
                           : "Waiting for local storage; free space or use Storage cleanup")
        }
        if settings.reduceWhenHot, environment.thermal == .fair || environment.thermal == .unknown {
            return BackupAdmissionDecision(allowsNewPreparation: true, concurrencyLimit: 1,
                                           reason: environment.thermal == .unknown
                                           ? "Reduced speed until device temperature is known"
                                           : "Reduced speed while the device is warm",
                                           blocker: nil, storageBlockedSince: nil)
        }
        return .allowed
    }

    static func reservationBytes(estimatedBytes: Int64?) -> Int64 {
        guard let estimate = estimatedBytes, estimate > 0 else { return unknownItemReservation }
        // Export can involve an intermediate copy in addition to the final body.
        return saturatedSum([estimate, estimate])
    }

    static func saturatedSum(_ values: [Int64]) -> Int64 {
        values.reduce(0) { sum, value in
            let next = sum.addingReportingOverflow(max(0, value))
            return next.overflow ? .max : next.partialValue
        }
    }
}
