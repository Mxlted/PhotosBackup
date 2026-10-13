import XCTest
@testable import PhotosBackup

final class CredentialStoreTests: XCTestCase {

    /// An unsigned build has no keychain-access-group, so the Keychain refuses
    /// every write. That is an environment limit, not a bad credential -- the
    /// account has to stay usable for the session instead of reading as
    /// rejected. Observed live on 2026-09-08 as a yellow Uploads page.
    func testAWriteFailureStillYieldsAUsableCredential() async throws {
        struct RefusingStore: SecretStore {
            func read() throws -> Data? { nil }
            func write(_ data: Data) throws { throw CredentialStore.Failure.keychain(errSecMissingEntitlement) }
            func delete() throws {}
        }
        let store = CredentialStore(secrets: RefusingStore())
        do {
            _ = try await store.save(result())
            XCTFail("expected the write to fail")
        } catch let unpersisted as CredentialStore.Unpersisted {
            XCTAssertEqual(unpersisted.credential.email, "person@gmail.com")
            XCTAssertFalse(unpersisted.credential.authData.isEmpty)
            XCTAssertFalse(unpersisted.reason.isEmpty)
        }
    }

    /// A bound token is the opposite case: refused outright, never persisted.
    func testABoundTokenIsRefusedRatherThanReportedAsUnpersisted() async {
        let store = CredentialStore(secrets: MemorySecretStore())
        do {
            _ = try await store.save(result(encrypted: true))
            XCTFail("expected a bound token to be refused")
        } catch let failure as CredentialStore.Failure {
            XCTAssertEqual(failure, .bound)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }


    private func result(encrypted: Bool = false, email: String = "person@gmail.com") -> TokenExchange.Result {
        let authData = TokenExchange.googlePhotosCredentialBody(
            androidId: "0123456789abcdef", email: email, masterToken: "aas_et/master")
        return TokenExchange.Result(androidId: "0123456789abcdef", email: email,
                                    masterToken: "aas_et/master", photosAccessToken: "ya29.token",
                                    photosTokenExpiry: Date(timeIntervalSince1970: 1_900_000_000),
                                    authData: authData, encrypted: encrypted)
    }

    func testSavedCredentialSurvivesANewStoreOverTheSameSecrets() async throws {
        let secrets = MemorySecretStore()
        let saved = try await CredentialStore(secrets: secrets).save(result())
        XCTAssertEqual(saved.email, "person@gmail.com")
        XCTAssertEqual(saved.masterToken, "aas_et/master")

        // A fresh store, as on the next launch, reads the same record back.
        let reloaded = try await CredentialStore(secrets: secrets).load()
        XCTAssertEqual(reloaded, saved)
    }

    func testWhatIsSavedIsWhatGPMCClientCanConsume() async throws {
        let secrets = MemorySecretStore()
        _ = try await CredentialStore(secrets: secrets).save(result())
        let loaded = try await CredentialStore(secrets: secrets).load()
        let credential = try XCTUnwrap(loaded)
        let auth = try AuthData(credential.authData)
        XCTAssertEqual(auth.values["Email"], "person@gmail.com")
        XCTAssertEqual(auth.values["Token"], "aas_et/master")
        XCTAssertNoThrow(try GPMCClient(authData: credential.authData))
    }

    func testBoundTokenIsNeverWrittenToDisk() async {
        let secrets = MemorySecretStore()
        do {
            _ = try await CredentialStore(secrets: secrets).save(result(encrypted: true))
            XCTFail("expected a bound token to be refused")
        } catch let failure as CredentialStore.Failure {
            XCTAssertEqual(failure, .bound)
        } catch {
            XCTFail("expected CredentialStore.Failure.bound, got \(error)")
        }
        XCTAssertNil(try? secrets.read())
        XCTAssertEqual(secrets.writes, 0)
    }

    func testNoCredentialYetReadsAsNilRatherThanAnError() async throws {
        let loaded = try await CredentialStore(secrets: MemorySecretStore()).load()
        XCTAssertNil(loaded)
    }

    func testAnUnreadableBlobIsDiscardedRatherThanFailingEveryLaunch() async {
        let secrets = MemorySecretStore(Data("not json".utf8))
        do {
            _ = try await CredentialStore(secrets: secrets).load()
            XCTFail("expected the corrupt blob to be reported")
        } catch let failure as CredentialStore.Failure {
            XCTAssertEqual(failure, .corrupt)
        } catch {
            XCTFail("expected CredentialStore.Failure.corrupt, got \(error)")
        }
        XCTAssertNil(try? secrets.read())
    }

    func testClearRemovesTheStoredCredential() async throws {
        let secrets = MemorySecretStore()
        let store = CredentialStore(secrets: secrets)
        _ = try await store.save(result())
        await store.clear()
        XCTAssertNil(try secrets.read())
        let reloaded = try await store.load()
        XCTAssertNil(reloaded)
    }

    func testKeychainRoundTrip() throws {
        let store = KeychainSecretStore(service: "com.g8row.photosbackup.tests", account: UUID().uuidString)
        addTeardownBlock { try? store.delete() }
        do {
            try store.write(Data("first".utf8))
        } catch {
            // An unsigned simulator build can be refused a keychain item
            // (errSecMissingEntitlement). That is an environment limitation,
            // not a bug in the store, so skip rather than fail.
            throw XCTSkip("Keychain unavailable in this build: \(error.localizedDescription)")
        }
        XCTAssertEqual(try store.read(), Data("first".utf8))
        try store.write(Data("second".utf8))
        XCTAssertEqual(try store.read(), Data("second".utf8), "a second write must update, not duplicate")
        try store.delete()
        XCTAssertNil(try store.read())
        XCTAssertNoThrow(try store.delete(), "deleting a missing item is not an error")
    }
}

@MainActor
final class PhotosAccountTests: XCTestCase {

    private func result(email: String = "person@gmail.com", encrypted: Bool = false) -> TokenExchange.Result {
        TokenExchange.Result(androidId: "0123456789abcdef", email: email, masterToken: "aas_et/master",
                             photosAccessToken: "ya29.token", photosTokenExpiry: nil,
                             authData: TokenExchange.googlePhotosCredentialBody(
                                androidId: "0123456789abcdef", email: email, masterToken: "aas_et/master"),
                             encrypted: encrypted)
    }

    func testRestoreWithNothingStoredIsDisconnected() async {
        let account = PhotosAccount(store: CredentialStore(secrets: MemorySecretStore()))
        await account.restore()
        XCTAssertEqual(account.status, .disconnected)
        XCTAssertNil(account.currentClient())
    }

    func testConnectThenRestoreKeepsTheAccount() async {
        let secrets = MemorySecretStore()
        let account = PhotosAccount(store: CredentialStore(secrets: secrets))
        await account.connect(result())
        XCTAssertTrue(account.status.isUsable)
        XCTAssertNotNil(account.currentClient())

        let relaunched = PhotosAccount(store: CredentialStore(secrets: secrets))
        await relaunched.restore()
        XCTAssertEqual(relaunched.status.email, "person@gmail.com")
        XCTAssertTrue(relaunched.status.isUsable)
    }

    func testBoundTokenLeavesTheAccountRejectedNotConnected() async {
        let account = PhotosAccount(store: CredentialStore(secrets: MemorySecretStore()))
        await account.connect(result(encrypted: true))
        XCTAssertFalse(account.status.isUsable)
        guard case .rejected(_, let reason) = account.status else { return XCTFail("expected .rejected") }
        XCTAssertTrue(reason.contains("bound"))
        XCTAssertNil(account.currentClient())
    }

    func testOnlyCredentialErrorsChangeTheAccountState() async {
        let account = PhotosAccount(store: CredentialStore(secrets: MemorySecretStore()))
        await account.connect(result())
        account.report(GPMCError(kind: .transport, message: "no network"))
        XCTAssertTrue(account.status.isUsable, "a network blip must not disconnect the account")
        account.report(GPMCError(kind: .server(500), message: "boom"))
        XCTAssertTrue(account.status.isUsable)
        account.report(GPMCError(kind: .credentialRejected, message: "Connect the account again."))
        XCTAssertFalse(account.status.isUsable)
        XCTAssertEqual(account.status.email, "person@gmail.com")
        XCTAssertNil(account.currentClient())
    }

    func testDisconnectClearsTheStoredCredential() async {
        let secrets = MemorySecretStore()
        let account = PhotosAccount(store: CredentialStore(secrets: secrets))
        await account.connect(result())
        await account.disconnect()
        XCTAssertEqual(account.status, .disconnected)
        XCTAssertNil(try? secrets.read())
    }

    func testLateRejectionCannotRejectAReconnectedAccount() async {
        let pending = PendingVerification()
        let account = PhotosAccount(store: CredentialStore(secrets: MemorySecretStore()),
                                    verifyClient: { _ in try await pending.run() })
        await account.connect(result())
        let check = Task { await account.verify() }
        await fulfillment(of: [pending.started], timeout: 2)

        // Even reconnecting the same address creates a different credential.
        await account.connect(result())
        let replacement = account.currentClient()
        pending.finish(throwing: GPMCError(kind: .credentialRejected, message: "Old credential rejected"))

        let outcome = await check.value
        XCTAssertEqual(outcome, .superseded)
        XCTAssertTrue(account.status.isUsable)
        XCTAssertTrue(account.currentClient() === replacement)
        XCTAssertFalse(account.verifying)
    }

    func testLateSuccessCannotVerifyANewAccount() async {
        let pending = PendingVerification()
        let account = PhotosAccount(store: CredentialStore(secrets: MemorySecretStore()),
                                    verifyClient: { _ in try await pending.run() })
        await account.connect(result())
        let check = Task { await account.verify() }
        await fulfillment(of: [pending.started], timeout: 2)

        await account.connect(result(email: "new@example.test"))
        let replacementStatus = account.status
        pending.finish()

        let outcome = await check.value
        XCTAssertEqual(outcome, .superseded)
        XCTAssertEqual(account.status, replacementStatus)
    }

    func testLateRejectionAfterDisconnectKeepsAccountDisconnected() async {
        let pending = PendingVerification()
        let account = PhotosAccount(store: CredentialStore(secrets: MemorySecretStore()),
                                    verifyClient: { _ in try await pending.run() })
        await account.connect(result())
        let check = Task { await account.verify() }
        await fulfillment(of: [pending.started], timeout: 2)

        await account.disconnect()
        pending.finish(throwing: GPMCError(kind: .credentialRejected, message: "Old credential rejected"))

        let outcome = await check.value
        XCTAssertEqual(outcome, .superseded)
        XCTAssertEqual(account.status, .disconnected)
        XCTAssertNil(account.currentClient())
    }

    func testCurrentVerificationStillReportsSuccessAndRejection() async {
        let pending = PendingVerification()
        let account = PhotosAccount(store: CredentialStore(secrets: MemorySecretStore()),
                                    verifyClient: { _ in try await pending.run() })
        await account.connect(result())
        let check = Task { await account.verify() }
        await fulfillment(of: [pending.started], timeout: 2)
        pending.finish()
        let outcome = await check.value
        XCTAssertEqual(outcome, .succeeded)
        XCTAssertTrue(account.status.isUsable)

        let rejected = PhotosAccount(store: CredentialStore(secrets: MemorySecretStore()),
                                     verifyClient: { _ in
            throw GPMCError(kind: .credentialRejected, message: "Credential rejected")
        })
        await rejected.connect(result())
        let rejection = await rejected.verify()
        XCTAssertEqual(rejection, .failed("Credential rejected"))
        XCTAssertFalse(rejected.status.isUsable)
        XCTAssertNil(rejected.currentClient())
    }
}

@MainActor
private final class PendingVerification {
    let started = XCTestExpectation(description: "Verification suspended")
    private var continuation: CheckedContinuation<Void, Error>?

    func run() async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            started.fulfill()
        }
    }

    func finish(throwing error: Error? = nil) {
        if let error { continuation?.resume(throwing: error) }
        else { continuation?.resume() }
        continuation = nil
    }
}
