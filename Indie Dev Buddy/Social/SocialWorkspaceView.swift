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
    let openAccounts: () -> Void

    private enum InboxFilter: String, CaseIterable {
        case all = "All Comments", needsReply = "Needs Reply", replied = "Replied", done = "Done", unknown = "Unknown"

        func includes(_ status: SocialEngagementStore.ReplyStatus) -> Bool {
            self == .all || rawValue == status.rawValue
        }
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

        var viewsForSort: Int { views ?? -1 }
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
        let status: SocialEngagementStore.ReplyStatus

        var author: String { comment.authorName ?? comment.authorHandle ?? "Unknown author" }
    }

    @State private var selectedProfile: ContentRecipientIdentity?
    @State private var provider: String?
    @State private var appID: String?
    @State private var waitingForTarget: SocialPerformanceTarget?
    @State private var filter = InboxFilter.all
    @State private var detailWidth: CGFloat = 700
    @State private var comparingFormats = false
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
                return CommentRow(id: key, post: row, comment: comment, status: store.replyStatus(for: key, in: thread))
            }
        }.sorted {
            let left = $0.comment.createdAt ?? .distantPast
            let right = $1.comment.createdAt ?? .distantPast
            return left == right ? $0.comment.id < $1.comment.id : left > right
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if accounts.isEmpty {
                ContentUnavailableView {
                    Label("No Connected Profiles", systemImage: "person.crop.circle.badge.plus")
                } description: {
                    Text("Connect an enabled profile to load social activity.")
                } actions: {
                    Button("Open Social Accounts", action: openAccounts)
                }
            } else {
                controls.padding(12)
                Divider()
                Group {
                    if inbox { inboxBody } else { performanceBody }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(inbox ? "Inbox" : "Performance")
        .onChange(of: target, initial: true) {
            guard !inbox, let target else { return }
            provider = nil
            selectedProfile = target.identity
            appID = nil
            format = nil
            days = 0
            comparingFormats = false
            waitingForTarget = target
            selectTargetIfLoaded()
        }
        .onChange(of: posts.map(\.id)) { selectTargetIfLoaded() }
        .onChange(of: matchingAccounts.compactMap(\.providerIdentity)) { _, profiles in
            if let selectedProfile, !profiles.contains(selectedProfile) { self.selectedProfile = nil }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { detailWidth = $0 }
        .task(id: automaticRefreshID) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                for identity in automaticRefreshID.identities {
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
        RefreshID(identities: accounts.compactMap(\.providerIdentity).filter { !SocialEngagementStore.manualOnly($0) },
                  active: scenePhase == .active, inbox: inbox)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            TimelineView(.periodic(from: .now, by: 5)) { context in
                ViewThatFits(in: .horizontal) {
                    HStack { profilePicker; Spacer(minLength: 8); refreshButton(at: context.date) }
                    VStack(alignment: .leading) { profilePicker; refreshButton(at: context.date) }
                }
                if let selectedProfile, identities.contains(selectedProfile) {
                    refreshStatus(selectedProfile, at: context.date)
                } else if !identities.isEmpty {
                    DisclosureGroup("Profile Refresh Status") {
                        ForEach(matchingAccounts) { account in
                            if let identity = account.providerIdentity {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(profileName(account)).font(.caption.weight(.semibold))
                                    refreshStatus(identity, at: context.date)
                                }
                                .padding(.top, 4)
                            }
                        }
                    }
                    .font(.caption)
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack { activityFilters; Spacer(minLength: 0) }
                VStack(alignment: .leading) { activityFilters }
            }
        }
    }

    @ViewBuilder
    private var activityFilters: some View {
        filterMenu
        if inbox {
            Picker("Status", selection: $filter) {
                ForEach(InboxFilter.allCases, id: \.self) { Text($0.rawValue) }
            }
            .fixedSize()
        } else {
            Picker("Published", selection: $days) {
                Text("Last 7 Days").tag(7)
                Text("Last 30 Days").tag(30)
                Text("All Loaded Posts").tag(0)
            }
            .labelsHidden()
            .accessibilityLabel("Publication date filter")
            .fixedSize()
            if selectedProfile != nil {
                Toggle("Compare Formats", isOn: $comparingFormats)
                    .toggleStyle(.button)
                    .fixedSize()
            }
        }
    }

    private var profilePicker: some View {
        Picker("Profile", selection: $selectedProfile) {
            Text("All Profiles").tag(nil as ContentRecipientIdentity?)
            ForEach(matchingAccounts) { account in
                Text(profileName(account)).tag(account.providerIdentity)
            }
        }
    }

    private var filterMenu: some View {
        let active = provider != nil || appID != nil || (!inbox && format != nil)
        return Menu(active ? "Filters Applied" : "Filters", systemImage: "line.3.horizontal.decrease") {
            Picker("Provider", selection: $provider) {
                Text("All Providers").tag(nil as String?)
                ForEach(providers, id: \.self) { Text($0).tag(Optional($0)) }
            }
            if !snapshot.apps.isEmpty {
                Picker("App", selection: $appID) {
                    Text("All Apps").tag(nil as String?)
                    ForEach(snapshot.apps) { Text($0.name).tag(Optional($0.id)) }
                }
            }
            if !inbox {
                Picker("Format", selection: $format) {
                    Text("All Formats").tag(nil as String?)
                    ForEach(["Image", "Video", "Multiple attachments", "Other media", "Unknown"], id: \.self) {
                        Text($0).tag(Optional($0))
                    }
                }
            }
            if active {
                Divider()
                Button("Reset Filters") {
                    provider = nil
                    appID = nil
                    format = nil
                }
            }
        }
        .fixedSize()
    }

    private func refreshButton(at date: Date) -> some View {
        let selected = selectedProfile.flatMap { identities.contains($0) ? $0 : nil }
        let eligible = selected.map { [$0] } ?? identities.filter { !SocialEngagementStore.manualOnly($0) }
        let targets = eligible.filter { store.canRefresh($0, at: date) }
        let manualOnly = selected.map(SocialEngagementStore.manualOnly) ?? false
        return HStack(spacing: 8) {
            if identities.contains(where: store.refreshing.contains) {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("Refreshing social activity")
            }
            Button(selected == nil ? "Refresh Eligible Profiles" : "Refresh Profile", systemImage: "arrow.clockwise") {
                let refreshInbox = inbox
                Task {
                    for identity in targets {
                        await store.refresh(identity, inbox: refreshInbox, manual: true, using: runtime.connections)
                    }
                }
            }
            .disabled(targets.isEmpty)
            .help(manualOnly ? "Reads may use API credits or count toward provider limits."
                  : "X and LinkedIn refresh individually.")
        }
        .fixedSize()
    }

    private var inboxBody: some View {
        let rows = comments
        let displayed = rows.filter { filter.includes($0.status) || $0.id == commentSelection }
        let selected = displayed.first { $0.id == commentSelection }
        return Group {
            if displayed.isEmpty {
                activityPlaceholder(filtered: !rows.isEmpty)
            } else if detailWidth >= 640 {
                HSplitView {
                    commentList(displayed).frame(minWidth: 220, idealWidth: 260)
                    conversationPane(selected).frame(minWidth: 340, maxWidth: .infinity)
                }
            } else {
                VSplitView {
                    commentList(displayed).frame(minHeight: 100, idealHeight: 150, maxHeight: 240)
                    conversationPane(selected).frame(minHeight: 180, maxHeight: .infinity)
                }
            }
        }
        .onChange(of: filter) {
            if let selected, !filter.includes(selected.status) { commentSelection = nil }
        }
    }

    private func commentList(_ rows: [CommentRow]) -> some View {
        List(rows, selection: $commentSelection) { row in
            VStack(alignment: .leading, spacing: 4) {
                Text(row.author).font(.headline)
                Text(row.comment.readableText).lineLimit(2)
                Label(row.status.rawValue, systemImage: row.status.symbol)
                    .font(.caption.weight(.medium))
                Text(profileName(row.post.account))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 5)
            .tag(row.id)
        }
        .accessibilityLabel("Comments")
    }

    @ViewBuilder
    private func conversationPane(_ row: CommentRow?) -> some View {
        if let row {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        postHeader(row.post, heading: "Original Post")
                        Divider()
                        HStack {
                            Text("Conversation").font(.headline)
                                .accessibilityAddTraits(.isHeader)
                            Spacer()
                            Label(row.status.rawValue, systemImage: row.status.symbol).font(.caption)
                        }
                        Text(row.post.thread?.incomplete == true
                             ? "More comments are available on the provider. This view shows the first page."
                             : "This sample may omit nested or older replies. Open the post for the full thread.")
                            .font(.caption).foregroundStyle(.secondary)
                        conversationMessage(row.comment)
                        ForEach(row.post.thread?.comments.filter { $0.parentID == row.comment.id } ?? []) { reply in
                            conversationMessage(reply).padding(.leading, 16)
                        }
                        if let sent = store.sent[row.id],
                           row.post.thread?.comments.contains(where: { $0.id == sent.id }) != true {
                            conversationMessage(sent, fallback: "Sent reply").padding(.leading, 16)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                }
                replyComposer(row)
            }
        } else {
            ContentUnavailableView("Select a Comment", systemImage: "bubble.left.and.bubble.right",
                                   description: Text("Review the original post and loaded replies here."))
        }
    }

    private func conversationMessage(_ post: SocialPost, fallback: String = "Unknown author") -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(post.authorName ?? post.authorHandle ?? fallback).font(.headline)
            Text(post.readableText).textSelection(.enabled)
            if let date = post.createdAt {
                Text(date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func replyComposer(_ row: CommentRow) -> some View {
        let profile = profileName(row.post.account)
        let canReply = store.profiles[row.id.profile]?.capabilities.contains(.reply) == true
        return VStack(alignment: .leading, spacing: 8) {
            Divider()
            if canReply {
                TextField("Reply as \(profile)", text: Binding(
                    get: { drafts[row.id, default: ""] }, set: { drafts[row.id] = $0 }
                ), axis: .vertical)
                .lineLimit(2...4)
                .accessibilityIdentifier("social-reply")
            } else {
                Text("Reply access is unavailable for this profile. You can open the post on the provider.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Menu("Triage") {
                    if row.status == .unknown || row.status == .needsReply {
                        Button(row.status == .needsReply ? "Clear Needs Reply" : "Flag Needs Reply", systemImage: "flag") {
                            store.toggleNeedsReply(row.id)
                        }
                    }
                    Button(row.status == .done ? "Reopen" : "Mark Done", systemImage: "checkmark.circle") {
                        store.toggleDone(row.id)
                    }
                }
                Spacer()
                if canReply {
                    Button("Send Reply") { send(row) }
                        .buttonStyle(.borderedProminent)
                        .disabled(store.sending.contains(row.id) || drafts[row.id, default: ""].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            if sendError == row.id {
                Text("The provider did not confirm the reply. Check the post before trying again.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding([.horizontal, .bottom], 12)
    }

    private var performanceBody: some View {
        let rows = posts.filter { row in
            (format == nil || row.format == format) &&
            (days == 0 || row.post.createdAt.map { Date.now.timeIntervalSince($0) <= Double(days) * 86_400 } == true)
        }
        return Group {
            if rows.isEmpty && waitingForTarget == nil {
                activityPlaceholder(filtered: !posts.isEmpty)
            } else {
                VSplitView {
                    performanceTable(rows)
                        .frame(minHeight: 150, idealHeight: 280)
                    ScrollView {
                        performanceDetail(rows)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                    .frame(minHeight: 130, idealHeight: 320, maxHeight: .infinity)
                }
            }
        }
    }

    private func performanceTable(_ rows: [PostRow]) -> some View {
        VStack(spacing: 0) {
            Table(rows.sorted(using: postSort), selection: $postSelection, sortOrder: $postSort) {
                TableColumn("Post", value: \.title) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title).lineLimit(1)
                        if selectedProfile == nil {
                            Text(profileName(row.account)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .width(min: 150, ideal: 270)
                TableColumn("Format", value: \.format).width(min: 70, ideal: 95)
                TableColumn("Published", value: \.published) { row in
                    Text(row.post.createdAt?.formatted(date: .abbreviated, time: .omitted) ?? "—")
                }
                .width(min: 82, ideal: 104)
                TableColumn("Likes", value: \.likeCountForSort) { row in
                    metricCell(row.post.likeCount, missing: "Unavailable")
                }
                .width(min: 46, ideal: 54)
                TableColumn("Views", value: \.viewsForSort) { row in
                    metricCell(row.views, missing: insightsState(row))
                }
                .width(min: 48, ideal: 60)
                TableColumn("Sampled", value: \.commentCountForSort) { row in
                    metricCell(row.thread?.comments.count, missing: "No comment sample loaded")
                }
                .width(min: 62, ideal: 69)
            }
            .accessibilityLabel("Post performance")
            .onChange(of: postSelection) { if postSelection != nil { comparingFormats = false } }
            Text("Likes include favourites where applicable. Sampled counts are loaded comments and replies. Hover over a dash for its status.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
    }

    private func metricCell(_ count: Int?, missing: String) -> some View {
        Text(count?.formatted() ?? "—")
            .monospacedDigit()
            .accessibilityLabel(count?.formatted() ?? missing)
            .help(count?.formatted() ?? missing)
    }

    private func insightsState(_ row: PostRow) -> String {
        guard SocialPlatform(rawValue: row.id.identity.platform)?.isMeta == true else { return "Unavailable" }
        if store.profiles[row.id.identity]?.insightIssues[row.id.post] != nil { return "Unavailable after refresh" }
        return row.insights == nil ? "Insights not yet fetched" : "Unavailable for this post"
    }

    @ViewBuilder
    private func performanceDetail(_ rows: [PostRow]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if comparingFormats, selectedProfile != nil {
                formatComparison(rows)
            } else if let selected = rows.first(where: { $0.id == postSelection }) {
                postHeader(selected, heading: "Published Post")
                insightsDetail(selected)
                Divider()
                Text("Loaded Conversation").font(.headline).accessibilityAddTraits(.isHeader)
                if let thread = selected.thread {
                    Text("\(thread.comments.count.formatted()) loaded · Checked \(thread.checkedAt.formatted(date: .abbreviated, time: .shortened)). Open the post for the full conversation.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(thread.comments) { comment in
                        conversationMessage(comment)
                            .padding(.leading, comment.parentID != nil && comment.parentID != selected.id.post ? 12 : 0)
                    }
                } else {
                    Text("No sample loaded. Open Inbox and refresh this profile to check for comments.")
                        .foregroundStyle(.secondary)
                }
            } else if let waitingForTarget, selectedProfile == waitingForTarget.identity {
                Text("This post is outside the loaded sample. Refresh this profile to check recent posts.")
                    .foregroundStyle(.secondary)
                Link("Open Published Post", destination: waitingForTarget.url)
            } else if selectedProfile != nil {
                formatComparison(rows)
            } else {
                Text("Select a post for results, or choose a profile to compare formats.").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func insightsDetail(_ row: PostRow) -> some View {
        let profile = store.profiles[row.id.identity]
        LabeledContent("Likes / Favourites", value: row.post.likeCount?.formatted() ?? "Unavailable")
        if let date = profile?.postsCheckedAt {
            let staleAfter: TimeInterval = SocialEngagementStore.manualOnly(row.id.identity) ? 86_400 : 900
            let cached = profile?.postsIssue != nil || Date.now.timeIntervalSince(date) > staleAfter
            Text("\(cached ? "Cached post counts" : "Post counts checked") · \(date.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption).foregroundStyle(.secondary)
        }
        if SocialPlatform(rawValue: row.id.identity.platform)?.isMeta == true {
            Divider()
            TimelineView(.periodic(from: .now, by: 5)) { context in
                let identity = row.id.identity
                VStack(alignment: .leading, spacing: 4) {
                    Button("Refresh Post Insights", systemImage: "chart.bar.xaxis") {
                        Task { await store.refreshInsights(row.post.id, for: identity, using: runtime.connections) }
                    }
                    .disabled(!store.canRefresh(identity, at: context.date))
                    .help("Fetch insights for this post only. Meta permissions and limits apply.")
                    if let retry = store.retryAt(for: identity), retry > context.date {
                        Text("Insights refresh available after \(retry.formatted(date: .omitted, time: .standard))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            let issue = profile?.insightIssues[row.id.post]
            if let issue {
                Label(issue, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
            }
            if let insights = row.insights {
                let labels = [
                    "views": "Views", "reach": "Reach", "likes": "Likes",
                    "comments": "Provider Comment Total", "saved": "Saves", "shares": "Shares",
                    "replies": "Provider Reply Total", "reposts": "Reposts", "quotes": "Quotes",
                    "post_media_view": "Media Views", "post_total_media_view_unique": "Unique Media Viewers"
                ]
                if insights.counts.isEmpty {
                    Text("The provider returned no insights for this post.").foregroundStyle(.secondary)
                }
                ForEach(insights.counts.keys.sorted(), id: \.self) { metric in
                    if let label = labels[metric], let count = insights.counts[metric] {
                        LabeledContent(label, value: count.formatted())
                    }
                }
                let cached = issue != nil || Date.now.timeIntervalSince(insights.checkedAt) > 86_400
                Text("\(cached ? "Cached insights" : "Insights checked") · \(insights.checkedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            } else if issue == nil {
                Text("Insights not yet fetched.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func formatComparison(_ rows: [PostRow]) -> some View {
        let grouped = Dictionary(grouping: rows, by: \.format)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Likes / Favourites by Format").font(.headline).accessibilityAddTraits(.isHeader)
            Text("Median of available counts for the filtered posts. Formats use the provider’s attachment metadata.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(grouped.keys.sorted(), id: \.self) { kind in
                if let posts = grouped[kind] {
                    let counts = posts.compactMap(\.post.likeCount).sorted()
                    let median: Double? = counts.isEmpty ? nil :
                        (Double(counts[(counts.count - 1) / 2]) + Double(counts[counts.count / 2])) / 2
                    LabeledContent(kind, value: "\(median?.formatted() ?? "Unavailable") · \(counts.count) of \(posts.count) measured")
                }
            }
        }
    }

    private func postHeader(_ row: PostRow, heading: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(heading).font(.headline).accessibilityAddTraits(.isHeader)
            Text(profileName(row.account)).font(.subheadline).foregroundStyle(.secondary)
            Text(row.title).textSelection(.enabled)
            ViewThatFits(in: .horizontal) {
                HStack { postLinks(row) }
                VStack(alignment: .leading) { postLinks(row) }
            }
        }
    }

    @ViewBuilder
    private func postLinks(_ row: PostRow) -> some View {
        if let url = row.post.url, url.scheme == "https", url.host != nil {
            Link("Open on \(providerTitle(row.id.identity))", destination: url)
        }
        if let record = linkedContent(row) {
            Button("Open Workspace Post") { openContent(record.id) }
        }
    }

    private func activityPlaceholder(filtered: Bool) -> some View {
        let loading = identities.contains(where: store.refreshing.contains)
        let manual = selectedProfile.map(SocialEngagementStore.manualOnly) == true
        let selected = selectedProfile.flatMap { store.profiles[$0] }
        let issue = inbox ? selected?.inboxIssue : selected?.postsIssue
        let noAccess = inbox && selected?.inboxCheckedAt != nil && selected?.capabilities.contains(.readReplies) == false
        return Group {
            if loading && !filtered {
                ProgressView(inbox ? "Loading Comments…" : "Loading Posts…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if noAccess || issue != nil {
                ContentUnavailableView {
                    Label(noAccess ? "Comment Access Unavailable" : "Refresh Unavailable", systemImage: "exclamationmark.circle")
                } description: {
                    Text(issue ?? "This profile’s current permissions don’t allow comment reads.")
                } actions: {
                    Button("Open Social Accounts", action: openAccounts)
                }
            } else if filtered {
                ContentUnavailableView(inbox ? "No Matching Comments" : "No Matching Posts", systemImage: "line.3.horizontal.decrease",
                                       description: Text("Adjust the filters to include more results."))
            } else {
                ContentUnavailableView(inbox ? "No Comments Loaded" : "No Posts Loaded", systemImage: inbox ? "tray" : "chart.bar.xaxis",
                                       description: Text(manual ? "Choose Refresh Profile to load activity. Reads may use API credits or count toward limits."
                                                                 : "Check profile refresh status or choose a profile."))
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

    private func refreshStatus(_ identity: ContentRecipientIdentity, at now: Date) -> some View {
        let profile = store.profiles[identity]
        let manual = SocialEngagementStore.manualOnly(identity)
        let policy = manual ? "Manual refresh · Provider limits or credits may apply" : "Automatic while open"
        let issue = inbox ? profile?.inboxIssue : profile?.postsIssue
        let date = inbox ? profile?.inboxCheckedAt : profile?.postsCheckedAt
        return VStack(alignment: .leading, spacing: 2) {
            Text(policy).fontWeight(.medium)
            if inbox, profile?.postsCheckedAt != nil, profile?.capabilities.contains(.readReplies) == false {
                Text("Comment access unavailable")
            } else if let date {
                Text("Last successful update \(date.formatted(date: .abbreviated, time: .shortened))")
            } else {
                Text("Waiting for first update")
            }
            if let issue { Label(issue, systemImage: "exclamationmark.circle") }
            if let retry = store.retryAt(for: identity), retry > now {
                Text("Refresh available after \(retry.formatted(date: .omitted, time: .standard))")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
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
