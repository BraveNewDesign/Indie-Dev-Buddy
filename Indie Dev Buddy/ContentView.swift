import SwiftUI
import AppKit

@MainActor @Observable final class WorkspaceSession {
    var store: WorkspaceStore?
    var snapshot: WorkspaceSnapshot?
    var snapshotGeneration = 0
    var error: String?
    var workspaceURL: URL?
    var knownWorkspaces: [URL] = []
    var failedWorkspaceURL: URL?
    var workspaceOpenError: String?
    var isOpening = false

    @ObservationIgnored private var didRestore = false
    static let recentWorkspacesKey = "recentWorkspacePaths"

    static func orderedWorkspaces(_ workspaces: [URL], recentData: Data) -> [URL] {
        let recentPaths = (try? JSONDecoder().decode([String].self, from: recentData)) ?? []
        let byPath = Dictionary(workspaces.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let recent = recentPaths.compactMap { byPath[$0] }
        let recentSet = Set(recentPaths)
        return recent + workspaces.filter { !recentSet.contains($0.path) }
    }

    private func reloadKnownWorkspaces() throws {
        knownWorkspaces = Self.orderedWorkspaces(
            try WorkspaceRegistry.workspaces(),
            recentData: UserDefaults.standard.data(forKey: Self.recentWorkspacesKey) ?? Data()
        )
    }

    private func updateRecents(_ url: URL, removing: Bool = false) {
        let defaults = UserDefaults.standard
        let data = defaults.data(forKey: Self.recentWorkspacesKey) ?? Data()
        var paths = (try? JSONDecoder().decode([String].self, from: data)) ?? []
        paths.removeAll { $0 == url.path }
        if !removing { paths.insert(url.path, at: 0) }
        if let updated = try? JSONEncoder().encode(paths) {
            defaults.set(updated, forKey: Self.recentWorkspacesKey)
        }
    }

    func restore() {
        guard !didRestore else { return }
        didRestore = true
        do {
            try reloadKnownWorkspaces()
            if let workspace = knownWorkspaces.first {
                open(.existing(workspace))
            }
        } catch {
            workspaceOpenError = error.localizedDescription
        }
    }

    enum Destination {
        case existing(URL)
        case create(in: URL)

        var label: String {
            switch self {
            case .existing(let url): url.lastPathComponent
            case .create: "a new workspace"
            }
        }
    }

    func choose(create: Bool, near previousURL: URL? = nil) -> Destination? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = create
        panel.directoryURL = previousURL?.deletingLastPathComponent()
        panel.prompt = create ? "Choose Save Location" : "Open Workspace"
        panel.message = create
            ? "Choose a location for the new workspace folder."
            : "Choose an existing Indie Dev Buddy workspace folder."
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return create ? .create(in: url) : .existing(url)
    }

    func open(_ destination: Destination, onOpened: @escaping () -> Void = {}) {
        guard !isOpening else { return }
        isOpening = true
        workspaceOpenError = nil
        failedWorkspaceURL = nil
        Task { [self] in
            defer { isOpening = false }
            var url: URL
            switch destination {
            case .existing(let existing):
                url = existing.standardizedFileURL
            case .create(let parent):
                let baseName = "Indie Dev Buddy Workspace"
                url = parent.appendingPathComponent(baseName, isDirectory: true)
                var suffix = 2
                while FileManager.default.fileExists(atPath: url.path) {
                    url = parent.appendingPathComponent("\(baseName) \(suffix)", isDirectory: true)
                    suffix += 1
                }
            }
            let newStore = WorkspaceStore(rootURL: url)
            do {
                if case .create = destination {
                    _ = try await newStore.createWorkspace(at: url, name: url.lastPathComponent)
                }
                let loaded = try await newStore.load()
                try WorkspaceRegistry.addWorkspace(url)
                updateRecents(url)
                try reloadKnownWorkspaces()
                if let previous = store { await previous.stopWatching() }
                onOpened()
                workspaceURL = url
                store = newStore
                snapshot = loaded
                snapshotGeneration &+= 1
                await newStore.startWatching { [weak self] in Task { @MainActor in self?.refresh() } }
            } catch {
                if store == nil {
                    failedWorkspaceURL = url
                    workspaceOpenError = error.localizedDescription
                } else {
                    self.error = "Could not open \(url.lastPathComponent). \(error.localizedDescription)"
                }
            }
        }
    }
    func forget(_ url: URL, onRemoved: @escaping () -> Void) {
        guard !isOpening else { return }
        isOpening = true
        Task {
            defer { isOpening = false }
            do {
                try WorkspaceRegistry.removeWorkspace(url)
                updateRecents(url.standardizedFileURL, removing: true)
                try reloadKnownWorkspaces()
            } catch {
                self.error = "Could not remove the workspace from the app. \(error.localizedDescription)"
                return
            }
            if workspaceURL?.standardizedFileURL.path == url.standardizedFileURL.path {
                if let store { await store.stopWatching() }
                self.workspaceURL = nil
                self.store = nil
                snapshot = nil
            }
            onRemoved()
        }
    }
    func renameWorkspace(to name: String) {
        guard let store, !isOpening else { return }
        isOpening = true
        Task {
            defer { isOpening = false }
            do {
                _ = try await store.renameWorkspace(to: name)
                let loaded = try await store.load()
                guard self.store === store else { return }
                snapshot = loaded
                snapshotGeneration &+= 1
            } catch {
                self.error = "Could not rename the workspace. \(error.localizedDescription)"
            }
        }
    }
    func refresh() {
        guard let store else { return }
        Task {
            do {
                let loaded = try await store.load()
                guard self.store === store else { return }
                snapshot = loaded
                snapshotGeneration &+= 1
            } catch {
                if self.store === store { self.error = error.localizedDescription }
            }
        }
    }
    func reload() async {
        guard let store else { return }
        do {
            let loaded = try await store.load()
            guard self.store === store else { return }
            snapshot = loaded
            snapshotGeneration &+= 1
        } catch {
            if self.store === store { self.error = error.localizedDescription }
        }
    }
}

struct ContentView: View {
    @State private var session = WorkspaceSession()
    @AppStorage("rootSection") private var section = "Dashboard"
    @State private var hasUnsavedEdits = false
    @State private var pendingWorkspaceChange: WorkspaceSession.Destination?
    @State private var pendingWorkspaceSaveAction: WorkspaceSaveAction?
    @State private var savingBeforeSwitch = false
    @FocusedValue(\.workspaceSaveAction) private var workspaceSaveAction
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .automatic
    @State private var pendingWorkspaceToForget: URL?
    @AppStorage("marketingSelectionID") private var marketingSelectionID: String?
    @State private var contentCreateRequest: ContentKind?
    @State private var managementSelectionRequest: ManagementRecordSelection?
    @State private var managementCreateRequest: ManagementCreateRequest?
    @State private var pendingRootAction: RootAction?
    @State private var searchText = ""
    @AppStorage("selectedAppID") private var selectedAppID: String?
    @State private var contentListResetGeneration = 0
    @State private var appsOverviewGeneration = 0
    @FocusState private var searchFocused: Bool
    @State private var showingWorkspaceOptions = false
    @State private var showingRenameWorkspace = false
    @State private var workspaceNameDraft = ""

    private enum RootAction {
        case section(String)
        case content(String)
        case showContentList
        case management(ManagementRecordSelection)
        case createContent(ContentKind)
        case createManagement(ManagementCreateRequest)
    }

    private struct SearchResult: Identifiable {
        let id: String
        let title: String
        let detail: String
        let symbol: String
        var socialPlatform: String? = nil
        let destination: Destination

        enum Destination {
            case content(String)
            case management(ManagementRecordSelection)
        }
    }

    var body: some View {
        Group {
            if let snapshot = session.snapshot, let store = session.store {
                NavigationSplitView(columnVisibility: $sidebarVisibility) {
                    VStack(alignment: .leading, spacing: 0) {
                        sidebarNavigation(snapshot)
                            .disabled(commandActions.isBusy)
                            .frame(maxHeight: .infinity)
                        Divider()
                            .padding(.horizontal, 12)
                        workspaceSwitcher(snapshot.manifest.name)
                    }
                    .searchable(text: $searchText, placement: .sidebar, prompt: "Search workspace")
                    .searchFocused($searchFocused)
                    .controlSize(.small)
                    .onExitCommand { clearSearch() }
                    .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
                } detail: {
                    workspaceDetail(snapshot, store: store)
                        .disabled(session.isOpening || savingBeforeSwitch)
                }
                .id(store.rootURL)
            } else {
                welcomeView
            }
        }
        .focusedSceneValue(\.workspaceCommands, commandActions)
        .confirmationDialog(pendingDialogTitle, isPresented: pendingDialogPresentation, titleVisibility: .visible) {
            pendingDialogActions
        } message: {
            pendingDialogMessage
        }
        .task {
            if section == "Websites & Social Accounts" {
                section = ManagementSection.websites.rawValue
            }
            session.restore()
        }
        .alert("Workspace", isPresented: Binding(get: { session.error != nil }, set: { if !$0 { session.error = nil } })) {
            Button("OK") { session.error = nil }
        } message: { Text(session.error ?? "") }
        .alert("Rename Workspace", isPresented: $showingRenameWorkspace) {
            TextField("Workspace name", text: $workspaceNameDraft)
            Button("Rename") { session.renameWorkspace(to: workspaceNameDraft) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Choose a name shown in Indie Dev Buddy. The workspace folder stays where it is.")
        }
    }

    private var pendingDialogTitle: String {
        if let destination = pendingWorkspaceChange { return "Switch to \(destination.label)?" }
        if let workspace = pendingWorkspaceToForget { return "Remove “\(workspace.lastPathComponent)” from the app?" }
        return "Discard unsaved changes?"
    }

    private var pendingDialogPresentation: Binding<Bool> {
        Binding(
            get: { pendingRootAction != nil || pendingWorkspaceChange != nil || pendingWorkspaceToForget != nil },
            set: { if !$0 { clearPendingAction() } }
        )
    }

    @ViewBuilder private var pendingDialogActions: some View {
        if let destination = pendingWorkspaceChange {
            if let saveAction = pendingWorkspaceSaveAction ?? workspaceSaveAction {
                Button("Save and Switch") {
                    clearPendingAction()
                    savingBeforeSwitch = true
                    saveAction.perform { success in
                        savingBeforeSwitch = false
                        if success { openWorkspace(destination) }
                    }
                }
            }
            Button("Discard and Switch", role: .destructive) {
                clearPendingAction()
                openWorkspace(destination)
            }
        } else if pendingWorkspaceToForget != nil {
            Button(hasUnsavedEdits ? "Discard Changes and Remove" : "Remove Workspace",
                   role: .destructive, action: discardAndContinue)
        } else {
            Button("Discard Changes", role: .destructive, action: discardAndContinue)
        }
        Button("Cancel", role: .cancel, action: clearPendingAction)
    }

    @ViewBuilder private var pendingDialogMessage: some View {
        if hasUnsavedEdits { Text("The current editor has unsaved changes.") }
        else if pendingWorkspaceToForget != nil { Text("The workspace folder and its files stay on your Mac.") }
    }

    private var commandActions: WorkspaceCommandActions {
        WorkspaceCommandActions(
            recent: session.knownWorkspaces,
            hasWorkspace: session.store != nil,
            isBusy: session.isOpening || savingBeforeSwitch,
            open: { chooseWorkspace(create: false) },
            create: { chooseWorkspace(create: true) },
            openRecent: { requestWorkspaceChange(.existing($0)) },
            newContent: requestCreateContent,
            newRecord: requestCreateManagement,
            find: {
                sidebarVisibility = .all
                searchFocused = true
            },
            refresh: session.refresh
        )
    }

    private func workspaceSwitcher(_ name: String) -> some View {
        Button {
            showingWorkspaceOptions.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.up")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 2)
            .frame(minHeight: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .help("Switch or manage workspaces")
        .accessibilityLabel("Workspace: \(name)")
        .disabled(commandActions.isBusy)
        .popover(isPresented: $showingWorkspaceOptions, arrowEdge: .top) {
            workspaceOptions
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var workspaceOptions: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !commandActions.recent.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(commandActions.recent, id: \.path) { workspace in
                            let isCurrent = workspace.path == session.workspaceURL?.path
                            workspaceOption(workspace.lastPathComponent, symbol: isCurrent ? "checkmark" : "folder") {
                                requestWorkspaceChange(.existing(workspace))
                            }
                            .help(workspace.path)
                            .accessibilityAddTraits(isCurrent ? .isSelected : [])
                        }
                    }
                }
                .frame(maxHeight: 180)
                .fixedSize(horizontal: false, vertical: true)
                Divider()
            }
            workspaceOption("Open Workspace…", symbol: "folder", action: commandActions.open)
            workspaceOption("New Workspace…", symbol: "plus", action: commandActions.create)
            workspaceOption("Refresh Workspace", symbol: "arrow.clockwise", action: session.refresh)
            if let url = session.workspaceURL {
                workspaceOption("Rename Workspace…", symbol: "pencil") {
                    workspaceNameDraft = session.snapshot?.manifest.name ?? url.lastPathComponent
                    showingRenameWorkspace = true
                }
                workspaceOption("Show in Finder", symbol: "arrow.up.forward.app") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                Divider()
                workspaceOption("Remove Workspace from App…", symbol: "minus.circle") {
                    requestForgetWorkspace(url)
                }
            }
        }
        .padding(8)
        .frame(width: 250)
    }

    private func workspaceOption(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button {
            showingWorkspaceOptions = false
            action()
        } label: {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.borderless)
        .controlSize(.regular)
    }

    @ViewBuilder
    private func sidebarNavigation(_ snapshot: WorkspaceSnapshot) -> some View {
        if searchText.isEmpty {
            List(selection: Binding(get: { Optional(section) }, set: { (selection: String?) in
                if let value = selection, value != section { requestRootAction(.section(value)) }
            })) {
                sidebarRow("Dashboard", symbol: "rectangle.grid.2x2", destination: "Dashboard")
                Section {
                    sidebarRow("Apps", symbol: "square.stack.3d.up", destination: "Apps")
                        .badge(snapshot.apps.count)
                    sidebarRow("Websites", symbol: "globe", destination: ManagementSection.websites.rawValue)
                } header: {
                    sidebarHeader("Products")
                }
                Section {
                    sidebarRow("Content", symbol: "megaphone", destination: "Marketing Content")
                        .badge(snapshot.content.count)
                        .onTapGesture {
                            if section == "Marketing Content" { requestRootAction(.showContentList) }
                        }
                    sidebarRow("Files", symbol: "folder", destination: "Files")
                } header: {
                    sidebarHeader("Workspace")
                }
                Section {
                    sidebarRow("Identities", symbol: "person.crop.circle", destination: ManagementSection.identities.rawValue)
                    sidebarRow("Social Accounts", symbol: "at", destination: ManagementSection.socialAccounts.rawValue)
                } header: {
                    sidebarHeader("Accounts")
                }
            }
            .listStyle(.sidebar)
            .environment(\.defaultMinListRowHeight, 36)
        } else {
            let results = searchResults(snapshot)
            if results.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section {
                        ForEach(results) { result in
                            Button {
                                selectSearchResult(result)
                            } label: {
                                Label {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(result.title)
                                        Text(result.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                } icon: {
                                    if let socialPlatform = result.socialPlatform {
                                        SocialPlatformIcon(platform: socialPlatform, size: 16)
                                            .frame(width: 22)
                                    } else {
                                        SidebarIcon(symbol: result.symbol)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        sidebarHeader("Workspace Results")
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }

    private func sidebarRow(_ title: String, symbol: String, destination: String) -> some View {
        Label {
            Text(title)
                .lineLimit(1)
        } icon: {
            SidebarIcon(symbol: symbol, isSelected: section == destination)
        }
        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        .contentShape(Rectangle())
        .listRowBackground(
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary)
                .padding(.horizontal, 10)
                .opacity(section == destination ? 1 : 0)
        )
        .tag(destination)
    }

    private struct SidebarIcon: View {
        @Environment(\.backgroundProminence) private var backgroundProminence
        let symbol: String
        var isSelected = false

        var body: some View {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(color)
                .frame(width: 22)
                .accessibilityHidden(true)
        }

        private var color: Color {
            if backgroundProminence == .increased { return .primary }
            return isSelected ? .accentColor : .secondary
        }
    }

    private func sidebarHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(nil)
    }

    private func workspaceDetail(_ snapshot: WorkspaceSnapshot, store: WorkspaceStore) -> some View {
        VStack(spacing: 0) {
            if !snapshot.errors.isEmpty {
                DisclosureGroup("\(snapshot.errors.count) workspace file issue(s)") {
                    ForEach(snapshot.errors) { issue in Text("\(issue.path): \(issue.message)").textSelection(.enabled) }
                }.padding().background(.orange.opacity(0.12))
            }
            switch section {
            case "Dashboard":
                WorkspaceDashboardView(
                    snapshot: snapshot,
                    workspaceRoot: store.rootURL,
                    generation: session.snapshotGeneration,
                    openSection: { requestRootAction(.section($0)) },
                    openContent: { requestRootAction(.content($0)) },
                    openRecord: { requestRootAction(.management($0)) },
                    createContent: requestCreateContent,
                    createRecord: requestCreateManagement
                )
            case "Marketing Content":
                ContentLibraryView(
                    snapshot: snapshot,
                    snapshotGeneration: session.snapshotGeneration,
                    store: store,
                    refresh: session.refresh,
                    initialSelectionID: marketingSelectionID,
                    onInitialSelectionHandled: { marketingSelectionID = nil },
                    listResetGeneration: contentListResetGeneration,
                    onUnsavedChangesChange: { hasUnsavedEdits = $0 },
                    initialCreateKind: contentCreateRequest,
                    onCreateRequestHandled: { contentCreateRequest = nil }
                )
            case "Files":
                AssetLibraryView(store: store, snapshot: snapshot)
                    .id(store.rootURL)
                    .navigationTitle("Files")
            default:
                ManagementWorkspaceView(
                    section: ManagementSection(rawValue: section) ?? .apps,
                    snapshot: snapshot,
                    store: store,
                    onSnapshotChanged: session.refresh,
                    onReloadSnapshot: session.reload,
                    onUnsavedEditsChanged: { hasUnsavedEdits = $0 },
                    onOpenMarketingContent: { id in
                        requestRootAction(.content(id))
                        session.refresh()
                    },
                    onOpenRecord: { requestRootAction(.management($0)) },
                    selectionRequest: managementSelectionRequest,
                    createRequest: managementCreateRequest,
                    onExternalRequestHandled: {
                        managementSelectionRequest = nil
                        managementCreateRequest = nil
                    },
                    restoredAppID: selectedAppID,
                    onAppSelectionChange: { selectedAppID = $0 }
                )
                .id(section == "Apps" ? "Apps-\(appsOverviewGeneration)" : section)
            }
        }
    }

    private var welcomeView: some View {
        VStack(spacing: 16) {
            if session.isOpening {
                ProgressView("Opening Workspace…")
            } else if let error = session.workspaceOpenError {
                Image(systemName: "folder.badge.questionmark")
                    .font(.system(size: 44)).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(session.failedWorkspaceURL.map { "Can’t open “\($0.lastPathComponent)”" } ?? "Can’t restore your workspace")
                    .font(.title.bold())
                Text(error).foregroundStyle(.secondary).multilineTextAlignment(.center)
                HStack {
                    Button("Choose Another…") { chooseWorkspace(create: false) }
                    Button("Locate Workspace…") { chooseWorkspace(create: false, near: session.failedWorkspaceURL) }
                        .buttonStyle(.borderedProminent)
                }
                Button("Create Workspace…") { chooseWorkspace(create: true) }
                    .buttonStyle(.link)
            } else {
                Image(systemName: "folder.badge.gearshape")
                    .font(.system(size: 44)).foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text("Welcome to Indie Dev Buddy").font(.largeTitle.bold())
                Text("Your apps, drafts, and accounts live in a folder of ordinary files on your Mac.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                HStack {
                    Button("Open Workspace…") { chooseWorkspace(create: false) }
                    Button("Create Workspace…") { chooseWorkspace(create: true) }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .frame(maxWidth: 450)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minWidth: 520, minHeight: 360)
    }

    private func chooseWorkspace(create: Bool, near previousURL: URL? = nil) {
        guard !session.isOpening, !savingBeforeSwitch else { return }
        if let destination = session.choose(create: create, near: previousURL) {
            requestWorkspaceChange(destination)
        }
    }

    private func requestWorkspaceChange(_ destination: WorkspaceSession.Destination) {
        guard !session.isOpening, !savingBeforeSwitch else { return }
        if case .existing(let url) = destination, url.standardizedFileURL.path == session.workspaceURL?.path { return }
        if hasUnsavedEdits {
            pendingWorkspaceSaveAction = workspaceSaveAction
            pendingWorkspaceChange = destination
        } else {
            openWorkspace(destination)
        }
    }

    private func openWorkspace(_ destination: WorkspaceSession.Destination) {
        session.open(destination) {
            hasUnsavedEdits = false
            selectedAppID = nil
            marketingSelectionID = nil
            managementSelectionRequest = nil
            managementCreateRequest = nil
            contentCreateRequest = nil
            clearSearch()
        }
    }

    private func clearSearch() {
        searchText = ""
        searchFocused = false
    }

    private func clearPendingAction() {
        pendingRootAction = nil
        pendingWorkspaceChange = nil
        pendingWorkspaceSaveAction = nil
        pendingWorkspaceToForget = nil
    }

    private func discardAndContinue() {
        let action = pendingRootAction
        let workspaceToForget = pendingWorkspaceToForget
        clearPendingAction()
        if let action {
            applyRootAction(action)
        } else if let workspaceToForget {
            session.forget(workspaceToForget) {
                hasUnsavedEdits = false
            }
        }
    }

    private func requestRootAction(_ action: RootAction) {
        if hasUnsavedEdits { pendingRootAction = action }
        else { applyRootAction(action) }
    }

    private func applyRootAction(_ action: RootAction) {
        hasUnsavedEdits = false
        switch action {
        case .section(let value):
            section = value
            selectedAppID = nil
            managementSelectionRequest = nil
            if value != "Marketing Content" { marketingSelectionID = nil }
            if value == "Apps" { appsOverviewGeneration += 1 }
        case .content(let id): section = "Marketing Content"; selectedAppID = nil; marketingSelectionID = id
        case .showContentList:
            contentListResetGeneration &+= 1
        case .management(let selection):
            section = selection.type.section.rawValue
            selectedAppID = selection.type == .app ? selection.id : nil
            managementSelectionRequest = selection
        case .createContent(let kind): section = "Marketing Content"; selectedAppID = nil; contentCreateRequest = kind
        case .createManagement(let kind):
            section = kind.section.rawValue
            selectedAppID = nil
            managementCreateRequest = kind
        }
    }

    private func requestCreateContent(_ kind: ContentKind) {
        if section == "Marketing Content" { contentCreateRequest = kind }
        else { requestRootAction(.createContent(kind)) }
    }

    private func requestForgetWorkspace(_ url: URL) {
        guard !commandActions.isBusy else { return }
        pendingWorkspaceToForget = url
    }

    private func requestCreateManagement(_ kind: ManagementCreateRequest) {
        let target = kind.section.rawValue
        if section == target { managementCreateRequest = kind }
        else { requestRootAction(.createManagement(kind)) }
    }

    private func selectSearchResult(_ result: SearchResult) {
        clearSearch()
        switch result.destination {
        case .content(let id):
            if section == "Marketing Content" { marketingSelectionID = id }
            else { requestRootAction(.content(id)) }
        case .management(let selection):
            let target = selection.type.section.rawValue
            if section == target {
                managementSelectionRequest = selection
            }
            else { requestRootAction(.management(selection)) }
        }
    }

    private func searchResults(_ snapshot: WorkspaceSnapshot) -> [SearchResult] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        func matches(_ values: String...) -> Bool {
            values.contains { $0.localizedCaseInsensitiveContains(query) }
        }
        var results: [SearchResult] = []
        results += snapshot.apps.filter { matches($0.name, $0.platforms.joined(separator: " ")) }.map {
            SearchResult(id: "app:\($0.id)", title: $0.name, detail: "App · \($0.platforms.joined(separator: ", "))", symbol: "app.dashed", destination: .management(ManagementRecordSelection(type: .app, id: $0.id)))
        }
        results += snapshot.identities.filter { matches($0.name, $0.kind ?? "") }.map {
            SearchResult(id: "identity:\($0.id)", title: $0.name, detail: "Identity · \($0.kind ?? "")", symbol: "person.crop.circle", destination: .management(ManagementRecordSelection(type: .identity, id: $0.id)))
        }
        results += snapshot.websites.filter { matches($0.name, $0.baseURL.absoluteString) }.map {
            SearchResult(id: "website:\($0.id)", title: $0.name, detail: "Website · \($0.baseURL.host ?? $0.baseURL.absoluteString)", symbol: "globe", destination: .management(ManagementRecordSelection(type: .website, id: $0.id)))
        }
        results += snapshot.socialAccounts.filter { matches($0.platform, $0.handle ?? "", $0.profileURL?.absoluteString ?? "") }.map {
            SearchResult(id: "account:\($0.id)", title: [$0.platform, $0.handle].compactMap { $0 }.joined(separator: " · "), detail: "Social Account", symbol: "at", socialPlatform: $0.platform, destination: .management(ManagementRecordSelection(type: .socialAccount, id: $0.id)))
        }
        results += snapshot.content.filter { matches($0.title, $0.kind.rawValue, $0.status.rawValue) }.map {
            SearchResult(id: "content:\($0.id)", title: $0.title, detail: "\($0.kind.rawValue.capitalized) · \($0.status.rawValue.capitalized)", symbol: $0.kind == .blog ? "doc.text" : $0.kind == .social ? "bubble.left.and.bubble.right" : "lightbulb", destination: .content($0.id))
        }
        return Array(results.prefix(60))
    }

}
