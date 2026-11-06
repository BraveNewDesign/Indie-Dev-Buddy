import SwiftUI
import AppKit

@MainActor @Observable final class WorkspaceSession {
    var store: WorkspaceStore?
    var snapshot: WorkspaceSnapshot?
    var snapshotGeneration = 0
    var error: String?
    var workspaceURL: URL?
    var knownWorkspaces: [URL] = []

    func restore() {
        do {
            let saved = try WorkspaceRegistry.workspaces()
            knownWorkspaces = saved
            if let workspace = saved.first { open(workspace) }
        } catch { self.error = "Could not reopen the workspace: \(error.localizedDescription)" }
    }
    func choose(create: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = create ? "Choose Save Location" : "Open Workspace"
        panel.message = create
            ? "Choose where to save the workspace. Indie Dev Buddy will create a new “Indie Dev Buddy Workspace” folder inside the selected folder."
            : "Choose an existing Indie Dev Buddy workspace folder."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if create {
            Task {
                do {
                    let baseName = "Indie Dev Buddy Workspace"
                    var destination = url.appendingPathComponent(baseName, isDirectory: true)
                    var suffix = 2
                    while FileManager.default.fileExists(atPath: destination.path) {
                        destination = url.appendingPathComponent("\(baseName) \(suffix)", isDirectory: true)
                        suffix += 1
                    }
                    let newStore = WorkspaceStore(rootURL: destination)
                    _ = try await newStore.createWorkspace(at: destination, name: destination.lastPathComponent)
                    open(destination)
                }
                catch { self.error = error.localizedDescription }
            }
        } else { open(url) }
    }
    func open(_ url: URL) {
        let newStore = WorkspaceStore(rootURL: url)
        Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await newStore.load()
                try WorkspaceRegistry.addWorkspace(url)
                knownWorkspaces = try WorkspaceRegistry.workspaces()
                if let previous = store { await previous.stopWatching() }
                workspaceURL = url
                store = newStore
                snapshot = loaded
                snapshotGeneration &+= 1
                await newStore.startWatching { [weak self] in Task { @MainActor in self?.refresh() } }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
    func forget(_ url: URL) {
        Task {
            if workspaceURL?.standardizedFileURL.path == url.standardizedFileURL.path {
                if let store { await store.stopWatching() }
                self.workspaceURL = nil
                self.store = nil
                snapshot = nil
            }
            try? WorkspaceRegistry.removeWorkspace(url)
            knownWorkspaces = (try? WorkspaceRegistry.workspaces()) ?? []
        }
    }
    func refresh() {
        guard let store else { return }
        Task {
            do {
                snapshot = try await store.load()
                snapshotGeneration &+= 1
            } catch { self.error = error.localizedDescription }
        }
    }
    func reload() async {
        guard let store else { return }
        do {
            snapshot = try await store.load()
            snapshotGeneration &+= 1
        } catch { self.error = error.localizedDescription }
    }
}

struct ContentView: View {
    @State private var session = WorkspaceSession()
    @AppStorage("rootSection") private var section = "Apps"
    @State private var hasUnsavedEdits = false
    @State private var pendingWorkspaceChange = false
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
                NavigationSplitView {
                    Group {
                        if searchText.isEmpty {
                            List(selection: Binding(get: { Optional(section) }, set: { (selection: String?) in
                                if let value = selection, value != section { requestRootAction(.section(value)) }
                            })) {
                                Label("Apps", systemImage: "square.stack.3d.up")
                                    .badge(snapshot.apps.count).tag("Apps")
                                Label("Marketing Content", systemImage: "megaphone")
                                    .badge(snapshot.content.count).tag("Marketing Content")
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        if section == "Marketing Content" { requestRootAction(.showContentList) }
                                    }
                                Label("Files", systemImage: "folder").tag("Files")
                                Section("Profiles") {
                                    Label("Identities", systemImage: "person.crop.circle")
                                        .tag(ManagementSection.identities.rawValue)
                                    Label("Websites", systemImage: "globe")
                                        .tag(ManagementSection.websites.rawValue)
                                    Label("Social Accounts", systemImage: "at")
                                        .tag(ManagementSection.socialAccounts.rawValue)
                                }
                            }
                        } else if searchResults(snapshot).isEmpty {
                            ContentUnavailableView.search(text: searchText)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            List {
                            Section("Workspace Results") {
                                ForEach(searchResults(snapshot)) { result in
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
                                                SocialPlatformIcon(platform: socialPlatform, size: 20)
                                            } else {
                                                Image(systemName: result.symbol).foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            }
                        }
                    }
                    .searchable(text: $searchText, placement: .sidebar, prompt: "Search workspace")
                    .searchFocused($searchFocused)
                    .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
                } detail: {
                    VStack(spacing: 0) {
                        if !snapshot.errors.isEmpty {
                            DisclosureGroup("\(snapshot.errors.count) workspace file issue(s)") {
                                ForEach(snapshot.errors) { issue in Text("\(issue.path): \(issue.message)").textSelection(.enabled) }
                            }.padding().background(.orange.opacity(0.12))
                        }
                        switch section {
                        case "Marketing Content": ContentLibraryView(snapshot: snapshot, snapshotGeneration: session.snapshotGeneration, store: store, refresh: session.refresh, initialSelectionID: marketingSelectionID, onInitialSelectionHandled: { marketingSelectionID = nil }, listResetGeneration: contentListResetGeneration, onUnsavedChangesChange: { hasUnsavedEdits = $0 }, initialCreateKind: contentCreateRequest, onCreateRequestHandled: { contentCreateRequest = nil })
                        case "Files": WorkspaceFilesBrowser(root: store.rootURL)
                        default: ManagementWorkspaceView(section: ManagementSection(rawValue: section) ?? .apps, snapshot: snapshot, store: store, onSnapshotChanged: session.refresh, onReloadSnapshot: session.reload, onUnsavedEditsChanged: { hasUnsavedEdits = $0 }, onOpenMarketingContent: { id in requestRootAction(.content(id)); session.refresh() }, onOpenRecord: { requestRootAction(.management($0)) }, selectionRequest: managementSelectionRequest, createRequest: managementCreateRequest, onExternalRequestHandled: { managementSelectionRequest = nil; managementCreateRequest = nil }, restoredAppID: selectedAppID, onAppSelectionChange: { selectedAppID = $0 }).id(section == "Apps" ? "Apps-\(appsOverviewGeneration)" : section)
                        }
                    }
                    .toolbar {
                        ToolbarItem {
                            Menu {
                                ForEach(session.knownWorkspaces, id: \.path) { workspace in
                                    Menu(workspace.lastPathComponent) {
                                        Button("Open Workspace", systemImage: "folder") {
                                            if hasUnsavedEdits { pendingWorkspaceChange = true }
                                            else { session.open(workspace) }
                                        }
                                        Button("Remove from App", systemImage: "minus.circle", role: .destructive) {
                                            requestForgetWorkspace(workspace)
                                        }
                                    }
                                }
                                if !session.knownWorkspaces.isEmpty { Divider() }
                                Button("Refresh Workspace", systemImage: "arrow.clockwise", action: session.refresh)
                                Button("Add Existing Workspace…", systemImage: "folder.badge.plus") { session.choose(create: false) }
                                Button("Create New Workspace…", systemImage: "plus") { session.choose(create: true) }
                            } label: { Label("Workspaces", systemImage: "folder") }
                                .labelStyle(.iconOnly)
                        }
                    }
                }
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "folder.badge.gearshape").font(.system(size: 48)).foregroundStyle(.tint)
                    Text("Welcome to Indie Dev Buddy").font(.largeTitle.bold())
                    Text("Your information is saved as ordinary files in a dedicated workspace folder. When creating one, choose the parent location and Indie Dev Buddy will create the workspace folder there.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 430)
                    HStack { Button("Open Existing Workspace") { session.choose(create: false) }; Button("Create New Workspace…") { session.choose(create: true) }.buttonStyle(.borderedProminent) }
                }.padding(40).frame(minWidth: 620, minHeight: 420)
            }
        }
        .confirmationDialog("Discard unsaved changes?", isPresented: Binding(get: { pendingRootAction != nil || pendingWorkspaceChange || pendingWorkspaceToForget != nil }, set: { if !$0 { pendingRootAction = nil; pendingWorkspaceChange = false; pendingWorkspaceToForget = nil } })) {
            Button("Discard Changes", role: .destructive) {
                hasUnsavedEdits = false
                if let pendingRootAction {
                    self.pendingRootAction = nil
                    applyRootAction(pendingRootAction)
                } else if pendingWorkspaceChange { session.choose(create: false) }
                else if let workspace = pendingWorkspaceToForget { session.forget(workspace) }
                pendingWorkspaceChange = false
                pendingWorkspaceToForget = nil
            }
            Button("Keep Editing", role: .cancel) { pendingRootAction = nil; pendingWorkspaceChange = false; pendingWorkspaceToForget = nil }
        } message: { Text("Save your changes before leaving this editor, or discard them. Removing a workspace only removes it from this app; its folder and files stay where they are.") }
        .task {
            if section == "Websites & Social Accounts" {
                section = ManagementSection.websites.rawValue
            }
            session.restore()
        }
        .alert("Workspace", isPresented: Binding(get: { session.error != nil }, set: { if !$0 { session.error = nil } })) {
            Button("OK") { session.error = nil }
        } message: { Text(session.error ?? "") }
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
        if hasUnsavedEdits { pendingWorkspaceToForget = url }
        else { session.forget(url) }
    }

    private func requestCreateManagement(_ kind: ManagementCreateRequest) {
        let target = kind.section.rawValue
        if section == target { managementCreateRequest = kind }
        else { requestRootAction(.createManagement(kind)) }
    }

    private func selectSearchResult(_ result: SearchResult) {
        searchText = ""
        searchFocused = false
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
