import SwiftUI
import XCTest
@testable import PhotosBackup

@MainActor
final class AccountConnectWebViewTests: XCTestCase {
    func testOnlyExactGoogleAccountCookieDomainsAreAccepted() async throws {
        var captured: [String] = []
        let coordinator = EmbeddedSetupWebView.Coordinator(loading: .constant(false)) { captured.append($0) }
        for domain in ["accounts.google.com.example.test", "fakeaccounts.google.com", "example.test"] {
            coordinator.capture(from: [try cookie(domain: domain)])
        }
        await drainHandoff()
        XCTAssertTrue(captured.isEmpty)

        coordinator.capture(from: [try cookie(domain: "accounts.google.com")])
        await drainHandoff()
        XCTAssertEqual(captured, ["test-token"])
    }

    func testDomainCookieAndDuplicateCallbacksDeliverOnlyOnce() async throws {
        var captured: [String] = []
        let coordinator = EmbeddedSetupWebView.Coordinator(loading: .constant(false)) { captured.append($0) }
        let cookies = [try cookie(domain: ".accounts.google.com")]
        coordinator.capture(from: cookies)
        coordinator.capture(from: cookies)
        await drainHandoff()
        XCTAssertEqual(captured, ["test-token"])
    }

    func testCookieReadFinishingAfterDismissalCannotCaptureToken() async throws {
        var captured: [String] = []
        let coordinator = EmbeddedSetupWebView.Coordinator(loading: .constant(false)) { captured.append($0) }
        coordinator.stop()
        coordinator.capture(from: [try cookie(domain: "accounts.google.com")])
        await drainHandoff()
        XCTAssertTrue(captured.isEmpty)
    }

    func testDismissalBetweenCaptureAndQueuedHandoffDoesNotSpendToken() async throws {
        var captured: [String] = []
        let coordinator = EmbeddedSetupWebView.Coordinator(loading: .constant(false)) { captured.append($0) }
        coordinator.capture(from: [try cookie(domain: "accounts.google.com")])
        coordinator.stop()
        await drainHandoff()
        XCTAssertTrue(captured.isEmpty)
    }

    private func cookie(domain: String) throws -> HTTPCookie {
        try XCTUnwrap(HTTPCookie(properties: [
            .domain: domain, .path: "/", .name: "oauth_token", .value: "test-token", .secure: "TRUE",
        ]))
    }

    /// A FIFO sentinel after capture's main-queue callback; no timing delay.
    private func drainHandoff() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
