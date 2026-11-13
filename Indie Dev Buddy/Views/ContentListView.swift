import SwiftUI

struct ContentListView<RowActions: View>: View {
    let snapshot: WorkspaceSnapshot
    let stage: ContentStage?
    let showsControls: Bool
    let open: (String) -> Void
    let create: (ContentKind) -> Void
    @ViewBuilder let rowActions: (ContentRecord) -> RowActions

    @State private var search = ""
    @State private var association: Association?
    @State private var accountID: String?
    @State private var sort: Sort = .plannedDate

    private enum Association: Hashable {
        case app(String), website(String)

        func matches(_ item: ContentRecord) -> Bool {
            switch self {
            case .app(let id): item.appIds.contains(id)
            case .website(let id): item.websiteId == id
            }
        }
    }

    private enum Sort: String, CaseIterable {
        case plannedDate = "Planned Date"
        case title = "Title"
        case progress = "Publishing Progress"
    }

    private var records: [ContentRecord] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return snapshot.content.filter { item in
            guard stage == nil || ContentStage(item) == stage,
                  association?.matches(item) ?? true,
                  accountID.map({ id in item.destinations.contains { $0.accountId == id } }) ?? true else { return false }
            return query.isEmpty || ([item.title, item.excerpt ?? ""] + item.associationNames(in: snapshot))
                .contains { $0.localizedStandardContains(query) }
        }.sorted {
            switch sort {
            case .plannedDate:
                let left = $0.plannedDate ?? .distantFuture
                let right = $1.plannedDate ?? .distantFuture
                if left != right { return left < right }
            case .progress:
                if $0.publishingProgress != $1.publishingProgress { return $0.publishingProgress < $1.publishingProgress }
            case .title:
                break
            }
            let comparison = $0.title.localizedStandardCompare($1.title)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
    }

    var body: some View {
        let items = records
        VStack(spacing: 0) {
            if items.isEmpty {
                ContentUnavailableView {
                    Label("No Matching Content", systemImage: "tray")
                } actions: {
                    if !search.isEmpty || association != nil || accountID != nil {
                        Button("Clear Search and Filters") {
                            search = ""
                            association = nil
                            accountID = nil
                        }
                    } else if stage != .posted {
                        Button(stage == .ideas ? "New Idea" : "New Social Post") {
                            create(stage == .ideas ? .idea : .social)
                        }
                    }
                }
            } else {
                List(items) { item in
                    Button { open(item.id) } label: {
                        ContentLibraryRow(item: item, snapshot: snapshot)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { rowActions(item) }
                }
            }
        }
        .toolbar {
            if showsControls {
                ToolbarItem {
                    TextField("Search content", text: $search)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Search content")
                        .frame(idealWidth: 180)
                }
                filterToolbar
            }
        }
    }

    private var filterToolbar: some ToolbarContent {
        ToolbarItem {
            Menu("Filter and Sort", systemImage: association == nil && accountID == nil
                 ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill") {
                Picker("App or Website", selection: $association) {
                    Text("All Apps and Websites").tag(nil as Association?)
                    ForEach(snapshot.apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
                        Text($0.name).tag(Association.app($0.id) as Association?)
                    }
                    ForEach(snapshot.websites.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
                        Label($0.name, systemImage: "globe").tag(Association.website($0.id) as Association?)
                    }
                }
                Picker("Social Account", selection: $accountID) {
                    Text("All Accounts").tag(nil as String?)
                    ForEach(snapshot.socialAccounts.sorted { $0.contentFilterTitle.localizedStandardCompare($1.contentFilterTitle) == .orderedAscending }) {
                        Text($0.contentFilterTitle).tag($0.id as String?)
                    }
                }
                Divider()
                Picker("Sort by", selection: $sort) {
                    ForEach(Sort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
            }
            .labelStyle(.iconOnly)
            .help("Filter and Sort")
        }
    }
}

struct ContentLibraryRow: View {
    let item: ContentRecord
    let snapshot: WorkspaceSnapshot
    var compact = false
    var showsPlannedTime = false

    private var accounts: [SocialAccountRecord] {
        let byID = snapshot.socialAccountsByID
        return item.destinations.compactMap { byID[$0.accountId] }
    }

    private var relatedTitle: String? {
        if let sourceID = item.sourceContentId {
            return snapshot.content.first { $0.id == sourceID }?.title
        }
        return nil
    }

    private var dateLabel: String? {
        if let date = item.plannedDate {
            if showsPlannedTime {
                return Calendar.current.startOfDay(for: date) == date ? nil : date.formatted(date: .omitted, time: .shortened)
            }
            return "Planned \(date.formatted(date: .abbreviated, time: .omitted))"
        }
        if ContentStage(item) == .posted, let date = item.destinations.compactMap(\.publishedDate).max() {
            return "Published \(date.formatted(date: .abbreviated, time: .omitted))"
        }
        return nil
    }

    private var status: String {
        let stage = ContentStage(item)
        if stage == .posted { return stage.rawValue }
        let schedules = item.destinations.filter { $0.status == .scheduled }.compactMap(\.schedule)
        let apiStates = schedules.filter { $0.mode == .api }.map(\.state)
        if apiStates.contains(.outcomeUnknown) { return "Needs Review" }
        if apiStates.contains(.failed) { return "Delivery Failed" }
        if apiStates.contains(.overdue) { return "Overdue" }
        if apiStates.contains(.canceled) { return "Schedule Canceled" }
        let automatic = apiStates.filter { $0 == .queued || $0 == .sending }.count
        let manual = item.destinations.filter { $0.status == .manuallyScheduled }.count
            + schedules.filter { $0.mode == .manual }.count
        if automatic > 0, manual > 0 { return "\(automatic) automatic · \(manual) manual" }
        if automatic > 0 { return "\(automatic) automatically scheduled" }
        if manual > 0 { return "\(manual) manually scheduled" }
        return stage.rawValue
    }

    var body: some View {
        let layout = compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                             : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
        layout {
            VStack(alignment: .leading, spacing: 4) {
                Label(item.title.isEmpty ? "Untitled Content" : item.title, systemImage: kindIcon)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(compact ? 2 : 1)
                let names = item.associationNames(in: snapshot)
                if !names.isEmpty {
                    Text(names.joined(separator: ", ")).lineLimit(1)
                }
                if let relatedTitle {
                    Label(relatedTitle, systemImage: "link").lineLimit(1)
                } else if let groupID = item.relatedGroupId {
                    let linkedCount = snapshot.content.lazy.filter { $0.id != item.id && $0.relatedGroupId == groupID }.count
                    if linkedCount > 0 {
                        Label(linkedCount == 1 ? "1 related item" : "\(linkedCount) related items", systemImage: "link")
                    }
                }
                if compact, let excerpt = item.excerpt, !excerpt.isEmpty {
                    Text(excerpt).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: compact ? .leading : .trailing, spacing: 4) {
                HStack(spacing: 5) {
                    ForEach(accounts.prefix(4)) { account in
                        SocialPlatformIcon(platform: account.platform, size: 14)
                            .accessibilityLabel(account.contentFilterTitle)
                            .help(account.contentFilterTitle)
                    }
                    if accounts.count > 4 { Text("+\(accounts.count - 4)") }
                    if !item.destinations.isEmpty {
                        Text("\(item.publishedDestinationCount) of \(item.destinations.count) posted")
                    }
                }
                Text(status)
                if let dateLabel { Text(dateLabel) }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    private var kindIcon: String {
        switch item.kind {
        case .social: "megaphone"
        case .blog: "doc.text"
        case .idea: "lightbulb"
        }
    }
}

private extension ContentRecord {
    var publishedDestinationCount: Int {
        destinations.filter { $0.status == .published }.count
    }

    var publishingProgress: Double {
        guard !destinations.isEmpty else { return status == .published ? 1 : 0 }
        return Double(publishedDestinationCount) / Double(destinations.count)
    }

    func associationNames(in snapshot: WorkspaceSnapshot) -> [String] {
        var names = snapshot.apps.filter { appIds.contains($0.id) }.map(\.name)
        if let website = snapshot.websites.first(where: { $0.id == websiteId }) { names.append(website.name) }
        if names.isEmpty {
            let destinationIDs = Set(destinations.map(\.accountId))
            let owners = snapshot.socialAccounts.filter { destinationIDs.contains($0.id) }.compactMap(\.owner)
            names += snapshot.apps.filter { app in owners.contains { $0.type == .app && $0.id == app.id } }.map(\.name)
            names += snapshot.identities.filter { identity in owners.contains { $0.type == .identity && $0.id == identity.id } }.map(\.name)
        }
        return names
    }
}

private extension SocialAccountRecord {
    var contentFilterTitle: String {
        if let name = handle ?? displayName { return "\(platform) · \(name)" }
        return platform
    }
}
