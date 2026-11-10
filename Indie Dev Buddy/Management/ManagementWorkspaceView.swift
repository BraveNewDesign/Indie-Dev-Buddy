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
}

enum ManagementCreateRequest: Equatable {
    case app, website, socialAccount

    var section: ManagementSection {
        switch self {
        case .app: .apps
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
    let section: ManagementSection
    let snapshot: WorkspaceSnapshot
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

    @State private var selectedID: String?
    @State private var ownerFilterID = "all"
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

    init(section: ManagementSection, snapshot: WorkspaceSnapshot, store: WorkspaceStore, onSnapshotChanged: @escaping () -> Void, onReloadSnapshot: @escaping () async -> Void = {}, onUnsavedEditsChanged: @escaping (Bool) -> Void = { _ in }, onOpenMarketingContent: @escaping (String) -> Void, onOpenRecord: @escaping (ManagementRecordSelection) -> Void = { _ in }, selectionRequest: ManagementRecordSelection? = nil, createRequest: ManagementCreateRequest? = nil, onExternalRequestHandled: @escaping () -> Void = {}, restoredAppID: String? = nil, onAppSelectionChange: @escaping (String?) -> Void = { _ in }) {
        self.section = section
        self.snapshot = snapshot
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
                    recordList.navigationTitle("Apps")
                }
            } else {
                HSplitView {
                    // Keep the record list from collapsing when the selected detail has a larger minimum size.
                    recordList.frame(width: 360)
                    detailContent
                        .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .navigationTitle(section.rawValue)
            }
        }
        .toolbar {
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

    private var recordList: some View {
        VStack(spacing: 0) {
            if section == .apps {
                Text(snapshot.apps.count == 1 ? "1 app" : "\(snapshot.apps.count) apps")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }

            if section == .websites || section == .socialAccounts {
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
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.vertical, 8)
            }

            List(selection: Binding(get: { selectedID }, set: requestSelection)) {
                ForEach(rows) { row in
                    HStack(spacing: 10) {
                        Group {
                            if let iconURL = row.iconURL, let image = NSImage(contentsOf: iconURL) {
                                if section == .identities {
                                    Image(nsImage: image).resizable().scaledToFill().clipShape(Circle())
                                } else {
                                    Image(nsImage: image).resizable().scaledToFit()
                                }
                            } else if let platform = row.socialPlatform {
                                SocialPlatformIcon(platform: platform, size: 24)
                            } else {
                                Image(systemName: row.symbol).font(.title3).foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: section == .apps ? 36 : (section == .identities ? 30 : 24), height: 30)
                        .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.title).font(.headline)
                            if !row.subtitle.isEmpty {
                                Text(row.subtitle).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 8)
                        if section == .apps {
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                    }
                    .padding(.vertical, 6)
                    .tag(Optional(row.id))
                }
            }
            .overlay {
                if rows.isEmpty {
                    ContentUnavailableView("No \(section.rawValue)", systemImage: sectionSymbol, description: Text("Add a record to manage it in this workspace."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        case .apps:
            snapshot.apps.map { app in
                let details = [
                    app.platforms.joined(separator: ", "),
                    (app.developmentStatus ?? .development).label
                ].filter { !$0.isEmpty }
                let recordPath = Self.findRecordPath(root: store.rootURL, category: "Apps", id: app.id)
                let folderPath = recordPath.map { String($0.dropLast("/record.json".count)) }
                let iconURL = folderPath.flatMap { Self.safeAppIconURL(root: store.rootURL, appFolderRelativePath: $0, iconPath: app.iconPath) }
                return ManagementRow(id: app.id, title: app.name, subtitle: details.joined(separator: " · "), symbol: "app.dashed", iconURL: iconURL)
            }
        case .identities:
            snapshot.identities.map { identity in
                ManagementRow(id: identity.id, title: identity.name, subtitle: identity.kind ?? "", symbol: "person.crop.circle", iconURL: Self.safeWorkspacePhotoURL(root: store.rootURL, photoPath: identity.photoPath))
            }
        case .websites:
            snapshot.websites.filter { matchesOwnerFilter($0.owner) }.map { record in
                ManagementRow(id: record.id, title: record.name, subtitle: "\(ownerName(record.owner)) · \(record.baseURL.host ?? record.baseURL.absoluteString)", symbol: "globe")
            }
        case .socialAccounts:
            snapshot.socialAccounts.filter { matchesOwnerFilter($0.owner) }.map { record in
                let handle = record.handle?.trimmingCharacters(in: .whitespacesAndNewlines)
                let accountName = (handle?.isEmpty == false ? handle : nil) ?? record.profileURL?.host
                let account = SocialPlatformIcon.assetName(for: record.platform) != nil
                    ? (accountName ?? "Unconfigured account")
                    : [record.platform, accountName].compactMap { $0 }.joined(separator: " · ")
                return ManagementRow(id: record.id, title: account.isEmpty ? "Unconfigured account" : account, subtitle: record.owner.map(ownerName) ?? "Owner not set", symbol: "at", socialPlatform: record.platform)
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
        AppRecordEditor(record: record, identities: snapshot.identities, websites: snapshot.websites, snapshot: snapshot, workspaceStore: store, onOpenMarketingContent: onOpenMarketingContent, onSnapshotChanged: onSnapshotChanged, onDirtyChange: setDirty, onSave: { await save($0, category: "Apps", name: $0.name, expectedRevision: loadedRevision) }).id("\(record?.id ?? "new-app")-\(editorGeneration)")
    }
    @ViewBuilder private func editor(for record: IdentityRecord?) -> some View {
        VStack(spacing: 0) {
            IdentityRecordEditor(record: record, workspaceStore: store, onDirtyChange: setDirty, onSave: { await save($0, category: "Identities", name: $0.name, expectedRevision: loadedRevision) }).id("\(record?.id ?? "new-identity")-\(editorGeneration)")
            if let record {
                relatedRecords(owner: RecordOwner(type: .identity, id: record.id))
            }
        }
    }
    @ViewBuilder private func editor(for record: WebsiteRecord?) -> some View {
        VStack(spacing: 0) {
            WebsiteRecordEditor(record: record, owners: ownerChoices, onDirtyChange: setDirty, onSave: { await save($0, category: "Websites", name: $0.name, expectedRevision: loadedRevision) }).id("\(record?.id ?? "new-website")-\(editorGeneration)")
            if let record {
                relatedRecords(owner: record.owner, excludingWebsiteID: record.id)
            }
        }
    }
    @ViewBuilder private func editor(for record: SocialAccountRecord?) -> some View {
        VStack(spacing: 0) {
            SocialAccountRecordEditor(record: record, owners: ownerChoices, identities: snapshot.identities, workspaceStore: store, onDirtyChange: setDirty, onSave: { await save($0, category: "SocialAccounts", name: $0.platform, expectedRevision: loadedRevision) }).id("\(record?.id ?? "new-social-account")-\(editorGeneration)")
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
        requestNavigation(.record(request.id))
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
        switch value {
        case .selection(let next): selectedID = next; creating = false
        case .record(let id):
            selectedID = id
            creating = false
            if section == .websites || section == .socialAccounts { ownerFilterID = "all" }
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

    fileprivate static func findRecordPath(root: URL, category: String, id: String) -> String? {
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

    fileprivate static func safeWorkspacePhotoURL(root: URL, photoPath: String?) -> URL? {
        guard let photoPath, !photoPath.isEmpty, !photoPath.hasPrefix("/"),
              !photoPath.split(separator: "/").contains("..") else { return nil }
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let resolved = root.appendingPathComponent(photoPath).standardizedFileURL.resolvingSymlinksInPath()
        let prefix = resolvedRoot.path.hasSuffix("/") ? resolvedRoot.path : resolvedRoot.path + "/"
        guard resolved.path.hasPrefix(prefix), FileManager.default.fileExists(atPath: resolved.path) else { return nil }
        return resolved
    }

    fileprivate static func slug(_ text: String) -> String {
        let pieces = text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let value = pieces.prefix(8).joined(separator: "-")
        return value.isEmpty ? "record" : value
    }
}

private enum PendingManagementNavigation {
    case selection(String?)
    case record(String)
    case create
    case ownerFilter(String)
}

private struct ManagementRow: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    var iconURL: URL? = nil
    var socialPlatform: String? = nil
}

private struct OwnerChoice: Identifiable, Hashable {
    let owner: RecordOwner
    let title: String
    let detail: String
    var id: String { "\(owner.type.rawValue):\(owner.id)" }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

private struct AppRecordEditor: View {
    let record: AppRecord?
    let identities: [IdentityRecord]
    let websites: [WebsiteRecord]
    let snapshot: WorkspaceSnapshot
    let workspaceStore: WorkspaceStore
    let onOpenMarketingContent: (String) -> Void
    let onSnapshotChanged: () -> Void
    let onDirtyChange: (Bool) -> Void
    let onSave: (AppRecord) async -> Bool
    @State private var name = ""
    @State private var appDescription = ""
    @State private var bundleIDs = ""
    @State private var developmentStatus = AppDevelopmentStatus.development.rawValue
    @State private var developerID = ""
    @State private var platforms = ""
    @State private var projectPath = ""
    @State private var projectURL: URL?
    @State private var projectAvailable = false
    @State private var projectMessage: String?
    @State private var draftID = UUID().uuidString.lowercased()
    @State private var repositoryURL = ""
    @State private var appStoreURL = ""
    @State private var testFlightURL = ""
    @State private var iconPath: String?
    @State private var iconPreview: NSImage?
    @State private var pendingIconData: Data?
    @State private var pendingIconRevision: String?
    @State private var pendingIconWrittenPath: String?
    @State private var iconError: String?
    @State private var showingIconPicker = false
    @State private var links: [AppWebsiteLink] = []
    @State private var saving = false
    @State private var detailTab = "Overview"
    @State private var editingOverview = false
    @State private var overviewIsDirty = false
    @State private var fileMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            appHeader
                .padding(.horizontal, 20)
                .padding(.top, 16)

            Picker("App detail", selection: $detailTab) {
                Text("Overview").tag("Overview")
                Text("Marketing").tag("Marketing")
                Text("Files").tag("Files")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 420, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            ZStack(alignment: .topLeading) {
                Group {
                    if record == nil || editingOverview {
                        overviewForm
                    } else {
                        appOverview
                    }
                }
                    .opacity(detailTab == "Overview" ? 1 : 0)
                    .allowsHitTesting(detailTab == "Overview")
                    .accessibilityHidden(detailTab != "Overview")
                if let appID = record?.id {
                    AppMarketingContentPanel(
                        appID: appID, appName: name, snapshot: snapshot, store: workspaceStore,
                        actionsEnabled: !overviewIsDirty,
                        onOpen: onOpenMarketingContent, onCreated: onSnapshotChanged
                    )
                    .opacity(detailTab == "Marketing" ? 1 : 0)
                    .allowsHitTesting(detailTab == "Marketing")
                    .accessibilityHidden(detailTab != "Marketing")
                } else {
                    ContentUnavailableView("Save App First", systemImage: "megaphone", description: Text("Save the app overview before creating related marketing content."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .opacity(detailTab == "Marketing" ? 1 : 0)
                        .allowsHitTesting(detailTab == "Marketing")
                        .accessibilityHidden(detailTab != "Marketing")
                }
                appFilesPanel
                    .opacity(detailTab == "Files" ? 1 : 0)
                    .allowsHitTesting(detailTab == "Files")
                    .accessibilityHidden(detailTab != "Files")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle(record == nil ? "New App" : name)
        .onAppear(perform: load)
        .onChange(of: record) { _, _ in
            if !editingOverview { load() }
        }
        .onChange(of: draftRecord) { _, _ in reportOverviewDirty(isDirty) }
    }

    private var appHeader: some View {
        HStack(spacing: 12) {
            Group {
                if let iconPreview {
                    Image(nsImage: iconPreview).resizable().scaledToFit()
                } else {
                    Image(systemName: "app.dashed").font(.title).foregroundStyle(.secondary)
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(name.isEmpty ? "New App" : name)
                    .font(.title.bold())
                    .accessibilityAddTraits(.isHeader)
                Text([platforms, identities.first(where: { $0.id == developerID })?.name ?? "", AppDevelopmentStatus.allCases.first(where: { $0.rawValue == developmentStatus })?.label ?? ""]
                    .filter { !$0.isEmpty }
                    .joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if record != nil && detailTab == "Overview" && !editingOverview {
                Button("Edit", systemImage: "pencil") { editingOverview = true }
            }
        }
    }

    private var appOverview: some View {
        Form {
            if !appDescription.isEmpty {
                Section("Description") { Text(appDescription).textSelection(.enabled) }
            }
            Section("App Details") {
                LabeledContent("Developer Identity", value: identities.first { $0.id == developerID }?.name ?? "Unassigned")
                LabeledContent("Platforms", value: platforms.isEmpty ? "Unspecified" : platforms)
                if !bundleIDs.isEmpty {
                    LabeledContent("Bundle IDs") { Text(bundleIDs).textSelection(.enabled) }
                }
            }
            Section("Xcode Project") {
                if projectPath.isEmpty {
                    Text("No project linked").foregroundStyle(.secondary)
                } else {
                    Text(URL(fileURLWithPath: projectPath).lastPathComponent)
                    if let projectMessage { Text(projectMessage).foregroundStyle(.secondary) }
                    if projectAvailable {
                        Button("Open Project", systemImage: "arrow.up.right.square", action: openProjectLocation)
                        Button("Reveal in Finder", systemImage: "folder", action: revealProjectLocation)
                    }
                }
            }
            Section("Links") {
                if let url = record?.appStoreURL { Link("App Store Listing", destination: url) }
                if let url = record?.testFlightURL { Link("TestFlight Beta", destination: url) }
                if let url = record?.repositoryURL { Link("Source Code Repository", destination: url) }
                ForEach(links) { link in
                    let website = websites.first { $0.id == link.websiteId }
                    let websiteName = website?.name ?? "Website"
                    let purpose = websiteLinkPurposeLabel(link.purpose)
                    let label = "\(websiteName) — \(purpose)"
                    if let url = link.url ?? website?.baseURL {
                        Link(label, destination: url)
                    } else {
                        Text(label).foregroundStyle(.secondary)
                    }
                }
                if record?.appStoreURL == nil, record?.testFlightURL == nil, record?.repositoryURL == nil, links.isEmpty {
                    Text("No links added").foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
    }

    private func websiteLinkPurposeLabel(_ purpose: String) -> String {
        switch purpose.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "product": "Product page"
        case "support": "Support page"
        case "privacy": "Privacy policy"
        case "docs", "documentation": "Documentation"
        default: purpose.capitalized
        }
    }

    private func reportOverviewDirty(_ value: Bool) {
        overviewIsDirty = value
        onDirtyChange(overviewIsDirty)
    }

    private var appFilesPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("App Files").font(.largeTitle.bold())
            if let appFolderRelativePath, let appID = record?.id {
                Text("App assets live in this workspace folder. Your Xcode project remains at its linked location.")
                    .foregroundStyle(.secondary)
                LabeledContent("Workspace app folder", value: appFolderRelativePath)
                HStack {
                    Button("Open Assets Folder", systemImage: "folder") { openAppAssetsFolder(reveal: false) }
                    Button("Reveal Assets in Finder", systemImage: "finder") { openAppAssetsFolder(reveal: true) }
                }
                if !projectPath.isEmpty {
                    Divider()
                    LabeledContent("Linked Xcode project", value: projectPath)
                    HStack {
                        Button("Open Project", systemImage: "arrow.up.right.square") { openProjectLocation() }.disabled(!projectAvailable)
                        Button("Reveal Project in Finder", systemImage: "finder") { revealProjectLocation() }.disabled(!projectAvailable)
                    }
                }
                Text("App ID: \(appID)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            } else {
                ContentUnavailableView("Save App First", systemImage: "folder", description: Text("Save this app before creating its asset folder."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let fileMessage { Label(fileMessage, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func openAppAssetsFolder(reveal: Bool) {
        do {
            guard let appFolderRelativePath else { throw CocoaError(.fileNoSuchFile) }
            let root = workspaceStore.rootURL.standardizedFileURL.resolvingSymlinksInPath()
            let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
            let appFolder = workspaceStore.rootURL.appendingPathComponent(appFolderRelativePath, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
            guard appFolder.path.hasPrefix(rootPrefix),
                  (try appFolder.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else { throw CocoaError(.fileReadInvalidFileName) }
            let assets = appFolder.appendingPathComponent("Assets", isDirectory: true)
            if FileManager.default.fileExists(atPath: assets.path) {
                let resolved = assets.standardizedFileURL.resolvingSymlinksInPath()
                guard resolved.path.hasPrefix(rootPrefix),
                      (try resolved.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else { throw CocoaError(.fileReadInvalidFileName) }
            } else {
                try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: false)
            }
            if reveal { NSWorkspace.shared.activateFileViewerSelecting([assets]) }
            else { NSWorkspace.shared.open(assets) }
            fileMessage = nil
        } catch { fileMessage = error.localizedDescription }
    }

    private var overviewForm: some View {
        Form {
            Section("App") {
                HStack(spacing: 14) {
                    Group {
                        if let iconPreview { Image(nsImage: iconPreview).resizable().scaledToFit() }
                        else { Image(systemName: "app.dashed").resizable().scaledToFit().foregroundStyle(.secondary) }
                    }
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel(iconPreview == nil ? "No app icon selected" : "App icon preview")
                    VStack(alignment: .leading, spacing: 8) {
                        Button(iconPath == nil ? "Choose App Icon…" : "Replace App Icon…") { showingIconPicker = true }
                        if iconPath != nil {
                            Button("Clear App Icon", role: .destructive) {
                                iconPath = nil
                                iconPreview = nil
                                pendingIconData = nil
                                pendingIconRevision = nil
                                pendingIconWrittenPath = nil
                                iconError = nil
                            }
                        }
                        if let iconError { Text(iconError).font(.caption).foregroundStyle(.red) }
                        else { Text("Optional artwork copied into this app’s workspace Assets folder.").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                TextField("Name", text: $name)
                Picker("Developer identity", selection: $developerID) {
                    Text("None").tag("")
                    ForEach(identities) { Text($0.name).tag($0.id) }
                }
                TextField("Platforms (comma separated)", text: $platforms, prompt: Text("macOS, iOS"))
                Picker("Development state", selection: $developmentStatus) {
                    ForEach(AppDevelopmentStatus.allCases) { status in Text(status.label).tag(status.rawValue) }
                }
                TextField("Bundle IDs (comma separated, optional)", text: $bundleIDs, prompt: Text("com.example.app"))
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Xcode project location")
                        Spacer()
                        Button(projectPath.isEmpty || !projectAvailable ? "Choose…" : "Relink…", systemImage: "folder") { chooseProjectLocation() }
                    }
                    if !projectPath.isEmpty {
                        Text(projectPath).font(.caption).foregroundStyle(projectAvailable ? Color.secondary : Color.red).textSelection(.enabled)
                        HStack {
                            Button("Open", systemImage: "arrow.up.right.square") { openProjectLocation() }
                                .disabled(!projectAvailable)
                            Button("Reveal in Finder", systemImage: "finder") { revealProjectLocation() }
                                .disabled(!projectAvailable)
                        }
                    } else {
                        Text("Choose an Xcode project, workspace, or source folder. The project stays in its current location.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let projectMessage { Text(projectMessage).font(.caption).foregroundStyle(.red) }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Description")
                        .font(.headline)
                    TextEditor(text: $appDescription)
                        .font(.body)
                        .frame(minHeight: 80)
                        .accessibilityLabel("App description")
                    Text("A short summary shown with this app in the workspace.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Links") {
                TextField("Repository URL", text: $repositoryURL)
                TextField("App Store URL", text: $appStoreURL)
                TextField("TestFlight URL", text: $testFlightURL)
                HStack {
                    if let url = optionalWebURL(repositoryURL) {
                        Button("Open Repository", systemImage: "arrow.up.right.square") { NSWorkspace.shared.open(url) }
                    }
                    if let url = optionalWebURL(appStoreURL) {
                        Button("Open App Store", systemImage: "arrow.up.right.square") { NSWorkspace.shared.open(url) }
                    }
                    if let url = optionalWebURL(testFlightURL) {
                        Button("Open TestFlight", systemImage: "arrow.up.right.square") { NSWorkspace.shared.open(url) }
                    }
                }
            }
            Section("Website pages") {
                if links.isEmpty { Text("No website pages linked.").foregroundStyle(.secondary) }
                ForEach($links) { $link in
                    VStack(alignment: .leading) {
                        Picker("Website", selection: $link.websiteId) {
                            ForEach(websites) { Text($0.name).tag($0.id) }
                        }
                        HStack {
                            TextField("Purpose", text: $link.purpose)
                            TextField("Page URL", text: Binding(get: { link.url?.absoluteString ?? "" }, set: { link.url = optionalWebURL($0) }))
                        }
                        Toggle("Primary app page", isOn: $link.isPrimary)
                        if let url = link.url {
                            Button("Open Page", systemImage: "arrow.up.right.square") { NSWorkspace.shared.open(url) }
                        }
                    }
                    .padding(.vertical, 4)
                }
                Button("Add Website Page", systemImage: "plus") {
                    guard let website = websites.first else { return }
                    links.append(AppWebsiteLink(websiteId: website.id, purpose: "product", isPrimary: links.isEmpty))
                }
                .disabled(websites.isEmpty)
            }
            saveBar
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fileImporter(isPresented: $showingIconPicker, allowedContentTypes: [.image], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task { await importAppIcon(from: url) }
            case .failure(let error): iconError = error.localizedDescription
            }
        }
    }

    /// Resolve the app's workspace folder by stable record ID so folder names can change safely.
    private var appFolderRelativePath: String? {
        guard record != nil else { return nil }
        let base = workspaceStore.rootURL.appendingPathComponent("Apps", isDirectory: true)
        guard let folders = try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else { return nil }
        for folder in folders {
            let recordURL = folder.appendingPathComponent("record.json")
            guard let data = try? Data(contentsOf: recordURL),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["id"] as? String == record?.id else { continue }
            return "Apps/\(folder.lastPathComponent)"
        }
        return nil
    }

    private var saveBar: some View {
        Section {
            HStack {
                Spacer()
                if record != nil {
                    Button("Done") { editingOverview = false }
                        .disabled(isDirty || saving)
                        .help("Save your changes before closing the editor.")
                }
                Button("Save App") { Task { await save() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
            }
        }
    }
    private func load() {
        guard let record else { return }
        name = record.name; appDescription = record.description ?? ""; bundleIDs = record.bundleIDs?.joined(separator: ", ") ?? ""
        developmentStatus = (record.developmentStatus ?? .development).rawValue
        developerID = record.developerIdentityId ?? ""; platforms = record.platforms.joined(separator: ", ")
        draftID = record.id
        projectPath = record.projectPath ?? ""; repositoryURL = record.repositoryURL?.absoluteString ?? ""; appStoreURL = record.appStoreURL?.absoluteString ?? ""; testFlightURL = record.testFlightURL?.absoluteString ?? ""; links = record.websiteLinks
        iconPath = record.iconPath
        if iconPath != nil { Task { await loadAppIconPreview() } }
        resolveProjectLocation()
    }
    private func save() async {
        saving = true
        defer { saving = false }
        do {
            if let pendingIconData, let iconPath {
                guard let appFolder = targetAppFolderRelativePath else { throw CocoaError(.fileNoSuchFile) }
                let destination = "\(appFolder)/\(iconPath)"
                pendingIconRevision = try await workspaceStore.write(
                    pendingIconData,
                    relativePath: destination,
                    expectedRevision: pendingIconWrittenPath == destination ? pendingIconRevision : nil
                )
                pendingIconWrittenPath = destination
            }
            if await onSave(draftRecord) {
                pendingIconData = nil
                pendingIconRevision = nil
                pendingIconWrittenPath = nil
                iconError = nil
                editingOverview = false
                reportOverviewDirty(false)
            }
        } catch {
            iconError = "Could not save the app icon: \(error.localizedDescription)"
        }
    }

    private var targetAppFolderRelativePath: String? {
        if let appFolderRelativePath { return appFolderRelativePath }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return "Apps/\(Self.folderSlug(name))-\((record?.id ?? draftID).prefix(8))"
    }

    private static func folderSlug(_ text: String) -> String {
        let pieces = text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let value = pieces.prefix(8).joined(separator: "-")
        return value.isEmpty ? "record" : value
    }

    private func importAppIcon(from sourceURL: URL) async {
        let access = sourceURL.startAccessingSecurityScopedResource()
        defer { if access { sourceURL.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: sourceURL)
            guard !data.isEmpty, data.count <= 20 * 1_024 * 1_024,
                  let image = NSImage(data: data),
                  let type = UTType(filenameExtension: sourceURL.pathExtension), type.conforms(to: .image) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let ext = type.preferredFilenameExtension ?? sourceURL.pathExtension.lowercased()
            guard !ext.isEmpty, ext.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) else {
                throw CocoaError(.fileReadInvalidFileName)
            }
            iconPath = "Assets/app-icon-\(UUID().uuidString.lowercased()).\(ext)"
            pendingIconData = data
            pendingIconRevision = nil
            pendingIconWrittenPath = nil
            iconPreview = image
            iconError = nil
        } catch {
            iconError = "Could not import this app icon: \(error.localizedDescription)"
        }
    }

    private func safeAppIconRelativePath(_ iconPath: String) -> String? {
        guard !iconPath.isEmpty, !iconPath.hasPrefix("/"),
              !iconPath.split(separator: "/").contains(".."),
              let appFolderRelativePath else { return nil }
        let root = workspaceStore.rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let folder = workspaceStore.rootURL.appendingPathComponent(appFolderRelativePath, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let image = folder.appendingPathComponent(iconPath).standardizedFileURL.resolvingSymlinksInPath()
        let folderPrefix = folder.path.hasSuffix("/") ? folder.path : folder.path + "/"
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard folder.path.hasPrefix(rootPrefix), image.path.hasPrefix(folderPrefix) else { return nil }
        return "\(appFolderRelativePath)/\(iconPath)"
    }

    private func loadAppIconPreview() async {
        guard let iconPath, let safeRelativePath = safeAppIconRelativePath(iconPath) else { return }
        do {
            let data = try await workspaceStore.read(relativePath: safeRelativePath).data
            guard self.iconPath == iconPath else { return }
            iconPreview = NSImage(data: data)
            if iconPreview == nil { iconError = "The linked icon file is not a readable image. Replace or clear it." }
        } catch {
            guard self.iconPath == iconPath else { return }
            iconPreview = nil
            iconError = "The linked icon is unavailable. Replace or clear it. \(error.localizedDescription)"
        }
    }

    private var draftRecord: AppRecord {
        let parsedBundleIDs = bundleIDs.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return AppRecord(
            id: record?.id ?? draftID,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            description: appDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : appDescription,
            bundleIDs: parsedBundleIDs.isEmpty ? nil : parsedBundleIDs,
            developmentStatus: AppDevelopmentStatus(rawValue: developmentStatus) ?? .development,
            iconPath: iconPath,
            developerIdentityId: developerID.isEmpty ? nil : developerID,
            platforms: platforms.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) },
            projectPath: projectPath.isEmpty ? nil : projectPath,
            repositoryURL: optionalWebURL(repositoryURL), appStoreURL: optionalWebURL(appStoreURL),
            testFlightURL: optionalWebURL(testFlightURL), websiteLinks: links
        )
    }

    private var isDirty: Bool {
        if var record {
            // Older records omit the state; the editor displays the same default.
            if record.developmentStatus == nil { record.developmentStatus = .development }
            return draftRecord != record
        }
        return !draftRecord.name.isEmpty || !appDescription.isEmpty || !bundleIDs.isEmpty || developmentStatus != AppDevelopmentStatus.development.rawValue || developerID != "" || !platforms.isEmpty || !projectPath.isEmpty || !repositoryURL.isEmpty || !appStoreURL.isEmpty || !testFlightURL.isEmpty || iconPath != nil || !links.isEmpty
    }

    private var bookmarkKey: String { "projectLocationBookmark.\(record?.id ?? draftID)" }

    private func chooseProjectLocation() {
        let panel = NSOpenPanel()
        panel.title = "Choose Xcode Project Location"
        panel.message = "Select an Xcode project, workspace, or source folder."
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let hasAccess = url.startAccessingSecurityScopedResource()
            defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
            let bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            try WorkspaceRegistry.setBookmark(bookmark, forKey: bookmarkKey)
            projectPath = url.path
            projectURL = url
            projectAvailable = true
            projectMessage = nil
        } catch {
            projectMessage = "Couldn’t save access to this location: \(error.localizedDescription)"
            projectAvailable = false
        }
    }

    private func resolveProjectLocation() {
        guard !projectPath.isEmpty else { projectURL = nil; projectAvailable = false; return }
        do {
            guard let bookmark = try WorkspaceRegistry.bookmark(forKey: bookmarkKey) else {
                projectURL = nil; projectAvailable = false
                projectMessage = "Access to this location is unavailable. Relink the project to continue."
                return
            }
            var isStale = false
            let url = try URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)
            guard url.startAccessingSecurityScopedResource() else {
                projectURL = nil; projectAvailable = false
                projectMessage = "macOS could not restore access to this location. Relink the project."
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }
            guard FileManager.default.fileExists(atPath: url.path) else {
                projectURL = nil; projectAvailable = false
                projectMessage = "This location can’t be found. Relink the project location."
                return
            }
            projectURL = url
            projectAvailable = true
            projectMessage = nil
            if isStale {
                let refreshed = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                try WorkspaceRegistry.setBookmark(refreshed, forKey: bookmarkKey)
            }
        } catch {
            projectURL = nil; projectAvailable = false
            projectMessage = "Access to this location expired. Relink the project."
        }
    }

    private func openProjectLocation() {
        guard let projectURL, projectAvailable else { return }
        let hasAccess = projectURL.startAccessingSecurityScopedResource()
        defer { if hasAccess { projectURL.stopAccessingSecurityScopedResource() } }
        guard NSWorkspace.shared.open(projectURL) else { projectMessage = "The location couldn’t be opened."; return }
    }

    private func revealProjectLocation() {
        guard let projectURL, projectAvailable else { return }
        let hasAccess = projectURL.startAccessingSecurityScopedResource()
        defer { if hasAccess { projectURL.stopAccessingSecurityScopedResource() } }
        NSWorkspace.shared.activateFileViewerSelecting([projectURL])
    }
}

private struct IdentityRecordEditor: View {
    let record: IdentityRecord?
    let workspaceStore: WorkspaceStore
    let onDirtyChange: (Bool) -> Void
    let onSave: (IdentityRecord) async -> Bool
    @State private var name = ""
    @State private var kind = "Personal"
    @State private var draftID = UUID().uuidString.lowercased()
    @State private var photoPath: String?
    @State private var photoPreview: NSImage?
    @State private var photoError: String?
    @State private var showingPhotoPicker = false
    @State private var saving = false
    var body: some View {
        Form {
            Section("Identity") {
                TextField("Name", text: $name)
                Picker("Type", selection: $kind) {
                    Text("Personal").tag("Personal")
                    Text("Business").tag("Business")
                    Text("Brand").tag("Brand")
                }
            }
            Section("Photo") {
                HStack(spacing: 14) {
                    Group {
                        if let photoPreview {
                            Image(nsImage: photoPreview).resizable().scaledToFill()
                        } else {
                            Image(systemName: "person.crop.circle.fill").resizable().scaledToFit().foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 64, height: 64)
                    .clipShape(Circle())
                    .accessibilityLabel(photoPreview == nil ? "No identity photo selected" : "Identity photo preview")
                    VStack(alignment: .leading, spacing: 8) {
                        Button(photoPath == nil ? "Choose Photo…" : "Replace Photo…") { showingPhotoPicker = true }
                        if photoPath != nil {
                            Button("Remove Photo", role: .destructive) {
                                photoPath = nil
                                photoPreview = nil
                                photoError = nil
                            }
                        }
                        if let photoError { Text(photoError).font(.caption).foregroundStyle(.red) }
                        else if photoPath == nil { Text("Used as the default avatar for this identity’s social accounts.").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            Section { HStack { Spacer(); Button("Save Identity") { Task { await save() } }.buttonStyle(.borderedProminent).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving) } }
        }
        .formStyle(.grouped)
        .navigationTitle(record == nil ? "New Identity" : name)
        .onAppear {
            if let record {
                draftID = record.id
                name = record.name
                kind = record.kind ?? "Personal"
                photoPath = record.photoPath
                if let photoPath { Task { await loadPhotoPreview(relativePath: photoPath) } }
            }
        }
        .onChange(of: name) { _, _ in onDirtyChange(isDirty) }
        .onChange(of: kind) { _, _ in onDirtyChange(isDirty) }
        .onChange(of: photoPath) { _, _ in onDirtyChange(isDirty) }
        .fileImporter(isPresented: $showingPhotoPicker, allowedContentTypes: [.image], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task { await importPhoto(from: url) }
            case .failure(let error): photoError = error.localizedDescription
            }
        }
    }
    private func save() async {
        saving = true; defer { saving = false }
        if await onSave(IdentityRecord(id: draftID, name: name.trimmingCharacters(in: .whitespacesAndNewlines), kind: kind, photoPath: photoPath)) { onDirtyChange(false) }
    }
    private func loadPhotoPreview(relativePath: String) async {
        do {
            let data = try await workspaceStore.read(relativePath: relativePath).data
            guard photoPath == relativePath else { return }
            photoPreview = NSImage(data: data)
            if photoPreview == nil { photoError = "The linked photo file is not a readable image. Replace or remove it." }
        } catch {
            guard photoPath == relativePath else { return }
            photoPreview = nil
            photoError = "The linked photo is unavailable. Replace or remove it. \(error.localizedDescription)"
        }
    }
    private func importPhoto(from sourceURL: URL) async {
        let access = sourceURL.startAccessingSecurityScopedResource()
        defer { if access { sourceURL.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: sourceURL)
            guard !data.isEmpty, data.count <= 20 * 1_024 * 1_024,
                  let image = NSImage(data: data),
                  let type = UTType(filenameExtension: sourceURL.pathExtension), type.conforms(to: .image) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let ext = type.preferredFilenameExtension ?? sourceURL.pathExtension.lowercased()
            guard !ext.isEmpty, ext.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) else {
                throw CocoaError(.fileReadInvalidFileName)
            }
            let identityFolder = record.flatMap { ManagementWorkspaceView.findRecordPath(root: workspaceStore.rootURL, category: "Identities", id: $0.id) }
                .map { String($0.dropLast("/record.json".count)) }
                ?? "Identities/\(ManagementWorkspaceView.slug(name))-\(draftID.prefix(8))"
            let path = "\(identityFolder)/Assets/identity-photo-\(UUID().uuidString.lowercased()).\(ext)"
            _ = try await workspaceStore.write(data, relativePath: path, expectedRevision: nil)
            photoPath = path
            photoPreview = image
            photoError = nil
        } catch {
            photoError = "Could not import this photo: \(error.localizedDescription)"
        }
    }
    private var isDirty: Bool {
        record.map {
            $0.name != name.trimmingCharacters(in: .whitespacesAndNewlines) || ($0.kind ?? "Personal") != kind || $0.photoPath != photoPath
        } ?? (!name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || kind != "Personal" || photoPath != nil)
    }
}

private struct WebsiteRecordEditor: View {
    let record: WebsiteRecord?
    let owners: [OwnerChoice]
    let onDirtyChange: (Bool) -> Void
    let onSave: (WebsiteRecord) async -> Bool
    @State private var name = ""
    @State private var ownerID = ""
    @State private var baseURL = "https://"
    @State private var blogEnabled = false
    @State private var blogIndexURL = ""
    @State private var saving = false
    var body: some View {
        Form {
            Section("Website") {
                TextField("Name", text: $name)
                ownerPicker
                TextField("Base URL", text: $baseURL)
                Toggle("Enable as a blog destination", isOn: $blogEnabled)
                if blogEnabled { TextField("Blog index URL (optional)", text: $blogIndexURL) }
            }
            Section { HStack { Spacer(); Button("Save Website") { Task { await save() } }.buttonStyle(.borderedProminent).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || URL(string: baseURL)?.scheme == nil || ownerID.isEmpty || saving) } }
        }
        .formStyle(.grouped)
        .navigationTitle(record == nil ? "New Website" : name)
        .onAppear { if let record { name = record.name; ownerID = "\(record.owner.type.rawValue):\(record.owner.id)"; baseURL = record.baseURL.absoluteString; blogEnabled = record.blogEnabled; blogIndexURL = record.blogIndexURL?.absoluteString ?? "" } else { ownerID = owners.first?.id ?? "" } }
        .onChange(of: dirtySignature) { _, _ in onDirtyChange(isDirty) }
    }
    private var ownerPicker: some View {
        Picker("Owner", selection: $ownerID) {
            Text("Choose owner").tag("")
            ForEach(owners) { choice in Text("\(choice.title) (\(choice.detail))").tag(choice.id) }
        }
    }
    private func save() async {
        guard let choice = owners.first(where: { $0.id == ownerID }), let url = URL(string: baseURL) else { return }
        saving = true; defer { saving = false }
        let value = WebsiteRecord(id: record?.id ?? UUID().uuidString.lowercased(), name: name.trimmingCharacters(in: .whitespacesAndNewlines), owner: choice.owner, baseURL: url, blogEnabled: blogEnabled, blogIndexURL: optionalWebURL(blogIndexURL))
        if await onSave(value) { onDirtyChange(false) }
    }
    private var dirtySignature: String { "\(name)|\(ownerID)|\(baseURL)|\(blogEnabled)|\(blogIndexURL)" }
    private var isDirty: Bool {
        if let record {
            return record.name != name.trimmingCharacters(in: .whitespacesAndNewlines) || ownerID != "\(record.owner.type.rawValue):\(record.owner.id)" || baseURL != record.baseURL.absoluteString || blogEnabled != record.blogEnabled || blogIndexURL != (record.blogIndexURL?.absoluteString ?? "")
        }
        return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || ownerID != (owners.first?.id ?? "") || baseURL != "https://" || blogEnabled || !blogIndexURL.isEmpty
    }
}

private struct SocialAccountRecordEditor: View {
    @Environment(SocialPublishingRuntime.self) private var socialPublishingRuntime
    let record: SocialAccountRecord?
    let owners: [OwnerChoice]
    let identities: [IdentityRecord]
    let workspaceStore: WorkspaceStore
    let onDirtyChange: (Bool) -> Void
    let onSave: (SocialAccountRecord) async -> Bool
    @State private var platform = "Threads"
    @State private var customPlatform = ""
    @State private var ownerID = ""
    @State private var handle = ""
    @State private var displayName = ""
    @State private var profileURL = ""
    @State private var enabled = true
    @State private var draftID = UUID().uuidString.lowercased()
    @State private var avatarPath: String?
    @State private var avatarPreview: NSImage?
    @State private var identityAvatarPreview: NSImage?
    @State private var avatarError: String?
    @State private var showingAvatarPicker = false
    @State private var showingBlueskyConnect = false
    @State private var showingOAuthConnect = false
    @State private var showingAccountActivity = false
    @State private var providerIdentity: ContentRecipientIdentity?
    @State private var connectedAccount: SocialAccount?
    @State private var saving = false
    private let platforms = ["Bluesky", "Threads", "Instagram", "X", "Facebook", "LinkedIn", "Mastodon", "Other"]
    private var platformValue: String { platform == "Other" ? customPlatform : platform }
    private var apiPlatform: SocialPlatform? { SocialPlatform.workspacePlatform(platformValue) }

    init(record: SocialAccountRecord?, owners: [OwnerChoice], identities: [IdentityRecord], workspaceStore: WorkspaceStore, onDirtyChange: @escaping (Bool) -> Void, onSave: @escaping (SocialAccountRecord) async -> Bool) {
        self.record = record
        self.owners = owners
        self.identities = identities
        self.workspaceStore = workspaceStore
        self.onDirtyChange = onDirtyChange
        self.onSave = onSave

        let ownerID = record?.owner.map { "\($0.type.rawValue):\($0.id)" } ?? ""
        let ownerIdentity = ownerID.hasPrefix("identity:")
            ? identities.first { $0.id == String(ownerID.dropFirst("identity:".count)) }
            : nil
        _ownerID = State(initialValue: ownerID)
        _avatarPath = State(initialValue: record?.avatarPath)
        _avatarPreview = State(initialValue: Self.loadImage(path: record?.avatarPath, root: workspaceStore.rootURL))
        _identityAvatarPreview = State(initialValue: Self.loadImage(path: ownerIdentity?.photoPath, root: workspaceStore.rootURL))
    }

    var body: some View {
        Form {
            Section("Social account") {
                Picker("Platform", selection: $platform) { ForEach(platforms, id: \.self) { Text($0).tag($0) } }
                if platform == "Other" { TextField("Platform name", text: $customPlatform) }
                Picker("Owner", selection: $ownerID) {
                    Text("Choose owner").tag("")
                    ForEach(owners) { Text("\($0.title) (\($0.detail))").tag($0.id) }
                }
                TextField("Handle", text: $handle, prompt: Text("@name"))
                TextField("Display name", text: $displayName)
                TextField("Profile URL", text: $profileURL)
                Toggle("Enabled for new posts", isOn: $enabled)
                Text("A new post can use this account when it is enabled, has an owner, and has a platform plus a handle or profile URL.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            connectionSection
            Section("Avatar") {
                HStack(spacing: 14) {
                    Group {
                        if let displayedAvatarPreview {
                            Image(nsImage: displayedAvatarPreview).resizable().scaledToFill()
                        } else {
                            Image(systemName: "person.crop.circle.fill").resizable().scaledToFit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 64, height: 64)
                    .clipShape(Circle())
                    .accessibilityLabel(displayedAvatarPreview == nil ? "No account avatar selected" : (avatarPath == nil ? "Identity photo avatar preview" : "Custom account avatar preview"))
                    VStack(alignment: .leading, spacing: 8) {
                        Button(avatarPath == nil ? "Choose Custom Avatar…" : "Replace Custom Avatar…") { showingAvatarPicker = true }
                        if avatarPath != nil {
                            Button("Use Identity Photo") {
                                avatarPath = nil
                                avatarPreview = nil
                                avatarError = nil
                            }
                        }
                        if let avatarError {
                            Text(avatarError).font(.caption).foregroundStyle(.red)
                        } else if avatarPath == nil, selectedIdentity?.photoPath != nil {
                            Text("Using the owner’s identity photo. Add a custom avatar to override it.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else if avatarPath == nil {
                            Text("Using a custom avatar overrides the owner’s identity photo when one is set.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section { HStack { Spacer(); Button("Save Social Account") { Task { await save() } }.buttonStyle(.borderedProminent).disabled(platformValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || ownerID.isEmpty || (handle.isEmpty && profileURL.isEmpty) || saving) } }
        }
        .formStyle(.grouped)
        .navigationTitle(record == nil ? "New Social Account" : platformValue)
        .sheet(isPresented: $showingBlueskyConnect) {
            BlueskyConnectionSheet(initialHandle: handle, onConnected: applyConnection)
        }
        .sheet(isPresented: $showingOAuthConnect) {
            if let apiPlatform {
                SocialOAuthConnectionSheet(platform: apiPlatform, onConnected: applyConnection)
            }
        }
        .sheet(isPresented: $showingAccountActivity) {
            if let providerIdentity, let connectedAccount {
                SocialAccountActivityView(identity: providerIdentity, account: connectedAccount)
            }
        }
        .onAppear(perform: load)
        .task(id: providerIdentity) {
            connectedAccount = nil
            guard let identity = providerIdentity else { return }
            let accounts = try? await socialPublishingRuntime.connections.accounts()
            guard !Task.isCancelled, providerIdentity == identity else { return }
            connectedAccount = accounts?.first {
                $0.platform.rawValue == identity.platform && $0.server == identity.server && $0.remoteID == identity.remoteID
            }
        }
        .onChange(of: platformValue) { _, newValue in
            if SocialPlatform.workspacePlatform(newValue)?.rawValue != providerIdentity?.platform { providerIdentity = nil }
        }
        .onChange(of: dirtySignature) { _, _ in onDirtyChange(isDirty) }
        .onChange(of: ownerID) { _, _ in loadIdentityAvatarPreview() }
        .onChange(of: selectedIdentity?.photoPath) { _, _ in loadIdentityAvatarPreview() }
        .fileImporter(isPresented: $showingAvatarPicker, allowedContentTypes: [.image], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task { await importAvatar(from: url) }
            case .failure(let error): avatarError = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private var connectionSection: some View {
        Section("API connection") {
            if let apiPlatform {
                if let connectedAccount {
                    Label("Connected as \(connectedAccount.displayName ?? connectedAccount.username)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    if let authenticatedUserName = connectedAccount.authenticatedUserName,
                       authenticatedUserName != connectedAccount.displayName {
                        Text("Authorized by \(authenticatedUserName)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button("View Account Activity…") { showingAccountActivity = true }
                } else if providerIdentity != nil {
                    Label("Connection unavailable on this Mac", systemImage: "exclamationmark.circle")
                } else {
                    Label("API connection not configured", systemImage: "lock.shield")
                }
                if apiPlatform.requiresBroker {
                    Text("\(apiPlatform.workspaceTitle) requires provider registration and a trusted HTTPS exchange service.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button(providerIdentity == nil ? "Connect \(apiPlatform.workspaceTitle)…" : "Reconnect \(apiPlatform.workspaceTitle)…") {
                    if apiPlatform == .bluesky { showingBlueskyConnect = true }
                    else { showingOAuthConnect = true }
                }
                if providerIdentity != nil {
                    Button("Unlink from This Workspace Account", role: .destructive) { providerIdentity = nil }
                    Text("Save the workspace account to apply the change.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Label("Manual posting", systemImage: "hand.tap")
            }
        }
    }

    private func applyConnection(_ account: SocialAccount) {
        providerIdentity = ContentRecipientIdentity(platform: account.platform.rawValue,
                                                     server: account.server,
                                                     remoteID: account.remoteID)
        handle = account.username
        if let name = account.displayName, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            displayName = name
        }
        if let profileURL = account.profileURL, profileURL.scheme?.lowercased() == "https", profileURL.host != nil {
            self.profileURL = profileURL.absoluteString
        }
    }
    private func load() {
        guard let record else {
            ownerID = owners.first?.id ?? ""
            return
        }
        draftID = record.id
        platform = platforms.contains(record.platform) ? record.platform : "Other"
        customPlatform = platforms.contains(record.platform) ? "" : record.platform
        ownerID = record.owner.map { "\($0.type.rawValue):\($0.id)" } ?? ""
        handle = record.handle ?? ""; displayName = record.displayName ?? ""; profileURL = record.profileURL?.absoluteString ?? ""; enabled = record.enabled
        providerIdentity = record.providerIdentity
        avatarPath = record.avatarPath
        avatarPreview = Self.loadImage(path: record.avatarPath, root: workspaceStore.rootURL)
        loadIdentityAvatarPreview()
    }
    private var selectedIdentity: IdentityRecord? {
        guard ownerID.hasPrefix("identity:") else { return nil }
        let identityID = String(ownerID.dropFirst("identity:".count))
        return identities.first { $0.id == identityID }
    }
    private var displayedAvatarPreview: NSImage? { avatarPath == nil ? identityAvatarPreview : (avatarPreview ?? identityAvatarPreview) }
    private func loadIdentityAvatarPreview() {
        identityAvatarPreview = Self.loadImage(path: selectedIdentity?.photoPath, root: workspaceStore.rootURL)
    }

    private static func loadImage(path: String?, root: URL) -> NSImage? {
        guard let url = ManagementWorkspaceView.safeWorkspacePhotoURL(root: root, photoPath: path) else { return nil }
        return NSImage(contentsOf: url)
    }
    private func importAvatar(from sourceURL: URL) async {
        let access = sourceURL.startAccessingSecurityScopedResource()
        defer { if access { sourceURL.stopAccessingSecurityScopedResource() } }
        do {
            let sourceData = try Data(contentsOf: sourceURL)
            guard !sourceData.isEmpty, sourceData.count <= 20 * 1_024 * 1_024,
                  let image = NSImage(data: sourceData),
                  let contentType = UTType(filenameExtension: sourceURL.pathExtension), contentType.conforms(to: .image) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let accountID = record?.id ?? draftID
            let accountFolder = try await avatarFolderRelativePath(for: accountID)
            let ext = contentType.preferredFilenameExtension ?? sourceURL.pathExtension.lowercased()
            guard !ext.isEmpty, ext.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) else {
                throw CocoaError(.fileReadInvalidFileName)
            }
            let relativePath = "\(accountFolder)/Assets/avatar-\(UUID().uuidString.lowercased()).\(ext)"
            _ = try await workspaceStore.write(sourceData, relativePath: relativePath, expectedRevision: nil)
            avatarPath = relativePath
            avatarPreview = image
            avatarError = nil
        } catch {
            avatarError = "Could not import this avatar: \(error.localizedDescription)"
        }
    }
    private func avatarFolderRelativePath(for accountID: String) async throws -> String {
        if record != nil {
            let category = workspaceStore.rootURL.appendingPathComponent("SocialAccounts", isDirectory: true)
            let folders = try FileManager.default.contentsOfDirectory(at: category, includingPropertiesForKeys: [.isDirectoryKey])
            let decoder = JSONDecoder()
            for folder in folders where (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                let relativeRecord = "SocialAccounts/\(folder.lastPathComponent)/record.json"
                guard let bytes = try? await workspaceStore.read(relativePath: relativeRecord),
                      let stored = try? decoder.decode(SocialAccountRecord.self, from: bytes.data), stored.id == accountID else { continue }
                return "SocialAccounts/\(folder.lastPathComponent)"
            }
            throw CocoaError(.fileNoSuchFile)
        }
        return "SocialAccounts/\(folderName(platformValue))-\(accountID.prefix(8))"
    }
    private func folderName(_ value: String) -> String {
        let pieces = value.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let slug = pieces.prefix(8).joined(separator: "-")
        return slug.isEmpty ? "record" : slug
    }
    private func save() async {
        guard let choice = owners.first(where: { $0.id == ownerID }) else { return }
        saving = true; defer { saving = false }
        if await onSave(SocialAccountRecord(id: record?.id ?? draftID, platform: platformValue.trimmingCharacters(in: .whitespacesAndNewlines), owner: choice.owner, handle: handle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : handle.trimmingCharacters(in: .whitespacesAndNewlines), displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : displayName.trimmingCharacters(in: .whitespacesAndNewlines), profileURL: optionalWebURL(profileURL), avatarPath: avatarPath, providerIdentity: providerIdentity, enabled: enabled)) { onDirtyChange(false) }
    }
    private var dirtySignature: String { "\(platform)|\(customPlatform)|\(ownerID)|\(handle)|\(displayName)|\(profileURL)|\(enabled)|\(avatarPath ?? "")|\(providerIdentity?.platform ?? "")|\(providerIdentity?.server.absoluteString ?? "")|\(providerIdentity?.remoteID ?? "")" }
    private var isDirty: Bool {
        if let record {
            let savedPlatform = platforms.contains(record.platform) ? record.platform : "Other"
            let savedCustomPlatform = platforms.contains(record.platform) ? "" : record.platform
            return platform != savedPlatform || customPlatform != savedCustomPlatform || ownerID != (record.owner.map { "\($0.type.rawValue):\($0.id)" } ?? "") || handle != (record.handle ?? "") || displayName != (record.displayName ?? "") || profileURL != (record.profileURL?.absoluteString ?? "") || enabled != record.enabled || avatarPath != record.avatarPath || providerIdentity != record.providerIdentity
        }
        return platform != "Threads" || !customPlatform.isEmpty || ownerID != (owners.first?.id ?? "") || !handle.isEmpty || !displayName.isEmpty || !profileURL.isEmpty || !enabled || avatarPath != nil
    }
}

private struct BlueskyConnectionSheet: View {
    @Environment(SocialPublishingRuntime.self) private var socialPublishingRuntime
    @Environment(\.dismiss) private var dismiss
    let initialHandle: String
    let onConnected: (SocialAccount) -> Void
    @State private var handle = ""
    @State private var appPassword = ""
    @State private var server = "https://bsky.social"
    @State private var isConnecting = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            TextField("Handle", text: $handle, prompt: Text("name.bsky.social"))
            SecureField("App password", text: $appPassword)
            TextField("PDS server", text: $server)
            Text("Create an app password in Bluesky settings. The resulting connection credential is stored in Keychain.")
                .font(.caption).foregroundStyle(.secondary)
            if let errorMessage { Text(errorMessage).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button("Cancel") { appPassword = ""; dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(isConnecting ? "Connecting…" : "Connect") { Task { await connect() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(isConnecting || handle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || appPassword.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 430)
        .onAppear { handle = initialHandle }
    }

    private func connect() async {
        guard let serverURL = URL(string: server.trimmingCharacters(in: .whitespacesAndNewlines)),
              serverURL.scheme?.lowercased() == "https", serverURL.host != nil else {
            errorMessage = "Enter a trusted HTTPS PDS server URL."
            return
        }
        isConnecting = true
        defer { isConnecting = false }
        do {
            let account = try await socialPublishingRuntime.connections.connectBluesky(
                identifier: handle.trimmingCharacters(in: .whitespacesAndNewlines),
                appPassword: appPassword,
                server: serverURL
            )
            appPassword = ""
            onConnected(account)
            dismiss()
        } catch {
            appPassword = ""
            errorMessage = "Bluesky connection failed: \(error.localizedDescription)"
        }
    }
}

private func optionalWebURL(_ value: String) -> URL? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return URL(string: trimmed)
}

private struct AppMarketingContentPanel: View {
    let appID: String
    let appName: String
    let snapshot: WorkspaceSnapshot
    let store: WorkspaceStore
    let actionsEnabled: Bool
    let onOpen: (String) -> Void
    let onCreated: () -> Void

    @State private var isCreating = false
    @State private var errorMessage: String?

    private var records: [ContentRecord] {
        snapshot.content.filter { $0.appIds.contains(appID) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Marketing Content").font(.largeTitle.bold())
                    Text("Content associated with \(appName.isEmpty ? "this app" : appName).")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Menu("Create", systemImage: "plus") {
                    Button("Blog Article") { create(.blog) }
                    Button("Social Post") { create(.social) }
                    Button("Idea") { create(.idea) }
                }
                .disabled(!actionsEnabled || isCreating)
            }
            if !actionsEnabled {
                Label("Save or discard app changes before opening or creating marketing content.", systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            }
            if records.isEmpty {
                ContentUnavailableView("No Marketing Content", systemImage: "megaphone", description: Text("Create an article, social post, or idea for this app."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(records) { item in
                    HStack {
                        Image(systemName: item.kind == .blog ? "doc.text" : item.kind == .social ? "bubble.left.and.bubble.right" : "lightbulb")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title).font(.headline)
                            Text("\(item.kind.rawValue.capitalized) · \(item.status.rawValue.capitalized)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Open") { onOpen(item.id) }
                            .disabled(!actionsEnabled)
                    }
                    .padding(.vertical, 4)
                }
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
        }
        .padding(24)
        .alert("Couldn’t Create Content", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func create(_ kind: ContentKind) {
        guard actionsEnabled, !isCreating else { return }
        isCreating = true
        let record = ContentRecord(
            kind: kind,
            title: kind == .blog ? "Untitled Article" : kind == .social ? "Untitled Social Post" : "New Idea",
            appIds: [appID],
            originalBodyPath: kind == .social ? "original.txt" : "body.md",
            status: kind == .idea ? .idea : .draft
        )
        let folder = "Content/\(record.id)"
        guard let bodyPath = record.originalBodyPath else { isCreating = false; return }
        Task {
            do {
                _ = try await store.write(Data(), relativePath: "\(folder)/\(bodyPath)")
                _ = try await store.save(record, relativePath: "\(folder)/record.json")
                onCreated()
                onOpen(record.id)
            } catch { errorMessage = error.localizedDescription }
            isCreating = false
        }
    }
}
