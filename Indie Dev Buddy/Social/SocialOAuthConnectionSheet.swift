import AppKit
import AuthenticationServices
import Foundation
import Security
import SocialKit
import SwiftUI

struct SocialOAuthConnectionSheet: View {
    @Environment(SocialPublishingRuntime.self) private var runtime
    @Environment(\.dismiss) private var dismiss
    let platform: SocialPlatform
    let onConnected: (SocialAccount) -> Void
    @State private var registration = SocialOAuthRegistration()
    @State private var brokerCredential = ""
    @State private var connectionTask: Task<Void, Never>?
    @State private var message: String?
    @State private var canRetryCredentialSave = false
    @State private var showingMetaAccessHelp = false
    @State private var metaMethod: MetaConnectionMethod = .accessToken
    @State private var associatedDomains: [String] = []
    @State private var accessToken = ""
    @State private var reportedScopes = ""
    @State private var tokenIsLongLived = false
    @State private var tokenHasExpiration = false
    @State private var tokenExpiration = Date()

    private var isMetaPlatform: Bool { [.facebookPages, .instagram, .threads].contains(platform) }

    var body: some View {
        Form {
            if isMetaPlatform {
                Section("Connection method") {
                    if associatedDomains.contains(where: { $0.hasPrefix("webcredentials:") }) {
                        Picker("Connect using", selection: $metaMethod) {
                            Text("Meta access token").tag(MetaConnectionMethod.accessToken)
                            Text("Browser sign-in").tag(MetaConnectionMethod.oauth)
                        }
                        .pickerStyle(.segmented)
                        .disabled(connectionTask != nil)
                    } else {
                        Text("Browser sign-in is unavailable in this build. It requires an associated HTTPS callback domain.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(metaMethod == .accessToken
                         ? "Local connection. No exchange service is needed."
                         : "Browser sign-in requires a trusted exchange service and a registered callback.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if metaMethod == .accessToken {
                    metaAccessTokenSection
                } else {
                    providerRegistrationSection
                    if platform.requiresBroker { exchangeServiceSection }
                    if !metaBrowserReady && connectionTask == nil {
                        Text("Browser sign-in is unavailable until the registration, associated callback, and exchange service are configured.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                providerRegistrationSection
                if platform.requiresBroker { exchangeServiceSection }
            }
            if let message {
                Text(message)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                if platform == .mastodon {
                    Button("Test Keychain", action: testKeychain)
                        .disabled(connectionTask != nil)
                }
                if platform == .mastodon && canRetryCredentialSave {
                    Button("Retry Keychain Save", action: retryCredentialSave)
                        .disabled(connectionTask != nil)
                }
                Spacer()
                Button(actionTitle) {
                    if isMetaPlatform && metaMethod == .accessToken { importAccessToken() }
                    else { beginConnection() }
                }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canConnect)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear {
            registration = .load(platform)
            if isMetaPlatform { associatedDomains = SocialOAuthRegistration.signedAssociatedDomains() }
        }
        .sheet(isPresented: $showingMetaAccessHelp) {
            MetaAccessHelpView(platform: platform)
        }
        .onDisappear {
            connectionTask?.cancel()
            brokerCredential = ""
            accessToken = ""
        }
    }

    @ViewBuilder
    private var providerRegistrationSection: some View {
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
                Toggle("Request LinkedIn comment and feed access", isOn: Binding(
                    get: { registration.requestLinkedInActivity ?? false },
                    set: { registration.requestLinkedInActivity = $0 }
                ))
                Text("This requests Community Management scopes for posts and comments. LinkedIn must approve them for this app; leave off for publishing-only access.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if isMetaPlatform {
                Button("How do I get a Meta access token?") { showingMetaAccessHelp = true }
                    .font(.caption)
            }
        }
    }

    private var exchangeServiceSection: some View {
        Section("Trusted Exchange Service") {
            TextField("HTTPS service base URL", text: $registration.brokerEndpoint)
            SecureField("Service access credential", text: $brokerCredential)
            Text("Use a service you control that implements the token exchange contract. Keep the provider app secret on that service. The service credential is used for this connection and is not saved.")
                .font(.caption).foregroundStyle(.secondary)
            if platform == .facebookPages {
                Text("Keychain stores the Page token and the source Facebook user grant. Indie Dev Buddy uses the grant only to recover access to this same Page while the grant remains valid.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var metaAccessTokenSection: some View {
        Section("Meta access token") {
            SecureField("User access token", text: $accessToken)
                .textContentType(.password)
            if platform == .facebookPages {
                TextField("Facebook Page ID", text: $registration.accountTarget)
            }
            TextField("Verified permissions (optional, comma-separated)", text: $reportedScopes)
            if platform != .facebookPages {
                Toggle("Meta issued this as a long-lived token", isOn: $tokenIsLongLived)
                Text("Enable this only for a confirmed long-lived token. Indie Dev Buddy waits at least 24 hours after import before trying to renew it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("I know when this token expires", isOn: $tokenHasExpiration)
            if tokenHasExpiration {
                DatePicker(platform == .facebookPages ? "User grant expires" : "Token expires",
                           selection: $tokenExpiration)
            } else {
                Text(platform == .facebookPages ? "User grant expiry is unknown." : "Token expiry is unknown.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(platform == .facebookPages
                 ? "Use a long-lived Facebook user token if possible. Indie Dev Buddy stores the Page token and the broader user grant in this Mac’s Keychain. It uses the user grant to recover the selected Page token while the grant remains valid. The Page token has its own lifetime."
                 : "Use a long-lived user token from Meta. Indie Dev Buddy verifies the token with Meta, stores it in this Mac’s Keychain, and publishes directly from this Mac. Leave permissions blank if you are unsure.")
                .font(.caption).foregroundStyle(.secondary)
            Button("How do I get a Meta access token?") { showingMetaAccessHelp = true }
                .font(.caption)
        }
    }

    private var actionTitle: String {
        guard connectionTask == nil else { return "Connecting…" }
        return isMetaPlatform && metaMethod == .accessToken ? "Verify and Save Token" : "Authorize in Browser"
    }

    private var canConnect: Bool {
        guard connectionTask == nil else { return false }
        if isMetaPlatform && metaMethod == .accessToken {
            return !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && (platform != .facebookPages || !registration.accountTarget.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        return !isMetaPlatform || metaBrowserReady
    }

    private var metaBrowserReady: Bool {
        registration.metaBrowserReady(for: platform, associatedDomains: associatedDomains)
            && SocialOAuthBroker.validBearer(brokerCredential)
    }

    private func beginConnection() {
        guard !isMetaPlatform || metaBrowserReady else {
            message = "Set up the associated HTTPS callback and trusted exchange service, or connect with a Meta access token."
            return
        }
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
        canRetryCredentialSave = false
        brokerCredential = ""
        connectionTask = Task {
            defer { connectionTask = nil }
            do {
                let account = try await runtime.connections.connectOAuth(
                    platform: platform, clientID: settings.clientID, redirectURI: redirect,
                    accountTarget: accountTarget, instance: instance, exchange: broker,
                    requestLinkedInActivity: settings.requestLinkedInActivity ?? false
                ) { authorizationURL, callbackURL in
                    try await browser.authenticate(authorizationURL, redirect: callbackURL)
                }
                try Task.checkCancellation()
                settings.save(platform)
                onConnected(account)
                dismiss()
            } catch is CancellationError {
                message = "Authorization was canceled."
            } catch {
                if platform == .mastodon, let error = error as? SocialError,
                   case .credentialStorage = error {
                    canRetryCredentialSave = true
                }
                message = authorizationFailureMessage(for: error)
            }
        }
    }

    private func retryCredentialSave() {
        message = nil
        connectionTask = Task {
            defer { connectionTask = nil }
            do {
                let account = try await runtime.connections.retryPendingMastodonCredentialSave()
                try Task.checkCancellation()
                registration.save(.mastodon)
                canRetryCredentialSave = false
                onConnected(account)
                dismiss()
            } catch {
                message = authorizationFailureMessage(for: error)
            }
        }
    }

    private func testKeychain() {
        message = nil
        connectionTask = Task {
            defer { connectionTask = nil }
            do {
                try await runtime.connections.testCredentialStorage()
                message = "Keychain test succeeded. No Mastodon authorization was requested."
            } catch {
                if let error = error as? SocialError, case .credentialStorage(let status) = error {
                    message = "Keychain test failed (OSStatus \(status))."
                } else {
                    message = "Keychain test failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func authorizationFailureMessage(for error: any Error) -> String {
        guard let socialError = error as? SocialError else {
            let error = error as NSError
            return "Could not connect \(platform.workspaceTitle). Diagnostic: \(error.domain) error \(error.code)."
        }

        let detail: String
        switch socialError {
        case .invalidConfiguration:
            detail = "The server or OAuth settings are incompatible. Check the HTTPS server address, callback URL, PKCE support, and requested permissions."
        case .invalidResponse:
            detail = "The server returned a response Indie Dev Buddy could not read."
        case .authorizationFailed:
            detail = "Authorization did not return a valid callback. Check that the callback URL is unchanged and approve the requested access."
        case .httpStatus(let status):
            detail = "The server rejected a connection request with HTTP \(status)."
        case .transportFailure:
            detail = "Indie Dev Buddy could not reach the server. Check your network connection and try again."
        case .authenticationRequired:
            detail = "The server did not accept the account authorization. Try connecting again."
        case .credentialStorage(let status):
            detail = "macOS Keychain rejected saving the account (OSStatus \(status))."
        default:
            detail = socialError.localizedDescription
        }

        return "Could not connect \(platform.workspaceTitle). \(detail)"
    }

    private func importAccessToken() {
        let trimmedToken = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let scopes = Set(reportedScopes.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })
        let token = OAuthToken(accessToken: trimmedToken,
                               expiresAt: tokenHasExpiration ? tokenExpiration : nil,
                               grantedScopes: scopes.isEmpty ? nil : scopes,
                               metaLongLivedRefreshEligibleAt: tokenIsLongLived && platform != .facebookPages
                                   ? Date().addingTimeInterval(24 * 60 * 60) : nil)
        accessToken = ""
        message = nil
        connectionTask = Task {
            defer { connectionTask = nil }
            do {
                let account = try await runtime.connections.importMetaToken(
                    token, platform: platform,
                    pageID: platform == .facebookPages ? registration.accountTarget : nil
                )
                try Task.checkCancellation()
                onConnected(account)
                dismiss()
            } catch is CancellationError {
                message = "Token verification was canceled."
            } catch {
                message = "Meta did not accept this token for the selected account. Check that it is current, has the needed permissions, and matches the Page or profile."
            }
        }
    }
}

private enum MetaConnectionMethod: String, Hashable {
    case accessToken
    case oauth
}

nonisolated struct SocialOAuthRegistration: Codable {
    static let callbackScheme = "com.bravenewdesign.indiedevbuddy.oauth"
    var clientID = ""
    var redirect = ""
    var instance = ""
    var accountTarget = ""
    var brokerEndpoint = ""
    var requestLinkedInActivity: Bool? = false

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

    func metaBrowserReady(for platform: SocialPlatform, associatedDomains: [String]) -> Bool {
        guard platform == .facebookPages || platform == .instagram || platform == .threads,
              !clientID.isEmpty, clientID.utf8.allSatisfy({ (48...57).contains($0) }),
              platform != .facebookPages || (!accountTarget.isEmpty && accountTarget.utf8.allSatisfy({ (48...57).contains($0) })),
              let url = callback(for: platform), let host = url.host?.lowercased(),
              url.port == nil, !url.path.isEmpty,
              associatedDomains.contains("webcredentials:\(host)"),
              let endpoint = URL(string: brokerEndpoint),
              Self.httpsURL(endpoint) != nil, endpoint.port == nil || endpoint.port == 443 else { return false }
        return true
    }

    static func signedAssociatedDomains() -> [String] {
        guard let task = SecTaskCreateFromSelf(nil) else { return [] }
        return SecTaskCopyValueForEntitlement(task, "com.apple.developer.associated-domains" as CFString, nil) as? [String] ?? []
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
