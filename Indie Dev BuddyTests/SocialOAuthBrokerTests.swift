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
            : #"{"access_token":"fixture-access","refresh_token":"ignored","expires_at":"2027-01-01T00:00:00Z","meta_long_lived_refresh_eligible_at":"2026-12-02T00:00:00Z"}"#
        return (Data(body.utf8), response)
    }
}
