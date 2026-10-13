import XCTest
@testable import PhotosBackup

@MainActor
final class BackupNotificationTests: XCTestCase {
    func testPermissionDenialDoesNotRequestAgainOrBlockBackup() async throws {
        let (defaults, suite) = try temporaryDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let delivery = FakeBackupNotifications()
        delivery.permissionAllowed = false
        delivery.authorized = false
        let controller = BackupNotificationController(delivery: delivery, defaults: defaults)
        XCTAssertEqual(delivery.permissionRequests, 0, "Construction must not show a permission prompt")
        let allowed = await controller.requestPermission()
        XCTAssertFalse(allowed)
        XCTAssertTrue(controller.permissionDescription.contains("not allowed"))
        controller.enabled = true
        await controller.consider(session(.completed), account: "scope-one")
        XCTAssertTrue(delivery.messages.isEmpty)
        XCTAssertEqual(delivery.permissionRequests, 1, "Decisions must never prompt automatically")
    }

    func testCompletionIsDeduplicatedAcrossRetriesAndRelaunch() async throws {
        let (defaults, suite) = try temporaryDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let delivery = FakeBackupNotifications()
        let first = BackupNotificationController(delivery: delivery, defaults: defaults)
        first.enabled = true
        let finished = session(.completed)
        await first.consider(finished, account: "scope-one")
        await first.consider(finished, account: "scope-one")
        XCTAssertEqual(delivery.messages.map(\.kind), [.completed])
        let relaunchedDelivery = FakeBackupNotifications()
        let relaunched = BackupNotificationController(delivery: relaunchedDelivery, defaults: defaults)
        relaunched.enabled = true
        await relaunched.consider(finished, account: "scope-one")
        XCTAssertTrue(relaunchedDelivery.messages.isEmpty)
    }

    func testAccountSwitchWhileAuthorizationAwaitsDiscardsOldNotice() async throws {
        let (defaults, suite) = try temporaryDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let delivery = FakeBackupNotifications()
        let entered = expectation(description: "Authorization query is in flight")
        delivery.authorizationStarted = entered
        delivery.holdAuthorization = true
        let controller = BackupNotificationController(delivery: delivery, defaults: defaults)
        controller.enabled = true
        let finished = session(.completed)
        let pending = Task { await controller.consider(finished, account: "scope-one") }
        await fulfillment(of: [entered], timeout: 2)
        controller.activate(account: "scope-two", session: UUID())
        delivery.resolveAuthorization(true)
        await pending.value
        XCTAssertTrue(delivery.messages.isEmpty)
    }

    func testSameSessionBecomingPausedDuringAuthorizationCannotNotifyCompletion() async throws {
        let (defaults, suite) = try temporaryDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let delivery = FakeBackupNotifications()
        let entered = expectation(description: "Completion authorization is awaiting")
        delivery.authorizationStarted = entered
        delivery.holdAuthorization = true
        let controller = BackupNotificationController(delivery: delivery, defaults: defaults)
        controller.enabled = true
        let finished = session(.completed)
        let pending = Task { await controller.consider(finished, account: "scope-one") }
        await fulfillment(of: [entered], timeout: 2)
        var paused = finished
        paused.outcome = .paused
        paused.finishedAt = nil
        await controller.consider(paused, account: "scope-one")
        delivery.resolveAuthorization(true)
        await pending.value
        XCTAssertTrue(delivery.messages.isEmpty)
    }

    func testIncompleteDeferredPausedAndOrdinaryWorkingSessionsStayQuiet() async throws {
        let (defaults, suite) = try temporaryDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let delivery = FakeBackupNotifications()
        let controller = BackupNotificationController(delivery: delivery, defaults: defaults)
        controller.enabled = true
        for outcome in [BackupSession.Outcome.scanning, .incomplete, .deferred, .paused, .working, .stopped] {
            await controller.consider(session(outcome), account: "scope-one")
        }
        XCTAssertTrue(delivery.messages.isEmpty)
        await controller.consider(session(.completedWithFailures), account: "scope-one")
        XCTAssertEqual(delivery.messages.map(\.kind), [.failures])
        XCTAssertEqual(delivery.messages.first?.targetTab, 2)
    }

    func testActionNoticesAreDeduplicatedAndContainNoItemOrAccountData() async throws {
        let (defaults, suite) = try temporaryDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let delivery = FakeBackupNotifications()
        let controller = BackupNotificationController(delivery: delivery, defaults: defaults)
        controller.enabled = true
        var waiting = session(.needsAttention)
        waiting.failedAssets = ["private-photo-identifier"]
        await controller.consider(waiting, account: "private-account-scope", problem: .account)
        await controller.consider(waiting, account: "private-account-scope", problem: .account)
        await controller.consider(waiting, account: "private-account-scope", problem: .remoteStorage)
        XCTAssertEqual(delivery.messages.map(\.kind), [.account, .remoteStorage])
        for message in delivery.messages {
            XCTAssertEqual(message.targetTab, 3)
            XCTAssertFalse((message.title + message.body).contains("private-"))
            XCTAssertFalse(message.body.contains(waiting.id.uuidString))
        }
    }

    func testObsoleteAndInvalidActionsAreIgnoredAndColdStartActionIsReconciled() throws {
        let (defaults, suite) = try temporaryDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = BackupNotificationController(delivery: FakeBackupNotifications(), defaults: defaults)
        let current = UUID()
        controller.open(session: current, tab: 2)
        XCTAssertNil(controller.destinationTab)
        controller.activate(account: "scope-one", session: current)
        XCTAssertEqual(controller.destinationTab, 2, "Cold-start action should resolve after account/session restoration")
        controller.activate(account: "scope-two", session: UUID())
        XCTAssertNil(controller.destinationTab)
        controller.open(session: current, tab: 2)
        XCTAssertNil(controller.destinationTab)
        let next = UUID()
        controller.activate(account: "scope-two", session: next)
        controller.open(session: next, tab: 999)
        XCTAssertNil(controller.destinationTab)
        controller.open(session: next, tab: 3)
        XCTAssertEqual(controller.destinationTab, 3)
    }

    func testPersistentStorageBlockUsesInjectedTimeAndSurvivesRelaunch() async throws {
        let (defaults, suite) = try temporaryDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        var clock = Date(timeIntervalSince1970: 10_000)
        let blocked = session(.paused)
        let delivery = FakeBackupNotifications()
        let controller = BackupNotificationController(delivery: delivery, defaults: defaults, now: { clock })
        controller.enabled = true
        await controller.consider(blocked, account: "scope-one", localStorageBlocked: true)
        XCTAssertTrue(delivery.messages.isEmpty)
        clock = clock.addingTimeInterval(901)
        let relaunchedDelivery = FakeBackupNotifications()
        let relaunched = BackupNotificationController(delivery: relaunchedDelivery, defaults: defaults, now: { clock })
        relaunched.enabled = true
        await relaunched.consider(blocked, account: "scope-one", localStorageBlocked: true)
        XCTAssertEqual(relaunchedDelivery.messages.map(\.kind), [.localStorage])
        await relaunched.consider(blocked, account: "scope-one", localStorageBlocked: true)
        XCTAssertEqual(relaunchedDelivery.messages.count, 1)
        await controller.consider(blocked, account: "scope-one", localStorageBlocked: false)
        await relaunched.consider(blocked, account: "scope-one", localStorageBlocked: false)
    }

    func testFailedDeliveryReleasesClaimSoNextOpportunityCanRetry() async throws {
        let (defaults, suite) = try temporaryDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let delivery = FakeBackupNotifications()
        delivery.shouldFailDelivery = true
        let controller = BackupNotificationController(delivery: delivery, defaults: defaults)
        controller.enabled = true
        let finished = session(.completed)
        await controller.consider(finished, account: "scope-one")
        XCTAssertTrue(delivery.messages.isEmpty)
        delivery.shouldFailDelivery = false
        await controller.consider(finished, account: "scope-one")
        XCTAssertEqual(delivery.messages.count, 1)
    }

    private func session(_ outcome: BackupSession.Outcome) -> BackupSession {
        var result = BackupSession(now: Date(timeIntervalSince1970: 100), scanComplete: outcome.isComplete)
        result.outcome = outcome
        result.finishedAt = outcome.isComplete ? Date(timeIntervalSince1970: 101) : nil
        return result
    }

    private func temporaryDefaults() throws -> (UserDefaults, String) {
        let suite = "notification-tests.\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
    }
}

@MainActor
private final class FakeBackupNotifications: BackupNotificationDelivering {
    enum Failure: Error { case rejected }
    var permissionAllowed = true
    var authorized = true
    var permissionRequests = 0
    var messages: [BackupNotificationMessage] = []
    var removed: [String] = []
    var shouldFailDelivery = false
    var holdAuthorization = false
    var authorizationStarted: XCTestExpectation?
    private var authorizationContinuation: CheckedContinuation<Bool, Never>?

    func requestPermission() async -> Bool {
        permissionRequests += 1
        return permissionAllowed
    }
    func isAuthorized() async -> Bool {
        authorizationStarted?.fulfill()
        guard holdAuthorization else { return authorized }
        return await withCheckedContinuation { authorizationContinuation = $0 }
    }
    func resolveAuthorization(_ allowed: Bool) {
        authorizationContinuation?.resume(returning: allowed)
        authorizationContinuation = nil
    }
    func deliver(_ message: BackupNotificationMessage) async throws {
        if shouldFailDelivery { throw Failure.rejected }
        messages.append(message)
    }
    func remove(_ identifiers: [String]) { removed.append(contentsOf: identifiers) }
}
