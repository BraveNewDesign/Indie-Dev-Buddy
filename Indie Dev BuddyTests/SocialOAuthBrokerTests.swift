import Foundation
import SocialKit
import Testing
@testable import Indie_Dev_Buddy

struct SocialOAuthBrokerTests {
    @Test func metaBrowserRequiresMatchingSignedCallbackAndCompleteRegistration() {
        var registration = SocialOAuthRegistration(
            clientID: "123", redirect: "https://callback.example/instagram",
            brokerEndpoint: "https://broker.example"
        )
        #expect(!registration.metaBrowserReady(for: .instagram, associatedDomains: []))
        #expect(!registration.metaBrowserReady(for: .instagram, associatedDomains: ["applinks:callback.example"]))
        #expect(!registration.metaBrowserReady(for: .instagram, associatedDomains: ["webcredentials:other.example"]))
        let domains = ["webcredentials:callback.example"]
        #expect(registration.metaBrowserReady(for: .instagram, associatedDomains: domains))
        registration.redirect = "https://callback.example/instagram?extra=true"
        #expect(!registration.metaBrowserReady(for: .instagram, associatedDomains: domains))
    }

    @Test func facebookPresetRequiresSignedDomainAndAllowsPageDiscovery() throws {
        #expect(SocialOAuthRegistration.facebookBrowserPreset(associatedDomains: []) == nil)
        let domains = ["webcredentials:connect.bravenewdesign.com"]
        var preset = try #require(SocialOAuthRegistration.facebookBrowserPreset(associatedDomains: domains))
        #expect(preset.redirect == "https://connect.bravenewdesign.com/oauth/callback/facebook")
        #expect(preset.brokerEndpoint == "https://connect.bravenewdesign.com")
        #expect(preset.accountTarget.isEmpty)
        #expect(preset.metaBrowserReady(for: .facebookPages, associatedDomains: domains))
        preset.accountTarget = "a Page name"
        #expect(!preset.metaBrowserReady(for: .facebookPages, associatedDomains: domains))
    }

    @Test func facebookBrowserDiscoverySavesOnlyChosenPage() async throws {
        let fixture = BrokerFixture()
        let endpoint = try #require(URL(string: "https://broker.example"))
        let redirect = try #require(URL(string: "https://callback.example/facebook"))
        let broker = try SocialOAuthBroker(endpoint: endpoint, bearer: "fixture-service-key") {
            try await fixture.respond(to: $0)
        }
        let credentials = MemoryCredentialStore()
        let connections = SocialConnections(credentialStore: credentials, metaTransport: FacebookDiscoveryFixture())
        let account = try await connections.connectOAuth(
            platform: .facebookPages, clientID: "123", redirectURI: redirect,
            accountTarget: nil, instance: nil, exchange: broker,
            chooseFacebookPage: { pages in
                #expect(pages.map(\.remoteID) == ["101", "102"])
                return "102"
            }
        ) { authorize, callback in
            let request = try #require(URLComponents(url: authorize, resolvingAgainstBaseURL: false))
            let state = try #require(request.queryItems?.first { $0.name == "state" }?.value)
            var result = try #require(URLComponents(url: callback, resolvingAgainstBaseURL: false))
            result.queryItems = [URLQueryItem(name: "state", value: state), URLQueryItem(name: "code", value: "fixture-code")]
            return try #require(result.url)
        }
        #expect(account.remoteID == "102")
        #expect(await credentials.accounts().map(\.remoteID) == ["102"])
        #expect(await fixture.requests.count == 2)
    }

    @Test func facebookTokenPickerSavesOnlyChosenPageAndCanBeCancelled() async throws {
        let credentials = MemoryCredentialStore()
        let connections = SocialConnections(credentialStore: credentials, metaTransport: FacebookDiscoveryFixture())
        let token = OAuthToken(accessToken: "fixture-access")
        await #expect(throws: CancellationError.self) {
            try await connections.importMetaToken(token, platform: .facebookPages) { _ in
                throw CancellationError()
            }
        }
        #expect(await credentials.accounts().isEmpty)

        let account = try await connections.importMetaToken(token, platform: .facebookPages) { pages in
            #expect(pages.map(\.remoteID) == ["101", "102"])
            return "102"
        }
        #expect(account.remoteID == "102")
        #expect(await credentials.accounts().map(\.remoteID) == ["102"])
    }

    @Test func instagramTokenImportDiscoversSingleEligibleProfile() async throws {
        let credentials = MemoryCredentialStore()
        let connections = SocialConnections(credentialStore: credentials, metaTransport: InstagramFacebookDiscoveryFixture())
        let account = try await connections.importMetaToken(
            OAuthToken(accessToken: "fixture-access"), platform: .instagram, instagramAccessMethod: .facebookLogin
        ) { _ in
            Issue.record("A single linked Instagram account should connect automatically")
            return "201"
        }
        #expect(account.remoteID == "201")
        #expect(await credentials.credential(for: account.id)?.facebookPageSourceGrant != nil)
    }

    @Test func instagramFacebookLoginDiscoversLinkedProfileAndSavesPageGrant() async throws {
        let fixture = BrokerFixture()
        let endpoint = try #require(URL(string: "https://broker.example"))
        let redirect = try #require(URL(string: "https://callback.example/facebook"))
        let broker = try SocialOAuthBroker(endpoint: endpoint, bearer: "fixture-service-key") {
            try await fixture.respond(to: $0)
        }
        let credentials = MemoryCredentialStore()
        let connections = SocialConnections(credentialStore: credentials, metaTransport: InstagramFacebookDiscoveryFixture())
        let account = try await connections.connectOAuth(
            platform: .instagram, clientID: "123", redirectURI: redirect,
            accountTarget: nil, instance: nil, exchange: broker,
            instagramFacebookLogin: true,
            chooseFacebookPage: { _ in
                Issue.record("A single linked Instagram profile should connect automatically")
                return "201"
            }
        ) { authorize, callback in
            let request = try #require(URLComponents(url: authorize, resolvingAgainstBaseURL: false))
            let query = try #require(request.queryItems)
            let state = try #require(query.first { $0.name == "state" }?.value)
            #expect(query.first { $0.name == "scope" }?.value?.contains("instagram_manage_insights") == true)
            var result = try #require(URLComponents(url: callback, resolvingAgainstBaseURL: false))
            result.queryItems = [URLQueryItem(name: "state", value: state), URLQueryItem(name: "code", value: "fixture-code")]
            return try #require(result.url)
        }
        #expect(account.platform == .instagram)
        #expect(account.remoteID == "201")
        #expect(await credentials.credential(for: account.id)?.facebookPageSourceGrant != nil)
        #expect(await fixture.requests.map { $0["platform"] } == ["facebookPages", "facebookPages"])
    }

    @Test func metaExchangeUsesOnePreparedAttemptAndRejectsMismatchedProviderOrRedirect() async throws {
        let fixture = BrokerFixture()
        let endpoint = try #require(URL(string: "https://broker.example"))
        let redirect = try #require(URL(string: "https://callback.example/instagram"))
        let otherRedirect = try #require(URL(string: "https://callback.example/instagram/"))
        let broker = try SocialOAuthBroker(endpoint: endpoint, bearer: "fixture-service-key") {
            try await fixture.respond(to: $0)
        }
        #expect(!String(reflecting: broker).contains("fixture-service-key"))
        #expect(Mirror(reflecting: broker).children.isEmpty)

        await #expect(throws: SocialError.authorizationFailed) {
            try await broker.exchange(platform: .instagram, code: "code", redirectURI: redirect)
        }
        try await broker.prepare(platform: .instagram, clientID: "123", redirectURI: redirect, state: "fixture-state")
        await #expect(throws: SocialError.authorizationFailed) {
            try await broker.exchange(platform: .threads, code: "code", redirectURI: redirect)
        }
        await #expect(throws: SocialError.authorizationFailed) {
            try await broker.exchange(platform: .instagram, code: "code", redirectURI: otherRedirect)
        }
        let result = try await broker.exchange(platform: .instagram, code: "code", redirectURI: redirect)
        #expect(result.accessToken == "fixture-access")
        #expect(result.refreshToken == nil)
        #expect(result.metaLongLivedRefreshEligibleAt != nil)
        #expect(!String(reflecting: result).contains("fixture-access"))
        await #expect(throws: SocialError.authorizationFailed) {
            try await broker.exchange(platform: .instagram, code: "code", redirectURI: redirect)
        }

        let requests = await fixture.requests
        #expect(requests == [
            [
                "platform": "instagram", "client_id": "123", "redirect_uri": redirect.absoluteString,
                "state": "fixture-state"
            ],
            [
                "platform": "instagram", "code": "code", "redirect_uri": redirect.absoluteString,
                "state": "fixture-state", "session_id": "test-session"
            ]
        ])
    }

    @Test func linkedInRenewalUsesRefreshGrantAndPreservesRateLimit() async throws {
        let endpoint = try #require(URL(string: "https://broker.example"))
        let broker = try SocialOAuthBroker(endpoint: endpoint, bearer: "fixture-service-key") { request in
            let url = try #require(request.url)
            #expect(url.path == "/oauth/refresh")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-service-key")
            let fields = try JSONDecoder().decode([String: String].self, from: #require(request.httpBody))
            #expect(fields == ["platform": SocialPlatform.linkedIn.rawValue, "refresh_token": "saved-refresh"])
            let response = try #require(HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil,
                                                      headerFields: ["Retry-After": "600"]))
            return (Data(), response)
        }
        await #expect(throws: SocialError.rateLimited(retryAfter: "600")) {
            try await broker.refresh(platform: .linkedIn,
                                     token: OAuthToken(accessToken: "current-access", refreshToken: "saved-refresh"))
        }
    }

    @Test func cancellationPreventsExchangeAndFailureConsumesAttempt() async throws {
        let fixture = BrokerFixture(failExchange: true)
        let endpoint = try #require(URL(string: "https://broker.example"))
        let redirect = try #require(URL(string: "https://callback.example/instagram"))
        let broker = try SocialOAuthBroker(endpoint: endpoint, bearer: "fixture-service-key") {
            try await fixture.respond(to: $0)
        }
        try await broker.prepare(platform: .instagram, clientID: "123", redirectURI: redirect, state: "fixture-state")

        let canceled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await broker.exchange(platform: .instagram, code: "code", redirectURI: redirect)
        }
        await #expect(throws: CancellationError.self) { try await canceled.value }
        #expect(await fixture.requests.count == 1)
        for _ in 0..<2 {
            await #expect(throws: SocialError.authorizationFailed) {
                try await broker.exchange(platform: .instagram, code: "code", redirectURI: redirect)
            }
        }
        #expect(await fixture.requests.count == 2)
    }
}

private actor BrokerFixture {
    private(set) var requests: [[String: String]] = []
    private let failExchange: Bool

    init(failExchange: Bool = false) {
        self.failExchange = failExchange
    }

    func respond(to request: URLRequest) throws -> (Data, URLResponse) {
        let url = try #require(request.url)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-service-key")
        requests.append(try JSONDecoder().decode([String: String].self, from: #require(request.httpBody)))
        let isRegistration = url.path == "/oauth/session"
        let status = !isRegistration && failExchange ? 400 : 200
        let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
        let body = isRegistration
            ? #"{"session_id":"test-session"}"#
            : requests.last?["platform"] == "facebookPages"
                ? #"{"access_token":"fixture-access"}"#
                : #"{"access_token":"fixture-access","refresh_token":"ignored","expires_at":"2027-01-01T00:00:00Z","meta_long_lived_refresh_eligible_at":"2026-12-02T00:00:00Z"}"#
        return (Data(body.utf8), response)
    }
}

private nonisolated struct FacebookDiscoveryFixture: HTTPTransport {
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let url = try #require(request.url)
        let body: String
        switch url.path {
        case "/v27.0/me/permissions":
            body = #"{"data":[{"permission":"pages_manage_posts","status":"granted"}]}"#
        case "/v27.0/me/accounts":
            let includesTokens = url.query?.contains("access_token") == true
            body = includesTokens
                ? #"{"data":[{"id":"101","name":"First","access_token":"page-one","tasks":["CREATE_CONTENT"]},{"id":"102","name":"Second","access_token":"page-two","tasks":["CREATE_CONTENT"]}]}"#
                : #"{"data":[{"id":"101","name":"First"},{"id":"102","name":"Second"}]}"#
        case "/v27.0/me":
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer page-two")
            body = #"{"id":"102","name":"Second"}"#
        default:
            Issue.record("Unexpected Facebook endpoint")
            return HTTPResponse(statusCode: 404)
        }
        return HTTPResponse(statusCode: 200, body: Data(body.utf8))
    }
}

private nonisolated struct InstagramFacebookDiscoveryFixture: HTTPTransport {
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let url = try #require(request.url)
        let body: String
        switch url.path {
        case "/v27.0/me/permissions":
            body = #"{"data":[{"permission":"pages_show_list","status":"granted"},{"permission":"pages_read_engagement","status":"granted"},{"permission":"instagram_basic","status":"granted"},{"permission":"instagram_content_publish","status":"granted"}]}"#
        case "/v27.0/me/accounts":
            body = #"{"data":[{"id":"101","name":"Studio","access_token":"page-one","tasks":["CREATE_CONTENT"],"instagram_business_account":{"id":"201","username":"studio"}}]}"#
        case "/v27.0/201":
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer page-one")
            body = #"{"id":"201","username":"studio"}"#
        default:
            Issue.record("Unexpected linked Instagram endpoint")
            return HTTPResponse(statusCode: 404)
        }
        return HTTPResponse(statusCode: 200, body: Data(body.utf8))
    }
}
