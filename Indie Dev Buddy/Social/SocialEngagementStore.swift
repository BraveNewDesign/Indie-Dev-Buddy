import CryptoKit
import Foundation
import Observation
import SocialKit

/// Shared by windows so opening a second window does not multiply provider requests.
@MainActor @Observable
final class SocialEngagementStore {
    nonisolated struct Thread: Sendable {
        let comments: [SocialPost]
        let incomplete: Bool
        let checkedAt: Date
    }

    enum ReplyStatus: String, CaseIterable {
        case needsReply = "Needs Reply", replied = "Replied", done = "Done", unknown = "Unknown"

        var symbol: String {
            switch self {
            case .needsReply: "flag"
            case .replied: "arrowshape.turn.up.left"
            case .done: "checkmark.circle"
            case .unknown: "questionmark.circle"
            }
        }
    }

    nonisolated struct Insights: Sendable {
        let counts: [String: Int]
        let checkedAt: Date
    }

    struct Profile {
        var posts: [SocialPost] = []
        var threads: [String: Thread] = [:]
        var insights: [String: Insights] = [:]
        var insightIssues: [String: String] = [:]
        var capabilities: Set<SocialCapability> = []
        var postsCheckedAt: Date?
        var inboxCheckedAt: Date?
        var postsIssue: String?
        var inboxIssue: String?
    }

    struct CommentKey: Hashable, Encodable {
        let profile: ContentRecipientIdentity
        let postID: String
        let commentID: String
    }

    private(set) var profiles: [ContentRecipientIdentity: Profile] = [:]
    private(set) var refreshing: Set<ContentRecipientIdentity> = []
    private(set) var sending: Set<CommentKey> = []
    private(set) var sent: [CommentKey: SocialPost] = [:]
    private let defaults: UserDefaults
    private var done: Set<String>
    private var flagged: Set<String>
    private var nextRefresh: [ContentRecipientIdentity: Date] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        done = Set(defaults.stringArray(forKey: "social.inbox.done") ?? [])
        flagged = Set(defaults.stringArray(forKey: "social.inbox.needsReply") ?? [])
    }

    func canRefresh(_ identity: ContentRecipientIdentity, at date: Date) -> Bool {
        !refreshing.contains(identity) && nextRefresh[identity, default: .distantPast] <= date
    }

    func retryAt(for identity: ContentRecipientIdentity) -> Date? { nextRefresh[identity] }

    static func manualOnly(_ identity: ContentRecipientIdentity) -> Bool {
        switch SocialPlatform(rawValue: identity.platform) {
        case .facebookPages, .instagram, .threads, .mastodon, .bluesky: false
        case .x, .linkedIn, nil: true
        }
    }

    func toggleDone(_ key: CommentKey) {
        guard let digest = doneIdentifier(key) else { return }
        if !done.insert(digest).inserted { done.remove(digest) }
        defaults.set(done.sorted(), forKey: "social.inbox.done")
    }

    func toggleNeedsReply(_ key: CommentKey) {
        guard let digest = doneIdentifier(key) else { return }
        if !flagged.insert(digest).inserted { flagged.remove(digest) }
        defaults.set(flagged.sorted(), forKey: "social.inbox.needsReply")
    }

    func refresh(_ identity: ContentRecipientIdentity, inbox: Bool, manual: Bool, using connections: SocialConnections) async {
        guard !Task.isCancelled,
              nextRefresh[identity, default: .distantPast] <= .now,
              manual || !Self.manualOnly(identity) else { return }
        let checkedAt = inbox ? profiles[identity]?.inboxCheckedAt : profiles[identity]?.postsCheckedAt
        guard manual || Date.now.timeIntervalSince(checkedAt ?? .distantPast) >= 900,
              refreshing.insert(identity).inserted else { return }
        defer { refreshing.remove(identity) }
        if manual { nextRefresh[identity] = .now.addingTimeInterval(15) }

        do {
            let capabilities = try await connections.capabilities(for: identity)
            let posts = try await connections.posts(for: identity)
            try Task.checkCancellation()
            var profile = profiles[identity, default: Profile()]
            profile.capabilities = capabilities
            var ids = Set<String>()
            profile.posts = posts.items.filter { $0.parentID == nil && ids.insert($0.id).inserted }
            profile.postsCheckedAt = .now
            profile.postsIssue = nil
            profile.threads = profile.threads.filter { ids.contains($0.key) }
            profile.insights = profile.insights.filter { ids.contains($0.key) }
            profile.insightIssues = profile.insightIssues.filter { ids.contains($0.key) }
            profiles[identity] = profile

            guard inbox, capabilities.contains(.readReplies) else {
                if inbox {
                    profiles[identity]?.threads = [:]
                    profiles[identity]?.inboxCheckedAt = .now
                    profiles[identity]?.inboxIssue = nil
                }
                return
            }

            // One recent-post page and a bounded number of comment reads. X may charge per read.
            var threads: [String: Thread] = [:]
            for post in profile.posts.prefix(Self.manualOnly(identity) ? 4 : 8) {
                try Task.checkCancellation()
                let page = try await connections.replies(to: post.id, for: identity)
                try Task.checkCancellation()
                var commentIDs = Set<String>()
                threads[post.id] = Thread(
                    comments: page.items.filter { commentIDs.insert($0.id).inserted },
                    incomplete: page.nextCursor != nil,
                    checkedAt: .now
                )
            }
            profiles[identity]?.threads = threads
            profiles[identity]?.inboxCheckedAt = .now
            profiles[identity]?.inboxIssue = nil
        } catch {
            guard !Task.isCancelled else { return }
            let issue: String
            let delay: TimeInterval
            switch error as? SocialError {
            case .rateLimited(let retryAfter):
                delay = max(900, retryAfter.flatMap(TimeInterval.init) ?? 0)
                issue = "The provider rate limited this profile."
            case .billingRequired:
                delay = 900
                issue = "This provider requires API credits or an eligible plan."
            case .permissionDenied, .permissionDeniedAt, .httpStatus(403):
                delay = 120
                issue = "The provider denied access. Check profile permissions in Social Accounts."
            case .authenticationRequired, .authorizationFailed, .httpStatus(401):
                delay = 120
                issue = "The provider requires authorization. Check the connection in Social Accounts."
            default:
                delay = 120
                issue = "Refresh failed. Check the connection in Social Accounts."
            }
            nextRefresh[identity] = .now.addingTimeInterval(delay)
            let keyPath = inbox ? \Profile.inboxIssue : \Profile.postsIssue
            profiles[identity, default: Profile()][keyPath: keyPath] = issue
        }
    }

    func refreshInsights(_ postID: String, for identity: ContentRecipientIdentity, using connections: SocialConnections) async {
        guard profiles[identity]?.posts.contains(where: { $0.id == postID }) == true,
              nextRefresh[identity, default: .distantPast] <= .now,
              refreshing.insert(identity).inserted else { return }
        defer { refreshing.remove(identity) }
        nextRefresh[identity] = .now.addingTimeInterval(15)
        profiles[identity]?.insightIssues[postID] = nil

        do {
            let counts = try await connections.postInsights(postID, for: identity)
            profiles[identity]?.insights[postID] = Insights(counts: counts, checkedAt: .now)
        } catch let error as SocialError {
            switch error {
            case .rateLimited(let retryAfter):
                let delay = max(900, retryAfter.flatMap(TimeInterval.init) ?? 0)
                let retry = Date.now.addingTimeInterval(delay)
                nextRefresh[identity] = retry
                profiles[identity]?.insightIssues[postID] = "Rate limited. Try again after \(retry.formatted())."
            case .permissionDeniedAt(let permission):
                profiles[identity]?.insightIssues[postID] = "This connection needs \(permission) and eligible Meta app access."
            case .authenticationRequired:
                profiles[identity]?.insightIssues[postID] = "Reconnect this profile before refreshing insights."
            default:
                profiles[identity]?.insightIssues[postID] = "Insights are unavailable for this post or account."
            }
        } catch {
            profiles[identity]?.insightIssues[postID] = "Could not refresh insights. Try again later."
        }
    }

    func send(_ text: String, to key: CommentKey, using connections: SocialConnections) async throws {
        guard profiles[key.profile]?.capabilities.contains(.reply) == true,
              sending.insert(key).inserted else { throw SocialError.unsupported(.reply) }
        defer { sending.remove(key) }
        sent[key] = try await connections.reply(text, to: key.commentID, for: key.profile)
        if let digest = doneIdentifier(key), flagged.remove(digest) != nil {
            defaults.set(flagged.sorted(), forKey: "social.inbox.needsReply")
        }
    }

    func replyStatus(for key: CommentKey, in thread: Thread) -> ReplyStatus {
        let digest = doneIdentifier(key)
        if digest.map(done.contains) == true { return .done }
        if sent[key] != nil || thread.comments.contains(where: { $0.parentID == key.commentID && owns($0, on: key.profile) }) {
            return .replied
        }
        // Every current adapter can omit nested, paginated, or older replies.
        return digest.map(flagged.contains) == true ? .needsReply : .unknown
    }

    private func doneIdentifier(_ key: CommentKey) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let bytes = try? encoder.encode(key) else { return nil }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    func owns(_ post: SocialPost, on identity: ContentRecipientIdentity) -> Bool {
        post.isOwnedByAccount ?? (post.authorID == identity.remoteID)
    }
}
