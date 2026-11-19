import SocialKit
import SwiftUI

struct SocialPerformanceTarget: Equatable {
    let identity: ContentRecipientIdentity
    let url: URL
}

struct SocialWorkspaceView: View {
    @Environment(SocialPublishingRuntime.self) private var runtime
    @Environment(\.scenePhase) private var scenePhase
    let snapshot: WorkspaceSnapshot
    let inbox: Bool
    let target: SocialPerformanceTarget?
    let openContent: (String) -> Void

    private enum InboxFilter: String, CaseIterable {
        case needsReply = "Needs Reply", all = "All", replied = "Replied", done = "Done", unknown = "Unknown"
    }

    private nonisolated struct PostRow: Identifiable, Sendable {
        struct ID: Hashable, Sendable {
            let identity: ContentRecipientIdentity
            let post: String
        }

        let id: ID
        let account: SocialAccountRecord
        let post: SocialPost
        let thread: SocialEngagementStore.Thread?
        let insights: SocialEngagementStore.Insights?

        var views: Int? { insights?.counts["views"] ?? insights?.counts["post_media_view"] }

        var published: Date { post.createdAt ?? .distantPast }
        var likeCountForSort: Int { post.likeCount ?? -1 }
        var commentCountForSort: Int { thread?.comments.count ?? -1 }
        var title: String { post.readableText.isEmpty ? "Media post" : post.readableText }
        var format: String {
            if post.media.count > 1 { return "Multiple attachments" }
            switch post.media.first?.kind {
            case .image: return "Image"
            case .video: return "Video"
            case .unknown: return "Other media"
            case nil: return "Unknown"
            }
        }
    }

    private struct CommentRow: Identifiable {
        let id: SocialEngagementStore.CommentKey
        let post: PostRow
        let comment: SocialPost
        let status: String

        var author: String { comment.authorName ?? comment.authorHandle ?? "Unknown author" }
    }

    @State private var selectedProfile: ContentRecipientIdentity?
    @State private var provider: String?
    @State private var appID: String?
    @State private var waitingForTarget: SocialPerformanceTarget?
    @State private var filter = InboxFilter.needsReply
    @State private var format: String?
    @State private var days = 30
    @State private var postSelection: PostRow.ID?
    @State private var commentSelection: SocialEngagementStore.CommentKey?
    @State private var drafts: [SocialEngagementStore.CommentKey: String] = [:]
    @State private var sendError: SocialEngagementStore.CommentKey?
    @State private var postSort = [KeyPathComparator(\PostRow.published, order: .reverse)]

    private var store: SocialEngagementStore { runtime.engagement }

    private var accounts: [SocialAccountRecord] {
        var seen = Set<ContentRecipientIdentity>()
        return snapshot.socialAccounts.filter {
            guard $0.enabled, let identity = $0.providerIdentity else { return false }
            return seen.insert(identity).inserted
        }
    }

    private var providers: [String] {
        Set(accounts.compactMap { $0.providerIdentity.map(providerTitle) }).sorted()
    }

    private var matchingAccounts: [SocialAccountRecord] {
        accounts.filter { account in
            guard let identity = account.providerIdentity else { return false }
            return provider == nil || provider == providerTitle(identity)
        }
    }

    private var identities: [ContentRecipientIdentity] {
        matchingAccounts.compactMap(\.providerIdentity).filter { selectedProfile == nil || selectedProfile == $0 }
    }

    private var posts: [PostRow] {
        matchingAccounts.flatMap { account -> [PostRow] in
            guard let identity = account.providerIdentity, identities.contains(identity),
                  let profile = store.profiles[identity] else { return [] }
            return profile.posts.compactMap { post in
                let row = PostRow(id: .init(identity: identity, post: post.id), account: account, post: post, thread: profile.threads[post.id], insights: profile.insights[post.id])
                guard let appID else { return row }
                let appOwnsProfile = account.owner?.type == .app && account.owner?.id == appID
                return appOwnsProfile || linkedContent(row)?.appIds.contains(appID) == true ? row : nil
            }
        }
    }

    private var comments: [CommentRow] {
        posts.flatMap { row -> [CommentRow] in
            guard let thread = row.thread else { return [] }
            return thread.comments.filter { !store.owns($0, on: row.id.identity) }.map { comment in
                let key = SocialEngagementStore.CommentKey(profile: row.id.identity, postID: row.id.post, commentID: comment.id)
                return CommentRow(id: key, post: row, comment: comment, status: store.replyStatus(for: key, comment: comment, in: thread))
            }
        }.sorted { ($0.comment.createdAt ?? .distantPast) > ($1.comment.createdAt ?? .distantPast) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            controls.padding()
            Divider()
            if accounts.isEmpty {
                ContentUnavailableView("No Connected Profiles", systemImage: "person.crop.circle.badge.plus",
                                       description: Text("Connect an enabled profile in Social Accounts."))
            } else if inbox {
                inboxBody
            } else {
                performanceBody
            }
        }
        .navigationTitle(inbox ? "Inbox" : "Performance")
        .onChange(of: target, initial: true) {
            guard !inbox, let target else { return }
            provider = nil
            selectedProfile = target.identity
            days = 0
            waitingForTarget = target
            selectTargetIfLoaded()
        }
        .onChange(of: posts.map(\.id)) { selectTargetIfLoaded() }
        .task(id: automaticRefreshID) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                for identity in identities where !SocialEngagementStore.manualOnly(identity) {
                    await store.refresh(identity, inbox: inbox, manual: false, using: runtime.connections)
                }
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
    }

    private struct RefreshID: Equatable {
        let identities: [ContentRecipientIdentity]
        let active: Bool
        let inbox: Bool
    }

    private var automaticRefreshID: RefreshID {
        RefreshID(identities: identities, active: scenePhase == .active, inbox: inbox)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Provider", selection: $provider) {
                    Text("All Providers").tag(nil as String?)
                    ForEach(providers, id: \.self) { Text($0).tag(Optional($0)) }
                }
                .onChange(of: provider) {
                    if selectedProfile.map(identities.contains) == false { selectedProfile = nil }
                }
                Picker("Profile", selection: $selectedProfile) {
                    Text("All Profiles").tag(nil as ContentRecipientIdentity?)
                    ForEach(matchingAccounts) { account in
                        Text(profileName(account)).tag(account.providerIdentity)
                    }
                }
                Spacer()
                refreshButton
            }
            HStack {
                if !snapshot.apps.isEmpty {
                    Picker("App", selection: $appID) {
                        Text("All Apps").tag(nil as String?)
                        ForEach(snapshot.apps) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
                if inbox {
                    Picker("Status", selection: $filter) {
                        ForEach(InboxFilter.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    Text("Needs Reply means no response was found in the loaded comments.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Format", selection: $format) {
                        Text("All Formats").tag(nil as String?)
                        ForEach(["Image", "Video", "Multiple attachments", "Other media", "Unknown"], id: \.self) {
                            Text($0).tag(Optional($0))
                        }
                    }
                    Picker("Date", selection: $days) {
                        Text("Last 7 Days").tag(7)
                        Text("Last 30 Days").tag(30)
                        Text("All Loaded Posts").tag(0)
                    }
                }
                Spacer()
                if identities.contains(where: store.refreshing.contains) { ProgressView().controlSize(.small) }
            }
            if selectedProfile == nil && identities.contains(where: SocialEngagementStore.manualOnly) {
                Text("Select X or LinkedIn in Profile to refresh it separately.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !identities.isEmpty {
                DisclosureGroup("Refresh status") {
                    ForEach(matchingAccounts.filter { $0.providerIdentity.map(identities.contains) == true }) { account in
                        if let identity = account.providerIdentity {
                            Text("\(profileName(account)) · \(refreshStatus(identity))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var refreshButton: some View {
        let selected = selectedProfile.flatMap { identities.contains($0) ? $0 : nil }
        let eligible = selected.map { [$0] } ?? identities.filter { !SocialEngagementStore.manualOnly($0) }
        let targets = eligible
        let manualOnly = selected.map(SocialEngagementStore.manualOnly) ?? false
        return Button(manualOnly ? "Refresh Profile (Manual)" : "Refresh", systemImage: "arrow.clockwise") {
            let refreshInbox = inbox
            Task {
                for identity in targets {
                    await store.refresh(identity, inbox: refreshInbox, manual: true, using: runtime.connections)
                }
            }
        }
        .disabled(targets.isEmpty || targets.allSatisfy(store.refreshing.contains))
        .help(manualOnly ? "Requests may use API credits or count toward provider limits."
              : "Refresh eligible profiles. Select a manual-only profile to refresh it separately.")
    }

    private var inboxBody: some View {
        let rows = comments
        let selected = rows.first { $0.id == commentSelection }
        let displayed = rows.filter { $0.status == filter.rawValue || filter == .all || $0.id == commentSelection }
        return HSplitView {
            VStack(spacing: 0) {
                List(displayed, selection: $commentSelection) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(row.author).font(.headline)
                            Spacer()
                            Text(row.status).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(row.comment.readableText).lineLimit(2)
                        Text(profileName(row.post.account)).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    .tag(row.id)
                }
                if displayed.isEmpty {
                    Text(rows.isEmpty ? "No comments loaded for these profiles. Check Refresh status for account coverage."
                         : "No comments match this status.")
                        .font(.caption).foregroundStyle(.secondary).padding()
                }
            }
            .frame(minWidth: 260)
            if let selected {
                ScrollView { commentDetail(selected).padding() }
                    .frame(minWidth: 290, maxWidth: .infinity)
            } else {
                ContentUnavailableView("Select a Comment", systemImage: "bubble.left.and.bubble.right")
                    .frame(minWidth: 290, maxWidth: .infinity)
            }
        }
        .onChange(of: filter) { commentSelection = nil }
    }

    private func commentDetail(_ row: CommentRow) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            postHeader(row.post)
            Divider()
            Text(row.author).font(.headline)
            Text(row.comment.readableText).textSelection(.enabled)
            if let date = row.comment.createdAt { Text(date.formatted()).foregroundStyle(.secondary) }
            ForEach(row.post.thread?.comments.filter { $0.parentID == row.comment.id } ?? []) { reply in
                VStack(alignment: .leading, spacing: 4) {
                    Text(reply.authorName ?? reply.authorHandle ?? "Reply").font(.headline)
                    Text(reply.readableText).textSelection(.enabled)
                }
                .padding(.leading, 16)
            }
            if let sent = store.sent[row.id],
               row.post.thread?.comments.contains(where: { $0.id == sent.id }) != true {
                Text("Sent reply").font(.headline)
                Text(sent.readableText).textSelection(.enabled)
            }
            Button(row.status == "Done" ? "Reopen" : "Mark Done") { store.toggleDone(row.id) }
            if store.profiles[row.id.profile]?.capabilities.contains(.reply) == true {
                TextField("Reply as \(profileName(row.post.account))",
                          text: Binding(get: { drafts[row.id, default: ""] }, set: { drafts[row.id] = $0 }),
                          axis: .vertical)
                    .lineLimit(3...8)
                Button("Send Reply") { send(row) }
                    .disabled(store.sending.contains(row.id) || drafts[row.id, default: ""].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if sendError == row.id {
                Text("The provider did not confirm the reply. Check the post before trying again.")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var performanceBody: some View {
        let rows = posts.filter { row in
            (format == nil || row.format == format) &&
            (days == 0 || row.post.createdAt.map { Date.now.timeIntervalSince($0) <= Double(days) * 86_400 } == true)
        }
        return VSplitView {
            VStack(alignment: .leading, spacing: 0) {
                Table(rows.sorted(using: postSort), selection: $postSelection, sortOrder: $postSort) {
                    TableColumn("Post", value: \.title) { Text($0.title).lineLimit(1) }
                    TableColumn("Profile") { Text(profileName($0.account)) }
                    TableColumn("Format", value: \.format)
                    TableColumn("Published", value: \.published) { row in
                        Text(row.post.createdAt?.formatted(date: .abbreviated, time: .omitted) ?? "—")
                    }
                    TableColumn("Likes / Favourites", value: \.likeCountForSort) { Text($0.post.likeCount?.formatted() ?? "—") }
                    TableColumn("Views") { Text($0.views?.formatted() ?? "—") }
                    TableColumn("Loaded Comments", value: \.commentCountForSort) { Text($0.thread?.comments.count.formatted() ?? "—") }
                }
                Text("A dash means unavailable. View counts use the provider’s definition. Loaded comments are a sample from Inbox.")
                    .font(.caption).foregroundStyle(.secondary).padding(8)
            }
            .frame(minHeight: 170)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let selected = rows.first(where: { $0.id == postSelection }) {
                        postHeader(selected)
                        insightsDetail(selected)
                        if let thread = selected.thread {
                            ForEach(thread.comments) { comment in
                                Text(comment.readableText).textSelection(.enabled)
                            }
                        }
                    } else if let waitingForTarget, selectedProfile == waitingForTarget.identity {
                        Text("This post hasn’t been found in the loaded sample. Refresh this profile to check recent posts.")
                            .foregroundStyle(.secondary)
                        Link("Open Published Post", destination: waitingForTarget.url)
                    } else if selectedProfile != nil {
                        Text("Likes / Favourites by Format").font(.headline)
                        ForEach(Dictionary(grouping: rows, by: \.format).keys.sorted(), id: \.self) { kind in
                            formatSummary(kind, rows: rows.filter { $0.format == kind })
                        }
                    } else {
                        Text("Select a post for details or choose one profile to compare formats.")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .frame(minHeight: 110)
        }
    }

    @ViewBuilder
    private func insightsDetail(_ row: PostRow) -> some View {
        if SocialPlatform(rawValue: row.id.identity.platform)?.isMeta == true {
            let identity = row.id.identity
            Button("Refresh Post Insights", systemImage: "chart.bar.xaxis") {
                Task { await store.refreshInsights(row.post.id, for: identity, using: runtime.connections) }
            }
            .disabled(store.refreshing.contains(identity))
            .help("Fetch insights for this post only. Meta permissions and limits apply.")
            if let issue = store.profiles[identity]?.insightIssues[row.post.id] {
                Text(issue).foregroundStyle(.secondary)
            }
            if let insights = row.insights {
                let labels = [
                    "views": "Views", "reach": "Reach", "likes": "Likes", "comments": "Comments",
                    "saved": "Saves", "shares": "Shares", "replies": "Replies",
                    "reposts": "Reposts", "quotes": "Quotes", "post_media_view": "Media Views",
                    "post_total_media_view_unique": "Unique Media Viewers"
                ]
                if insights.counts.isEmpty {
                    Text("The provider returned no insights for this post.").foregroundStyle(.secondary)
                }
                ForEach(insights.counts.keys.sorted(), id: \.self) { metric in
                    if let label = labels[metric], let count = insights.counts[metric] {
                        LabeledContent(label, value: count.formatted())
                    }
                }
                Text("Insights checked \(insights.checkedAt.formatted())")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func formatSummary(_ kind: String, rows: [PostRow]) -> some View {
        let counts = rows.compactMap(\.post.likeCount).sorted()
        let median: Double? = counts.isEmpty ? nil :
            (Double(counts[(counts.count - 1) / 2]) + Double(counts[counts.count / 2])) / 2
        return Text("\(kind) · \(rows.count) posts · Median \(median?.formatted() ?? "—") (\(counts.count) measured)")
    }

    private func postHeader(_ row: PostRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(profileName(row.account)).font(.headline)
            Text(row.title).textSelection(.enabled)
            HStack {
                if let url = row.post.url, url.scheme == "https", url.host != nil {
                    Link("Open on \(providerTitle(row.id.identity))", destination: url)
                    if let record = linkedContent(row) {
                        Button("Open Content") { openContent(record.id) }
                    }
                }
                if let date = store.profiles[row.id.identity]?.postsCheckedAt {
                    Text("Updated \(date.formatted())").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func linkedContent(_ row: PostRow) -> ContentRecord? {
        guard let url = row.post.url else { return nil }
        let aliases = Set(snapshot.socialAccounts.filter { $0.providerIdentity == row.id.identity }.map(\.id))
        return snapshot.content.first { item in
            item.destinations.contains { $0.publishedURL == url && aliases.contains($0.accountId) }
        }
    }

    private func selectTargetIfLoaded() {
        guard let waitingForTarget, selectedProfile == waitingForTarget.identity,
              let post = posts.first(where: { $0.id.identity == waitingForTarget.identity && $0.post.url == waitingForTarget.url }) else { return }
        postSelection = post.id
        self.waitingForTarget = nil
    }

    private func refreshStatus(_ identity: ContentRecipientIdentity) -> String {
        let profile = store.profiles[identity]
        let policy = SocialEngagementStore.manualOnly(identity) ? "Manual refresh" : "Automatic while open"
        if let issue = profile?.issue { return "\(policy) · \(issue)" }
        if inbox, let profile, !profile.capabilities.contains(.readReplies), profile.postsCheckedAt != nil {
            return "\(policy) · Comment access unavailable"
        }
        let date = inbox ? profile?.inboxCheckedAt : profile?.postsCheckedAt
        return "\(policy) · \(date?.formatted() ?? "Waiting for refresh")"
    }

    private func profileName(_ account: SocialAccountRecord) -> String {
        let provider = account.providerIdentity.map(providerTitle) ?? account.platform
        guard let name = account.displayName ?? account.handle else { return provider }
        return "\(name) · \(provider)"
    }

    private func providerTitle(_ identity: ContentRecipientIdentity) -> String {
        SocialPlatform(rawValue: identity.platform)?.workspaceTitle ?? identity.platform
    }

    private func send(_ row: CommentRow) {
        let text = drafts[row.id, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        sendError = nil
        Task {
            do {
                try await store.send(text, to: row.id, using: runtime.connections)
                if drafts[row.id]?.trimmingCharacters(in: .whitespacesAndNewlines) == text { drafts[row.id] = nil }
            } catch {
                sendError = row.id
            }
        }
    }
}
