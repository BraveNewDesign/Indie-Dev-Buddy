import SwiftUI
import AppKit

enum ManagementInitialTab: Equatable {
    case apps
    case websitesAndSocialAccounts
}

private enum ManagementSection: String, CaseIterable, Identifiable, Equatable {
    case apps = "Apps"
    case identities = "Identities"
    case websites = "Websites"
    case socialAccounts = "Social Accounts"
    var id: String { rawValue }
}

/// Reusable management surface for local workspace records. The host owns refresh/reload;
/// this view writes records explicitly when the user presses Save.
struct ManagementWorkspaceView: View {
    let initialTab: ManagementInitialTab
    let snapshot: WorkspaceSnapshot
    let store: WorkspaceStore
    let onSnapshotChanged: () -> Void
    let onUnsavedEditsChanged: (Bool) -> Void
    let onOpenMarketingContent: (String) -> Void

    @State private var section: ManagementSection
    @State private var selectedID: String?
    @State private var creating = false
    @State private var editorIsDirty = false
    @State private var pendingNavigation: PendingManagementNavigation?
    @State private var saveError: String?
    @State private var savedMessage: String?
    @State private var loadedRevision: String?
    @State private var revisionMismatch = false

    init(initialTab: ManagementInitialTab, snapshot: WorkspaceSnapshot, store: WorkspaceStore, onSnapshotChanged: @escaping () -> Void, onUnsavedEditsChanged: @escaping (Bool) -> Void = { _ in }, onOpenMarketingContent: @escaping (String) -> Void) {
        self.initialTab = initialTab
        self.snapshot = snapshot
        self.store = store
        self.onSnapshotChanged = onSnapshotChanged
        self.onUnsavedEditsChanged = onUnsavedEditsChanged
        self.onOpenMarketingContent = onOpenMarketingContent
        _section = State(initialValue: initialTab == .apps ? .apps : .websites)
    }

    // Keeps call sites concise when the host already has sidebar section labels.
    init(snapshot: WorkspaceSnapshot, store: WorkspaceStore, onSnapshotChanged: @escaping () -> Void, initialTab: String, onUnsavedEditsChanged: @escaping (Bool) -> Void = { _ in }, onOpenMarketingContent: @escaping (String) -> Void) {
        self.init(initialTab: initialTab == "Apps" ? .apps : .websitesAndSocialAccounts, snapshot: snapshot, store: store, onSnapshotChanged: onSnapshotChanged, onUnsavedEditsChanged: onUnsavedEditsChanged, onOpenMarketingContent: onOpenMarketingContent)
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                Picker("Record type", selection: Binding(get: { section }, set: requestSection)) {
                    ForEach(availableSections) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding()

                List(selection: Binding(get: { selectedID }, set: requestSelection)) {
                    ForEach(rows) { row in
                        Label {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(row.title)
                                if !row.subtitle.isEmpty {
                                    Text(row.subtitle).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        } icon: {
                            Image(systemName: row.symbol).foregroundStyle(.secondary)
                        }
                        .tag(Optional(row.id))
                    }
                }
                .overlay {
                    if rows.isEmpty {
                        ContentUnavailableView("No \(section.rawValue)", systemImage: sectionSymbol, description: Text("Add a record to manage it in this workspace."))
                    }
                }

                Button(action: beginCreate) {
                    Label("Add \(singularName)", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding()
            }
            .navigationTitle(section.rawValue)
            .toolbar { ToolbarItem(placement: .primaryAction) { Button("Add", systemImage: "plus", action: beginCreate).help("Add \(singularName)") } }
        } detail: {
            detailContent
        }
        .alert("Couldn’t Save", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: { Text(saveError ?? "") }
        .alert("Saved", isPresented: Binding(get: { savedMessage != nil }, set: { if !$0 { savedMessage = nil } })) {
            Button("OK", role: .cancel) { savedMessage = nil }
        } message: { Text(savedMessage ?? "") }
        .confirmationDialog("Discard unsaved changes?", isPresented: Binding(get: { pendingNavigation != nil }, set: { if !$0 { pendingNavigation = nil } }), titleVisibility: .visible) {
            Button("Discard Changes", role: .destructive) { applyPendingNavigation() }
            Button("Keep Editing", role: .cancel) { pendingNavigation = nil }
        } message: { Text("Your changes haven’t been saved. Discard them and continue?") }
        .onChange(of: section) { _, _ in selectedID = nil; creating = false }
        .task(id: selectedID) { await loadSelectedRevision() }
    }

    private var availableSections: [ManagementSection] {
        initialTab == .apps ? [.apps] : [.identities, .websites, .socialAccounts]
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
        case .socialAccounts: "bubble.left.and.bubble.right"
        }
    }

    private var rows: [ManagementRow] {
        switch section {
        case .apps:
            snapshot.apps.map { ManagementRow(id: $0.id, title: $0.name, subtitle: $0.platforms.joined(separator: ", "), symbol: "app.dashed") }
        case .identities:
            snapshot.identities.map { ManagementRow(id: $0.id, title: $0.name, subtitle: $0.kind ?? "", symbol: "person.crop.circle") }
        case .websites:
            snapshot.websites.map { record in
                ManagementRow(id: record.id, title: record.name, subtitle: "\(ownerName(record.owner)) · \(record.baseURL.absoluteString)", symbol: "globe")
            }
        case .socialAccounts:
            snapshot.socialAccounts.map { record in
                let account = [record.platform, record.handle].compactMap { $0 }.joined(separator: " · ")
                return ManagementRow(id: record.id, title: account.isEmpty ? "Unconfigured account" : account, subtitle: record.owner.map(ownerName) ?? "Owner not set", symbol: "bubble.left.and.bubble.right")
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
        }
    }

    @ViewBuilder private func editor(for record: AppRecord?) -> some View {
        AppRecordEditor(record: record, identities: snapshot.identities, websites: snapshot.websites, snapshot: snapshot, workspaceStore: store, onOpenMarketingContent: onOpenMarketingContent, onSnapshotChanged: onSnapshotChanged, onDirtyChange: setDirty, onSave: { await save($0, category: "Apps", name: $0.name, expectedRevision: loadedRevision) }).id(record?.id ?? "new-app")
    }
    @ViewBuilder private func editor(for record: IdentityRecord?) -> some View {
        IdentityRecordEditor(record: record, onDirtyChange: setDirty, onSave: { await save($0, category: "Identities", name: $0.name, expectedRevision: loadedRevision) }).id(record?.id ?? "new-identity")
    }
    @ViewBuilder private func editor(for record: WebsiteRecord?) -> some View {
        WebsiteRecordEditor(record: record, owners: ownerChoices, onDirtyChange: setDirty, onSave: { await save($0, category: "Websites", name: $0.name, expectedRevision: loadedRevision) }).id(record?.id ?? "new-website")
    }
    @ViewBuilder private func editor(for record: SocialAccountRecord?) -> some View {
        SocialAccountRecordEditor(record: record, owners: ownerChoices, onDirtyChange: setDirty, onSave: { await save($0, category: "SocialAccounts", name: $0.platform, expectedRevision: loadedRevision) }).id(record?.id ?? "new-social-account")
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

    private func requestSection(_ value: ManagementSection) {
        guard value != section else { return }
        requestNavigation(.section(value))
    }

    private func requestSelection(_ value: String?) {
        guard value != selectedID else { return }
        requestNavigation(.selection(value))
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
        case .section(let next): section = next; selectedID = nil; creating = false
        case .selection(let next): selectedID = next; creating = false
        case .create: selectedID = nil; creating = true
        }
        setDirty(false)
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
            saveError = error.localizedDescription
            return false
        }
    }

    private func loadSelectedRevision() async {
        loadedRevision = nil
        revisionMismatch = false
        guard !creating, let selectedID else { return }
        let category: String
        switch section {
        case .apps: category = "Apps"
        case .identities: category = "Identities"
        case .websites: category = "Websites"
        case .socialAccounts: category = "SocialAccounts"
        }
        guard let path = Self.findRecordPath(root: store.rootURL, category: category, id: selectedID) else { revisionMismatch = snapshotContains(id: selectedID, category: category); return }
        do {
            let file = try await store.read(relativePath: path)
            guard snapshotMatches(id: selectedID, category: category, data: file.data) else {
                revisionMismatch = true
                saveError = "This record changed on disk after the workspace was loaded. Refresh the workspace before editing."
                return
            }
            loadedRevision = file.revision
        }
        catch { saveError = error.localizedDescription }
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

    private static func findRecordPath(root: URL, category: String, id: String) -> String? {
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

    private static func slug(_ text: String) -> String {
        let pieces = text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let value = pieces.prefix(8).joined(separator: "-")
        return value.isEmpty ? "record" : value
    }
}

private enum PendingManagementNavigation {
    case section(ManagementSection)
    case selection(String?)
    case create
}

private struct ManagementRow: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
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
    @State private var developerID = ""
    @State private var platforms = ""
    @State private var projectPath = ""
    @State private var projectURL: URL?
    @State private var projectAvailable = false
    @State private var projectMessage: String?
    @State private var draftID = UUID().uuidString.lowercased()
    @State private var repositoryURL = ""
    @State private var appStoreURL = ""
    @State private var links: [AppWebsiteLink] = []
    @State private var saving = false
    @State private var detailTab = "Overview"
    @State private var overviewIsDirty = false
    @State private var releaseIsDirty = false
    @State private var fileMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            Picker("App detail", selection: $detailTab) {
                Text("Overview").tag("Overview")
                Text("Releases").tag("Releases")
                Text("Marketing").tag("Marketing")
                Text("Files").tag("Files")
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 420)
            .padding(.vertical, 10)

            ZStack {
                overviewForm
                    .opacity(detailTab == "Overview" ? 1 : 0)
                    .allowsHitTesting(detailTab == "Overview")
                    .accessibilityHidden(detailTab != "Overview")
                if let appFolderRelativePath {
                    ReleasesView(appID: record?.id ?? draftID, appName: name.isEmpty ? "App" : name, appFolderRelativePath: appFolderRelativePath, workspaceStore: workspaceStore, onDirtyStateChange: reportReleaseDirty)
                        .id(record?.id ?? draftID)
                        .opacity(detailTab == "Releases" ? 1 : 0)
                        .allowsHitTesting(detailTab == "Releases")
                        .accessibilityHidden(detailTab != "Releases")
                } else {
                    ContentUnavailableView("Save App First", systemImage: "tag", description: Text("Save the app overview before adding releases."))
                        .opacity(detailTab == "Releases" ? 1 : 0)
                        .allowsHitTesting(detailTab == "Releases")
                        .accessibilityHidden(detailTab != "Releases")
                }
                if let appID = record?.id {
                    AppMarketingContentPanel(
                        appID: appID, appName: name, snapshot: snapshot, store: workspaceStore,
                        actionsEnabled: !overviewIsDirty && !releaseIsDirty,
                        onOpen: onOpenMarketingContent, onCreated: onSnapshotChanged
                    )
                    .opacity(detailTab == "Marketing" ? 1 : 0)
                    .allowsHitTesting(detailTab == "Marketing")
                    .accessibilityHidden(detailTab != "Marketing")
                } else {
                    ContentUnavailableView("Save App First", systemImage: "megaphone", description: Text("Save the app overview before creating related marketing content."))
                        .opacity(detailTab == "Marketing" ? 1 : 0)
                        .allowsHitTesting(detailTab == "Marketing")
                        .accessibilityHidden(detailTab != "Marketing")
                }
                appFilesPanel
                    .opacity(detailTab == "Files" ? 1 : 0)
                    .allowsHitTesting(detailTab == "Files")
                    .accessibilityHidden(detailTab != "Files")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(record == nil ? "New App" : name)
        .onAppear(perform: load)
        .onChange(of: draftRecord) { _, _ in reportOverviewDirty(isDirty) }
    }

    private func reportOverviewDirty(_ value: Bool) {
        overviewIsDirty = value
        onDirtyChange(overviewIsDirty || releaseIsDirty)
    }

    private func reportReleaseDirty(_ value: Bool) {
        releaseIsDirty = value
        onDirtyChange(overviewIsDirty || releaseIsDirty)
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
                TextField("Name", text: $name)
                Picker("Developer identity", selection: $developerID) {
                    Text("None").tag("")
                    ForEach(identities) { Text($0.name).tag($0.id) }
                }
                TextField("Platforms (comma separated)", text: $platforms, prompt: Text("macOS, iOS"))
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
            }
            Section("Links") {
                TextField("Repository URL", text: $repositoryURL)
                TextField("App Store URL", text: $appStoreURL)
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
    }

    /// Resolve by stable record ID so renaming the app folder or title does not strand releases.
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
                Button("Save App") { Task { await save() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
            }
        }
    }
    private func load() {
        guard let record else { return }
        name = record.name; developerID = record.developerIdentityId ?? ""; platforms = record.platforms.joined(separator: ", ")
        draftID = record.id
        projectPath = record.projectPath ?? ""; repositoryURL = record.repositoryURL?.absoluteString ?? ""; appStoreURL = record.appStoreURL?.absoluteString ?? ""; links = record.websiteLinks
        resolveProjectLocation()
    }
    private func save() async {
        saving = true; defer { saving = false }
        if await onSave(draftRecord) { reportOverviewDirty(false) }
    }

    private var draftRecord: AppRecord {
        AppRecord(id: record?.id ?? draftID, name: name.trimmingCharacters(in: .whitespacesAndNewlines), developerIdentityId: developerID.isEmpty ? nil : developerID, platforms: platforms.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }, projectPath: projectPath.isEmpty ? nil : projectPath, repositoryURL: optionalWebURL(repositoryURL), appStoreURL: optionalWebURL(appStoreURL), websiteLinks: links)
    }

    private var isDirty: Bool {
        if let record { return draftRecord != record }
        return !draftRecord.name.isEmpty || developerID != "" || !platforms.isEmpty || !projectPath.isEmpty || !repositoryURL.isEmpty || !appStoreURL.isEmpty || !links.isEmpty
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
            UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
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
        guard let bookmark = UserDefaults.standard.data(forKey: bookmarkKey) else {
            projectURL = nil; projectAvailable = false
            projectMessage = "Access to this location is unavailable. Relink the project to continue."
            return
        }
        do {
            var isStale = false
            let url = try URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)
            let hasAccess = url.startAccessingSecurityScopedResource()
            defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
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
                UserDefaults.standard.set(refreshed, forKey: bookmarkKey)
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
    let onDirtyChange: (Bool) -> Void
    let onSave: (IdentityRecord) async -> Bool
    @State private var name = ""
    @State private var kind = "Personal"
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
            Section { HStack { Spacer(); Button("Save Identity") { Task { await save() } }.buttonStyle(.borderedProminent).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving) } }
        }
        .formStyle(.grouped)
        .navigationTitle(record == nil ? "New Identity" : name)
        .onAppear { if let record { name = record.name; kind = record.kind ?? "Personal" } }
        .onChange(of: name) { _, _ in onDirtyChange(isDirty) }
        .onChange(of: kind) { _, _ in onDirtyChange(isDirty) }
    }
    private func save() async {
        saving = true; defer { saving = false }
        if await onSave(IdentityRecord(id: record?.id ?? UUID().uuidString.lowercased(), name: name.trimmingCharacters(in: .whitespacesAndNewlines), kind: kind)) { onDirtyChange(false) }
    }
    private var isDirty: Bool { record.map { $0.name != name.trimmingCharacters(in: .whitespacesAndNewlines) || ($0.kind ?? "Personal") != kind } ?? (!name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || kind != "Personal") }
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
    let record: SocialAccountRecord?
    let owners: [OwnerChoice]
    let onDirtyChange: (Bool) -> Void
    let onSave: (SocialAccountRecord) async -> Bool
    @State private var platform = "Threads"
    @State private var customPlatform = ""
    @State private var ownerID = ""
    @State private var handle = ""
    @State private var profileURL = ""
    @State private var enabled = true
    @State private var saving = false
    private let platforms = ["Threads", "Instagram", "X", "Facebook", "LinkedIn", "Other"]
    private var platformValue: String { platform == "Other" ? customPlatform : platform }
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
                TextField("Profile URL", text: $profileURL)
                Toggle("Enabled for new posts", isOn: $enabled)
                Text("A new post can use this account when it is enabled, has an owner, and has a platform plus a handle or profile URL.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section { HStack { Spacer(); Button("Save Social Account") { Task { await save() } }.buttonStyle(.borderedProminent).disabled(platformValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || ownerID.isEmpty || (handle.isEmpty && profileURL.isEmpty) || saving) } }
        }
        .formStyle(.grouped)
        .navigationTitle(record == nil ? "New Social Account" : platformValue)
        .onAppear(perform: load)
        .onChange(of: dirtySignature) { _, _ in onDirtyChange(isDirty) }
    }
    private func load() {
        guard let record else { ownerID = owners.first?.id ?? ""; return }
        platform = platforms.contains(record.platform) ? record.platform : "Other"
        customPlatform = platforms.contains(record.platform) ? "" : record.platform
        ownerID = record.owner.map { "\($0.type.rawValue):\($0.id)" } ?? ""
        handle = record.handle ?? ""; profileURL = record.profileURL?.absoluteString ?? ""; enabled = record.enabled
    }
    private func save() async {
        guard let choice = owners.first(where: { $0.id == ownerID }) else { return }
        saving = true; defer { saving = false }
        if await onSave(SocialAccountRecord(id: record?.id ?? UUID().uuidString.lowercased(), platform: platformValue.trimmingCharacters(in: .whitespacesAndNewlines), owner: choice.owner, handle: handle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : handle.trimmingCharacters(in: .whitespacesAndNewlines), profileURL: optionalWebURL(profileURL), enabled: enabled)) { onDirtyChange(false) }
    }
    private var dirtySignature: String { "\(platform)|\(customPlatform)|\(ownerID)|\(handle)|\(profileURL)|\(enabled)" }
    private var isDirty: Bool {
        if let record {
            let savedPlatform = platforms.contains(record.platform) ? record.platform : "Other"
            let savedCustomPlatform = platforms.contains(record.platform) ? "" : record.platform
            return platform != savedPlatform || customPlatform != savedCustomPlatform || ownerID != (record.owner.map { "\($0.type.rawValue):\($0.id)" } ?? "") || handle != (record.handle ?? "") || profileURL != (record.profileURL?.absoluteString ?? "") || enabled != record.enabled
        }
        return platform != "Threads" || !customPlatform.isEmpty || ownerID != (owners.first?.id ?? "") || !handle.isEmpty || !profileURL.isEmpty || !enabled
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
                Label("Save or discard app and release changes before opening or creating marketing content.", systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            }
            if records.isEmpty {
                ContentUnavailableView("No Marketing Content", systemImage: "megaphone", description: Text("Create an article, social post, or idea for this app."))
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
