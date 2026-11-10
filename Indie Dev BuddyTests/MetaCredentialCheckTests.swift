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
