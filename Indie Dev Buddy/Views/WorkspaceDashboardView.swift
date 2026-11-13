import SwiftUI
import ImageIO

struct WorkspaceDashboardView: View {
    let snapshot: WorkspaceSnapshot
    let workspaceRoot: URL
    let generation: Int
    @State private var channel: String?
    let openSection: (String) -> Void
    let openContent: (String) -> Void
    let openRecord: (ManagementRecordSelection) -> Void
    let createContent: (ContentKind) -> Void
    let createRecord: (ManagementCreateRequest) -> Void

    private struct Row: Identifiable {
        let id: String
        let title: String
        let detail: String
        var artwork: Artwork? = nil
        var excerpt: String? = nil
        var platform: String? = nil
        var openAppStore: (() -> Void)? = nil
        var actionTitle = "Open"
        let action: () -> Void
    }

    private struct Artwork: Hashable {
        var paths: [String] = []
        var folder: String? = nil
        let symbol: String
        let tint: Color
    }

    private struct Plan: Identifiable {
        var id: String { row.id }
        let date: Date
        let accountID: String?
        let row: Row
    }

    private var activeAccounts: [SocialAccountRecord] {
        snapshot.socialAccounts.filter(\.enabled)
    }

    private var blogEnabled: Bool {
        snapshot.websites.contains(where: \.blogEnabled) || snapshot.content.contains { $0.kind == .blog }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                let issues = deliveryIssues
                let plans = plannedContent
                let drafts = openDrafts
                if !issues.isEmpty {
                    card("Publishing Needs Attention", icon: "exclamationmark.triangle", rows: issues) {
                        openSection("Marketing Content")
                    }
                }
                if let focus = plans.first(where: { $0.date >= Date() })?.row
                    ?? drafts.first(where: { $0.actionTitle == "Review Draft" })
                    ?? appRows.first ?? drafts.first {
                    featured(focus)
                } else if snapshot.content.isEmpty && snapshot.websites.isEmpty && activeAccounts.isEmpty {
                    emptyState
                }
                let otherPlans = plansOutsideWeek(plans)
                if otherPlans.count < plans.count {
                    publishing(plans)
                }
                if !otherPlans.isEmpty {
                    card("Other Planned Content", icon: "calendar", rows: otherPlans.map(\.row)) {
                        openSection("Marketing Content")
                    }
                }
                let articles = drafts.filter { $0.artwork?.symbol == "doc.richtext" }
                let otherDrafts = drafts.filter { $0.artwork?.symbol != "doc.richtext" }
                if !snapshot.apps.isEmpty {
                    collection("My Apps", rows: appRows, wide: false, appsOnly: true) { openSection("Apps") }
                }
                if !otherDrafts.isEmpty {
                    collection("Ready and Drafts", rows: otherDrafts, wide: true) { openSection("Marketing Content") }
                }
                if blogEnabled && !articles.isEmpty {
                    collection("Articles", rows: articles, wide: true) { openSection("Marketing Content") }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 16)], alignment: .leading, spacing: 16) {
                    if !snapshot.websites.isEmpty {
                        card("Websites", icon: "globe", rows: websiteRows) { openSection(ManagementSection.websites.rawValue) }
                    }
                    if !activeAccounts.isEmpty {
                        card("Social Accounts", icon: "at", rows: accountRows) { openSection(ManagementSection.socialAccounts.rawValue) }
                    }
                }
            }
            .frame(maxWidth: 1040, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Dashboard")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu("Create", systemImage: "plus") {
                    Button("App") { createRecord(.app) }
                    Button("Identity") { createRecord(.identity) }
                    Button("Website") { createRecord(.website) }
                    Button("Social Account") { createRecord(.socialAccount) }
                    Divider()
                    if blogEnabled { Button("Blog Article") { createContent(.blog) } }
                    Button("Social Post") { createContent(.social) }
                    Button("Idea") { createContent(.idea) }
                }
                .labelStyle(.iconOnly)
                .help("Create")
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Start with what you’re building").font(.title2.bold())
            Text("Add an app or capture an idea. Your drafts and plans will appear here.")
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.blue.opacity(0.09), in: RoundedRectangle(cornerRadius: 20))
    }

    private func featured(_ row: Row) -> some View {
        Group {
            if row.artwork?.paths.isEmpty != false {
                HStack(spacing: 16) {
                    artwork(row.artwork).frame(width: 62, height: 62).clipShape(.rect(cornerRadius: 12))
                    featuredText(row)
                }
            } else {
                featuredWithImage(row)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((row.artwork?.tint ?? .accentColor).opacity(0.10), in: RoundedRectangle(cornerRadius: 20))
    }

    private func featuredWithImage(_ row: Row) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 24) {
                featuredText(row).frame(minWidth: 220, maxWidth: .infinity, alignment: .leading)
                artwork(row.artwork).frame(width: 244, height: 160).clipShape(.rect(cornerRadius: 14))
            }
            VStack(alignment: .leading, spacing: 16) {
                artwork(row.artwork).frame(height: 120).clipShape(.rect(cornerRadius: 14))
                featuredText(row)
            }
        }
    }

    private func featuredText(_ row: Row) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(row.detail).font(.subheadline).foregroundStyle(.secondary)
            Text(row.title).font(.title.bold()).accessibilityAddTraits(.isHeader)
            if let excerpt = row.excerpt, !excerpt.isEmpty {
                Text(excerpt).foregroundStyle(.secondary).lineLimit(2)
            }
            Button(row.actionTitle, action: row.action)
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
        }
    }

    private func collection(_ title: String, rows: [Row], wide: Bool, appsOnly: Bool = false, openAll: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Spacer()
                Button("View All", action: openAll).buttonStyle(.link)
                    .accessibilityLabel("View all \(title)")
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: wide ? 210 : 155), spacing: 12)], spacing: 12) {
                ForEach(rows.prefix(6)) { row in
                    if appsOnly {
                        Button(action: row.action) {
                            VStack(spacing: 9) {
                                artwork(row.artwork).frame(width: 88, height: 88)
                                Text(row.title)
                                    .font(.headline)
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2)
                                    .frame(maxWidth: .infinity)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if let openAppStore = row.openAppStore {
                                Button("Open App Store Connect", action: openAppStore)
                            }
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            Button(action: row.action) {
                                VStack(alignment: .leading, spacing: 7) {
                                    artwork(row.artwork)
                                        .frame(height: wide ? 100 : 80)
                                        .clipShape(.rect(cornerRadius: 10))
                                    Text(row.title).font(.headline).lineLimit(1)
                                    Text(row.excerpt?.isEmpty == false ? row.excerpt ?? row.detail : row.detail)
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    Spacer(minLength: 0)
                                }
                                .frame(height: wide ? 150 : 126, alignment: .topLeading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if let openAppStore = row.openAppStore {
                                Button("App Store Connect", action: openAppStore)
                                    .buttonStyle(.link)
                                    .accessibilityLabel("Open App Store Connect for \(row.title)")
                            }
                        }
                        .padding(10)
                        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
                    }
                }
            }
        }
    }

    private func publishing(_ plans: [Plan]) -> some View {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        let dates = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
        let accounts = activeAccounts.filter { account in plans.contains { $0.accountID == account.id } }
        let filter = accounts.contains { $0.id == channel } ? channel : nil
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Publishing This Week").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Spacer()
                if accounts.count > 1 {
                    Picker("Channel", selection: $channel) {
                        Text("All Channels").tag(nil as String?)
                        ForEach(accounts) { account in
                            Text(accountName(account)).tag(Optional(account.id))
                        }
                    }
                    .fixedSize()
                }
            }
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(dates, id: \.self) { date in
                        let items = plans.filter {
                            calendar.isDate($0.date, inSameDayAs: date) && (filter == nil || $0.accountID == filter)
                        }
                        VStack(alignment: .leading, spacing: 7) {
                            Text(calendar.isDateInToday(date) ? "Today" : date.formatted(.dateTime.weekday(.abbreviated).day()))
                                .font(.subheadline.bold())
                            ForEach(items.prefix(3)) { item in
                                Button(action: item.row.action) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        if item.row.artwork?.paths.isEmpty == false {
                                            artwork(item.row.artwork).frame(height: 42).clipShape(.rect(cornerRadius: 6))
                                        } else if let excerpt = item.row.excerpt, !excerpt.isEmpty {
                                            Text(excerpt).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                                        }
                                        HStack(alignment: .top, spacing: 4) {
                                            if let platform = item.row.platform {
                                                SocialPlatformIcon(platform: platform, size: 14)
                                                    .accessibilityHidden(true)
                                            }
                                            Text(item.row.title).font(.caption.bold()).lineLimit(2)
                                        }
                                        Text(item.row.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(4)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(6)
                                    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                            if items.count > 3 {
                                Button("+\(items.count - 3) more") { openSection("Marketing Content") }
                                    .buttonStyle(.link)
                            } else if items.isEmpty {
                                Text("No plans").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(9)
                        .frame(width: 125, alignment: .leading)
                        .background(.quaternary.opacity(0.30), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            Button("View Content") { openSection("Marketing Content") }.buttonStyle(.link)
        }
        .onChange(of: accounts.map(\.id), initial: true) { _, ids in
            if let channel, !ids.contains(channel) { self.channel = nil }
        }
    }

    private func plansOutsideWeek(_ plans: [Plan]) -> [Plan] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        guard let end = calendar.date(byAdding: .day, value: 7, to: start) else { return [] }
        return plans.filter { $0.date < start || $0.date >= end }
    }

    private func artwork(_ artwork: Artwork?) -> some View {
        DashboardArtworkView(
            workspaceRoot: workspaceRoot,
            generation: generation,
            paths: artwork?.paths ?? [],
            folder: artwork?.folder,
            symbol: artwork?.symbol ?? "square.stack",
            tint: artwork?.tint ?? .accentColor,
            clearBackground: artwork?.symbol == "app.dashed"
        )
        .accessibilityHidden(true)
    }

    private func contentArtwork(_ item: ContentRecord, paths: [String]? = nil) -> Artwork {
        let symbol = switch item.kind {
        case .blog: "doc.richtext"
        case .social: "megaphone"
        case .idea: "lightbulb"
        }
        let folder = recordFolder(category: "Content", id: item.id)
        return Artwork(paths: folder == nil ? [] : paths ?? item.mediaPaths, folder: folder,
                       symbol: symbol, tint: item.kind == .idea ? .orange : .indigo)
    }

    private func recordFolder(category: String, id: String) -> String? {
        snapshot.recordPaths[category]?[id].map { ($0 as NSString).deletingLastPathComponent }
    }

    private func card(_ title: String, icon: String, rows: [Row], openAll: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            ForEach(rows.prefix(4)) { row in
                Divider()
                Button(action: row.action) {
                    HStack {
                        if let image = row.artwork {
                            artwork(image).frame(width: 38, height: 38).clipShape(.rect(cornerRadius: 8))
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.title).font(.body.weight(.medium))
                            Text(row.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, 3)
                }
                .buttonStyle(.plain)
            }
            if rows.count > 4 {
                Button("Show All \(title)", action: openAll)
                    .buttonStyle(.link)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
    }

    private var deliveryIssues: [Row] {
        let accounts = snapshot.socialAccountsByID
        return snapshot.content.flatMap { item in
            item.destinations.compactMap { destination in
                guard destination.status != .published,
                      let state = destination.schedule?.state ?? destination.deliveryHistory?.last?.state,
                      state == .failed || state == .overdue || state == .outcomeUnknown else { return nil }
                let account = accountName(accounts[destination.accountId])
                return Row(id: "\(item.id)/\(destination.accountId)", title: item.title,
                           detail: "\(account) · \(state.displayTitle)") { openContent(item.id) }
            }
        }
    }

    private var plannedContent: [Plan] {
        let accounts = snapshot.socialAccountsByID
        return snapshot.content.flatMap { item -> [Plan] in
            var plans: [Plan] = item.destinations.compactMap { destination in
                guard destination.status == .scheduled || destination.status == .manuallyScheduled,
                      let schedule = destination.schedule,
                      schedule.state == .queued || schedule.state == .sending else { return nil }
                let date = schedule.scheduledDate
                let account = accountName(accounts[destination.accountId])
                let label = schedule.mode == .manual ? "Manual" : "API schedule"
                let detail = "\(date.formatted(date: .abbreviated, time: .shortened)) · \(account) · \(label)"
                return Plan(date: date, accountID: destination.accountId,
                            row: Row(id: "\(item.id)/\(destination.accountId)", title: item.title, detail: detail,
                                     artwork: contentArtwork(item, paths: destination.mediaPaths),
                                     excerpt: item.excerpt, platform: accounts[destination.accountId]?.platform, actionTitle: "Review Post") { openContent(item.id) })
            }
            if item.status != .published, let date = item.plannedDate {
                plans.append(Plan(date: date, accountID: nil,
                                  row: Row(id: item.id, title: item.title,
                                           detail: "\(date.formatted(date: .abbreviated, time: .omitted)) · Planned",
                                           artwork: contentArtwork(item), excerpt: item.excerpt,
                                           actionTitle: "Open Plan") { openContent(item.id) }))
            }
            return plans
        }
        .sorted { $0.date < $1.date }
    }

    private var openDrafts: [Row] {
        snapshot.content
            .filter { $0.status == .idea || $0.status == .draft || $0.status == .ready }
            .sorted {
                if ($0.status == .ready) != ($1.status == .ready) { return $0.status == .ready }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
            .map { item in
                let kind = item.kind == .blog ? "Article" : item.kind == .social ? "Social Post" : "Idea"
                let detail = item.kind == .idea && item.status == .idea ? kind : "\(kind) · \(item.status.displayTitle)"
                return Row(id: item.id, title: item.title, detail: detail, artwork: contentArtwork(item),
                           excerpt: item.excerpt,
                           actionTitle: item.status == .ready ? "Review Draft" : item.kind == .blog ? "Edit Article" : "Open Draft") {
                    openContent(item.id)
                }
            }
    }

    private var appRows: [Row] {
        snapshot.apps.sorted { left, right in
            let leftActive = left.developmentStatus == nil || left.developmentStatus == .development || left.developmentStatus == .beta
            let rightActive = right.developmentStatus == nil || right.developmentStatus == .development || right.developmentStatus == .beta
            if leftActive != rightActive { return leftActive }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }.map { app in
            let linked = app.appStoreConnectAppId?.isEmpty == false
            let detail = [app.developmentStatus?.label, linked ? "App Store Connect linked" : nil,
                          app.platforms.isEmpty ? nil : app.platforms.joined(separator: ", ")]
                .compactMap { $0 }.joined(separator: " · ")
            let folder = recordFolder(category: "Apps", id: app.id)
            let image = Artwork(paths: folder == nil ? [] : app.iconPath.map { [$0] } ?? [],
                                folder: folder, symbol: "app.dashed", tint: .blue)
            return Row(id: app.id, title: app.name, detail: detail.isEmpty ? "App" : detail,
                       artwork: image, excerpt: app.description,
                       openAppStore: linked ? { openRecord(.init(type: .app, id: app.id, opensAppStore: true)) } : nil,
                       actionTitle: "Open App") {
                openRecord(.init(type: .app, id: app.id))
            }
        }
    }

    private var websiteRows: [Row] {
        snapshot.websites.map { site in
            let host = site.baseURL.host ?? site.baseURL.absoluteString
            return Row(id: site.id, title: site.name, detail: site.blogEnabled ? "\(host) · Blog enabled" : host) {
                openRecord(.init(type: .website, id: site.id))
            }
        }
    }

    private var accountRows: [Row] {
        activeAccounts.map { account in
            let mode = account.providerIdentity == nil ? "Manual posting" : "API identity linked"
            let identityID = account.owner.flatMap { $0.type == .identity ? $0.id : nil }
            let identityPhoto = snapshot.identities.first { $0.id == identityID }?.photoPath
            let image = Artwork(paths: [account.avatarPath, identityPhoto].compactMap { $0 },
                                symbol: "person.crop.circle", tint: .teal)
            return Row(id: account.id, title: accountName(account), detail: "\(account.platform) · \(mode)", artwork: image) {
                openRecord(.init(type: .socialAccount, id: account.id))
            }
        }
    }

    private func accountName(_ account: SocialAccountRecord?) -> String {
        account?.displayName ?? account?.handle ?? account?.platform ?? "Unknown account"
    }
}

private struct DashboardArtworkView: View {
    let workspaceRoot: URL
    let generation: Int
    let paths: [String]
    let folder: String?
    let symbol: String
    let tint: Color
    var clearBackground = false
    @State private var image: CGImage?

    var body: some View {
        let request = WorkspaceThumbnailRequest(root: workspaceRoot, folder: folder, paths: paths, generation: generation)
        GeometryReader { proxy in
            ZStack {
                if !clearBackground {
                    LinearGradient(colors: [tint.opacity(0.22), tint.opacity(0.07)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: symbol == "app.dashed" || symbol == "person.crop.circle" ? .fit : .fill)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: min(52, proxy.size.height * 0.45), weight: .medium))
                        .foregroundStyle(tint)
                }
            }
            .clipped()
        }
        .task(id: request) {
            guard !paths.isEmpty else { image = nil; return }
            let result = await WorkspaceThumbnailCache.shared.load(request)
            guard !Task.isCancelled else { return }
            image = result
        }
    }
}

struct WorkspaceThumbnailRequest: Hashable, Sendable {
    let root: URL
    let folder: String?
    let paths: [String]
    let generation: Int
    var maxPixelSize = 640
}

actor WorkspaceThumbnailCache {
    static let shared = WorkspaceThumbnailCache()
    private let cache = NSCache<NSString, CGImage>()

    init() {
        cache.countLimit = 120
        cache.totalCostLimit = 48 * 1024 * 1024
    }

    func load(_ request: WorkspaceThumbnailRequest) -> CGImage? {
        guard !Task.isCancelled else { return nil }
        let root = request.root.standardizedFileURL.resolvingSymlinksInPath()
        let folder = request.folder.map { root.appendingPathComponent($0).resolvingSymlinksInPath() } ?? root
        guard folder.path == root.path || folder.path.hasPrefix(root.path + "/") else { return nil }
        for path in request.paths.prefix(8) {
            guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { continue }
            let url: URL
            if path.hasPrefix("asset:") {
                guard let managed = managedAssetURL(path, root: root) else { continue }
                url = managed
            } else {
                url = folder.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
                guard url.path.hasPrefix(folder.path + "/") else { continue }
            }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            let key = "\(url.path)|\(values.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0)|\(values.fileSize ?? 0)|\(request.maxPixelSize)" as NSString
            if let image = cache.object(forKey: key) { return image }
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: request.maxPixelSize,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { continue }
            cache.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
            return image
        }
        return nil
    }
}
