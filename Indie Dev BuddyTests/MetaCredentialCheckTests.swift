import Foundation
import SocialKit
import Testing
@testable import Indie_Dev_Buddy

struct MetaCredentialCheckTests {
    @Test func transientRenewalFailureBacksOffAndRevocationRequiresReconnect() async throws {
        let now = Date()
        let credential = SocialCredential(account: account, accessToken: "still-stored-token",
                                          expiresAt: now.addingTimeInterval(24 * 60 * 60),
                                          metaLongLivedRefreshEligibleAt: .distantPast)
        let store = MemoryCredentialStore()
        await store.save(credential)
        let transport = CredentialCheckTransport([
            response(status: 429, code: 4),
            response(status: 400, code: 190)
        ])
        let connections = SocialConnections(credentialStore: store, metaTransport: transport)

        let delayed = await connections.checkMetaCredentials(now: now)
        #expect(delayed[account.id]?.contains("Credential check delayed") == true)
        #expect(await store.credential(for: account.id)?.accessToken == "still-stored-token")

        _ = await connections.checkMetaCredentials(force: true, now: now.addingTimeInterval(60))
        #expect(await transport.calls == 1)

        let revoked = await connections.checkMetaCredentials(now: now.addingTimeInterval(301))
        #expect(revoked[account.id]?.contains("Reconnect") == true)
        #expect(await transport.calls == 2)
        #expect(await store.credential(for: account.id)?.accessToken == "still-stored-token")
    }

    @Test func legacyUnknownExpiryVerifiesProfileWithoutAttemptingRenewal() async throws {
        let store = MemoryCredentialStore()
        await store.save(SocialCredential(account: account, accessToken: "legacy-token"))
        let transport = CredentialCheckTransport([
            HTTPResponse(statusCode: 200, body: Data(#"{"id":"abc","username":"studio"}"#.utf8))
        ])
        let connections = SocialConnections(credentialStore: store, metaTransport: transport)

        let status = await connections.checkMetaCredentials()
        #expect(status[account.id] == "Token expiry is unknown.")
        #expect(await transport.paths == ["/v1.0/me"])
        #expect(await store.credential(for: account.id)?.expiresAt == nil)
    }

    @Test func reconnectRejectsDifferentProfileBeforeSavingCredential() async throws {
        let store = MemoryCredentialStore()
        let original = account
        await store.save(SocialCredential(account: original, accessToken: "original-token"))
        let transport = CredentialCheckTransport([
            HTTPResponse(statusCode: 200, body: Data(#"{"id":"different","username":"other"}"#.utf8))
        ])
        let connections = SocialConnections(credentialStore: store, metaTransport: transport)
        await #expect(throws: ConnectionIdentityMismatch.self) {
            try await connections.importMetaToken(
                OAuthToken(accessToken: "replacement-token"), platform: .threads,
                expected: SocialOAuthRegistration.identity(for: original)
            )
        }
        #expect(await store.accounts().map(\.id) == [original.id])
        #expect(await store.credential(for: original.id)?.accessToken == "original-token")
    }

    @Test func savedMastodonConnectionDistinguishesRateLimitingAndRevocation() async throws {
        let instance = try #require(URL(string: "https://social.example"))
        let account = SocialAccount(platform: .mastodon, server: instance, remoteID: "123", username: "studio")
        let identity = SocialOAuthRegistration.identity(for: account)
        let store = MemoryCredentialStore()
        await store.save(SocialCredential(account: account, accessToken: "saved-token"))
        let transport = CredentialCheckTransport([HTTPResponse(statusCode: 429, headers: ["Retry-After": "600"])])
        let connections = SocialConnections(credentialStore: store, metaTransport: transport)
        if case .rateLimited = await connections.recover(identity, force: true) {} else {
            Issue.record("Expected a provider rate limit")
        }
        if case .rateLimited = await connections.recover(identity, force: true) {} else {
            Issue.record("Expected a provider rate limit")
        }
        #expect(await transport.paths == ["/api/v1/accounts/verify_credentials"])
        #expect(await store.credential(for: account.id)?.accessToken == "saved-token")

        let revoked = SocialConnections(credentialStore: store,
                                        metaTransport: CredentialCheckTransport([HTTPResponse(statusCode: 401)]))
        #expect(await revoked.recover(identity, force: true) == .authorizationRequired)
        #expect(await store.credential(for: account.id)?.accessToken == "saved-token")
    }

    @Test func savedBlueskyRefreshGrantRepairsExpiredAccessToken() async throws {
        let server = try #require(URL(string: "https://bsky.example"))
        let account = SocialAccount(platform: .bluesky, server: server, remoteID: "did:plc:fixture", username: "studio")
        let store = MemoryCredentialStore()
        await store.save(SocialCredential(account: account, accessToken: "expired-access", refreshToken: "saved-refresh"))
        let transport = CredentialCheckTransport([
            HTTPResponse(statusCode: 400, body: Data(#"{"error":"ExpiredToken"}"#.utf8)),
            HTTPResponse(statusCode: 200, body: Data(#"{"did":"did:plc:fixture","handle":"studio","accessJwt":"new-access","refreshJwt":"new-refresh"}"#.utf8))
        ])
        let connections = SocialConnections(credentialStore: store, metaTransport: transport)
        let identity = SocialOAuthRegistration.identity(for: account)
        #expect(await connections.recover(identity, force: true) == .renewed)
        #expect(await transport.paths == ["/xrpc/com.atproto.server.getSession", "/xrpc/com.atproto.server.refreshSession"])
        #expect(await store.credential(for: account.id)?.refreshToken == "new-refresh")
    }

    @Test func manualRetryRechecksRejectedSavedTokenAndReportsMissingCredential() async throws {
        let store = MemoryCredentialStore()
        let account = account
        let identity = SocialOAuthRegistration.identity(for: account)
        let transport = CredentialCheckTransport([
            response(status: 400, code: 190),
            HTTPResponse(statusCode: 200, body: Data(#"{"id":"abc","username":"studio"}"#.utf8))
        ])
        let connections = SocialConnections(credentialStore: store, metaTransport: transport)
        #expect(await connections.recover(identity, force: true, manual: true) == .missingCredential)
        await store.save(SocialCredential(account: account, accessToken: "saved-token"))
        #expect(await connections.recover(identity, force: true) == .authorizationRequired)
        #expect(await connections.recover(identity, force: true, manual: true) == .ready)
        #expect(await transport.calls == 2)
    }

    private var account: SocialAccount {
        SocialAccount(platform: .threads, server: URL(string: "https://graph.threads.net")!,
                      remoteID: "abc", username: "studio")
    }

    private func response(status: Int, code: Int) -> HTTPResponse {
        HTTPResponse(statusCode: status, body: Data(#"{"error":{"code":\#(code)}}"#.utf8))
    }
}

private actor CredentialCheckTransport: HTTPTransport {
    private var responses: [HTTPResponse]
    private(set) var paths: [String] = []
    var calls: Int { paths.count }

    init(_ responses: [HTTPResponse]) { self.responses = responses }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        paths.append(request.url?.path ?? "")
        guard !responses.isEmpty else { throw SocialError.transportFailure }
        return responses.removeFirst()
    }
}
