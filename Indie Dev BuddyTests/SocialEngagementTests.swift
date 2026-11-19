import Foundation
import SocialKit
import Testing
@testable import Indie_Dev_Buddy

struct SocialEngagementTests {
    @MainActor @Test func meteredAndUnverifiedProfilesSkipAutomaticRefresh() async {
        let store = SocialEngagementStore()
        let connections = SocialConnections(credentialStore: MemoryCredentialStore())
        for platform in [SocialPlatform.x, .linkedIn] {
            let identity = ContentRecipientIdentity(
                platform: platform.rawValue, server: URL(fileURLWithPath: "/"), remoteID: "123"
            )
            await store.refresh(identity, inbox: true, manual: false, using: connections)
            await store.refresh(identity, inbox: false, manual: false, using: connections)
            #expect(store.profiles[identity] == nil)
        }
    }

    @Test func threadsInsightsKeepZeroAndOmitUnavailableCounts() async throws {
        let account = SocialAccount(platform: .threads, server: try #require(URL(string: "https://graph.threads.net")), remoteID: "123", username: "studio")
        let credentials = MemoryCredentialStore()
        await credentials.save(SocialCredential(account: account, accessToken: "fixture", grantedScopes: ["threads_manage_insights"]))
        let transport = InsightsTransport()
        let connections = SocialConnections(credentialStore: credentials, metaTransport: transport)

        let counts = try await connections.postInsights("456", for: SocialOAuthRegistration.identity(for: account))

        #expect(counts == ["views": 0, "likes": 12])
        #expect(await transport.paths == ["/v1.0/456/insights"])
    }
}

private actor InsightsTransport: HTTPTransport {
    private(set) var paths: [String] = []

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        paths.append(request.url?.path ?? "")
        let body = """
        {"data":[
            {"name":"views","values":[{"value":0}]},
            {"name":"likes","total_value":{"value":12}},
            {"name":"reposts","values":[{"value":null}]},
            {"name":"quotes","values":[{"value":{"unexpected":1}}]},
            {"name":"unrequested","values":[{"value":99}]}
        ]}
        """
        return HTTPResponse(statusCode: 200, body: Data(body.utf8))
    }
}
