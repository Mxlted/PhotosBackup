import XCTest
@testable import PhotosBackup

final class BackupAdmissionPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)
    private let gib = BackupAdmissionPolicy.gibibyte
    private var healthy: BackupAdmissionEnvironment {
        .init(power: .battery, batteryPercent: 80, thermal: .nominal, availableBytes: 20 * gib)
    }

    func testOldAndPartialSettingsKeepEveryRestrictionOff() throws {
        let settings = try JSONDecoder().decode(BackupAdmissionSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(settings, .init())
        XCTAssertFalse(settings.isEnabled)
        let partial = try JSONDecoder().decode(BackupAdmissionSettings.self,
                                              from: Data("{\"reduceWhenHot\":true}".utf8))
        XCTAssertTrue(partial.reduceWhenHot)
        XCTAssertFalse(partial.onlyWhileCharging)
        XCTAssertFalse(partial.protectFreeStorage)
        XCTAssertEqual(partial.minimumBatteryPercent, 0)
        XCTAssertEqual(try JSONDecoder().decode(BackupAdmissionSettings.self,
                                               from: JSONEncoder().encode(partial)), partial)
    }

    func testDefaultPolicyPreservesAdmissionEvenWhenEveryInputIsUnavailable() {
        var policy = BackupAdmissionPolicy()
        let unknown = BackupAdmissionEnvironment(power: .unknown, batteryPercent: nil,
                                                 thermal: .critical, availableBytes: nil)
        XCTAssertEqual(policy.evaluate(settings: .init(), environment: unknown, now: now), .allowed)
    }

    func testChargingOnlyRequiresKnownExternalPower() {
        var policy = BackupAdmissionPolicy()
        let settings = BackupAdmissionSettings(onlyWhileCharging: true)
        var input = healthy
        XCTAssertEqual(policy.evaluate(settings: settings, environment: input, now: now).blocker, .charging)
        input.power = .unknown
        XCTAssertEqual(policy.evaluate(settings: settings, environment: input, now: now).blocker, .powerUnavailable)
        input.power = .charging
        XCTAssertTrue(policy.evaluate(settings: settings, environment: input, now: now).allowsNewPreparation)
    }

    func testBatteryRecoveryUsesFivePointHysteresisAndChargingBypassesFloor() {
        var policy = BackupAdmissionPolicy()
        let settings = BackupAdmissionSettings(minimumBatteryPercent: 30)
        var input = healthy
        input.batteryPercent = 29
        XCTAssertFalse(policy.evaluate(settings: settings, environment: input, now: now).allowsNewPreparation)
        input.batteryPercent = 30
        XCTAssertFalse(policy.evaluate(settings: settings, environment: input, now: now).allowsNewPreparation)
        input.batteryPercent = 34
        XCTAssertFalse(policy.evaluate(settings: settings, environment: input, now: now).allowsNewPreparation)
        input.batteryPercent = 35
        XCTAssertTrue(policy.evaluate(settings: settings, environment: input, now: now).allowsNewPreparation)
        input.batteryPercent = 30
        XCTAssertTrue(policy.evaluate(settings: settings, environment: input, now: now).allowsNewPreparation)
        input.batteryPercent = 5
        input.power = .charging
        XCTAssertTrue(policy.evaluate(settings: settings, environment: input, now: now).allowsNewPreparation)
    }

    func testUnknownBatteryCannotSatisfyEnabledFloor() {
        var policy = BackupAdmissionPolicy()
        var input = healthy
        input.batteryPercent = nil
        let result = policy.evaluate(settings: .init(minimumBatteryPercent: 20), environment: input, now: now)
        XCTAssertFalse(result.allowsNewPreparation)
        XCTAssertEqual(result.blocker, .powerUnavailable)
    }

    func testThermalReductionAndPauseRequireStableRecovery() {
        var policy = BackupAdmissionPolicy()
        let settings = BackupAdmissionSettings(reduceWhenHot: true)
        var input = healthy
        input.thermal = .fair
        let warm = policy.evaluate(settings: settings, environment: input, now: now)
        XCTAssertTrue(warm.allowsNewPreparation)
        XCTAssertEqual(warm.concurrencyLimit, 1)
        input.thermal = .serious
        XCTAssertEqual(policy.evaluate(settings: settings, environment: input, now: now).blocker, .heat)
        input.thermal = .nominal
        XCTAssertFalse(policy.evaluate(settings: settings, environment: input, now: now).allowsNewPreparation)
        XCTAssertFalse(policy.evaluate(settings: settings, environment: input,
                                       now: now.addingTimeInterval(59)).allowsNewPreparation)
        XCTAssertTrue(policy.evaluate(settings: settings, environment: input,
                                      now: now.addingTimeInterval(60)).allowsNewPreparation)
    }

    func testHeatReturningOrUnknownDuringRecoveryRestartsHold() {
        var policy = BackupAdmissionPolicy()
        let settings = BackupAdmissionSettings(reduceWhenHot: true)
        var input = healthy
        input.thermal = .critical
        _ = policy.evaluate(settings: settings, environment: input, now: now)
        input.thermal = .nominal
        _ = policy.evaluate(settings: settings, environment: input, now: now)
        input.thermal = .unknown
        XCTAssertFalse(policy.evaluate(settings: settings, environment: input,
                                       now: now.addingTimeInterval(59)).allowsNewPreparation)
        input.thermal = .fair
        XCTAssertFalse(policy.evaluate(settings: settings, environment: input,
                                       now: now.addingTimeInterval(60)).allowsNewPreparation)
        let recovered = policy.evaluate(settings: settings, environment: input, now: now.addingTimeInterval(120))
        XCTAssertTrue(recovered.allowsNewPreparation)
        XCTAssertEqual(recovered.concurrencyLimit, 1)
    }

    func testStorageIncludesOtherPreparationsAndHeadroomWithRecoveryMargin() {
        var policy = BackupAdmissionPolicy()
        let settings = BackupAdmissionSettings(protectFreeStorage: true)
        var input = healthy
        input.availableBytes = 4 * gib
        // One 2 GiB reservation plus another 2 GiB export plus 1 GiB headroom.
        let blocked = policy.evaluate(settings: settings, environment: input,
                                      reservedBytes: 2 * gib, now: now)
        XCTAssertEqual(blocked.blocker, .localStorage)
        XCTAssertEqual(blocked.storageBlockedSince, now)
        input.availableBytes = 5 * gib
        XCTAssertFalse(policy.evaluate(settings: settings, environment: input,
                                       reservedBytes: 2 * gib, now: now.addingTimeInterval(60)).allowsNewPreparation)
        input.availableBytes = 5 * gib + BackupAdmissionPolicy.storageRecoveryMargin
        let recovered = policy.evaluate(settings: settings, environment: input,
                                        reservedBytes: 2 * gib, now: now.addingTimeInterval(120))
        XCTAssertTrue(recovered.allowsNewPreparation)
        XCTAssertNil(recovered.storageBlockedSince)
    }

    func testUnavailableStorageIsNotTreatedAsInfiniteSpace() {
        var policy = BackupAdmissionPolicy()
        var input = healthy
        input.availableBytes = nil
        XCTAssertEqual(policy.evaluate(settings: .init(protectFreeStorage: true),
                                       environment: input, now: now).blocker, .storageUnavailable)
    }

    func testSettingsDisabledClearEveryLatchWithoutWaitingForRecovery() {
        var policy = BackupAdmissionPolicy()
        let blocked = BackupAdmissionEnvironment(power: .battery, batteryPercent: 1,
                                                 thermal: .critical, availableBytes: 0)
        _ = policy.evaluate(settings: .init(onlyWhileCharging: true, minimumBatteryPercent: 30,
                                           reduceWhenHot: true, protectFreeStorage: true),
                            environment: blocked, now: now)
        XCTAssertEqual(policy.evaluate(settings: .init(), environment: blocked, now: now), .allowed)
    }

    func testReservationEstimatesAreConservativeAndCannotOverflow() {
        XCTAssertEqual(BackupAdmissionPolicy.reservationBytes(estimatedBytes: nil), 2 * gib)
        XCTAssertEqual(BackupAdmissionPolicy.reservationBytes(estimatedBytes: -1), 2 * gib)
        XCTAssertEqual(BackupAdmissionPolicy.reservationBytes(estimatedBytes: 100), 200)
        XCTAssertEqual(BackupAdmissionPolicy.reservationBytes(estimatedBytes: .max), .max)
        XCTAssertEqual(BackupAdmissionPolicy.saturatedSum([.max, 1]), .max)
        var policy = BackupAdmissionPolicy()
        XCTAssertFalse(policy.evaluate(settings: .init(protectFreeStorage: true), environment: healthy,
                                       reservedBytes: .max, requestedBytes: .max, now: now).allowsNewPreparation)
    }
}

@MainActor
final class BackupAdmissionMonitorTests: XCTestCase {
    private let gib = BackupAdmissionPolicy.gibibyte

    func testExistingPreferencesDefaultToOffAndPersistOptIn() throws {
        let suite = "admission-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "backup.automatic")
        let original = BackupPreferences(defaults: defaults)
        XCTAssertFalse(original.admissionSettings.isEnabled)
        original.admissionSettings = .init(onlyWhileCharging: true, minimumBatteryPercent: 30,
                                           reduceWhenHot: true, protectFreeStorage: true)
        let restored = BackupPreferences(defaults: defaults)
        XCTAssertEqual(restored.admissionSettings, original.admissionSettings)
        XCTAssertTrue(restored.automaticBackup)
    }

    func testConcurrentPreparationReservationsCannotSpendSameFreeBytes() async {
        let capacity = AdmissionCapacity(4 * gib)
        let monitor = makeMonitor(capacity: capacity)
        await monitor.refresh()
        let first = UUID()
        XCTAssertTrue(monitor.reservePreparation(id: first))
        XCTAssertTrue(monitor.reservePreparation(id: first), "Repeated ownership is idempotent")
        XCTAssertFalse(monitor.reservePreparation(id: UUID()))
        XCTAssertEqual(monitor.reservedBytes, 2 * gib)
        XCTAssertEqual(monitor.decision.blocker, .localStorage)
    }

    func testReservationReleaseRefreshesCapacityAfterMaterialization() async {
        let capacity = AdmissionCapacity(4 * gib)
        let monitor = makeMonitor(capacity: capacity)
        await monitor.refresh()
        let first = UUID()
        XCTAssertTrue(monitor.reservePreparation(id: first))
        // The exported file now occupies 2 GiB. Dropping the reservation against
        // the old 4 GiB sample would incorrectly permit another unknown item.
        await capacity.set(2 * gib)
        monitor.releaseReservation(id: first)
        XCTAssertEqual(monitor.reservedBytes, 2 * gib)
        await monitor.refresh()
        XCTAssertEqual(monitor.reservedBytes, 0)
        XCTAssertFalse(monitor.reservePreparation(id: UUID()))
        await capacity.set(5 * gib)
        await monitor.refresh()
        XCTAssertTrue(monitor.reservePreparation(id: UUID()))
    }

    func testPowerAndClockInputsAreInjectableAndRecoverWithoutQueuePauseMutation() async {
        var current = BackupAdmissionEnvironment(power: .battery, batteryPercent: 10,
                                                thermal: .nominal, availableBytes: nil)
        var instant = Date(timeIntervalSince1970: 100)
        let monitor = BackupAdmissionMonitor(settings: .init(onlyWhileCharging: true),
                                             environment: { current }, capacity: { nil }, now: { instant })
        XCTAssertEqual(monitor.decision.blocker, .charging)
        current.power = .charging
        instant = instant.addingTimeInterval(1)
        await monitor.refresh()
        XCTAssertTrue(monitor.decision.allowsNewPreparation)
    }

    private func makeMonitor(capacity: AdmissionCapacity) -> BackupAdmissionMonitor {
        BackupAdmissionMonitor(settings: .init(protectFreeStorage: true),
                               environment: { .init(power: .charging, batteryPercent: 100,
                                                    thermal: .nominal, availableBytes: nil) },
                               capacity: { await capacity.read() },
                               now: { Date(timeIntervalSince1970: 1_000) })
    }
}

private actor AdmissionCapacity {
    private var bytes: Int64?
    init(_ bytes: Int64?) { self.bytes = bytes }
    func set(_ bytes: Int64?) { self.bytes = bytes }
    func read() -> Int64? { bytes }
}
