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
    var expected: ContentRecipientIdentity? = nil
    var recovery: SocialConnections.Recovery? = nil
    let onConnected: (SocialAccount) -> Void
    @State private var registration = SocialOAuthRegistration()
    @State private var brokerCredential = ""
    @State private var rememberBroker = false
    @State private var loadedBroker: String?
    @State private var connectionTask: Task<Void, Never>?
    @State private var message: String?
    @State private var canRetryCredentialSave = false
    @State private var canFinishConnection: SocialAccount?
    @State private var showingMetaAccessHelp = false
    @State private var metaMethod: MetaConnectionMethod = .accessToken
    @State private var instagramAccessMethod: InstagramAccessMethod = .facebookLogin
    @State private var instagramAccountID = ""
    @State private var associatedDomains: [String] = []
    @State private var facebookPages: [SocialAccount] = []
    @State private var selectedPageID: String?
    @State private var pageSelection: CheckedContinuation<String, any Error>?
    @State private var accessToken = ""
    @State private var reportedScopes = ""
    @State private var tokenIsLongLived = false
    @State private var tokenHasExpiration = false
    @State private var tokenExpiration = Date()

    private var isMetaPlatform: Bool { [.facebookPages, .instagram, .threads].contains(platform) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(expected == nil ? "Connect \(platform.workspaceTitle)" : "Reconnect \(platform.workspaceTitle)")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
                .padding(20)
            Divider()
            Form {
                if let recovery, recovery.needsAuthorization {
                    Label(recovery.message, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.secondary)
                    if isMetaPlatform && metaMethod == .accessToken {
                        Text("Paste a current token for this same account. Indie Dev Buddy verifies it before updating Keychain.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
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
                            Label("Token import is available in this build", systemImage: "key")
                            Text("Browser sign-in requires a build signed for the HTTPS callback domain.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if metaMethod == .accessToken {
                        metaAccessTokenSection
                    } else {
                        if usingHostedMetaPreset {
                            hostedMetaSection
                        } else {
                            providerRegistrationSection
                            if platform.requiresBroker { exchangeServiceSection }
                        }
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
            }
            .formStyle(.grouped)
            .disabled(connectionTask != nil)
            Divider()
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
                    if let account = canFinishConnection { onConnected(account); dismiss() }
                    else if isMetaPlatform && metaMethod == .accessToken { importAccessToken() }
                    else { beginConnection() }
                }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canConnect)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 560, height: isMetaPlatform ? 510 : 420)
        .onAppear {
            registration = .load(platform, identity: expected)
            if platform == .facebookPages, expected == nil { registration.accountTarget = "" }

            if let expected {
                if platform == .facebookPages { registration.accountTarget = expected.remoteID }
                if platform == .mastodon { registration.instance = expected.server.absoluteString }
                if platform == .linkedIn {
                    registration.accountTarget = expected.remoteID.hasPrefix("urn:li:organization:") ? expected.remoteID : ""
                }
                if platform == .instagram { instagramAccountID = expected.remoteID }
            }
            if platform == .instagram, let expected {
                instagramAccessMethod = expected.server.host == "graph.instagram.com" ? .instagramLogin : .facebookLogin
            } else if let method = registration.instagramMethod {
                instagramAccessMethod = method == "instagram" ? .instagramLogin : .facebookLogin
            }
            if isMetaPlatform {
                associatedDomains = SocialOAuthRegistration.signedAssociatedDomains()
                if let preset = SocialOAuthRegistration.hostedMetaPreset(for: platform, associatedDomains: associatedDomains),
                   expected == nil || platform != .instagram || expected?.server.host == "graph.facebook.com",
                   registration.clientID.isEmpty && registration.redirect.isEmpty && registration.brokerEndpoint.isEmpty {
                    registration.clientID = preset.clientID
                    registration.redirect = preset.redirect
                    registration.brokerEndpoint = preset.brokerEndpoint
                    registration.prefersBrowser = true
                    registration.browserInstagramFacebookLogin = preset.browserInstagramFacebookLogin
                }
                if registration.prefersBrowser == true, associatedDomains.contains(where: { $0.hasPrefix("webcredentials:") }) {
                    metaMethod = .oauth
                }
            }
            loadSavedBroker()
        }
        .onChange(of: registration.brokerEndpoint) { _, _ in
            brokerCredential = ""
            loadSavedBroker()
        }
        .sheet(isPresented: $showingMetaAccessHelp) {
            MetaAccessHelpView(platform: platform, instagramAccessMethod: metaMethod == .oauth
                               ? (registration.browserInstagramFacebookLogin == true ? .facebookLogin : .instagramLogin)
                               : instagramAccessMethod)
        }
        .sheet(isPresented: Binding(get: { pageSelection != nil }, set: { if !$0 { finishPageSelection(nil) } })) {
            VStack(alignment: .leading, spacing: 12) {
                Text(platform == .instagram ? "Choose an Instagram Account" : "Choose a Facebook Page").font(.headline)
                List(facebookPages, id: \.remoteID, selection: $selectedPageID) { page in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(page.displayName ?? page.username)
                        Text("Account ID \(page.remoteID)").font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(page.remoteID)
                }
                HStack {
                    Button("Cancel") { finishPageSelection(nil) }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(platform == .instagram ? "Connect Account" : "Connect Page") { finishPageSelection(selectedPageID) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(selectedPageID == nil)
                }
            }
            .padding(20)
            .frame(width: 400, height: 280)
        }
        .onDisappear {
            finishPageSelection(nil)
            loadedBroker = nil
            connectionTask?.cancel()
            if platform == .mastodon {
                Task { await runtime.connections.discardPendingMastodonCredential() }
            }
            brokerCredential = ""
            accessToken = ""
        }
    }

    @ViewBuilder
    private var providerRegistrationSection: some View {
        Section("Provider Registration") {
            if platform != .mastodon {
                TextField(isMetaPlatform ? "Meta app ID (optional with broker discovery)" : "Public client or app ID", text: $registration.clientID)
            } else {
                TextField("Mastodon server", text: $registration.instance)
            }
            TextField("Registered callback URL", text: $registration.redirect)
            if platform == .instagram {
                Toggle("Use Facebook Login for Instagram", isOn: Binding(
                    get: { registration.browserInstagramFacebookLogin == true },
                    set: { registration.browserInstagramFacebookLogin = $0 }
                ))
            }
            if platform == .facebookPages {
                TextField("Facebook Page ID (optional)", text: $registration.accountTarget)
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
                if let preset = SocialOAuthRegistration.hostedMetaPreset(for: platform, associatedDomains: associatedDomains),
                   expected == nil || platform != .instagram || expected?.server.host == "graph.facebook.com" {
                    Button("Use Brave New Design Broker") {
                        registration.clientID = preset.clientID
                        registration.redirect = preset.redirect
                        registration.brokerEndpoint = preset.brokerEndpoint
                        registration.browserInstagramFacebookLogin = preset.browserInstagramFacebookLogin
                    }
                }
                Button("Set Up My Meta App") { showingMetaAccessHelp = true }
                    .font(.caption)
            }
        }
    }

    private var usingHostedMetaPreset: Bool {
        guard let preset = SocialOAuthRegistration.hostedMetaPreset(for: platform, associatedDomains: associatedDomains) else { return false }
        return registration.redirect == preset.redirect && registration.brokerEndpoint == preset.brokerEndpoint &&
            (preset.clientID.isEmpty || registration.clientID == preset.clientID) &&
            (registration.browserInstagramFacebookLogin == true) == (preset.browserInstagramFacebookLogin == true)
    }

    private var hostedMetaSection: some View {
        Section("Connect \(platform.workspaceTitle)") {
            if platform == .facebookPages {
                Text(expected == nil
                     ? "Sign in to Facebook, grant access, and choose a Page. If you authorize only one Page, it connects automatically."
                     : "Sign in to Facebook to restore access to this same Page.")
            } else if platform == .instagram, registration.browserInstagramFacebookLogin == true {
                Text("Sign in with Facebook and approve access to the Page linked to your professional Instagram account.")
            } else {
                Text("Sign in to \(platform.workspaceTitle) in your browser and approve access. Indie Dev Buddy saves the resulting connection in Keychain.")
            }
            SecureField("Broker password", text: $brokerCredential)
                .textContentType(.password)
            if savedBrokerCredential != nil && brokerCredential.isEmpty {
                Label("Broker password saved in Keychain", systemImage: "key.fill")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Remember password for this broker in Keychain", isOn: $rememberBroker)
            DisclosureGroup("Advanced Settings") {
                TextField("Meta app ID", text: $registration.clientID)
                TextField("Registered callback URL", text: $registration.redirect)
                TextField("HTTPS service base URL", text: $registration.brokerEndpoint)
                if platform == .facebookPages, expected == nil {
                    TextField("Facebook Page ID (optional)", text: $registration.accountTarget)
                }
            }
            .disabled(connectionTask != nil)
        }
    }

    private func choosePage(_ pages: [SocialAccount]) async throws -> String {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                facebookPages = pages
                selectedPageID = nil
                pageSelection = continuation
            }
        } onCancel: {
            Task { @MainActor in finishPageSelection(nil) }
        }
    }

    private func finishPageSelection(_ pageID: String?) {
        guard let continuation = pageSelection else { return }
        pageSelection = nil
        facebookPages = []
        selectedPageID = nil
        if let pageID { continuation.resume(returning: pageID) }
        else { continuation.resume(throwing: CancellationError()) }
    }

    private var exchangeServiceSection: some View {
        Section("Trusted Exchange Service") {
            TextField("HTTPS service base URL", text: $registration.brokerEndpoint)
            SecureField("Service access credential", text: $brokerCredential)
            Toggle("Remember exchange credential in Keychain", isOn: $rememberBroker)
            if savedBrokerCredential != nil && brokerCredential.isEmpty {
                Label("Saved credential available for this endpoint", systemImage: "key.fill")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Keep the provider app secret on the exchange service. A remembered credential is available only for this endpoint.")
                .font(.caption).foregroundStyle(.secondary)
            if platform == .facebookPages {
                Text("Keychain stores the Page token and the source Facebook user grant. Indie Dev Buddy uses the grant only to recover access to this same Page while the grant remains valid.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var metaAccessTokenSection: some View {
        Section("Access Token") {
            if platform == .instagram {
                Picker("Instagram login", selection: $instagramAccessMethod) {
                    Text("Facebook Login").tag(InstagramAccessMethod.facebookLogin)
                    Text("Instagram Login").tag(InstagramAccessMethod.instagramLogin)
                }
                .disabled(expected != nil)
            }
            SecureField(accessTokenLabel, text: $accessToken).textContentType(.password)
            if let expected {
                LabeledContent("Linked account ID", value: expected.remoteID)
            }
            Text(tokenImportHelp)
                .font(.caption).foregroundStyle(.secondary)
            Button("Set Up My Meta App") { showingMetaAccessHelp = true }
        }
        Section {
            DisclosureGroup("Advanced Token Settings") {
                if expected == nil && platform == .facebookPages {
                    TextField("Facebook Page ID (optional)", text: $registration.accountTarget)
                }
                if expected == nil && platform == .instagram && instagramAccessMethod == .facebookLogin {
                    TextField("Instagram account ID (optional)", text: $instagramAccountID)
                }
                if platform != .facebookPages && !(platform == .instagram && instagramAccessMethod == .facebookLogin) {
                    TextField("Verified permissions", text: $reportedScopes, prompt: Text("Optional, separated by commas"))
                    Toggle("Meta issued a long-lived token", isOn: $tokenIsLongLived)
                }
                Toggle("Specify expiration", isOn: $tokenHasExpiration)
                if tokenHasExpiration {
                    DatePicker(tokenExpirationLabel, selection: $tokenExpiration)
                }
            }
        }
    }

    private var tokenImportHelp: String {
        switch platform {
        case .facebookPages:
            return expected == nil
                ? "Paste a Facebook user token from Graph API Explorer. Continue to select an authorized Page."
                : "Paste a fresh Facebook user token with access to the linked Page."
        case .instagram where instagramAccessMethod == .facebookLogin:
            return expected == nil
                ? "Paste a Facebook user token from Graph API Explorer. Continue to choose a professional Instagram account linked to an authorized Page."
                : "Paste a fresh Facebook user token with access to the Page linked to this Instagram account."
        case .instagram:
            return "Use an Instagram user access token for your professional account."
        default:
            return "Use a Threads user access token for the profile you want to connect."
        }
    }

    private var accessTokenLabel: String {
        if platform == .instagram && instagramAccessMethod == .facebookLogin { return "Facebook user access token" }
        if platform == .instagram { return "Instagram user access token" }
        if platform == .facebookPages { return "Facebook user access token" }
        return "Threads user access token"
    }

    private var tokenExpirationLabel: String {
        platform == .facebookPages || platform == .instagram && instagramAccessMethod == .facebookLogin
            ? "User grant expires" : "Token expires"
    }

    private var actionTitle: String {
        if canFinishConnection != nil { return "Done" }
        guard connectionTask == nil else { return "Connecting…" }
        if isMetaPlatform && metaMethod == .accessToken {
            return usesTokenAccountPicker ? "Continue" : "Verify and Save Token"
        }
        if platform == .facebookPages { return "Continue with Facebook" }
        if platform == .instagram, registration.browserInstagramFacebookLogin == true { return "Continue with Facebook" }
        if isMetaPlatform { return "Continue with \(platform.workspaceTitle)" }
        return "Authorize in Browser"
    }

    private var canConnect: Bool {
        if canFinishConnection != nil { return true }
        guard connectionTask == nil else { return false }
        if isMetaPlatform && metaMethod == .accessToken {
            return !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return !isMetaPlatform || metaBrowserReady
    }

    private var usesTokenAccountPicker: Bool {
        guard expected == nil else { return false }
        if platform == .facebookPages { return registration.accountTarget.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return platform == .instagram && instagramAccessMethod == .facebookLogin &&
            instagramAccountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var savedBrokerCredential: String? {
        loadedBroker
    }

    private static let hostedBrokerIdentity = ContentRecipientIdentity(
        platform: "metaBroker", server: URL(string: "https://connect.bravenewdesign.com")!, remoteID: "operator"
    )

    private func loadSavedBroker() {
        loadedBroker = nil
        if let endpoint = URL(string: registration.brokerEndpoint) {
            if usingHostedMetaPreset {
                loadedBroker = SocialOAuthRegistration.exchangeCredential(for: Self.hostedBrokerIdentity, endpoint: endpoint)
            }
            if loadedBroker == nil, let expected {
                loadedBroker = SocialOAuthRegistration.exchangeCredential(for: expected, endpoint: endpoint)
            }
        }
        rememberBroker = loadedBroker != nil
    }

    private var effectiveBrokerCredential: String { brokerCredential.isEmpty ? savedBrokerCredential ?? "" : brokerCredential }

    private var discoversMetaRegistration: Bool {
        isMetaPlatform && (registration.clientID.isEmpty || usingHostedMetaPreset && platform == .threads)
    }

    private var metaBrowserReady: Bool {
        registration.metaBrowserReady(for: platform, associatedDomains: associatedDomains,
                                      allowMissingClientID: discoversMetaRegistration)
            && SocialOAuthBroker.validBearer(effectiveBrokerCredential)
    }

    private func beginConnection() {
        guard !isMetaPlatform || metaBrowserReady else {
            message = "Set up the associated HTTPS callback and trusted exchange service, or connect with a Meta access token."
            return
        }
        let discoverRegistration = discoversMetaRegistration
        guard registration.callback(for: platform) != nil,
              discoverRegistration || platform == .mastodon || !registration.clientID.isEmpty else {
            message = "Enter the public registration values and the exact callback for this provider."
            return
        }
        let instance = URL(string: registration.instance)
        if platform == .mastodon, instance.flatMap(SocialOAuthRegistration.httpsURL) == nil {
            message = "Enter a trusted HTTPS Mastodon server."
            return
        }
        let bearer = effectiveBrokerCredential
        let broker: SocialOAuthBroker?
        if platform.requiresBroker {
            guard let endpoint = URL(string: registration.brokerEndpoint),
                  let validated = try? SocialOAuthBroker(endpoint: endpoint, bearer: bearer) else {
                message = "Enter a trusted HTTPS exchange service and its access credential."
                return
            }
            broker = validated
        } else {
            broker = nil
        }
        let browser = SocialAuthorizationBrowser()
        let rememberForHostedBroker = usingHostedMetaPreset
        var settings = registration
        settings.prefersBrowser = true
        let accountTarget = settings.accountTarget.isEmpty ? nil : settings.accountTarget
        message = nil
        canRetryCredentialSave = false
        brokerCredential = ""
        connectionTask = Task {
            defer { connectionTask = nil }
            do {
                if discoverRegistration, let broker {
                    let hosted: SocialOAuthBroker.Registration
                    do {
                        hosted = try await broker.registration(for: settings.browserInstagramFacebookLogin == true ? .facebookPages : platform)
                    } catch SocialError.httpStatus(503) {
                        message = "\(platform.workspaceTitle) is not configured on the broker yet. Add its app ID and secret in Netlify, or use token import."
                        return
                    } catch SocialError.httpStatus(401) {
                        message = "The broker rejected your password. Enter the current password and try again."
                        return
                    }
                    guard hosted.redirect_uri == settings.redirect else { throw SocialError.invalidConfiguration }
                    settings.clientID = hosted.client_id
                    guard settings.metaBrowserReady(for: platform, associatedDomains: associatedDomains) else {
                        throw SocialError.invalidConfiguration
                    }
                }
                guard let redirect = settings.callback(for: platform) else { throw SocialError.invalidConfiguration }
                let account = try await runtime.connections.connectOAuth(
                    platform: platform, clientID: settings.clientID, redirectURI: redirect,
                    accountTarget: accountTarget, instance: instance, exchange: broker,
                    requestLinkedInActivity: settings.requestLinkedInActivity ?? false,
                    instagramFacebookLogin: settings.browserInstagramFacebookLogin == true,
                    chooseFacebookPage: { pages in try await choosePage(pages) }, expected: expected
                ) { authorizationURL, callbackURL in
                    try await browser.authenticate(authorizationURL, redirect: callbackURL)
                }
                try Task.checkCancellation()
                let identity = SocialOAuthRegistration.identity(for: account)
                settings.save(platform, identity: identity)
                if platform.requiresBroker, let endpoint = URL(string: settings.brokerEndpoint) {
                    do {
                        let credentialIdentity = rememberForHostedBroker ? Self.hostedBrokerIdentity : identity
                        if rememberBroker {
                            try SocialOAuthRegistration.saveExchangeCredential(bearer, for: credentialIdentity, endpoint: endpoint)
                        } else {
                            try SocialOAuthRegistration.removeExchangeCredential(for: credentialIdentity, endpoint: endpoint)
                            if rememberForHostedBroker {
                                try SocialOAuthRegistration.removeExchangeCredential(for: identity, endpoint: endpoint)
                            }
                        }
                    } catch {
                        canFinishConnection = account
                        message = "The account is connected, but Keychain could not remember the exchange credential."
                        return
                    }
                }
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
                let account = try await runtime.connections.retryPendingMastodonCredentialSave(expected: expected)
                try Task.checkCancellation()
                registration.save(.mastodon, identity: SocialOAuthRegistration.identity(for: account))
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
        if let mismatch = error as? ConnectionIdentityMismatch { return mismatch.localizedDescription }
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
                                   && !(platform == .instagram && instagramAccessMethod == .facebookLogin)
                                   ? Date().addingTimeInterval(24 * 60 * 60) : nil)
        accessToken = ""
        message = nil
        connectionTask = Task {
            defer { connectionTask = nil }
            do {
                let account = try await runtime.connections.importMetaToken(
                    token, platform: platform,
                    pageID: platform == .facebookPages ? registration.accountTarget : nil,
                    instagramAccessMethod: instagramAccessMethod,
                    instagramAccountID: platform == .instagram && instagramAccessMethod == .facebookLogin
                        ? instagramAccountID.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
                    expected: expected,
                    chooseAccount: { accounts in try await choosePage(accounts) }
                )
                try Task.checkCancellation()
                var settings = registration
                settings.prefersBrowser = false
                settings.instagramMethod = instagramAccessMethod == .instagramLogin ? "instagram" : "facebook"
                settings.save(platform, identity: SocialOAuthRegistration.identity(for: account))
                onConnected(account)
                dismiss()
            } catch is CancellationError {
                message = "Token verification was canceled."
            } catch let error as SocialError {
                message = "Could not connect \(platform.workspaceTitle): \(error.localizedDescription)"
            } catch {
                message = error.localizedDescription
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

    var prefersBrowser: Bool?
    var instagramMethod: String?
    var browserInstagramFacebookLogin: Bool?

    static func identity(for account: SocialAccount) -> ContentRecipientIdentity {
        .init(platform: account.platform.rawValue, server: account.server, remoteID: account.remoteID)
    }

    static func load(_ platform: SocialPlatform, identity: ContentRecipientIdentity? = nil) -> Self {
        let defaults = UserDefaults.standard
        let data = identity.flatMap { defaults.data(forKey: accountKey($0)) } ?? defaults.data(forKey: key(platform))
        if let data,
           let registration = try? JSONDecoder().decode(Self.self, from: data) {
            return registration
        }
        return Self(redirect: platform == .mastodon ? "\(callbackScheme):/mastodon" : "")
    }

    func save(_ platform: SocialPlatform, identity: ContentRecipientIdentity? = nil) {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key(platform))
            if let identity { UserDefaults.standard.set(data, forKey: Self.accountKey(identity)) }
        }
    }

    private static func key(_ platform: SocialPlatform) -> String { "social.oauth.registration.\(platform.rawValue)" }

    static func accountKey(_ identity: ContentRecipientIdentity) -> String {
        let parts = [identity.platform, identity.server.absoluteString, identity.remoteID]
        let encoded = parts.map { Data($0.utf8).base64EncodedString() }.joined(separator: ".")
        return "social.oauth.account." + encoded
    }

    private static func credentialQuery(_ identity: ContentRecipientIdentity, endpoint: URL) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.bravenewdesign.indiedevbuddy.social.exchange",
            kSecAttrAccount as String: accountKey(identity) + "." + endpoint.absoluteString
        ]
    }

    static func exchangeCredential(for identity: ContentRecipientIdentity, endpoint: URL) -> String? {
        var query = credentialQuery(identity, endpoint: endpoint)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func saveExchangeCredential(_ secret: String, for identity: ContentRecipientIdentity, endpoint: URL) throws {
        let query = credentialQuery(identity, endpoint: endpoint)
        let attributes = [kSecValueData as String: Data(secret.utf8)]
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw SocialError.credentialStorage(updated) }
        let item = query.merging(attributes) { _, new in new }
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw SocialError.credentialStorage(added) }
    }

    static func removeExchangeCredential(for identity: ContentRecipientIdentity, endpoint: URL) throws {
        let status = SecItemDelete(credentialQuery(identity, endpoint: endpoint) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SocialError.credentialStorage(status) }
    }

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

    static func facebookBrowserPreset(associatedDomains: [String]) -> Self? {
        hostedMetaPreset(for: .facebookPages, associatedDomains: associatedDomains)
    }

    static func hostedMetaPreset(for platform: SocialPlatform, associatedDomains: [String]) -> Self? {
        let host = "connect.bravenewdesign.com"
        guard platform.isMeta, associatedDomains.contains("webcredentials:\(host)") else { return nil }
        let throughFacebook = platform == .facebookPages || platform == .instagram
        let path = throughFacebook ? "facebook" : platform.rawValue
        return Self(clientID: throughFacebook ? "1666411485007953" : "",
                    redirect: "https://\(host)/oauth/callback/\(path)",
                    brokerEndpoint: "https://\(host)",
                    browserInstagramFacebookLogin: platform == .instagram ? true : nil)
    }

    func metaBrowserReady(for platform: SocialPlatform, associatedDomains: [String], allowMissingClientID: Bool = false) -> Bool {
        guard platform == .facebookPages || platform == .instagram || platform == .threads,
              allowMissingClientID || !clientID.isEmpty, clientID.utf8.allSatisfy({ (48...57).contains($0) }),
              platform != .facebookPages || accountTarget.utf8.allSatisfy({ (48...57).contains($0) }),
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
