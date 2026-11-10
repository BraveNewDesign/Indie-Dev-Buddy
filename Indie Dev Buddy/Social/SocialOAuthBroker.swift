import Foundation
import SocialKit

/// Owns one browser attempt. Meta's exchange is enabled only after the broker registers it.
actor SocialOAuthBroker: SessionBoundMetaOAuthExchange, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable {
    typealias SendRequest = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let endpoint: URL
    private let bearer: String
    private let send: SendRequest
    private var attempt: Attempt = .idle

    init(endpoint: URL, bearer: String, send: SendRequest? = nil) throws {
        guard SocialOAuthRegistration.httpsURL(endpoint) != nil,
              endpoint.port == nil || endpoint.port == 443,
              Self.validBearer(bearer) else {
            throw SocialError.invalidConfiguration
        }
        self.endpoint = endpoint
        self.bearer = bearer
        if let send {
            self.send = send
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            configuration.urlCache = nil
            let session = URLSession(configuration: configuration, delegate: RejectOAuthRedirects(), delegateQueue: nil)
            self.send = { try await session.data(for: $0) }
        }
    }

    nonisolated static func validBearer(_ bearer: String) -> Bool {
        !bearer.isEmpty && bearer.utf8.allSatisfy({ (33...126).contains($0) })
    }

    nonisolated var description: String { "SocialOAuthBroker(redacted)" }
    nonisolated var debugDescription: String { description }
    nonisolated var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }

    func prepare(platform: SocialPlatform, clientID: String, redirectURI: URL, state: String) async throws {
        guard platform == .facebookPages || platform == .instagram || platform == .threads,
              case .idle = attempt,
              SocialOAuthRegistration.httpsURL(redirectURI) != nil,
              !clientID.isEmpty, !state.isEmpty else {
            throw SocialError.invalidConfiguration
        }

        // Consume the idle state before suspending. A failed registration requires a new attempt.
        attempt = .consumed
        let registered: SessionResponse = try await post("session", fields: [
            "platform": platform.rawValue,
            "client_id": clientID,
            "redirect_uri": redirectURI.absoluteString,
            "state": state
        ])
        guard (1...128).contains(registered.session_id.utf8.count),
              registered.session_id.utf8.allSatisfy(Self.isSessionIDCharacter) else {
            throw SocialError.authorizationFailed
        }
        attempt = .prepared(platform: platform, redirect: redirectURI.absoluteString, state: state, id: registered.session_id)
    }

    func exchange(platform: SocialPlatform, code: String, redirectURI: URL) async throws -> OAuthToken {
        try Task.checkCancellation()
        guard !code.isEmpty else { throw SocialError.authorizationFailed }
        var fields = ["platform": platform.rawValue, "code": code, "redirect_uri": redirectURI.absoluteString]
        if platform == .linkedIn, case .idle = attempt {
            // LinkedIn's established broker contract is separate from Meta's session protocol.
        } else {
            guard case let .prepared(expectedPlatform, expectedRedirect, state, id) = attempt,
                  expectedPlatform == platform, expectedRedirect == redirectURI.absoluteString else {
                throw SocialError.authorizationFailed
            }
            fields["state"] = state
            fields["session_id"] = id
        }
        attempt = .consumed
        let decoded: TokenResponse = try await post("exchange", fields: fields)
        guard !decoded.access_token.isEmpty else { throw SocialError.authorizationFailed }
        let expiry = try decoded.expires_at.map(Self.decodeDate)
        let eligibleAt = try decoded.meta_long_lived_refresh_eligible_at.map(Self.decodeDate)
        if let eligibleAt {
            guard platform == .instagram || platform == .threads,
                  let expiry, eligibleAt < expiry else { throw SocialError.authorizationFailed }
        }
        return OAuthToken(accessToken: decoded.access_token,
                          refreshToken: platform == .linkedIn ? decoded.refresh_token : nil,
                          expiresAt: expiry,
                          grantedScopes: decoded.granted_scopes,
                          metaLongLivedRefreshEligibleAt: eligibleAt)
    }

    private func post<Response: Decodable & Sendable>(_ operation: String, fields: [String: String]) async throws -> Response {
        do {
            try Task.checkCancellation()
            let url = endpoint.appendingPathComponent("oauth").appendingPathComponent(operation)
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            request.httpMethod = "POST"
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.httpBody = try JSONEncoder().encode(fields)
            let (data, response) = try await send(request)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse, response.url == url,
                  (200..<300).contains(response.statusCode), data.count <= 64 * 1024 else {
                throw SocialError.authorizationFailed
            }
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            try Task.checkCancellation()
            throw SocialError.authorizationFailed
        }
    }

    private nonisolated static func decodeDate(_ date: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        if let value = formatter.date(from: date) { return value }
        formatter.formatOptions.insert(.withFractionalSeconds)
        guard let value = formatter.date(from: date) else { throw SocialError.authorizationFailed }
        return value
    }

    private nonisolated static func isSessionIDCharacter(_ character: UInt8) -> Bool {
        (48...57).contains(character) || (65...90).contains(character) || (97...122).contains(character)
            || character == 45 || character == 95
    }

    private enum Attempt {
        case idle
        case prepared(platform: SocialPlatform, redirect: String, state: String, id: String)
        case consumed
    }

    private nonisolated struct SessionResponse: Decodable, Sendable {
        let session_id: String
    }

    private nonisolated struct TokenResponse: Decodable, Sendable {
        let access_token: String
        let refresh_token: String?
        let expires_at: String?
        let granted_scopes: Set<String>?
        let meta_long_lived_refresh_eligible_at: String?
    }
}

private nonisolated final class RejectOAuthRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
