import XCTest
@testable import PhotosBackup

final class BlackScreenBackupTests: XCTestCase {
    @MainActor
    func testInterruptionRestoresAutoLockAndReturningReacquiresIt() {
        var disabled = false
        let session = BlackScreenAwakeSession(readIdleTimer: { disabled }, writeIdleTimer: { disabled = $0 })

        session.update(isVisible: true, isActive: true)
        XCTAssertTrue(disabled)
        // Repeated appearance must not replace the saved false with true.
        session.update(isVisible: true, isActive: true)
        session.update(isVisible: true, isActive: false)
        XCTAssertFalse(disabled, "Calls, Control Center, and backgrounding must release the override")

        session.update(isVisible: true, isActive: true)
        XCTAssertTrue(disabled)
        session.update(isVisible: false, isActive: true)
        XCTAssertFalse(disabled, "Exiting the mode must restore normal auto-lock")
    }

    @MainActor
    func testDismissalWhileInactiveCannotReenableTheOverride() {
        var disabled = false
        let session = BlackScreenAwakeSession(readIdleTimer: { disabled }, writeIdleTimer: { disabled = $0 })
        session.update(isVisible: true, isActive: true)
        session.update(isVisible: true, isActive: false)
        session.update(isVisible: false, isActive: false)
        session.update(isVisible: false, isActive: true)
        XCTAssertFalse(disabled)
    }

    @MainActor
    func testRestoresExistingIdleTimerSettingAndRecapturesOnNextActivation() {
        var disabled = true
        let session = BlackScreenAwakeSession(readIdleTimer: { disabled }, writeIdleTimer: { disabled = $0 })
        session.update(isVisible: true, isActive: true)
        session.update(isVisible: true, isActive: false)
        XCTAssertTrue(disabled)

        disabled = false
        session.update(isVisible: true, isActive: true)
        session.update(isVisible: false, isActive: true)
        XCTAssertFalse(disabled)
    }

    func testAPausedQueueExplainsWhyItIsNotUploading() {
        let status = BlackScreenBackupStatus(accountUsable: true, pauseReason: "Waiting for Wi-Fi",
                                             remaining: 100, failed: 0, waitingForICloud: 0)
        XCTAssertEqual(status.title, "Backup paused")
        XCTAssertEqual(status.detail, "Waiting for Wi-Fi")
    }

    func testFailedAndUnconnectedQueuesNeverClaimCompletion() {
        let failed = BlackScreenBackupStatus(accountUsable: true, pauseReason: nil,
                                             remaining: 0, failed: 2, waitingForICloud: 0)
        XCTAssertEqual(failed.title, "Backup needs attention")
        let disconnected = BlackScreenBackupStatus(accountUsable: false, pauseReason: "Waiting for Wi-Fi",
                                                   remaining: 100, failed: 0, waitingForICloud: 0)
        XCTAssertEqual(disconnected.title, "Connect to back up")
        let empty = BlackScreenBackupStatus(accountUsable: true, pauseReason: nil,
                                            remaining: 0, failed: 0, waitingForICloud: 0)
        XCTAssertEqual(empty.title, "Queue is clear", "An empty queue does not prove every album was scanned")
    }
}
