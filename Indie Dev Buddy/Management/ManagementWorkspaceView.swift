import SwiftUI
import AppKit
import UniformTypeIdentifiers
import SocialKit

enum ManagementRecordType: Equatable {
    case app, identity, website, socialAccount

    var section: ManagementSection {
        switch self {
        case .app: .apps
        case .identity: .identities
        case .website: .websites
        case .socialAccount: .socialAccounts
        }
    }
}

struct ManagementRecordSelection: Equatable {
    let type: ManagementRecordType
    let id: String
    var opensAppStore = false
}

enum ManagementCreateRequest: Equatable {
    case app, identity, website, socialAccount

    var section: ManagementSection {
        switch self {
        case .app: .apps
        case .identity: .identities
        case .website: .websites
        case .socialAccount: .socialAccounts
        }
    }
}

enum ManagementSection: String {
    case apps = "Apps"
    case identities = "Identities"
    case websites = "Websites"
    case socialAccounts = "Social Accounts"
}

/// Reusable management surface for local workspace records. The host owns refresh/reload;
/// this view writes records explicitly when the user presses Save.
struct ManagementWorkspaceView: View {
    @Environment(SocialPublishingRuntime.self) private var socialRuntime
    let section: ManagementSection
    let snapshot: WorkspaceSnapshot
    let snapshotGeneration: Int
    let store: WorkspaceStore
    let onSnapshotChanged: () -> Void
    let onReloadSnapshot: () async -> Void
    let onUnsavedEditsChanged: (Bool) -> Void
    let onOpenMarketingContent: (String) -> Void
    var onOpenRecord: (ManagementRecordSelection) -> Void = { _ in }
    var selectionRequest: ManagementRecordSelection? = nil
    var createRequest: ManagementCreateRequest? = nil
    var onExternalRequestHandled: () -> Void = {}
    var restoredAppID: String?
    var onAppSelectionChange: (String?) -> Void = { _ in }

    @AppStorage private var pinnedSocialAccountData: Data
    @State private var selectedID: String?
    @State private var opensAppStore = false
    @State private var reconnectAccountID: String?
    @State private var savedAccountIDs: Set<SocialAccount.ID>?
    @State private var availableWidth: CGFloat = 650
    @State private var ownerFilterID = "all"
    @State private var accountConnectionFilter = "all"
    @State private var creating = false
    @State private var editorIsDirty = false
    @State private var pendingNavigation: PendingManagementNavigation?
    @State private var saveError: String?
    @State private var saveConflict: (path: String, currentRevision: String?)?
    @State private var savedMessage: String?
    @State private var loadedRevision: String?
    @State private var revisionMismatch = false
    @State private var editorGeneration = 0
    @State private var confirmingDelete = false
    @State private var showingShowcase = false
    @State private var showingFacebookBulk = false

    init(section: ManagementSection, snapshot: WorkspaceSnapshot, snapshotGeneration: Int, store: WorkspaceStore, onSnapshotChanged: @escaping () -> Void, onReloadSnapshot: @escaping () async -> Void = {}, onUnsavedEditsChanged: @escaping (Bool) -> Void = { _ in }, onOpenMarketingContent: @escaping (String) -> Void, onOpenRecord: @escaping (ManagementRecordSelection) -> Void = { _ in }, selectionRequest: ManagementRecordSelection? = nil, createRequest: ManagementCreateRequest? = nil, onExternalRequestHandled: @escaping () -> Void = {}, restoredAppID: String? = nil, onAppSelectionChange: @escaping (String?) -> Void = { _ in }) {
        _pinnedSocialAccountData = AppStorage(wrappedValue: Data(), "pinnedSocialAccounts.\(snapshot.manifest.id)")
        self.section = section
        self.snapshot = snapshot
        self.snapshotGeneration = snapshotGeneration
        self.store = store
        self.onSnapshotChanged = onSnapshotChanged
        self.onReloadSnapshot = onReloadSnapshot
        self.onUnsavedEditsChanged = onUnsavedEditsChanged
        self.onOpenMarketingContent = onOpenMarketingContent
        self.onOpenRecord = onOpenRecord
        self.selectionRequest = selectionRequest
        self.createRequest = createRequest
        self.onExternalRequestHandled = onExternalRequestHandled
        self.restoredAppID = restoredAppID
        self.onAppSelectionChange = onAppSelectionChange
    }

    var body: some View {
        Group {
            if section == .apps {
                if selectedID != nil || creating {
                    detailContent
                        .toolbar {
                            ToolbarItem(placement: .navigation) {
                                Button("All Apps", systemImage: "chevron.left") {
                                    requestNavigation(.selection(nil))
                                }
                            }
                        }
                } else {
                    appList.navigationTitle("Apps")
                }
            } else if section == .socialAccounts && availableWidth < 580 {
                if selectedID != nil || creating {
                    detailContent
                        .toolbar {
                            ToolbarItem(placement: .navigation) {
                                Button("All Social Accounts", systemImage: "chevron.left") {
                                    requestNavigation(.selection(nil))
                                }
                            }
                        }
                } else {
                    recordList.navigationTitle(section.rawValue)
                }
            } else {
                HSplitView {
                    if section == .socialAccounts {
                        recordList.frame(minWidth: 220, idealWidth: 280, maxWidth: 330)
                    } else {
                        recordList.frame(width: 360)
                    }
                    detailContent
                        .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .navigationTitle(section.rawValue)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
        .task(id: snapshotGeneration) {
            guard section == .socialAccounts else { return }
            if let accounts = try? await socialRuntime.connections.accounts(), !Task.isCancelled {
                savedAccountIDs = Set(accounts.map(\.id))
            }
        }
        .toolbar {
            if section == .apps && selectedID == nil && !creating {
                ToolbarItem {
                    Button("Share Showcase", systemImage: "square.and.arrow.up") {
                        showingShowcase = true
                    }
                    .labelStyle(.titleAndIcon)
                    .help("Create a shareable image of your apps")
                    .disabled(snapshot.apps.isEmpty)
                }
            }
            if section == .socialAccounts {
                ToolbarItem {
                    Button("Connect Facebook & Instagram Accounts…", systemImage: "person.2.badge.plus") {
                        showingFacebookBulk = true
                    }
                    .disabled(editorIsDirty || creating)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Add \(singularName)", systemImage: "plus", action: beginCreate)
                    .labelStyle(.iconOnly)
                    .help("Add \(singularName)")
            }
            if selectedID != nil && !creating {
                ToolbarItem {
                    Menu("Record Actions", systemImage: "ellipsis.circle") {
                        Button("Delete \(singularName)…", role: .destructive) { confirmingDelete = true }
                    }
                    .labelStyle(.iconOnly)
                }
            }
        }
        .sheet(isPresented: $showingFacebookBulk) {
            let current = selectedID.flatMap { snapshot.socialAccountsByID[$0] }
            let identities = ([current].compactMap { $0 } + snapshot.socialAccounts).compactMap(\.providerIdentity)
            let source = identities.first {
                $0.platform == SocialPlatform.facebookPages.rawValue ||
                    ($0.platform == SocialPlatform.instagram.rawValue && $0.server.host == "graph.facebook.com")
            }
            let context = FacebookBulkConnectionContext(
                source: source, store: store, records: snapshot.socialAccounts, owners: ownerChoices,
                defaultOwner: ownerChoices.first { $0.owner == current?.owner }?.id, onChanged: onSnapshotChanged
            )
            SocialOAuthConnectionSheet(platform: .facebookPages, facebookBulk: context, onConnected: { _ in })
        }
        .sheet(isPresented: $showingShowcase) {
            let apps = sortedApps
            let icons = apps.reduce(into: [String: NSImage]()) { result, app in
                result[app.id] = appIcon(for: app)
            }
            AppShowcaseSheet(apps: apps, icons: icons, identities: snapshot.identities)
        }
        .confirmationDialog("Delete this \(singularName.lowercased())?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { deleteSelectedRecord() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("\(selectedRecordName) and its workspace folder will be permanently deleted. This discards any unsaved edits.")
        }
        .alert("Couldn’t Save", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: { Text(saveError ?? "") }
        .alert("Workspace File Changed", isPresented: Binding(get: { saveConflict != nil }, set: { if !$0 { saveConflict = nil } })) {
            if saveConflict?.currentRevision != nil {
                Button("Keep My Changes") { keepLocalAfterConflict() }
            }
            Button("Reload Workspace Copy", role: .destructive) { Task { await reloadAfterConflict() } }
            Button("Continue Editing", role: .cancel) { saveConflict = nil }
        } message: {
            Text("\(saveConflict?.path ?? "This record") changed outside Indie Dev Buddy. Keep My Changes lets your next save explicitly replace that version. Reload Workspace Copy discards the local draft.")
        }
        .alert("Saved", isPresented: Binding(get: { savedMessage != nil }, set: { if !$0 { savedMessage = nil } })) {
            Button("OK", role: .cancel) { savedMessage = nil }
        } message: { Text(savedMessage ?? "") }
        .confirmationDialog("Discard unsaved changes?", isPresented: Binding(get: { pendingNavigation != nil }, set: { if !$0 { pendingNavigation = nil } }), titleVisibility: .visible) {
            Button("Discard Changes", role: .destructive) { applyPendingNavigation() }
            Button("Keep Editing", role: .cancel) { pendingNavigation = nil }
        } message: { Text("Your changes haven’t been saved. Discard them and continue?") }
        .onChange(of: selectionRequest) { _, request in
            guard let request else { return }
            selectExternally(request)
            onExternalRequestHandled()
        }
        .onChange(of: createRequest) { _, request in
            guard let request else { return }
            createExternally(request)
            onExternalRequestHandled()
        }
        .onAppear {
            if let selectionRequest { selectExternally(selectionRequest); onExternalRequestHandled() }
            if let createRequest {
                createExternally(createRequest)
                onExternalRequestHandled()
            } else if selectionRequest == nil, section == .apps, selectedID == nil,
                      let restoredAppID, snapshot.apps.contains(where: { $0.id == restoredAppID }) {
                selectedID = restoredAppID
            }
        }
        .onChange(of: selectedID) { _, id in
            if section == .apps { onAppSelectionChange(id) }
        }
        .task(id: selectedID) { await loadSelectedRevision() }
    }

    private var sortedApps: [AppRecord] {
        snapshot.apps.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    private func appIcon(for app: AppRecord) -> NSImage? {
        guard let recordPath = snapshot.recordPaths["Apps"]?[app.id],
              let url = Self.safeAppIconURL(root: store.rootURL,
                                            appFolderRelativePath: (recordPath as NSString).deletingLastPathComponent,
                                            iconPath: app.iconPath) else { return nil }
        return NSImage(contentsOf: url)
    }

    private func appListIconRequest(for app: AppRecord) -> WorkspaceThumbnailRequest? {
        guard let recordPath = snapshot.recordPaths["Apps"]?[app.id],
              let iconPath = app.iconPath, !iconPath.hasPrefix("asset:") else { return nil }
        return WorkspaceThumbnailRequest(
            root: store.rootURL,
            folder: (recordPath as NSString).deletingLastPathComponent,
            paths: [iconPath],
            generation: snapshotGeneration,
            maxPixelSize: 128
        )
    }

    @ViewBuilder private var appList: some View {
        if snapshot.apps.isEmpty {
            ContentUnavailableView {
                Label("No Apps", systemImage: "square.grid.2x2")
            } description: {
                Text("Add an app to manage it in this workspace.")
            } actions: {
                Button("Add App", action: beginCreate)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: Binding(get: { selectedID }, set: requestSelection)) {
                Section {
                    ForEach(sortedApps) { app in
                        AppLibraryRow(app: app, iconRequest: appListIconRequest(for: app))
                            .tag(Optional(app.id))
                            .contextMenu {
                                Button("Open App Details", systemImage: "arrow.right") {
                                    requestSelection(app.id)
                                }
                            }
                    }
                } header: {
                    Text(snapshot.apps.count == 1 ? "1 app" : "\(snapshot.apps.count) apps")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                }
            }
            .listStyle(.inset)
        }
    }

    private var recordList: some View {
        let pinnedIDs = section == .socialAccounts ? pinnedSocialAccountIDs : []
        let visibleRows = rows
        let orderedRows = visibleRows.filter { pinnedIDs.contains($0.id) }
            + visibleRows.filter { !pinnedIDs.contains($0.id) }

        return VStack(spacing: 0) {
            if section == .websites || section == .socialAccounts {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { recordFilters }
                    VStack(alignment: .leading, spacing: 8) { recordFilters }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.vertical, 8)
            }

            List(selection: Binding(get: { selectedID }, set: requestSelection)) {
                ForEach(orderedRows) { row in
                    let isPinned = pinnedIDs.contains(row.id)
                    HStack(spacing: 10) {
                        Group {
                            if section == .identities {
                                IdentityRowPhoto(request: row.photoRequest, symbol: row.symbol)
                            } else if let platform = row.socialPlatform {
                                SocialPlatformIcon(platform: platform, size: 24)
                            } else {
                                Image(systemName: row.symbol).font(.title3).foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: section == .identities ? 30 : 24, height: 30)
                        .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.title).font(.headline)
                            if !row.subtitle.isEmpty {
                                Text(row.subtitle).font(.subheadline).foregroundStyle(.secondary)
                            }
                            if section == .socialAccounts, let account = snapshot.socialAccountsByID[row.id] {
                                accountHealth(account)
                            }
                        }
                        Spacer(minLength: 8)
                        if isPinned {
                            Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary)
                                .accessibilityLabel("Pinned")
                        }
                    }
                    .padding(.vertical, 6)
                    .tag(Optional(row.id))
                    .contextMenu { managementRowActions(row, isPinned: isPinned) }
                }
            }
            .overlay {
                if orderedRows.isEmpty {
                    ContentUnavailableView("No \(section.rawValue)", systemImage: sectionSymbol, description: Text("Add a record to manage it in this workspace."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

        }
    }

    @ViewBuilder
    private var recordFilters: some View {
        Picker("Filter by owner", selection: Binding(get: { ownerFilterID }, set: requestOwnerFilter)) {
            Text("All owners").tag("all")
            ForEach(ownerChoices) { owner in
                Text("\(owner.title) · \(owner.detail)").tag(owner.id)
            }
            Text("Unassigned / missing").tag("unassigned")
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .accessibilityLabel("Filter by owner")
        if section == .socialAccounts {
            Picker("Filter by API connection", selection: $accountConnectionFilter) {
                Text("All connections").tag("all")
                Text("API linked").tag("linked")
                Text("Manual only").tag("manual")
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .accessibilityLabel("Filter by API connection")
            .fixedSize()
        }
    }

    private func accountHealth(_ account: SocialAccountRecord) -> some View {
        let status: (title: String, symbol: String)
        if !account.enabled {
            status = ("Disabled", "pause.circle")
        } else if let identity = account.providerIdentity {
            let saved = SocialPlatform(rawValue: identity.platform).flatMap { platform in
                savedAccountIDs?.contains(.init(platform: platform, server: identity.server, remoteID: identity.remoteID))
            }
            switch socialRuntime.recovery(for: identity) ?? (saved == false ? .missingCredential : nil) {
            case .ready, .renewed:
                status = SocialEngagementStore.manualOnly(identity)
                    ? ("Saved · Manual refresh", "link")
                    : ("Connection available", "checkmark.circle")
            case .missingCredential, .authorizationRequired, .permissionsRequired, .configurationRequired:
                status = ("Authorization needed", "exclamationmark.circle")
            case .keychainUnavailable, .retryLater, .rateLimited:
                status = ("Check connection", "exclamationmark.circle")
            case nil:
                status = ("API linked", "link")
            }
        } else {
            status = ("Manual posting", "hand.tap")
        }
        return Label(status.title, systemImage: status.symbol)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var pinnedSocialAccountIDs: Set<String> {
        (try? JSONDecoder().decode(Set<String>.self, from: pinnedSocialAccountData)) ?? []
    }

    private func toggleSocialAccountPin(_ id: String) {
        var pinnedIDs = pinnedSocialAccountIDs
        if !pinnedIDs.insert(id).inserted {
            pinnedIDs.remove(id)
        }
        if let data = try? JSONEncoder().encode(pinnedIDs) {
            pinnedSocialAccountData = data
        }
    }

    @ViewBuilder
    private func managementRowActions(_ row: ManagementRow, isPinned: Bool) -> some View {
        Button("Edit \(singularName)", systemImage: "arrow.right") {
            requestSelection(row.id)
        }
        if section == .socialAccounts, let account = snapshot.socialAccountsByID[row.id] {
            Button(isPinned ? "Unpin" : "Pin to Top", systemImage: isPinned ? "pin.slash" : "pin") {
                toggleSocialAccountPin(row.id)
            }
            if let handle = account.handle, !handle.isEmpty {
                Button("Copy Handle", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(handle, forType: .string)
                }
            }
            if let profileURL = account.profileURL, let url = optionalWebURL(profileURL.absoluteString) {
                Link("Open Profile", destination: url)
            }
            if SocialPlatform.workspacePlatform(account.platform) != nil {
                Divider()
                Button(account.providerIdentity == nil ? "Connect…" : "Manage Connection…", systemImage: "link") {
                    requestNavigation(.connectAccount(row.id))
                }
            }
        }
    }

    private var singularName: String {
        switch section {
        case .apps: "App"
        case .identities: "Identity"
        case .websites: "Website"
        case .socialAccounts: "Social Account"
        }
    }

    private var sectionSymbol: String {
        switch section {
        case .apps: "square.grid.2x2"
        case .identities: "person.crop.circle"
        case .websites: "globe"
        case .socialAccounts: "at"
        }
    }

    private var selectedRecordName: String {
        guard let selectedID else { return "This record" }
        switch section {
        case .apps: return snapshot.apps.first(where: { $0.id == selectedID })?.name ?? "This record"
        case .identities: return snapshot.identities.first(where: { $0.id == selectedID })?.name ?? "This record"
        case .websites: return snapshot.websites.first(where: { $0.id == selectedID })?.name ?? "This record"
        case .socialAccounts: return snapshot.socialAccounts.first(where: { $0.id == selectedID })?.platform ?? "This record"
        }
    }

    private func deleteSelectedRecord() {
        guard let selectedID,
              let recordPath = Self.findRecordPath(root: store.rootURL, category: currentStorageCategory, id: selectedID) else {
            saveError = "This record’s workspace file could not be found. Refresh and try again."
            return
        }
        let folderPath = String(recordPath.dropLast("/record.json".count))
        Task {
            do {
                try await store.deleteItem(relativePath: folderPath)
                self.selectedID = nil
                creating = false
                setDirty(false)
                onSnapshotChanged()
            } catch { saveError = "Could not delete this record: \(error.localizedDescription)" }
        }
    }

    private var rows: [ManagementRow] {
        switch section {
        case .apps: []
        case .identities:
            snapshot.identities.map { identity in
                ManagementRow(id: identity.id, title: identity.name, subtitle: identity.kind ?? "", symbol: "person.crop.circle", photoRequest: .identityPhoto(root: store.rootURL, path: identity.photoPath, generation: snapshotGeneration))
            }
        case .websites:
            snapshot.websites.filter { matchesOwnerFilter($0.owner) }.map { record in
                ManagementRow(id: record.id, title: record.name, subtitle: "\(ownerName(record.owner)) · \(record.baseURL.host ?? record.baseURL.absoluteString)", symbol: "globe")
            }
        case .socialAccounts:
            snapshot.socialAccounts.filter {
                matchesOwnerFilter($0.owner) && (accountConnectionFilter == "all" ||
                    (accountConnectionFilter == "linked") == ($0.providerIdentity != nil))
            }.map { record in
                let handle = record.handle?.trimmingCharacters(in: .whitespacesAndNewlines)
                let accountName = (record.displayName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? record.displayName : nil)
                    ?? ((handle?.isEmpty == false ? handle : nil) ?? record.profileURL?.host)
                let account = SocialPlatformIcon.assetName(for: record.platform) != nil
                    ? (accountName ?? "Unconfigured account")
                    : [record.platform, accountName].compactMap { $0 }.joined(separator: " · ")
                let handleLabel = handle.flatMap { $0.isEmpty ? nil : ($0.hasPrefix("@") ? $0 : "@\($0)") }
                let provider = SocialPlatform.workspacePlatform(record.platform)?.workspaceTitle ?? record.platform
                let detail = [provider, handleLabel, record.owner.map(ownerName)].compactMap { $0 }.joined(separator: " · ")
                return ManagementRow(id: record.id, title: account.isEmpty ? "Unconfigured account" : account, subtitle: detail.isEmpty ? "Owner not set" : detail, symbol: "at", socialPlatform: record.platform)
            }
        }
    }

    @ViewBuilder private var detailContent: some View {
        if creating {
            switch section {
            case .apps: editor(for: Optional<AppRecord>.none)
            case .identities: editor(for: Optional<IdentityRecord>.none)
            case .websites: editor(for: Optional<WebsiteRecord>.none)
            case .socialAccounts: editor(for: Optional<SocialAccountRecord>.none)
            }
        } else if let selectedID {
            switch section {
            case .apps:
                if let value = snapshot.apps.first(where: { $0.id == selectedID }) { editor(for: value) }
            case .identities:
                if let value = snapshot.identities.first(where: { $0.id == selectedID }) { editor(for: value) }
            case .websites:
                if let value = snapshot.websites.first(where: { $0.id == selectedID }) { editor(for: value) }
            case .socialAccounts:
                if let value = snapshot.socialAccounts.first(where: { $0.id == selectedID }) { editor(for: value) }
            }
        } else {
            ContentUnavailableView("Select a \(singularName)", systemImage: sectionSymbol, description: Text("Choose a record from the list or add a new one."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private func editor(for record: AppRecord?) -> some View {
        AppRecordEditor(record: record, opensAppStore: opensAppStore, identities: snapshot.identities, websites: snapshot.websites, snapshot: snapshot, workspaceStore: store, onOpenMarketingContent: onOpenMarketingContent, onSnapshotChanged: onSnapshotChanged, onDirtyChange: setDirty, onSave: { await save($0, category: "Apps", name: $0.name, expectedRevision: loadedRevision) }).id("\(record?.id ?? "new-app")-\(editorGeneration)")
    }
    private func scopedAssetsButton(_ owner: AssetOwner) -> some View {
        ScopedAssetLibraryButton(store: store, snapshot: snapshot, owner: owner)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.horizontal)
    }

    @ViewBuilder private func editor(for record: IdentityRecord?) -> some View {
        VStack(spacing: 0) {
            if let record { scopedAssetsButton(AssetOwner(.identity, record.id)) }
            IdentityRecordEditor(record: record, workspaceStore: store, snapshotGeneration: snapshotGeneration, onDirtyChange: setDirty, onSave: { await save($0, category: "Identities", name: $0.name, expectedRevision: loadedRevision) }).id("\(record?.id ?? "new-identity")-\(editorGeneration)")
            if let record {
                relatedRecords(owner: RecordOwner(type: .identity, id: record.id))
            }
        }
    }
    @ViewBuilder private func editor(for record: WebsiteRecord?) -> some View {
        VStack(spacing: 0) {
            if let record { scopedAssetsButton(AssetOwner(.website, record.id)) }
            WebsiteRecordEditor(record: record, owners: ownerChoices, onDirtyChange: setDirty, onSave: { await save($0, category: "Websites", name: $0.name, expectedRevision: loadedRevision) }).id("\(record?.id ?? "new-website")-\(editorGeneration)")
            if let record {
                relatedRecords(owner: record.owner, excludingWebsiteID: record.id)
            }
        }
    }
    @ViewBuilder private func editor(for record: SocialAccountRecord?) -> some View {
        VStack(spacing: 0) {
            SocialAccountRecordEditor(record: record, owners: ownerChoices, identities: snapshot.identities, workspaceStore: store, onDirtyChange: setDirty, onSave: { await save($0, category: "SocialAccounts", name: $0.platform, expectedRevision: loadedRevision) }, connectionRequest: $reconnectAccountID).id("\(record?.id ?? "new-social-account")-\(editorGeneration)")
            if let owner = record?.owner {
                relatedRecords(owner: owner, excludingAccountID: record?.id)
            }
        }
    }

    @ViewBuilder private func relatedRecords(
        owner: RecordOwner,
        excludingWebsiteID: String? = nil,
        excludingAccountID: String? = nil
    ) -> some View {
        let apps = snapshot.apps.filter { app in
            if let excludingWebsiteID {
                return app.websiteLinks.contains { $0.websiteId == excludingWebsiteID }
            }
            return owner.type == .app ? app.id == owner.id : app.developerIdentityId == owner.id
        }
        let websites = snapshot.websites.filter { $0.owner == owner && $0.id != excludingWebsiteID }
        let accounts = snapshot.socialAccounts.filter { $0.owner == owner && $0.id != excludingAccountID }
        if !apps.isEmpty || !websites.isEmpty || !accounts.isEmpty {
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Related Records").font(.headline)
                    if !apps.isEmpty {
                        LabeledContent("Apps", value: apps.map(\.name).joined(separator: ", "))
                    }
                    ForEach(websites) { website in
                        Button(website.name, systemImage: "globe") {
                            onOpenRecord(ManagementRecordSelection(type: .website, id: website.id))
                        }.buttonStyle(.link)
                    }
                    ForEach(accounts) { account in
                        Button {
                            onOpenRecord(ManagementRecordSelection(type: .socialAccount, id: account.id))
                        } label: {
                            HStack(spacing: 6) {
                                SocialPlatformIcon(platform: account.platform, size: 16)
                                Text([account.platform, account.handle].compactMap { $0 }.joined(separator: " · "))
                            }
                        }
                        .buttonStyle(.link)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            .frame(maxHeight: 120)
        }
    }

    private var ownerChoices: [OwnerChoice] {
        snapshot.identities.map { OwnerChoice(owner: RecordOwner(type: .identity, id: $0.id), title: $0.name, detail: "Identity") }
        + snapshot.apps.map { OwnerChoice(owner: RecordOwner(type: .app, id: $0.id), title: $0.name, detail: "App") }
    }

    private func ownerName(_ owner: RecordOwner) -> String {
        switch owner.type {
        case .identity: snapshot.identities.first(where: { $0.id == owner.id })?.name ?? "Missing identity"
        case .app: snapshot.apps.first(where: { $0.id == owner.id })?.name ?? "Missing app"
        }
    }

    private func beginCreate() { requestNavigation(.create) }

    private func selectExternally(_ request: ManagementRecordSelection) {
        guard request.type.section == section else { return }
        requestNavigation(.record(request.id, opensAppStore: request.opensAppStore))
    }

    private func createExternally(_ request: ManagementCreateRequest) {
        guard request.section == section else { return }
        beginCreate()
    }

    private func requestSelection(_ value: String?) {
        guard value != selectedID else { return }
        requestNavigation(.selection(value))
    }

    private func requestOwnerFilter(_ value: String) {
        guard value != ownerFilterID else { return }
        requestNavigation(.ownerFilter(value))
    }

    private func requestNavigation(_ value: PendingManagementNavigation) {
        if editorIsDirty { pendingNavigation = value }
        else { applyNavigation(value) }
    }

    private func applyPendingNavigation() {
        guard let value = pendingNavigation else { return }
        pendingNavigation = nil
        applyNavigation(value)
    }

    private func applyNavigation(_ value: PendingManagementNavigation) {
        opensAppStore = false
        switch value {
        case .selection(let next): selectedID = next; creating = false
        case .record(let id, let showAppStore):
            opensAppStore = showAppStore
            selectedID = id
            creating = false
            if section == .websites || section == .socialAccounts { ownerFilterID = "all" }
        case .connectAccount(let id):
            if selectedID == id && editorIsDirty { editorGeneration += 1 }
            selectedID = id
            creating = false
            reconnectAccountID = id
        case .create: selectedID = nil; creating = true
        case .ownerFilter(let value): ownerFilterID = value; selectedID = nil; creating = false
        }
        setDirty(false)
    }

    private func matchesOwnerFilter(_ owner: RecordOwner?) -> Bool {
        switch ownerFilterID {
        case "all": return true
        case "unassigned":
            guard let owner else { return true }
            return !ownerChoices.contains { $0.owner == owner }
        default:
            guard let owner else { return false }
            return "\(owner.type.rawValue):\(owner.id)" == ownerFilterID
        }
    }

    private func setDirty(_ value: Bool) {
        guard editorIsDirty != value else { return }
        editorIsDirty = value
        onUnsavedEditsChanged(value)
    }

    private func save<Record: Codable & Sendable & Identifiable>(_ record: Record, category: String, name: String, expectedRevision: String?) async -> Bool {
        do {
            let recordID = String(describing: record.id)
            let existingPath = Self.findRecordPath(root: store.rootURL, category: category, id: recordID)
            let existsInSnapshot = snapshotContains(id: recordID, category: category)
            if existsInSnapshot {
                guard let existingPath else {
                    saveError = "This record’s file is missing or was moved while it was open. Refresh the workspace before saving."
                    return false
                }
                guard let expectedRevision else {
                    saveError = revisionMismatch ? "This record changed on disk after the workspace was loaded. Refresh it before saving." : "This record’s file revision was not verified against the loaded record. Refresh before saving."
                    return false
                }
                try await store.save(record, relativePath: existingPath, expectedRevision: expectedRevision)
                loadedRevision = try? await store.read(relativePath: existingPath).revision
            } else {
                guard existingPath == nil else {
                    saveError = "A record with this ID already exists on disk. Refresh the workspace before saving."
                    return false
                }
                let folder = Self.slug(name) + "-" + String(recordID.prefix(8))
                let path = "\(category)/\(folder)/record.json"
                try await store.save(record, relativePath: path, expectedRevision: nil)
                loadedRevision = try? await store.read(relativePath: path).revision
            }
            creating = false
            selectedID = recordID
            setDirty(false)
            savedMessage = "Saved \(name.isEmpty ? singularName.lowercased() : name)."
            onSnapshotChanged()
            return true
        } catch {
            if case WorkspaceStoreError.conflict(let path, let currentRevision) = error {
                saveConflict = (path, currentRevision)
            } else {
                saveError = error.localizedDescription
            }
            return false
        }
    }

    private func keepLocalAfterConflict() {
        guard let conflict = saveConflict, let currentRevision = conflict.currentRevision else { return }
        loadedRevision = currentRevision
        revisionMismatch = false
        saveConflict = nil
    }

    @MainActor
    private func reloadAfterConflict() async {
        saveConflict = nil
        await onReloadSnapshot()
        editorGeneration += 1
        await loadSelectedRevision()
        setDirty(false)
    }

    private func loadSelectedRevision() async {
        let revisionFromSuccessfulSave = loadedRevision
        let wasInSnapshot = selectedID.map { snapshotContains(id: $0, category: currentStorageCategory) } ?? false
        loadedRevision = nil
        revisionMismatch = false
        guard !creating, let selectedID else { return }
        let category = currentStorageCategory
        guard let path = Self.findRecordPath(root: store.rootURL, category: category, id: selectedID) else { revisionMismatch = snapshotContains(id: selectedID, category: category); return }
        do {
            let file = try await store.read(relativePath: path)
            if !wasInSnapshot, let revisionFromSuccessfulSave {
                guard file.revision == revisionFromSuccessfulSave else {
                    revisionMismatch = true
                    saveConflict = (path, file.revision)
                    return
                }
                loadedRevision = file.revision
                return
            }
            guard snapshotMatches(id: selectedID, category: category, data: file.data) else {
                revisionMismatch = true
                saveConflict = (path, file.revision)
                return
            }
            loadedRevision = file.revision
        }
        catch { saveError = error.localizedDescription }
    }

    private var currentStorageCategory: String {
        switch section {
        case .apps: "Apps"
        case .identities: "Identities"
        case .websites: "Websites"
        case .socialAccounts: "SocialAccounts"
        }
    }

    private func snapshotContains(id: String, category: String) -> Bool {
        switch category {
        case "Apps": snapshot.apps.contains { $0.id == id }
        case "Identities": snapshot.identities.contains { $0.id == id }
        case "Websites": snapshot.websites.contains { $0.id == id }
        case "SocialAccounts": snapshot.socialAccounts.contains { $0.id == id }
        default: false
        }
    }

    private func snapshotMatches(id: String, category: String, data: Data) -> Bool {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            switch category {
            case "Apps":
                let current = try decoder.decode(AppRecord.self, from: data)
                return snapshot.apps.first(where: { $0.id == id }) == current
            case "Identities":
                let current = try decoder.decode(IdentityRecord.self, from: data)
                return snapshot.identities.first(where: { $0.id == id }) == current
            case "Websites":
                let current = try decoder.decode(WebsiteRecord.self, from: data)
                return snapshot.websites.first(where: { $0.id == id }) == current
            case "SocialAccounts":
                let current = try decoder.decode(SocialAccountRecord.self, from: data)
                return snapshot.socialAccounts.first(where: { $0.id == id }) == current
            default: return false
            }
        } catch { return false }
    }

    static func findRecordPath(root: URL, category: String, id: String) -> String? {
        let base = root.appendingPathComponent(category, isDirectory: true)
        guard let folders = try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else { return nil }
        for folder in folders {
            let file = folder.appendingPathComponent("record.json")
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["id"] as? String == id else { continue }
            return "\(category)/\(folder.lastPathComponent)/record.json"
        }
        return nil
    }

    private static func safeAppIconURL(root: URL, appFolderRelativePath: String, iconPath: String?) -> URL? {
        guard let iconPath, !iconPath.isEmpty, !iconPath.hasPrefix("/"),
              !iconPath.split(separator: "/").contains("..") else { return nil }
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let folder = root.appendingPathComponent(appFolderRelativePath, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let resolved = folder.appendingPathComponent(iconPath).standardizedFileURL.resolvingSymlinksInPath()
        let folderPrefix = folder.path.hasSuffix("/") ? folder.path : folder.path + "/"
        let workspacePrefix = resolvedRoot.path.hasSuffix("/") ? resolvedRoot.path : resolvedRoot.path + "/"
        guard folder.path.hasPrefix(workspacePrefix), resolved.path.hasPrefix(folderPrefix),
              FileManager.default.fileExists(atPath: resolved.path) else { return nil }
        return resolved
    }

    static func safeWorkspacePhotoURL(root: URL, photoPath: String?) -> URL? {
        guard let photoPath, !photoPath.isEmpty, !photoPath.hasPrefix("/"),
              !photoPath.split(separator: "/").contains("..") else { return nil }
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let resolved = root.appendingPathComponent(photoPath).standardizedFileURL.resolvingSymlinksInPath()
        let prefix = resolvedRoot.path.hasSuffix("/") ? resolvedRoot.path : resolvedRoot.path + "/"
        guard resolved.path.hasPrefix(prefix), FileManager.default.fileExists(atPath: resolved.path) else { return nil }
        return resolved
    }

    static func slug(_ text: String) -> String {
        let pieces = text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let value = pieces.prefix(8).joined(separator: "-")
        return value.isEmpty ? "record" : value
    }
}

private enum PendingManagementNavigation {
    case selection(String?)
    case record(String, opensAppStore: Bool = false)
    case connectAccount(String)
    case create
    case ownerFilter(String)
}

private struct ManagementRow: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    var photoRequest: WorkspaceThumbnailRequest? = nil
    var socialPlatform: String? = nil
}

struct OwnerChoice: Identifiable, Hashable {
    let owner: RecordOwner
    let title: String
    let detail: String
    var id: String { "\(owner.type.rawValue):\(owner.id)" }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

private struct IdentityRowPhoto: View {
    let request: WorkspaceThumbnailRequest?
    let symbol: String
    @State private var photo: NSImage?

    var body: some View {
        Group {
            if let photo {
                Image(nsImage: photo).resizable().scaledToFill().clipShape(Circle())
            } else {
                Image(systemName: symbol).font(.title3).foregroundStyle(.secondary)
            }
        }
        .frame(width: 30, height: 30)
        .clipped()
        .task(id: request) {
            guard let request else { photo = nil; return }
            let image = await WorkspaceThumbnailCache.shared.load(request)
            guard !Task.isCancelled else { return }
            photo = image.map { NSImage(cgImage: $0, size: .zero) }
        }
    }
}

func optionalWebURL(_ value: String) -> URL? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return URL(string: trimmed)
}
