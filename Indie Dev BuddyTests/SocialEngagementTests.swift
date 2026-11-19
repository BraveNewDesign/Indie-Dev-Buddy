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

    @MainActor @Test func unknownReplyStatusCanBeTriagedWithoutInferringMissingReplies() throws {
        let suite = "social-engagement-tests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SocialEngagementStore(defaults: defaults)
        let identity = ContentRecipientIdentity(platform: "threads", server: try #require(URL(string: "https://graph.threads.net")), remoteID: "123")
        let key = SocialEngagementStore.CommentKey(profile: identity, postID: "post", commentID: "comment")
        let comment = SocialPost(id: "comment", text: "Example", authorID: "456")
        let sample = SocialEngagementStore.Thread(comments: [comment], incomplete: false, checkedAt: .now)

        #expect(store.replyStatus(for: key, in: sample) == .unknown)
        store.toggleNeedsReply(key)
        #expect(SocialEngagementStore(defaults: defaults).replyStatus(for: key, in: sample) == .needsReply)

        let reply = SocialPost(id: "reply", text: "Confirmed", authorID: identity.remoteID, parentID: comment.id)
        let withReply = SocialEngagementStore.Thread(comments: [comment, reply], incomplete: true, checkedAt: .now)
        #expect(store.replyStatus(for: key, in: withReply) == .replied)
        store.toggleDone(key)
        #expect(store.replyStatus(for: key, in: withReply) == .done)
        store.toggleDone(key)
        #expect(store.replyStatus(for: key, in: withReply) == .replied)
    }

    @Test(arguments: [SocialPlatform.x, .linkedIn])
    func backgroundConnectionCheckUsesOnlyLocalCredentials(platform: SocialPlatform) async throws {
        let account = SocialAccount(platform: platform, server: try #require(URL(string: "https://example.com")), remoteID: "123", username: "studio")
        let identity = SocialOAuthRegistration.identity(for: account)
        let credentials = MemoryCredentialStore()
        let transport = InsightsTransport()
        let connections = SocialConnections(credentialStore: credentials, metaTransport: transport)
        #expect(await connections.recover(identity, force: true) == .missingCredential)
        await credentials.save(SocialCredential(account: account, accessToken: "fixture"))
        #expect(await connections.recover(identity, force: true) == .ready)
        await credentials.save(SocialCredential(account: account, accessToken: "fixture", expiresAt: .distantPast))
        #expect(await connections.recover(identity, force: true) == .authorizationRequired)
        #expect(await transport.paths.isEmpty)
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
