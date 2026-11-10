import AppKit
import AuthenticationServices
import Foundation
import SocialKit
import SwiftUI

struct SocialOAuthConnectionSheet: View {
    @Environment(SocialPublishingRuntime.self) private var runtime
    @Environment(\.dismiss) private var dismiss
    let platform: SocialPlatform
    let onConnected: (ContentRecipientIdentity, String) -> Void
    @State private var registration = SocialOAuthRegistration()
    @State private var brokerCredential = ""
    @State private var connectionTask: Task<Void, Never>?
    @State private var message: String?

    var body: some View {
        Form {
            Section("Provider Registration") {
                if platform != .mastodon {
                    TextField("Public client or app ID", text: $registration.clientID)
                } else {
                    TextField("Mastodon server", text: $registration.instance)
                }
                TextField("Registered callback URL", text: $registration.redirect)
                if platform == .facebookPages {
                    TextField("Facebook Page ID", text: $registration.accountTarget)
                } else if platform == .linkedIn {
                    TextField("Organization URN (optional)", text: $registration.accountTarget)
                }
            }
            if platform.requiresBroker {
                Section("Trusted Exchange Service") {
                    TextField("HTTPS service base URL", text: $registration.brokerEndpoint)
                    SecureField("Service access credential", text: $brokerCredential)
                    Text("Use a service you control that implements the token exchange contract. Keep the provider app secret on that service. The service credential is used for this connection and is not saved.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let message {
                Text(message).foregroundStyle(.red)
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(connectionTask == nil ? "Authorize in Browser" : "Connecting…") { beginConnection() }
                    .buttonStyle(.borderedProminent)
                    .disabled(connectionTask != nil)
            }
        }
        .padding(20)
        .frame(width: 500)
        .onAppear { registration = .load(platform) }
        .onDisappear {
            connectionTask?.cancel()
            brokerCredential = ""
        }
    }

    private func beginConnection() {
        guard let redirect = registration.callback(for: platform),
              platform == .mastodon || !registration.clientID.isEmpty,
              platform != .facebookPages || !registration.accountTarget.isEmpty else {
            message = "Enter the public registration values and the exact callback for this provider."
            return
        }
        let instance = URL(string: registration.instance)
        if platform == .mastodon, instance.flatMap(SocialOAuthRegistration.httpsURL) == nil {
            message = "Enter a trusted HTTPS Mastodon server."
            return
        }
        let broker: SocialOAuthBroker?
        if platform.requiresBroker {
            guard let endpoint = URL(string: registration.brokerEndpoint),
                  let validated = try? SocialOAuthBroker(endpoint: endpoint, bearer: brokerCredential) else {
                message = "Enter a trusted HTTPS exchange service and its access credential."
                return
            }
            broker = validated
        } else {
            broker = nil
        }
        let browser = SocialAuthorizationBrowser()
        let settings = registration
        let accountTarget = settings.accountTarget.isEmpty ? nil : settings.accountTarget
        message = nil
        brokerCredential = ""
        connectionTask = Task {
            defer { connectionTask = nil }
            do {
                let account = try await runtime.connections.connectOAuth(
                    platform: platform, clientID: settings.clientID, redirectURI: redirect,
                    accountTarget: accountTarget, instance: instance, exchange: broker
                ) { authorizationURL, callbackURL in
                    try await browser.authenticate(authorizationURL, redirect: callbackURL)
                }
                try Task.checkCancellation()
                settings.save(platform)
                onConnected(ContentRecipientIdentity(platform: account.platform.rawValue,
                                                      server: account.server,
                                                      remoteID: account.remoteID), account.username)
                dismiss()
            } catch is CancellationError {
                message = "Authorization was canceled."
            } catch {
                message = "Could not authorize \(platform.workspaceTitle). Check the callback registration, account permissions, and service configuration."
            }
        }
    }
}

nonisolated struct SocialOAuthRegistration: Codable {
    static let callbackScheme = "com.bravenewdesign.indiedevbuddy.oauth"
    var clientID = ""
    var redirect = ""
    var instance = ""
    var accountTarget = ""
    var brokerEndpoint = ""

    static func load(_ platform: SocialPlatform) -> Self {
        if let data = UserDefaults.standard.data(forKey: key(platform)),
           let registration = try? JSONDecoder().decode(Self.self, from: data) {
            return registration
        }
        return Self(redirect: platform == .mastodon ? "\(callbackScheme):/mastodon" : "")
    }

    func save(_ platform: SocialPlatform) {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key(platform))
        }
    }

    private static func key(_ platform: SocialPlatform) -> String { "social.oauth.registration.\(platform.rawValue)" }

    func callback(for platform: SocialPlatform) -> URL? {
        guard let url = URL(string: redirect),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else { return nil }
        if Self.httpsURL(url) != nil { return url }
        guard !platform.requiresBroker, parts.scheme == Self.callbackScheme, !parts.path.isEmpty else { return nil }
        return url
    }

    static func httpsURL(_ url: URL) -> URL? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "https", parts.host?.isEmpty == false,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else { return nil }
        return url
    }
}

@MainActor
private final class SocialAuthorizationBrowser: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<URL, any Error>?

    func authenticate(_ url: URL, redirect: URL) async throws -> URL {
        guard let window = NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow else {
            throw SocialError.authorizationFailed
        }
        anchor = window
        defer { anchor = nil }
        let callback: ASWebAuthenticationSession.Callback
        if redirect.scheme?.lowercased() == "https", let host = redirect.host {
            callback = .https(host: host, path: redirect.path.isEmpty ? "/" : redirect.path)
        } else {
            callback = .customScheme(SocialOAuthRegistration.callbackScheme)
        }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let handler: ASWebAuthenticationSession.CompletionHandler = { @Sendable [weak self] url, error in
                    let canceled = (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
                    Task { @MainActor in
                        if let url { self?.complete(.success(url)) }
                        else { self?.complete(.failure(canceled ? CancellationError() : SocialError.authorizationFailed)) }
                    }
                }
                let session = ASWebAuthenticationSession(url: url, callback: callback, completionHandler: handler)
                session.presentationContextProvider = self
                session.prefersEphemeralWebBrowserSession = true
                self.session = session
                if !session.start() { complete(.failure(SocialError.authorizationFailed)) }
            }
        } onCancel: {
            Task { @MainActor in
                self.session?.cancel()
                self.complete(.failure(CancellationError()))
            }
        }
    }

    private var anchor: ASPresentationAnchor?
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor ?? NSWindow()
    }

    private func complete(_ result: Result<URL, any Error>) {
        let pending = continuation
        continuation = nil
        session = nil
        pending?.resume(with: result)
    }
}

/// The exchange contract matches SocialKit's standalone Meta validation client.
private nonisolated struct SocialOAuthBroker: ConfidentialOAuthExchange {
    private let endpoint: URL
    private let bearer: String
    private let session: URLSession

    init(endpoint: URL, bearer: String) throws {
        guard SocialOAuthRegistration.httpsURL(endpoint) != nil,
              endpoint.port == nil || endpoint.port == 443,
              !bearer.isEmpty, bearer.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw SocialError.invalidConfiguration
        }
        self.endpoint = endpoint
        self.bearer = bearer
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: RejectOAuthRedirects(), delegateQueue: nil)
    }

    func exchange(platform: SocialPlatform, code: String, redirectURI: URL) async throws -> OAuthToken {
        do {
            let url = endpoint.appendingPathComponent("oauth").appendingPathComponent("exchange")
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            request.httpMethod = "POST"
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.httpBody = try JSONEncoder().encode([
                "platform": platform.rawValue, "code": code, "redirect_uri": redirectURI.absoluteString
            ])
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse, response.url == url,
                  (200..<300).contains(response.statusCode), data.count <= 64 * 1024 else {
                throw SocialError.authorizationFailed
            }
            let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
            guard !decoded.access_token.isEmpty else { throw SocialError.authorizationFailed }
            let expiry = try decoded.expires_at.map { date in
                if let date = ISO8601DateFormatter().date(from: date) { return date }
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions.insert(.withFractionalSeconds)
                guard let result = formatter.date(from: date) else { throw SocialError.authorizationFailed }
                return result
            }
            return OAuthToken(accessToken: decoded.access_token, refreshToken: decoded.refresh_token,
                              expiresAt: expiry, grantedScopes: decoded.granted_scopes)
        } catch {
            try Task.checkCancellation()
            throw SocialError.authorizationFailed
        }
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_at: String?
        let granted_scopes: Set<String>?
    }
}

private nonisolated final class RejectOAuthRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
