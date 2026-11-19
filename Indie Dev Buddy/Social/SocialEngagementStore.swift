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
        var issue: String?
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
    private var done: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "social.inbox.done") ?? [])
    private var nextRefresh: [ContentRecipientIdentity: Date] = [:]

    static func manualOnly(_ identity: ContentRecipientIdentity) -> Bool {
        switch SocialPlatform(rawValue: identity.platform) {
        case .facebookPages, .instagram, .threads, .mastodon, .bluesky: false
        case .x, .linkedIn, nil: true
        }
    }

    func toggleDone(_ key: CommentKey) {
        guard let digest = doneIdentifier(key) else { return }
        if !done.insert(digest).inserted { done.remove(digest) }
        UserDefaults.standard.set(done.sorted(), forKey: "social.inbox.done")
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
        profiles[identity, default: Profile()].issue = nil

        do {
            let capabilities = try await connections.capabilities(for: identity)
            let posts = try await connections.posts(for: identity)
            try Task.checkCancellation()
            var profile = profiles[identity, default: Profile()]
            profile.capabilities = capabilities
            var ids = Set<String>()
            profile.posts = posts.items.filter { $0.parentID == nil && ids.insert($0.id).inserted }
            profile.postsCheckedAt = .now
            profile.threads = profile.threads.filter { ids.contains($0.key) }
            profile.insights = profile.insights.filter { ids.contains($0.key) }
            profile.insightIssues = profile.insightIssues.filter { ids.contains($0.key) }
            profiles[identity] = profile

            guard inbox, capabilities.contains(.readReplies) else {
                if inbox { profiles[identity]?.inboxCheckedAt = .now }
                return
            }

            // One recent-post page and a bounded number of comment reads. X may charge per read.
            for post in profile.posts.prefix(Self.manualOnly(identity) ? 4 : 8) {
                try Task.checkCancellation()
                let page = try await connections.replies(to: post.id, for: identity)
                try Task.checkCancellation()
                var commentIDs = Set<String>()
                profiles[identity]?.threads[post.id] = Thread(
                    comments: page.items.filter { commentIDs.insert($0.id).inserted },
                    incomplete: page.nextCursor != nil,
                    checkedAt: .now
                )
            }
            profiles[identity]?.inboxCheckedAt = .now
        } catch {
            guard !Task.isCancelled else { return }
            if let error = error as? SocialError {
                switch error {
                case .rateLimited(let retryAfter):
                    let delay = max(900, retryAfter.flatMap(TimeInterval.init) ?? 0)
                    nextRefresh[identity] = .now.addingTimeInterval(delay)
                    profiles[identity, default: Profile()].issue = "Rate limited. Try again after \(nextRefresh[identity, default: .now].formatted())."
                    return
                case .billingRequired:
                    nextRefresh[identity] = .now.addingTimeInterval(900)
                    profiles[identity, default: Profile()].issue = "This provider requires API credits or an eligible plan."
                    return
                default: break
                }
            }
            nextRefresh[identity] = .now.addingTimeInterval(120)
            profiles[identity, default: Profile()].issue = "Refresh failed. Check this profile’s connection and permissions in Social Accounts."
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
    }

    func replyStatus(for key: CommentKey, comment: SocialPost, in thread: Thread) -> String {
        if doneIdentifier(key).map(done.contains) == true { return "Done" }
        if sent[key] != nil || thread.comments.contains(where: { $0.parentID == comment.id && owns($0, on: key.profile) }) {
            return "Replied"
        }
        if thread.incomplete || comment.authorID == nil && comment.isOwnedByAccount == nil { return "Unknown" }
        // The current adapters do not guarantee nested-reply coverage or full conversation history.
        return "Needs Reply"
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
