import CryptoKit
import Foundation
import SocialKit
import SwiftUI

struct SocialAccountActivityView: View {
    @Environment(SocialPublishingRuntime.self) private var runtime
    @Environment(\.dismiss) private var dismiss
    let identity: ContentRecipientIdentity
    let account: SocialAccount
    @State private var capabilities: Set<SocialCapability> = []
    @State private var posts: [SocialPost] = []
    @State private var replies: [SocialPost] = []
    @State private var postCursor: String?
    @State private var replyCursor: String?
    @State private var selectedPostID: String?
    @State private var selectedPostQueryID: String?
    @State private var replyTarget: SocialPost?
    @State private var replyText = ""
    @State private var deleteTarget: SocialPost?
    @State private var loading = false
    @State private var writing = false
    @State private var message: String?
    @State private var activity: [ActivityEntry] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Account Activity").font(.title2.bold())
                    Text(account.displayName ?? account.username).font(.headline)
                    Text(account.authenticatedUserName.map { "\(account.platform.workspaceTitle) · Connected by \($0)" } ?? account.platform.workspaceTitle)
                        .foregroundStyle(.secondary)
                    if account.profileURL?.scheme?.lowercased() == "https", let profileURL = account.profileURL {
                        Link("Open profile", destination: profileURL).font(.caption)
                    }
                }
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await reload() } }
                    .disabled(loading || writing)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let message {
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
            if capabilities.contains(.listPosts) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(posts) { post in postRow(post) }
                        if postCursor != nil {
                            Button("Load More Posts") { Task { await loadPosts(reset: false) } }.disabled(loading)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if posts.isEmpty && !loading { Text("No posts returned.").foregroundStyle(.secondary) }
            } else if !loading {
                ContentUnavailableView("Posts Unavailable", systemImage: "text.bubble",
                                       description: Text("This connection doesn’t provide access to list posts."))
            }
            if loading { ProgressView().controlSize(.small) }
            if !activity.isEmpty {
                DisclosureGroup("Recent Actions") {
                    ScrollView {
                        ForEach(activity) { entry in
                            HStack {
                                Text(entry.action)
                                Text(entry.confirmed ? "Confirmed" : "Needs review").foregroundStyle(.secondary)
                                Spacer()
                                Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                            }
                            .font(.caption)
                        }
                    }
                    .frame(maxHeight: 100)
                }
            }
            if let replyTarget {
                Divider()
                Text(account.platform == .instagram ? "Reply to Comment" : "Write Reply").font(.headline)
                Text("Replying to \(replyTarget.authorName ?? replyTarget.authorHandle.map { "@\($0)" } ?? "this post or comment")")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Reply text", text: $replyText, axis: .vertical)
                    .lineLimit(2...4)
                HStack {
                    Button("Cancel Reply") { self.replyTarget = nil; replyText = "" }
                    Button("Send Reply") {
                        let text = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
                        let success = account.platform == .instagram
                            ? "Reply sent. Instagram does not expose nested replies in this comments list."
                            : "Reply sent."
                        perform("Reply", success: success) {
                            let target = replyTarget
                            _ = try await runtime.connections.reply(text, to: target.id, for: identity)
                            self.replyTarget = nil
                            replyText = ""
                            if account.platform != .instagram, let selectedPostQueryID {
                                await loadReplies(to: selectedPostQueryID, reset: true)
                            }
                        }
                    }
                    .help(account.platform == .instagram ? "Instagram sends this as a reply to the selected comment. Nested replies are not available in this list." : "Send a reply to the selected post or comment.")
                    .disabled(writing || replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 650, height: 550)
        .task {
            activity = loadActivity()
            await reload()
        }
        .confirmationDialog("Delete this reply from the provider?", isPresented: Binding(
            get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }
        ), titleVisibility: .visible, presenting: deleteTarget) { reply in
            Button("Delete Reply", role: .destructive) {
                perform("Delete reply", success: "Reply deleted.") {
                    try await runtime.connections.deleteReply(reply.id, for: identity)
                    replies.removeAll { $0.id == reply.id }
                }
            }
        }
    }

    private func postRow(_ post: SocialPost) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            itemText(post)
            HStack {
                if capabilities.contains(.readReplies) {
                    let noun = (account.platform == .facebookPages || account.platform == .instagram || account.platform == .linkedIn) ? "Comments" : "Replies"
                    Button(selectedPostID == post.id ? "Hide \(noun)" : "View \(noun)") {
                        if selectedPostID == post.id {
                            selectedPostID = nil
                            selectedPostQueryID = nil
                            replies = []
                            replyCursor = nil
                        } else {
                            selectedPostID = post.id
                            let queryID = account.platform == .x ? (post.conversationRootID ?? post.id) : post.id
                            selectedPostQueryID = queryID
                            Task { await loadReplies(to: queryID, reset: true) }
                        }
                    }
                    .disabled(loading)
                }
                if capabilities.contains(.reply), account.platform != .instagram {
                    Button("Reply") { composeReply(to: post) }.disabled(writing)
                }
                if capabilities.contains(.like) || capabilities.contains(.unlike) ||
                    capabilities.contains(.repost) || capabilities.contains(.unrepost) {
                    Menu("Actions") {
                        if capabilities.contains(.like) {
                            Button("Like") { perform("Like", success: "Like sent.") { try await runtime.connections.setLiked(true, postID: post.id, for: identity) } }
                        }
                        if capabilities.contains(.unlike) {
                            Button("Unlike") { perform("Unlike", success: "Like removed.") { try await runtime.connections.setLiked(false, postID: post.id, for: identity) } }
                        }
                        if capabilities.contains(.repost) {
                            Button("Repost") { perform("Repost", success: "Reposted.") { try await runtime.connections.setReposted(true, postID: post.id, for: identity) } }
                        }
                        if capabilities.contains(.unrepost) {
                            Button("Undo Repost") { perform("Undo repost", success: "Repost removed.") { try await runtime.connections.setReposted(false, postID: post.id, for: identity) } }
                        }
                    }
                    .disabled(writing)
                }
            }
            if selectedPostID == post.id {
                ForEach(replies) { reply in
                    VStack(alignment: .leading, spacing: 4) {
                        itemText(reply)
                        HStack {
                            if account.platform == .instagram && capabilities.contains(.reply) {
                                Button("Reply to Comment") { composeReply(to: reply) }.disabled(writing)
                            }
                            if capabilities.contains(.moderateReplies) {
                                Button("Hide") { perform("Hide reply", success: "Reply hidden.") { try await runtime.connections.setReplyHidden(true, replyID: reply.id, for: identity) } }
                                    .disabled(writing)
                                Button("Unhide") { perform("Unhide reply", success: "Reply unhidden.") { try await runtime.connections.setReplyHidden(false, replyID: reply.id, for: identity) } }
                                    .disabled(writing)
                            }
                            if capabilities.contains(.deleteReply), reply.authorID == account.remoteID {
                                Button("Delete…", role: .destructive) { deleteTarget = reply }.disabled(writing)
                            }
                        }
                    }
                    .padding(.leading, 14)
                }
                if replyCursor != nil, let selectedPostQueryID {
                    Button("Load More Comments") { Task { await loadReplies(to: selectedPostQueryID, reset: false) } }.disabled(loading)
                }
                if replies.isEmpty && !loading { Text("No comments returned.").font(.caption).foregroundStyle(.secondary) }
            }
            Divider()
        }
    }

    private func itemText(_ post: SocialPost) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(post.authorName ?? post.authorHandle.map { "@\($0)" } ?? "Author unavailable")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if let date = post.createdAt {
                    Text(date.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Text(verbatim: readableText(post)).textSelection(.enabled)
            if let url = post.url, url.scheme?.lowercased() == "https", url.host != nil {
                Link("View on Provider", destination: url).font(.caption)
            }
        }
    }

    private func composeReply(to post: SocialPost) {
        replyTarget = post
        replyText = ""
    }

    private func reload() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        message = nil
        do {
            capabilities = try await runtime.connections.capabilities(for: identity)
            try Task.checkCancellation()
        } catch {
            if !Task.isCancelled { message = message(for: error, fallback: "Could not read this connection. Check its credentials and permissions.") }
            return
        }
        if capabilities.contains(.listPosts) {
            await fetchPosts(reset: true)
        }
    }

    private func loadPosts(reset: Bool) async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        await fetchPosts(reset: reset)
    }

    private func fetchPosts(reset: Bool) async {
        do {
            let cursor = reset ? nil : postCursor
            let page = try await runtime.connections.posts(for: identity, cursor: cursor)
            try Task.checkCancellation()
            posts = merged(reset ? [] : posts, page.items)
            postCursor = page.nextCursor == cursor ? nil : page.nextCursor
            if reset {
                selectedPostID = nil
                selectedPostQueryID = nil
                replies = []
                replyCursor = nil
            }
        } catch {
            if !Task.isCancelled { message = message(for: error, fallback: "Could not load posts for this account.") }
        }
    }

    private func loadReplies(to postID: String, reset: Bool) async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let cursor = reset ? nil : replyCursor
            let page = try await runtime.connections.replies(to: postID, for: identity, cursor: cursor)
            guard !Task.isCancelled, selectedPostQueryID == postID else { return }
            replies = merged(reset ? [] : replies, page.items)
            replyCursor = page.nextCursor == cursor ? nil : page.nextCursor
        } catch {
            if !Task.isCancelled { message = message(for: error, fallback: "Could not load comments for this post.") }
        }
    }

    private func merged(_ existing: [SocialPost], _ incoming: [SocialPost]) -> [SocialPost] {
        var ids = Set(existing.map(\.id))
        return existing + incoming.filter { ids.insert($0.id).inserted }
    }

    private func perform(_ action: String, success: String, operation: @escaping @MainActor () async throws -> Void) {
        guard !writing else { return }
        writing = true
        message = nil
        Task {
            defer { writing = false }
            do {
                try await operation()
                recordActivity(action, confirmed: true)
                message = success
            } catch {
                recordActivity(action, confirmed: false)
                message = message(for: error, fallback: "The provider did not confirm this action. Check the post before trying again.")
            }
        }
    }

    private func readableText(_ post: SocialPost) -> String {
        guard post.textFormat == .html else { return post.text }
        var value = post.text.replacingOccurrences(of: #"(?is)<(script|style)[^>]*>.*?</\1\s*>"#, with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: #"(?i)<br\s*/?>|</p\s*>|</li\s*>|</div\s*>"#, with: "\n", options: .regularExpression)
        value = value.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        for (entity, replacement) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'")] {
            value = value.replacingOccurrences(of: entity, with: replacement)
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func message(for error: Error, fallback: String) -> String {
        guard let error = error as? SocialError else { return fallback }
        switch error {
        case .authenticationRequired, .authorizationFailed:
            return "Reconnect this account, then try again."
        case .permissionDenied:
            return "This account does not currently have permission for that action. Review its provider access."
        case .rateLimited(let retryAfter):
            return retryAfter.map { "The provider rate limited this action. Try again after \($0)." } ?? "The provider rate limited this action. Try again later."
        case .unsupported(let capability):
            return "This provider does not support \(capability.rawValue)."
        case .billingRequired:
            return "The provider requires an API plan or credits for this action."
        default:
            return fallback
        }
    }

    private struct ActivityEntry: Codable, Identifiable {
        var id = UUID()
        let action: String
        let confirmed: Bool
        let date: Date
    }

    private var activityKey: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let digest = SHA256.hash(data: (try? encoder.encode(identity)) ?? Data())
        return "social.activity." + digest.map { String(format: "%02x", $0) }.joined()
    }

    private func loadActivity() -> [ActivityEntry] {
        guard let data = UserDefaults.standard.data(forKey: activityKey) else { return [] }
        return (try? JSONDecoder().decode([ActivityEntry].self, from: data)) ?? []
    }

    private func recordActivity(_ action: String, confirmed: Bool) {
        let previous = loadActivity()
        activity = [ActivityEntry(action: action, confirmed: confirmed, date: Date())] + Array(previous.prefix(19))
        if let data = try? JSONEncoder().encode(activity) {
            UserDefaults.standard.set(data, forKey: activityKey)
        }
    }
}
