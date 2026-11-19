import Foundation
import SocialKit

extension SocialPlatform {
    nonisolated static func workspacePlatform(_ name: String) -> Self? {
        switch name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "bluesky": .bluesky
        case "facebook", "facebook pages": .facebookPages
        case "threads": .threads
        case "instagram": .instagram
        case "x", "twitter": .x
        case "linkedin": .linkedIn
        case "mastodon": .mastodon
        default: nil
        }
    }

    nonisolated var workspaceTitle: String {
        switch self {
        case .bluesky: "Bluesky"
        case .facebookPages: "Facebook Pages"
        case .threads: "Threads"
        case .instagram: "Instagram"
        case .x: "X"
        case .linkedIn: "LinkedIn"
        case .mastodon: "Mastodon"
        }
    }

    nonisolated var isMeta: Bool {
        self == .facebookPages || self == .instagram || self == .threads
    }

    nonisolated var requiresBroker: Bool {
        switch self {
        case .facebookPages, .threads, .instagram, .linkedIn: true
        default: false
        }
    }
}

/// Non-secret OAuth registration values for this host app. Provider credentials and tokens are
/// never persisted here; SocialKit stores account tokens in the device Keychain.
nonisolated struct SocialConnectionConfiguration: Sendable {
    var facebookAppID: String?
    var facebookRedirectURI: URL?
    var threadsAppID: String?
    var threadsRedirectURI: URL?
    var instagramAppID: String?
    var instagramRedirectURI: URL?
    var xClientID: String?
    var xRedirectURI: URL?
    var xMediaWriteEnabled: Bool
    var linkedInClientID: String?
    var linkedInRedirectURI: URL?
    var linkedInOrganizationURN: String?
    var mastodonRedirectURI: URL?
    var linkedinExchange: (any ConfidentialOAuthExchange)?
    var metaExchange: (any ConfidentialOAuthExchange)?

    init(
        facebookAppID: String? = nil,
        facebookRedirectURI: URL? = nil,
        threadsAppID: String? = nil,
        threadsRedirectURI: URL? = nil,
        instagramAppID: String? = nil,
        instagramRedirectURI: URL? = nil,
        xClientID: String? = nil,
        xRedirectURI: URL? = nil,
        xMediaWriteEnabled: Bool = false,
        linkedInClientID: String? = nil,
        linkedInRedirectURI: URL? = nil,
        linkedInOrganizationURN: String? = nil,
        mastodonRedirectURI: URL? = nil,
        linkedinExchange: (any ConfidentialOAuthExchange)? = nil,
        metaExchange: (any ConfidentialOAuthExchange)? = nil
    ) {
        self.facebookAppID = facebookAppID
        self.facebookRedirectURI = facebookRedirectURI
        self.threadsAppID = threadsAppID
        self.threadsRedirectURI = threadsRedirectURI
        self.instagramAppID = instagramAppID
        self.instagramRedirectURI = instagramRedirectURI
        self.xClientID = xClientID
        self.xRedirectURI = xRedirectURI
        self.xMediaWriteEnabled = xMediaWriteEnabled
        self.linkedInClientID = linkedInClientID
        self.linkedInRedirectURI = linkedInRedirectURI
        self.linkedInOrganizationURN = linkedInOrganizationURN
        self.mastodonRedirectURI = mastodonRedirectURI
        self.linkedinExchange = linkedinExchange
        self.metaExchange = metaExchange
    }
}

/// App-only facade around SocialKit. Keep account identity and credentials bound to the provider
/// Keychain record; workspace account handles are descriptive metadata, never credential keys.
actor SocialConnections {
    private let store: any CredentialStore
    private let configuration: SocialConnectionConfiguration
    private let bluesky: SocialClient<BlueskyAdapter>
    private let facebook: SocialClient<FacebookPagesAdapter>
    private let threads: SocialClient<ThreadsAdapter>
    private let instagram: SocialClient<InstagramAdapter>
    private let x: SocialClient<XAdapter>
    private var xClients: [String: SocialClient<XAdapter>] = [:]
    private var linkedInClients: [SocialAccount.ID: SocialClient<LinkedInAdapter>] = [:]
    private let verificationTransport: any HTTPTransport
    private let linkedIn: SocialClient<LinkedInAdapter>
    private let mastodon: SocialClient<MastodonAdapter>
    private var metaChecks: [SocialAccount.ID: Task<Void, Error>] = [:]
    private var metaCheckResults: [SocialAccount.ID: MetaCheckResult] = [:]
    private static let metaCheckInterval: TimeInterval = 6 * 60 * 60
    private static let metaRenewalWindow: TimeInterval = 7 * 24 * 60 * 60

    private struct MetaCheckResult {
        let nextCheck: Date
        let failures: Int
        let error: SocialError?
    }

    private var authorizingPlatforms: Set<SocialPlatform> = []
    private var recoveryTasks: [SocialAccount.ID: Task<Recovery, Never>] = [:]
    private var recoveryRetryAt: [SocialAccount.ID: Date] = [:]

    enum Recovery: Equatable, Sendable {
        case ready, renewed, missingCredential, authorizationRequired, permissionsRequired
        case keychainUnavailable, retryLater, configurationRequired, rateLimited(until: Date)

        var isAvailable: Bool { self == .ready || self == .renewed }

        var message: String {
            switch self {
            case .ready: "The saved connection is available."
            case .renewed: "Indie Dev Buddy renewed your saved authorization and stored it in Keychain."
            case .missingCredential: "This account is linked to the workspace, but its credential is missing from this Mac’s Keychain."
            case .authorizationRequired: "The saved authorization has expired or the provider rejected it. This account needs fresh authorization."
            case .permissionsRequired: "Authorize the required permissions to restore this account."
            case .keychainUnavailable: "Keychain is unavailable. Unlock it and check again."
            case .retryLater: "The provider could not be checked right now. Indie Dev Buddy kept your saved credential and will retry."
            case .rateLimited(let until):
                "The provider asked Indie Dev Buddy to wait. Try again after \(until.formatted(date: .abbreviated, time: .shortened))."
            case .configurationRequired: "Review this account’s connection setup."
            }
        }

        var needsAuthorization: Bool {
            self == .missingCredential || self == .authorizationRequired || self == .permissionsRequired || self == .configurationRequired
        }
    }

    func recover(_ identity: ContentRecipientIdentity, force: Bool = false, manual: Bool = false) async -> Recovery {
        guard let id = try? accountID(for: identity) else { return .configurationRequired }
        if !manual && (id.platform == .x || id.platform == .linkedIn) {
            // Background connection health for manual-only platforms comes from local credentials.
            do {
                guard let credential = try await store.credential(for: id) else { return .missingCredential }
                return credential.expiresAt.map { $0 <= .now } == true ? .authorizationRequired : .ready
            } catch {
                return .keychainUnavailable
            }
        }
        if let task = recoveryTasks[id] { return await task.value }
        if let retryAt = recoveryRetryAt[id], retryAt > .now { return .rateLimited(until: retryAt) }
        let task = Task { await runRecovery(for: id, force: force, manual: manual) }
        recoveryTasks[id] = task
        return await task.value
    }

    private func runRecovery(for id: SocialAccount.ID, force: Bool, manual: Bool) async -> Recovery {
        defer { recoveryTasks.removeValue(forKey: id) }
        do {
            guard let saved = try await store.credential(for: id) else { return .missingCredential }
            try await refreshCredentialsIfNeeded(for: id, force: force, checkingConnection: true, manual: manual)
            recoveryRetryAt.removeValue(forKey: id)
            if let current = try await store.credential(for: id),
               current.accessToken != saved.accessToken || current.expiresAt != saved.expiresAt {
                return .renewed
            }
            return .ready
        } catch let error as SocialError {
            switch error {
            case .authenticationRequired, .authorizationFailed, .unsupported(.refreshSession), .httpStatus(401):
                return .authorizationRequired
            case .permissionDenied, .permissionDeniedAt, .httpStatus(403):
                return .permissionsRequired
            case .credentialStorage: return .keychainUnavailable
            case .invalidConfiguration: return .configurationRequired
            case .rateLimited(let retryAfter):
                let delay = max(300, retryAfter.flatMap(TimeInterval.init) ?? 0)
                let retryAt = Date().addingTimeInterval(delay)
                recoveryRetryAt[id] = retryAt
                return .rateLimited(until: retryAt)
            default: return .retryLater
            }
        } catch {
            return .retryLater
        }
    }

    private func validateConnection(_ account: SocialAccount, expected: ContentRecipientIdentity?) throws {
        guard let expected else { return }
        guard try accountID(for: expected) == account.id else { throw ConnectionIdentityMismatch() }
    }

    private func connectVerified<Adapter: SocialAdapter>(
        _ adapter: Adapter, using client: SocialClient<Adapter>,
        authorization: Adapter.Authorization, expected: ContentRecipientIdentity?
    ) async throws -> SocialAccount {
        guard authorizingPlatforms.insert(adapter.platform).inserted else { throw SocialError.accountBusy }
        defer { authorizingPlatforms.remove(adapter.platform) }
        let credential = try await adapter.connect(authorization)
        try validateConnection(credential.account, expected: expected)
        return try await client.saveVerifiedCredential(credential)
    }

    private var pendingMastodonCredential: SocialCredential?

    init(
        serviceName: String = "com.bravenewdesign.indiedevbuddy.social",
        configuration: SocialConnectionConfiguration = .init(),
        credentialStore: (any CredentialStore)? = nil,
        metaTransport: any HTTPTransport = URLSessionTransport()
    ) {
        let store = credentialStore ?? KeychainCredentialStore(service: serviceName)
        self.store = store
        self.configuration = configuration
        verificationTransport = metaTransport
        bluesky = SocialClient(adapter: BlueskyAdapter(transport: metaTransport), store: store)
        facebook = SocialClient(adapter: FacebookPagesAdapter(transport: metaTransport), store: store)
        threads = SocialClient(adapter: ThreadsAdapter(transport: metaTransport), store: store)
        instagram = SocialClient(adapter: InstagramAdapter(transport: metaTransport), store: store)
        x = SocialClient(adapter: XAdapter(clientID: configuration.xClientID ?? "",
                                            includeMediaWriteScope: configuration.xMediaWriteEnabled), store: store)
        if let clientID = configuration.xClientID { xClients[clientID] = x }
        linkedIn = SocialClient(adapter: LinkedInAdapter(oauthBroker: configuration.linkedinExchange), store: store)
        mastodon = SocialClient(adapter: MastodonAdapter(), store: store)
    }

    private func xClient(clientID: String) -> SocialClient<XAdapter> {
        if let client = xClients[clientID] { return client }
        let client = SocialClient(adapter: XAdapter(clientID: clientID,
                                                  includeMediaWriteScope: configuration.xMediaWriteEnabled), store: store)
        xClients[clientID] = client
        return client
    }

    private func xClient(for id: SocialAccount.ID) -> SocialClient<XAdapter> {
        let registration = SocialOAuthRegistration.load(.x, identity: identity(for: id))
        return registration.clientID.isEmpty ? x : xClient(clientID: registration.clientID)
    }

    private func linkedinClient(for id: SocialAccount.ID) -> SocialClient<LinkedInAdapter> {
        if let client = linkedInClients[id] { return client }
        let identity = identity(for: id)
        let registration = SocialOAuthRegistration.load(.linkedIn, identity: identity)
        guard let endpoint = URL(string: registration.brokerEndpoint),
              let bearer = SocialOAuthRegistration.exchangeCredential(for: identity, endpoint: endpoint),
              let broker = try? SocialOAuthBroker(endpoint: endpoint, bearer: bearer) else { return linkedIn }
        let client = SocialClient(adapter: LinkedInAdapter(oauthBroker: broker), store: store)
        linkedInClients[id] = client
        return client
    }

    private func identity(for id: SocialAccount.ID) -> ContentRecipientIdentity {
        .init(platform: id.platform.rawValue, server: id.server, remoteID: id.remoteID)
    }

    func didAuthorize(_ id: SocialAccount.ID) async {
        if let task = recoveryTasks[id] { _ = await task.value }
        recoveryRetryAt.removeValue(forKey: id)
        linkedInClients.removeValue(forKey: id)
        if id.platform.isMeta { await clearMetaCheckResult(for: id) }
    }

    func accounts() async throws -> [SocialAccount] {
        try await store.accounts().sorted {
            ($0.platform.rawValue, $0.server.absoluteString, $0.username)
                < ($1.platform.rawValue, $1.server.absoluteString, $1.username)
        }
    }

    func refresh(_ identity: ContentRecipientIdentity) async throws -> SocialAccount {
        let id = try accountID(for: identity)
        switch id.platform {
        case .bluesky: return try await bluesky.refresh(id)
        case .facebookPages: return try await facebook.refresh(id)
        case .threads: return try await threads.refresh(id)
        case .instagram: return try await instagram.refresh(id)
        case .x: return try await xClient(for: id).refresh(id)
        case .linkedIn: return try await linkedinClient(for: id).refresh(id)
        case .mastodon: return try await mastodon.refresh(id)
        }
    }

    func capabilities(for identity: ContentRecipientIdentity) async throws -> Set<SocialCapability> {
        let id = try accountID(for: identity)
        switch id.platform {
        case .bluesky: return try await bluesky.capabilities(for: id)
        case .facebookPages: return try await facebook.capabilities(for: id)
        case .threads: return try await threads.capabilities(for: id)
        case .instagram: return try await instagram.capabilities(for: id)
        case .x: return try await xClient(for: id).capabilities(for: id)
        case .linkedIn: return try await linkedinClient(for: id).capabilities(for: id)
        case .mastodon: return try await mastodon.capabilities(for: id)
        }
    }

    func resolveBlueskyMentions(in text: String, for identity: ContentRecipientIdentity) async throws -> [ContentScheduledMention] {
        let id = try accountID(for: identity)
        guard id.platform == .bluesky else { throw SocialError.unsupported(.resolveMentions) }
        let expression = try NSRegularExpression(pattern: #"(?<![A-Za-z0-9._-])@([A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+)"#)
        let matches = expression.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
        var result: [ContentScheduledMention] = []
        for match in matches {
            guard let range = Range(match.range, in: text), let handleRange = Range(match.range(at: 1), in: text),
                  let start = range.lowerBound.samePosition(in: text.utf8),
                  let end = range.upperBound.samePosition(in: text.utf8) else { throw SocialError.invalidInput }
            let did = try await bluesky.resolveMention(String(text[handleRange]), as: id)
            result.append(ContentScheduledMention(
                byteStart: text.utf8.distance(from: text.utf8.startIndex, to: start),
                byteEnd: text.utf8.distance(from: text.utf8.startIndex, to: end), subjectID: did
            ))
        }
        return result
    }

    func deliver(
        _ intent: ContentDeliveryIntent, checkpoint: MetaPublishingCheckpoint?,
        saveCheckpoint: @escaping MetaPublishingCheckpointWriter
    ) async throws -> ContentDeliveryResult {
        let id = try accountID(for: intent.recipient)
        guard let server = URL(string: intent.recipient.server.absoluteString),
              server == id.server else { throw SocialError.invalidInput }

        do {
            if let recovery = recoveryTasks[id] { _ = await recovery.value }
            try await refreshCredentialsIfNeeded(for: id)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SocialError {
            return ContentDeliveryResult(state: .failed, message: Self.refreshFailureMessage(error))
        } catch {
            return ContentDeliveryResult(state: .failed,
                                         message: "The account could not be refreshed. Reconnect it before scheduled delivery.")
        }

        let mentions = (intent.mentions ?? []).map {
            SocialMention(byteStart: $0.byteStart, byteEnd: $0.byteEnd, subjectID: $0.subjectID)
        }
        let draft = TextPost(text: intent.text, idempotencyKey: intent.draftID,
                             createdAt: intent.draftCreatedAt, mentions: mentions)
        let media: [SocialMedia] = try intent.media.map { item in
            guard item.publicURL.scheme?.lowercased() == "https", item.publicURL.host != nil else {
                throw SocialError.invalidInput
            }
            switch item.kind {
            case .image: return SocialMedia.imageURL(item.publicURL)
            case .video: return SocialMedia.videoURL(item.publicURL)
            }
        }

        do {
            let post: SocialPost
            switch id.platform {
            case .bluesky:
                guard media.isEmpty else { throw SocialError.unsupported(.publishMedia) }
                post = try await bluesky.publish(draft, as: id)
            case .facebookPages:
                post = media.isEmpty
                    ? try await facebook.publish(draft, as: id)
                    : try await facebook.publishMedia(media, draft: draft, as: id)
            case .threads:
                post = try await threads.publishCheckpointedMetaPost(
                    media, draft: draft, as: id, checkpoint: checkpoint, save: saveCheckpoint
                )
            case .instagram:
                guard !media.isEmpty else { throw SocialError.invalidInput }
                post = try await instagram.publishCheckpointedMetaPost(
                    media, draft: draft, as: id, checkpoint: checkpoint, save: saveCheckpoint
                )
            case .x:
                guard media.isEmpty else {
                    // X requires uploaded image bytes; a public URL is not an interchangeable payload.
                    throw SocialError.unsupported(.publishMedia)
                }
                post = try await xClient(for: id).publish(draft, as: id)
            case .linkedIn:
                guard media.isEmpty else {
                    // LinkedIn also requires image bytes and an explicitly selected upload flow.
                    throw SocialError.unsupported(.publishMedia)
                }
                post = try await linkedinClient(for: id).publish(draft, as: id)
            case .mastodon:
                guard media.isEmpty else { throw SocialError.unsupported(.publishMedia) }
                post = try await mastodon.publish(draft, as: id)
            }
            return ContentDeliveryResult(state: .delivered, providerPostID: post.id, publishedURL: post.url)
        } catch let error as SocialError where (id.platform == .instagram || id.platform == .threads)
            && Self.canPauseMetaPolling(after: error) {
            throw PublishingCoordinator.PollingPaused.unavailable
        } catch let error as PublishingCoordinator.PollingPaused {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch SocialError.publishOutcomeUnknown(_) {
            return ContentDeliveryResult(state: .outcomeUnknown,
                                         message: "The provider may have accepted this post. Check it before retrying.")
        } catch let error as SocialError where Self.isDefiniteRejection(error) {
            return ContentDeliveryResult(state: .failed, message: error.localizedDescription)
        } catch {
            return ContentDeliveryResult(state: .outcomeUnknown,
                                         message: "Delivery may have reached the provider. Check the account before retrying.")
        }
    }

    func wasMetaContainerPublished(_ checkpoint: MetaPublishingCheckpoint, for intent: ContentDeliveryIntent) async throws -> Bool {
        let id = try accountID(for: intent.recipient)
        switch id.platform {
        case .threads: return try await threads.wasMetaContainerPublished(checkpoint, as: id)
        case .instagram: return try await instagram.wasMetaContainerPublished(checkpoint, as: id)
        default: return false
        }
    }

    func posts(for identity: ContentRecipientIdentity, cursor: String? = nil) async throws -> SocialPage<SocialPost> {
        let id = try accountID(for: identity)
        switch id.platform {
        case .bluesky: return try await bluesky.posts(cursor: cursor, as: id)
        case .facebookPages: return try await facebook.posts(cursor: cursor, as: id)
        case .threads: return try await threads.posts(cursor: cursor, as: id)
        case .instagram: return try await instagram.posts(cursor: cursor, as: id)
        case .x: return try await xClient(for: id).posts(cursor: cursor, as: id)
        case .linkedIn: return try await linkedinClient(for: id).posts(cursor: cursor, as: id)
        case .mastodon: return try await mastodon.posts(cursor: cursor, as: id)
        }
    }

    func post(_ postID: String, for identity: ContentRecipientIdentity) async throws -> SocialPost {
        let id = try accountID(for: identity)
        switch id.platform {
        case .bluesky: return try await bluesky.post(id: postID, as: id)
        case .facebookPages: return try await facebook.post(id: postID, as: id)
        case .threads: return try await threads.post(id: postID, as: id)
        case .instagram: return try await instagram.post(id: postID, as: id)
        case .x: return try await xClient(for: id).post(id: postID, as: id)
        case .linkedIn: return try await linkedinClient(for: id).post(id: postID, as: id)
        case .mastodon: return try await mastodon.post(id: postID, as: id)
        }
    }

    /// An explicit, single-post read. Use the same stored account and redirect-rejecting
    /// transport as the Meta adapters, and only query the documented metric set.
    func postInsights(_ postID: String, for identity: ContentRecipientIdentity) async throws -> [String: Int] {
        let id = try accountID(for: identity)
        guard id.platform.isMeta, postID.range(of: #"^[0-9]+(?:_[0-9]+)?$"#, options: .regularExpression) != nil else {
            throw SocialError.invalidInput
        }
        guard let credential = try await store.credential(for: id), credential.account.id == id else {
            throw SocialError.authenticationRequired
        }

        let host: String
        let version: String
        let scope: String
        let metrics: [String]
        switch id.platform {
        case .facebookPages:
            host = "graph.facebook.com"
            version = "v27.0"
            scope = "read_insights"
            metrics = ["post_media_view", "post_total_media_view_unique"]
        case .instagram:
            let instagramLogin = id.server.host == "graph.instagram.com"
            host = instagramLogin ? "graph.instagram.com" : "graph.facebook.com"
            version = "v27.0"
            scope = instagramLogin ? "instagram_business_manage_insights" : "instagram_manage_insights"
            metrics = ["views", "reach", "likes", "comments", "saved", "shares"]
        case .threads:
            host = "graph.threads.net"
            version = "v1.0"
            scope = "threads_manage_insights"
            metrics = ["views", "likes", "replies", "reposts", "quotes", "shares"]
        default:
            throw SocialError.invalidInput
        }
        if credential.grantedScopes?.contains(scope) == false {
            throw SocialError.permissionDeniedAt(scope)
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/\(version)/\(postID)/insights"
        components.queryItems = [URLQueryItem(name: "metric", value: metrics.joined(separator: ","))]
        guard let url = components.url else { throw SocialError.invalidConfiguration }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        let response = try await verificationTransport.send(request)
        let payload = try? JSONDecoder().decode(PostInsightsResponse.self, from: response.body)
        let code = payload?.error?.code
        if response.statusCode == 429 || [4, 17, 32, 613].contains(code ?? -1) {
            throw SocialError.rateLimited(retryAfter: response.header("Retry-After"))
        }
        if response.statusCode == 401 || [102, 190].contains(code ?? -1) { throw SocialError.authenticationRequired }
        if response.statusCode == 403 || [10, 200].contains(code ?? -1) { throw SocialError.permissionDeniedAt(scope) }
        guard (200..<300).contains(response.statusCode), let entries = payload?.data else {
            throw SocialError.httpStatus(response.statusCode)
        }
        var result: [String: Int] = [:]
        for entry in entries where metrics.contains(entry.name) {
            if let value = entry.total_value?.value ?? entry.values?.last?.value, value >= 0 {
                result[entry.name] = value
            }
        }
        return result
    }

    private nonisolated struct PostInsightsResponse: Decodable {
        struct Entry: Decodable {
            struct Value: Decodable {
                let value: Int?

                init(from decoder: Decoder) throws {
                    let fields = try decoder.container(keyedBy: CodingKeys.self)
                    value = try? fields.decode(Int.self, forKey: .value)
                }

                private enum CodingKeys: String, CodingKey { case value }
            }

            let name: String
            let values: [Value]?
            let total_value: Value?
        }

        struct Failure: Decodable { let code: Int }
        let data: [Entry]?
        let error: Failure?
    }

    func replies(to postID: String, for identity: ContentRecipientIdentity, cursor: String? = nil) async throws -> SocialPage<SocialPost> {
        let id = try accountID(for: identity)
        switch id.platform {
        case .bluesky, .mastodon: throw SocialError.unsupported(.readReplies)
        case .facebookPages: return try await facebook.replies(to: postID, cursor: cursor, as: id)
        case .threads: return try await threads.replies(to: postID, cursor: cursor, as: id)
        case .instagram: return try await instagram.replies(to: postID, cursor: cursor, as: id)
        case .x: return try await xClient(for: id).replies(to: postID, cursor: cursor, as: id)
        case .linkedIn: return try await linkedinClient(for: id).replies(to: postID, cursor: cursor, as: id)
        }
    }

    func reply(_ text: String, to postID: String, for identity: ContentRecipientIdentity) async throws -> SocialPost {
        let id = try accountID(for: identity)
        let draft = TextPost(text: text)
        switch id.platform {
        case .bluesky, .mastodon: throw SocialError.unsupported(.reply)
        case .facebookPages: return try await facebook.reply(draft, to: postID, as: id)
        case .threads: return try await threads.reply(draft, to: postID, as: id)
        case .instagram: return try await instagram.reply(draft, to: postID, as: id)
        case .x: return try await xClient(for: id).reply(draft, to: postID, as: id)
        case .linkedIn: return try await linkedinClient(for: id).reply(draft, to: postID, as: id)
        }
    }

    func setLiked(_ liked: Bool, postID: String, for identity: ContentRecipientIdentity) async throws {
        let id = try accountID(for: identity)
        switch id.platform {
        case .bluesky:
            guard liked else { throw SocialError.unsupported(.unlike) }
            try await bluesky.setLiked(true, postID: postID, as: id)
        case .facebookPages: try await facebook.setLiked(liked, postID: postID, as: id)
        case .threads, .instagram: throw SocialError.unsupported(liked ? .like : .unlike)
        case .x: try await xClient(for: id).setLiked(liked, postID: postID, as: id)
        case .linkedIn: try await linkedinClient(for: id).setLiked(liked, postID: postID, as: id)
        case .mastodon: try await mastodon.setLiked(liked, postID: postID, as: id)
        }
    }

    func setReposted(_ reposted: Bool, postID: String, for identity: ContentRecipientIdentity) async throws {
        let id = try accountID(for: identity)
        switch id.platform {
        case .threads: try await threads.setReposted(reposted, postID: postID, as: id)
        case .x: try await xClient(for: id).setReposted(reposted, postID: postID, as: id)
        case .bluesky, .facebookPages, .instagram, .linkedIn, .mastodon:
            throw SocialError.unsupported(reposted ? .repost : .unrepost)
        }
    }

    func setReplyHidden(_ hidden: Bool, replyID: String, for identity: ContentRecipientIdentity) async throws {
        let id = try accountID(for: identity)
        switch id.platform {
        case .threads: try await threads.setReplyHidden(hidden, id: replyID, as: id)
        case .bluesky, .facebookPages, .instagram, .linkedIn, .mastodon, .x:
            throw SocialError.unsupported(.moderateReplies)
        }
    }

    func deleteReply(_ replyID: String, for identity: ContentRecipientIdentity) async throws {
        let id = try accountID(for: identity)
        switch id.platform {
        case .facebookPages: try await facebook.deleteReply(id: replyID, as: id)
        case .threads: try await threads.deleteReply(id: replyID, as: id)
        case .instagram: try await instagram.deleteReply(id: replyID, as: id)
        case .x: try await xClient(for: id).deleteReply(id: replyID, as: id)
        case .bluesky, .linkedIn, .mastodon: throw SocialError.unsupported(.deleteReply)
        }
    }

    func disconnect(_ identity: ContentRecipientIdentity) async throws {
        let id = try accountID(for: identity)
        switch id.platform {
        case .bluesky: try await bluesky.disconnect(id)
        case .facebookPages: try await facebook.disconnect(id)
        case .threads: try await threads.disconnect(id)
        case .instagram: try await instagram.disconnect(id)
        case .x: try await xClient(for: id).disconnect(id)
        case .linkedIn: try await linkedinClient(for: id).disconnect(id)
        case .mastodon: try await mastodon.disconnect(id)
        }
        metaCheckResults.removeValue(forKey: id)
    }

    func connectBluesky(identifier: String, appPassword: String, server: URL = URL(string: "https://bsky.social")!, expected: ContentRecipientIdentity? = nil) async throws -> SocialAccount {
        try await connectVerified(BlueskyAdapter(transport: verificationTransport), using: bluesky,
                                  authorization: .init(identifier: identifier, appPassword: appPassword, server: server), expected: expected)
    }

    /// Imports a user-generated Meta access token without sending it through an exchange service.
    /// The provider adapters verify the token against the selected account before it is stored.
    func importMetaToken(
        _ token: OAuthToken,
        platform: SocialPlatform,
        pageID: String? = nil,
        instagramAccessMethod: InstagramAccessMethod = .instagramLogin,
        instagramAccountID: String? = nil,
        expected: ContentRecipientIdentity? = nil,
        chooseAccount: (@MainActor @Sendable ([SocialAccount]) async throws -> String)? = nil
    ) async throws -> SocialAccount {
        let credential: SocialCredential
        switch platform {
        case .facebookPages:
            let adapter = FacebookPagesAdapter(transport: verificationTransport)
            let selectedID: String
            if let supplied = expected?.remoteID ?? pageID?.trimmingCharacters(in: .whitespacesAndNewlines), !supplied.isEmpty {
                selectedID = supplied
            } else if let chooseAccount {
                selectedID = try await chooseMetaAccount(adapter.discoverPages(token), choose: chooseAccount)
            } else {
                throw SocialError.invalidInput
            }
            credential = try await adapter.developmentCredential(token, pageID: selectedID)
        case .threads:
            credential = try await ThreadsAdapter(transport: verificationTransport).developmentCredential(token)
        case .instagram:
            var selectedID = instagramAccountID
            if instagramAccessMethod == .facebookLogin {
                selectedID = expected?.remoteID ?? selectedID?.trimmingCharacters(in: .whitespacesAndNewlines)
                if selectedID?.isEmpty != false, let chooseAccount {
                    selectedID = try await chooseMetaAccount(linkedInstagramProfiles(token), choose: chooseAccount)
                }
            }
            credential = try await InstagramAdapter(transport: verificationTransport).developmentCredential(
                token, accessMethod: instagramAccessMethod, instagramAccountID: selectedID
            )
        default:
            throw SocialError.invalidInput
        }
        try Task.checkCancellation()
        try validateConnection(credential.account, expected: expected)
        let account: SocialAccount
        switch platform {
        case .facebookPages: account = try await facebook.saveVerifiedCredential(credential)
        case .threads: account = try await threads.saveVerifiedCredential(credential)
        case .instagram: account = try await instagram.saveVerifiedCredential(credential)
        default: throw SocialError.invalidInput
        }
        await clearMetaCheckResult(for: account.id)
        return account
    }

    func connectFacebookPages(pageID: String? = nil, browser: @escaping OAuthBrowser) async throws -> SocialAccount {
        guard let clientID = configuration.facebookAppID, let redirectURI = configuration.facebookRedirectURI,
              let exchange = configuration.metaExchange else { throw SocialError.invalidConfiguration }
        return try await facebook.connect(.init(clientID: clientID, redirectURI: redirectURI,
                                                pageID: pageID, browser: browser, exchange: exchange))
    }

    func connectThreads(browser: @escaping OAuthBrowser) async throws -> SocialAccount {
        guard let clientID = configuration.threadsAppID, let redirectURI = configuration.threadsRedirectURI,
              let exchange = configuration.metaExchange else { throw SocialError.invalidConfiguration }
        return try await threads.connect(.init(clientID: clientID, redirectURI: redirectURI,
                                               browser: browser, exchange: exchange))
    }

    func connectInstagram(browser: @escaping OAuthBrowser) async throws -> SocialAccount {
        guard let clientID = configuration.instagramAppID, let redirectURI = configuration.instagramRedirectURI,
              let exchange = configuration.metaExchange else { throw SocialError.invalidConfiguration }
        return try await instagram.connect(.init(clientID: clientID, redirectURI: redirectURI,
                                                 browser: browser, exchange: exchange))
    }

    func connectX(browser: @escaping OAuthBrowser) async throws -> SocialAccount {
        guard configuration.xClientID != nil, let redirectURI = configuration.xRedirectURI else {
            throw SocialError.invalidConfiguration
        }
        return try await x.connect(.init(redirectURI: redirectURI, browser: browser))
    }

    func connectLinkedIn(browser: @escaping OAuthBrowser) async throws -> SocialAccount {
        guard let clientID = configuration.linkedInClientID, let redirectURI = configuration.linkedInRedirectURI,
              configuration.linkedinExchange != nil else { throw SocialError.invalidConfiguration }
        return try await linkedIn.connect(.init(clientID: clientID, redirectURI: redirectURI,
                                                organizationURN: configuration.linkedInOrganizationURN,
                                                browser: browser))
    }

    func connectMastodon(server: URL, browser: @escaping OAuthBrowser) async throws -> SocialAccount {
        guard let redirectURI = configuration.mastodonRedirectURI else { throw SocialError.invalidConfiguration }
        return try await mastodon.connect(.init(server: server, redirectURI: redirectURI,
                                                applicationName: "Indie Dev Buddy", browser: browser))
    }

    func connectOAuth(
        platform: SocialPlatform,
        clientID: String,
        redirectURI: URL,
        accountTarget: String?,
        instance: URL?,
        exchange: (any ConfidentialOAuthExchange)?,
        requestLinkedInActivity: Bool = false,
        instagramFacebookLogin: Bool = false,
        chooseFacebookPage: (@MainActor @Sendable ([SocialAccount]) async throws -> String)? = nil,
        expected: ContentRecipientIdentity? = nil,
        browser: @escaping OAuthBrowser
    ) async throws -> SocialAccount {
        switch platform {
        case .facebookPages:
            guard let exchange else { throw SocialError.invalidConfiguration }
            let adapter = FacebookPagesAdapter(transport: verificationTransport)
            let scopes: Set<String> = ["pages_show_list", "pages_manage_posts", "pages_read_engagement",
                                       "pages_manage_engagement", "pages_read_user_content", "read_insights"]
            if accountTarget == nil, expected == nil, let chooseFacebookPage,
               let sessionExchange = exchange as? any SessionBoundMetaOAuthExchange {
                guard authorizingPlatforms.insert(.facebookPages).inserted else { throw SocialError.accountBusy }
                defer { authorizingPlatforms.remove(.facebookPages) }
                let token = try await facebookUserGrant(clientID: clientID, redirectURI: redirectURI,
                                                        scopes: scopes, broker: sessionExchange, browser: browser)
                let pages = try await adapter.discoverPages(token)
                let pageID = try await chooseMetaAccount(pages, choose: chooseFacebookPage)
                return try await importMetaToken(token, platform: .facebookPages, pageID: pageID)
            }
            let account = try await connectVerified(adapter, using: facebook,
                authorization: .init(clientID: clientID, redirectURI: redirectURI, pageID: accountTarget,
                                     scopes: scopes, browser: browser, exchange: exchange), expected: expected)
            await clearMetaCheckResult(for: account.id)
            return account
        case .threads:
            guard let exchange else { throw SocialError.invalidConfiguration }
            let account = try await connectVerified(ThreadsAdapter(transport: verificationTransport), using: threads, authorization: .init(clientID: clientID, redirectURI: redirectURI,
                                                   scopes: ["threads_basic", "threads_content_publish", "threads_read_replies",
                                                            "threads_manage_replies", "threads_delete", "threads_manage_insights"],
                                                   browser: browser, exchange: exchange), expected: expected)
            await clearMetaCheckResult(for: account.id)
            return account
        case .instagram:
            guard let exchange else { throw SocialError.invalidConfiguration }
            if instagramFacebookLogin {
                guard let broker = exchange as? any SessionBoundMetaOAuthExchange,
                      let chooseFacebookPage else { throw SocialError.invalidConfiguration }
                guard authorizingPlatforms.insert(.instagram).inserted else { throw SocialError.accountBusy }
                defer { authorizingPlatforms.remove(.instagram) }
                let scopes: Set<String> = ["pages_show_list", "pages_read_engagement", "instagram_basic",
                                           "instagram_content_publish", "instagram_manage_comments", "instagram_manage_insights"]
                let token = try await facebookUserGrant(clientID: clientID, redirectURI: redirectURI,
                                                        scopes: scopes, broker: broker, browser: browser)
                let instagramID: String
                if let expected { instagramID = expected.remoteID }
                else {
                    let profiles = try await linkedInstagramProfiles(token)
                    instagramID = try await chooseMetaAccount(profiles, choose: chooseFacebookPage)
                }
                return try await importMetaToken(token, platform: .instagram, instagramAccessMethod: .facebookLogin,
                                                 instagramAccountID: instagramID, expected: expected)
            }
            let account = try await connectVerified(InstagramAdapter(transport: verificationTransport), using: instagram, authorization: .init(clientID: clientID, redirectURI: redirectURI,
                                                     scopes: ["instagram_business_basic", "instagram_business_content_publish",
                                                              "instagram_business_manage_comments", "instagram_business_manage_insights"],
                                                     browser: browser, exchange: exchange), expected: expected)
            await clearMetaCheckResult(for: account.id)
            return account
        case .x:
            let adapter = XAdapter(clientID: clientID)
            let client = xClient(clientID: clientID)
            return try await connectVerified(adapter, using: client, authorization: .init(redirectURI: redirectURI, browser: browser), expected: expected)
        case .linkedIn:
            guard let exchange else { throw SocialError.invalidConfiguration }
            let adapter = LinkedInAdapter(oauthBroker: exchange)
            let client = try expected.map { linkedinClient(for: try accountID(for: $0)) } ?? linkedIn
            let scopes: Set<String>? = requestLinkedInActivity
                ? (accountTarget == nil
                    ? ["openid", "profile", "w_member_social", "r_member_social", "w_member_social_feed", "r_member_social_feed"]
                    : ["openid", "profile", "w_organization_social", "r_organization_social", "w_organization_social_feed", "r_organization_social_feed"])
                : nil
            return try await connectVerified(adapter, using: client, authorization: .init(clientID: clientID, redirectURI: redirectURI,
                                              scopes: scopes, organizationURN: accountTarget, browser: browser), expected: expected)
        case .mastodon:
            guard let instance else { throw SocialError.invalidConfiguration }
            let credential = try await MastodonAdapter().connect(.init(
                server: instance,
                redirectURI: redirectURI,
                applicationName: "Indie Dev Buddy",
                browser: browser
            ))
            try validateConnection(credential.account, expected: expected)
            try Task.checkCancellation()
            do {
                _ = try await mastodon.saveVerifiedCredential(credential)
                pendingMastodonCredential = nil
                return credential.account
            } catch {
                pendingMastodonCredential = credential
                throw error
            }
        case .bluesky: throw SocialError.invalidConfiguration
        }
    }

    func retryPendingMastodonCredentialSave(expected: ContentRecipientIdentity? = nil) async throws -> SocialAccount {
        guard let credential = pendingMastodonCredential else { throw SocialError.invalidConfiguration }
        try validateConnection(credential.account, expected: expected)
        _ = try await mastodon.saveVerifiedCredential(credential)
        pendingMastodonCredential = nil
        return credential.account
    }

    func discardPendingMastodonCredential() {
        pendingMastodonCredential = nil
    }

    func testCredentialStorage() async throws {
        guard let server = URL(string: "https://keychain-diagnostic.invalid") else {
            throw SocialError.invalidConfiguration
        }
        let account = SocialAccount(
            platform: .mastodon,
            server: server,
            remoteID: UUID().uuidString,
            username: "keychain-diagnostic"
        )
        let credential = SocialCredential(account: account, accessToken: "temporary-keychain-diagnostic")
        try await store.save(credential)
        try await store.remove(account.id)
    }

    private func facebookUserGrant(clientID: String, redirectURI: URL, scopes: Set<String>,
                                   broker: any SessionBoundMetaOAuthExchange, browser: @escaping OAuthBrowser) async throws -> OAuthToken {
        // SocialKit validates the callback and state before the one-time grant goes to discovery.
        do {
            let adapter = FacebookPagesAdapter(transport: verificationTransport)
            _ = try await adapter.connect(.init(clientID: clientID, redirectURI: redirectURI, scopes: scopes,
                                               browser: browser, exchange: FacebookPageDiscoveryExchange(broker: broker)))
            throw SocialError.invalidResponse
        } catch let grant as FacebookPageDiscoveryGrant {
            try Task.checkCancellation()
            return grant.token
        }
    }

    private func chooseMetaAccount(_ accounts: [SocialAccount],
                                   choose: @MainActor @Sendable ([SocialAccount]) async throws -> String) async throws -> String {
        guard let first = accounts.first else { throw SocialError.permissionDenied }
        let selected = accounts.count == 1 ? first.remoteID : try await choose(accounts)
        try Task.checkCancellation()
        guard accounts.contains(where: { $0.remoteID == selected }) else { throw SocialError.invalidInput }
        return selected
    }

    private func linkedInstagramProfiles(_ token: OAuthToken) async throws -> [SocialAccount] {
        let server = URL(string: "https://graph.facebook.com")!
        var profiles: [SocialAccount] = []
        var ids = Set<String>()
        var cursor: String?
        var seenCursors = Set<String>()
        for _ in 0..<50 {
            try Task.checkCancellation()
            var url = URLComponents(url: server, resolvingAgainstBaseURL: false)!
            url.path = "/v27.0/me/accounts"
            url.queryItems = [URLQueryItem(name: "fields", value: "tasks,instagram_business_account{id,username}"),
                              URLQueryItem(name: "limit", value: "100")]
            if let cursor { url.queryItems?.append(URLQueryItem(name: "after", value: cursor)) }
            guard let endpoint = url.url else { throw SocialError.invalidConfiguration }
            var request = URLRequest(url: endpoint)
            request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
            let response = try await verificationTransport.send(request)
            switch response.statusCode {
            case 200: break
            case 401: throw SocialError.authenticationRequired
            case 403: throw SocialError.permissionDenied
            case 429: throw SocialError.rateLimited(retryAfter: response.header("Retry-After"))
            default: throw SocialError.httpStatus(response.statusCode)
            }
            let page = try JSONDecoder().decode(LinkedInstagramProfiles.self, from: response.body)
            for entry in page.data where entry.tasks?.contains("CREATE_CONTENT") == true {
                guard let account = entry.instagram_business_account, ids.insert(account.id).inserted else { continue }
                profiles.append(SocialAccount(platform: .instagram, server: server, remoteID: account.id,
                                              username: account.username ?? account.id, displayName: account.username))
            }
            guard page.paging?.next != nil else { return profiles }
            guard let after = page.paging?.cursors?.after, !after.isEmpty, seenCursors.insert(after).inserted else {
                throw SocialError.invalidResponse
            }
            cursor = after
        }
        throw SocialError.invalidResponse
    }

    private nonisolated struct LinkedInstagramProfiles: Decodable {
        struct Page: Decodable {
            struct Account: Decodable { let id: String; let username: String? }
            let tasks: [String]?
            let instagram_business_account: Account?
        }
        struct Paging: Decodable {
            struct Cursors: Decodable { let after: String? }
            let next: String?
            let cursors: Cursors?
        }
        let data: [Page]
        let paging: Paging?
    }

    private func accountID(for identity: ContentRecipientIdentity) throws -> SocialAccount.ID {
        guard let platform = SocialPlatform(rawValue: identity.platform),
              identity.server.scheme?.lowercased() == "https", identity.server.host != nil,
              !identity.remoteID.isEmpty else { throw SocialError.invalidInput }
        return SocialAccount.ID(platform: platform, server: identity.server, remoteID: identity.remoteID)
    }

    private func refreshCredentialsIfNeeded(for id: SocialAccount.ID, now: Date = Date(),
                                            force: Bool = false, checkingConnection: Bool = false, manual: Bool = false) async throws {
        guard let credential = try await store.credential(for: id) else {
            throw SocialError.authenticationRequired
        }
        if id.platform.isMeta {
            let expired = credential.expiresAt.map { $0 <= now } ?? false
            if expired, id.platform != .facebookPages, credential.facebookPageSourceGrant == nil { throw SocialError.authenticationRequired }
            do {
                try await checkMetaCredential(id, force: expired || force, manual: manual, now: now)
            } catch let error as SocialError where !checkingConnection && Self.isTransientCredentialCheckError(error) {
                // Renewal can fail independently of an otherwise usable token.
                // The provider still checks the current credential on the publishing request.
                guard credential.expiresAt.map({ $0 > Date() }) ?? true else {
                    throw SocialError.authenticationRequired
                }
            }
            return
        }
        let expired = credential.expiresAt.map { $0 <= now } ?? false
        let nearExpiry = credential.expiresAt.map { $0 <= now.addingTimeInterval(300) } ?? false
        let identity = identity(for: id)
        if nearExpiry {
            let currentCapabilities = try await capabilities(for: identity)
            if currentCapabilities.contains(.refreshSession) {
                do {
                    _ = try await refresh(identity)
                    return
                } catch SocialError.unsupported(.refreshSession) where !expired {
                    // A broker without refresh support can still have a usable access token.
                }
            }
        }
        if expired { throw SocialError.authenticationRequired }
        if force || (id.platform == .bluesky && !checkingConnection) {
            do {
                try await verifyNonMetaConnection(id)
            } catch SocialError.httpStatus(401) {
                guard !nearExpiry, try await capabilities(for: identity).contains(.refreshSession) else {
                    throw SocialError.authenticationRequired
                }
                _ = try await refresh(identity)
            }
        }
    }

    private func verifyNonMetaConnection(_ id: SocialAccount.ID) async throws {
        let transport = verificationTransport
        let url: URL
        switch id.platform {
        case .bluesky:
            url = id.server.appendingPathComponent("xrpc/com.atproto.server.getSession")
        case .mastodon:
            url = id.server.appendingPathComponent("api/v1/accounts/verify_credentials")
        case .x:
            url = URL(string: "https://api.x.com/2/users/me")!
        case .linkedIn:
            url = URL(string: "https://api.linkedin.com/v2/userinfo")!
        default:
            return
        }
        guard url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else {
            throw SocialError.invalidConfiguration
        }
        let check: @Sendable (SocialCredential) async throws -> Void = { credential in
            var request = URLRequest(url: url)
            request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
            let response = try await transport.send(request)
            switch response.statusCode {
            case 200..<300: break
            case 400 where id.platform == .bluesky:
                let body = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]
                if let code = body?["error"] as? String, ["ExpiredToken", "InvalidToken"].contains(code) {
                    throw SocialError.httpStatus(401)
                }
                throw SocialError.httpStatus(400)
            case 429: throw SocialError.rateLimited(retryAfter: response.header("Retry-After"))
            default: throw SocialError.httpStatus(response.statusCode)
            }
            guard let body = try JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
                throw SocialError.invalidResponse
            }
            let returnedID: String?
            let expectedID: String?
            switch id.platform {
            case .bluesky:
                returnedID = body["did"] as? String
                expectedID = id.remoteID
            case .x:
                returnedID = (body["data"] as? [String: Any])?["id"] as? String
                expectedID = id.remoteID
            case .linkedIn:
                returnedID = (body["sub"] as? String).map { "urn:li:person:" + $0 }
                expectedID = id.remoteID.hasPrefix("urn:li:person:") ? id.remoteID : nil
            default:
                returnedID = body["id"] as? String
                expectedID = id.remoteID
            }
            guard let returnedID, expectedID.map({ $0 == returnedID }) ?? true else {
                throw SocialError.authenticationRequired
            }
        }
        switch id.platform {
        case .bluesky: try await bluesky.verifyCredential(id) { _, credential in try await check(credential) }
        case .mastodon: try await mastodon.verifyCredential(id) { _, credential in try await check(credential) }
        case .x: try await xClient(for: id).verifyCredential(id) { _, credential in try await check(credential) }
        case .linkedIn: try await linkedinClient(for: id).verifyCredential(id) { _, credential in try await check(credential) }
        default: break
        }
    }

    /// Only non-secret connection status leaves the actor. The app can refresh it while awake.
    func checkMetaCredentials(force: Bool = false, now: Date = Date()) async -> [SocialAccount.ID: String] {
        guard let accounts = try? await accounts() else { return [:] }
        var status: [SocialAccount.ID: String] = [:]
        for account in accounts where account.platform.isMeta {
            if Task.isCancelled { break }
            try? await checkMetaCredential(account.id, force: force, now: now)
            guard let credential = try? await store.credential(for: account.id) else { continue }
            status[account.id] = metaCredentialStatus(credential, now: now)
        }
        return status
    }

    func savedMetaStatus(for account: SocialAccount) async -> String? {
        guard let credential = try? await store.credential(for: account.id) else { return nil }
        return metaCredentialStatus(credential)
    }

    private func clearMetaCheckResult(for id: SocialAccount.ID) async {
        _ = try? await metaChecks[id]?.value
        metaCheckResults.removeValue(forKey: id)
    }

    private func checkMetaCredential(_ id: SocialAccount.ID, force: Bool = false, manual: Bool = false, now: Date = Date()) async throws {
        if let check = metaChecks[id] {
            return try await check.value
        }
        if let result = metaCheckResults[id], now < result.nextCheck {
            if let error = result.error, case .rateLimited = error { throw error }
            if !manual && (!force || result.error != nil) {
                if let error = result.error { throw error }
                return
            }
        }

        let check = Task { try await runMetaCheck(id, now: now) }
        metaChecks[id] = check
        try await check.value
    }

    private func runMetaCheck(_ id: SocialAccount.ID, now: Date) async throws {
        defer { metaChecks.removeValue(forKey: id) }
        do {
            try await probeMetaCredential(id, now: now)
            metaCheckResults[id] = MetaCheckResult(nextCheck: now.addingTimeInterval(Self.metaCheckInterval),
                                                  failures: 0, error: nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let error = error as? SocialError ?? .transportFailure
            let failures = min((metaCheckResults[id]?.failures ?? 0) + 1, 8)
            let backoff = min(300 * pow(2.0, Double(failures - 1)), Self.metaCheckInterval)
            let delay: TimeInterval
            switch error {
            case .rateLimited(let retryAfter):
                delay = max(backoff, retryAfter.flatMap(TimeInterval.init) ?? 0)
            case .accountBusy:
                delay = 60
            default:
                delay = Self.requiresReconnect(error) ? Self.metaCheckInterval : backoff
            }
            metaCheckResults[id] = MetaCheckResult(nextCheck: now.addingTimeInterval(delay),
                                                  failures: failures, error: error)
            throw error
        }
    }

    private func probeMetaCredential(_ id: SocialAccount.ID, now: Date) async throws {
        guard let credential = try await store.credential(for: id) else {
            throw SocialError.authenticationRequired
        }
        let expired = credential.expiresAt.map { $0 <= now } ?? false
        switch id.platform {
        case .facebookPages:
            do {
                try await facebook.verifyCredential(id) { adapter, credential in
                    _ = try await adapter.profile(credential: credential)
                }
            } catch let error as SocialError where Self.requiresReconnect(error) {
                guard let source = credential.facebookPageSourceGrant,
                      source.expiresAt.map({ $0 > now }) ?? true else { throw error }
                _ = try await facebook.refresh(id)
            }
        case .instagram where credential.facebookPageSourceGrant != nil:
            do {
                try await instagram.verifyCredential(id) { adapter, credential in
                    guard try await adapter.profile(credential: credential).id == id else {
                        throw SocialError.authenticationRequired
                    }
                }
            } catch let error as SocialError where Self.requiresReconnect(error) {
                guard let source = credential.facebookPageSourceGrant,
                      source.expiresAt.map({ $0 > now }) ?? true else { throw error }
                _ = try await instagram.refresh(id)
            }
        case .instagram, .threads:
            guard !expired else { throw SocialError.authenticationRequired }
            if credential.canRefreshMetaLongLivedToken(at: now),
               credential.expiresAt.map({ $0 <= now.addingTimeInterval(Self.metaRenewalWindow) }) ?? true {
                if id.platform == .instagram { _ = try await instagram.refresh(id) }
                else { _ = try await threads.refresh(id) }
            } else if id.platform == .instagram {
                try await instagram.verifyCredential(id) { adapter, credential in
                    guard try await adapter.profile(credential: credential).id == id else {
                        throw SocialError.authenticationRequired
                    }
                }
            } else {
                try await threads.verifyCredential(id) { adapter, credential in
                    guard try await adapter.profile(credential: credential).id == id else {
                        throw SocialError.authenticationRequired
                    }
                }
            }
        default:
            throw SocialError.invalidInput
        }
    }

    private func metaCredentialStatus(_ credential: SocialCredential, now: Date = Date()) -> String {
        let error = metaCheckResults[credential.account.id]?.error
        if error.map(Self.requiresReconnect) == true || credential.expiresAt.map({ $0 <= now }) == true {
            return "Reconnect with a current Meta token before scheduled delivery."
        }
        if let expiresAt = credential.expiresAt {
            let date = expiresAt.formatted(date: .abbreviated, time: .shortened)
            if error != nil { return "Credential check delayed. The current token expires \(date)." }
            if expiresAt <= now.addingTimeInterval(Self.metaRenewalWindow) {
                return "Token expires soon (\(date)). Reconnect if the expiry does not update."
            }
            return "Token expires \(date)."
        }
        if error != nil { return "Credential check delayed. Token expiry is unknown." }
        if let sourceExpiry = credential.facebookPageSourceGrant?.expiresAt {
            if sourceExpiry <= now {
                return "Page token expiry is unknown. The source user grant has expired and can no longer recover it."
            }
            return "Page token expiry is unknown. The source user grant expires \(sourceExpiry.formatted(date: .abbreviated, time: .shortened))."
        }
        return "Token expiry is unknown."
    }

    private static func isTransientCredentialCheckError(_ error: SocialError) -> Bool {
        switch error {
        case .transportFailure, .rateLimited, .invalidResponse: true
        case .httpStatus(let status): status == 408 || (500..<600).contains(status)
        default: false
        }
    }

    private static func requiresReconnect(_ error: SocialError) -> Bool {
        switch error {
        case .authenticationRequired, .authorizationFailed, .permissionDenied, .permissionDeniedAt, .httpStatus(401): true
        default: false
        }
    }

    private static func refreshFailureMessage(_ error: SocialError) -> String {
        switch error {
        case .authenticationRequired, .authorizationFailed, .unsupported(.refreshSession), .httpStatus(401):
            "The account authorization is expired or revoked. Reconnect the account before retrying delivery."
        case .permissionDenied, .permissionDeniedAt, .httpStatus(403):
            "The provider denied a required permission. Review the account’s access before retrying."
        case .credentialStorage:
            "Keychain is unavailable. Unlock it and check the connection before retrying."
        case .transportFailure, .accountBusy:
            "The connection could not be checked. Try again when the provider is reachable."
        case .rateLimited:
            "The provider rate limited the connection check. Wait before retrying delivery."
        case .billingRequired:
            "The provider requires additional API access or credits. The post was not sent."
        default:
            "The account could not be refreshed, so the post was not sent. Reconnect the account or review its provider settings."
        }
    }

    private static func canPauseMetaPolling(after error: SocialError) -> Bool {
        switch error {
        case .mediaProcessingTimedOut, .transportFailure: true
        case .httpStatus(let status): status >= 500
        default: false
        }
    }

    private static func isDefiniteRejection(_ error: SocialError) -> Bool {
        switch error {
        case .invalidConfiguration, .invalidInput, .unsupported, .authenticationRequired,
             .authorizationFailed, .permissionDenied, .permissionDeniedAt, .credentialStorage, .accountBusy,
             .rateLimited, .billingRequired, .mediaProcessingFailed, .mediaProcessingTimedOut:
            true
        case .httpStatus(let status):
            (400..<500).contains(status) && ![408, 409, 425].contains(status)
        default:
            false
        }
    }
}


struct ConnectionIdentityMismatch: LocalizedError {
    var errorDescription: String? { "The provider returned a different account. Sign in to the original account, or use Switch Account." }
}

private nonisolated struct FacebookPageDiscoveryGrant: Error {
    let token: OAuthToken
}

private nonisolated struct FacebookPageDiscoveryExchange: SessionBoundMetaOAuthExchange {
    let broker: any SessionBoundMetaOAuthExchange

    func prepare(platform: SocialPlatform, clientID: String, redirectURI: URL, state: String) async throws {
        try await broker.prepare(platform: platform, clientID: clientID, redirectURI: redirectURI, state: state)
    }

    func exchange(platform: SocialPlatform, code: String, redirectURI: URL) async throws -> OAuthToken {
        let token = try await broker.exchange(platform: platform, code: code, redirectURI: redirectURI)
        throw FacebookPageDiscoveryGrant(token: token)
    }
}
