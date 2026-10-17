import XCTest
@testable import PhotosBackup

final class DashboardBackupStatusTests: XCTestCase {
    func testPastCompletionsDoNotProveTheCurrentSelectionIsBackedUp() {
        let status = DashboardBackupStatus(accountUsable: true, pauseReason: nil,
                                           remaining: 0, failed: 0, completed: 500, hasSelectedAlbums: true)
        XCTAssertEqual(status.title, "No uploads waiting")
        XCTAssertEqual(status.detail, "No pending uploads. Use Back Up Now to check your selected albums.")
    }

    func testNewSelectionWithoutQueueHistoryDoesNotClaimCompletion() {
        let status = DashboardBackupStatus(accountUsable: true, pauseReason: nil,
                                           remaining: 0, failed: 0, completed: 0, hasSelectedAlbums: true)
        XCTAssertEqual(status.title, "Ready to back up")
        XCTAssertTrue(status.detail.contains("Back Up Now"))
    }

    func testNoSelectionDirectsUserToChooseAlbums() {
        let status = DashboardBackupStatus(accountUsable: true, pauseReason: nil,
                                           remaining: 0, failed: 0, completed: 500, hasSelectedAlbums: false)
        XCTAssertEqual(status.detail, "Choose albums to protect")
    }

    func testAccountPausePendingAndFailureStatesKeepTheirPriority() {
        let disconnected = DashboardBackupStatus(accountUsable: false, pauseReason: "Waiting for Wi-Fi",
                                                 remaining: 2, failed: 1, completed: 500, hasSelectedAlbums: true)
        XCTAssertEqual(disconnected.title, "Connect to back up")
        let paused = DashboardBackupStatus(accountUsable: true, pauseReason: "Waiting for Wi-Fi",
                                           remaining: 2, failed: 1, completed: 500, hasSelectedAlbums: true)
        XCTAssertEqual(paused.title, "Backup paused")
        XCTAssertEqual(paused.detail, "Waiting for Wi-Fi")
        let pending = DashboardBackupStatus(accountUsable: true, pauseReason: nil,
                                            remaining: 2, failed: 1, completed: 500, hasSelectedAlbums: true)
        XCTAssertEqual(pending.title, "Backing up…")
        XCTAssertEqual(pending.detail, "2 items remaining")
        let failed = DashboardBackupStatus(accountUsable: true, pauseReason: nil,
                                           remaining: 0, failed: 1, completed: 500, hasSelectedAlbums: true)
        XCTAssertEqual(failed.title, "Backup needs attention")
    }
}
