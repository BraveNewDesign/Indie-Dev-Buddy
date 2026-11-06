import SwiftUI
import AppKit

/// Stores security-scoped bookmark blobs in the app's container instead of UserDefaults.
/// Older builds used defaults; reads migrate those values after the file write succeeds.
enum LocalBookmarkStore {
    static func bookmark(forKey key: String) throws -> Data? {
        let url = try storeURL(createDirectory: false)
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            guard let bookmarks = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Data] else {
                throw CocoaError(.propertyListReadCorrupt)
            }
            return bookmarks[key]
        }
        guard let legacy = UserDefaults.standard.data(forKey: key) else { return nil }
        try setBookmark(legacy, forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        return legacy
    }

    static func setBookmark(_ bookmark: Data?, forKey key: String) throws {
        let url = try storeURL(createDirectory: true)
        var bookmarks: [String: Data] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            let existing = try Data(contentsOf: url)
            guard let decoded = try PropertyListSerialization.propertyList(from: existing, options: [], format: nil) as? [String: Data] else {
                throw CocoaError(.propertyListReadCorrupt)
            }
            bookmarks = decoded
        }
        bookmarks[key] = bookmark
        let encoded = try PropertyListSerialization.data(fromPropertyList: bookmarks, format: .binary, options: 0)
        try encoded.write(to: url, options: .atomic)
    }

    private static func storeURL(createDirectory: Bool) throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: createDirectory)
        let directory = support.appendingPathComponent("Indie Dev Buddy", isDirectory: true)
        if createDirectory { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        return directory.appendingPathComponent("ExternalFileBookmarks.plist")
    }
}

@MainActor @Observable final class WorkspaceSession {
    var store: WorkspaceStore?
    var snapshot: WorkspaceSnapshot?
    var error: String?
    var workspaceURL: URL?
    private var accessURL: URL?

    func restore() {
        do {
            guard let data = try LocalBookmarkStore.bookmark(forKey: "workspaceBookmark") else { return }
            var stale = false
            let url = try URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
            guard !stale else { error = "Workspace access needs to be renewed. Choose the folder again."; return }
            open(url)
        } catch { self.error = "Could not reopen the workspace: \(error.localizedDescription)" }
    }
    func choose(create: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = create ? "Create Workspace" : "Open Workspace"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if create {
            let scoped = url.startAccessingSecurityScopedResource()
            Task {
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do { let newStore = WorkspaceStore(rootURL: url); try await newStore.createWorkspace(at: url); open(url) }
                catch { self.error = error.localizedDescription }
            }
        } else { open(url) }
    }
    func open(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        let newStore = WorkspaceStore(rootURL: url)
        Task {
            do {
                let loaded = try await newStore.load()
                let bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                try LocalBookmarkStore.setBookmark(bookmark, forKey: "workspaceBookmark")
                if let previous = store { await previous.stopWatching() }
                accessURL?.stopAccessingSecurityScopedResource()
                accessURL = scoped ? url : nil
                workspaceURL = url; store = newStore; snapshot = loaded
                await newStore.startWatching { [weak self] in Task { @MainActor in self?.refresh() } }
            } catch {
                if scoped { url.stopAccessingSecurityScopedResource() }
                self.error = error.localizedDescription
            }
        }
    }
    func refresh() {
        guard let store else { return }
        Task { do { snapshot = try await store.load() } catch { self.error = error.localizedDescription } }
    }
}

struct ContentView: View {
    @State private var session = WorkspaceSession()
    @State private var section = "Apps"
    @State private var hasUnsavedEdits = false
    @State private var pendingWorkspaceChange = false
    @State private var marketingSelectionID: String?
    @State private var contentCreateRequest: ContentKind?
    @State private var managementSelectionRequest: ManagementRecordSelection?
    @State private var managementCreateRequest: ManagementCreateRequest?
    @State private var pendingRootAction: RootAction?
    @State private var searchText = ""
    @State private var selectedAppID: String?
    @State private var appsExpanded = true
    @FocusState private var searchFocused: Bool

    private enum RootAction {
        case section(String)
        case content(String)
        case management(ManagementRecordSelection)
        case createContent(ContentKind)
        case createManagement(ManagementCreateRequest)
    }

    private struct SearchResult: Identifiable {
        let id: String
        let title: String
        let detail: String
        let symbol: String
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
                            List(selection: Binding(get: { section == "Apps" ? (selectedAppID ?? section) : section }, set: { newValue in
                                guard let newValue else { return }
                                if snapshot.apps.contains(where: { $0.id == newValue }) {
                                    requestRootAction(.management(ManagementRecordSelection(type: .app, id: newValue)))
                                } else if newValue != section {
                                    requestRootAction(.section(newValue))
                                }
                            })) {
                                DisclosureGroup(isExpanded: $appsExpanded) {
                                    if snapshot.apps.isEmpty {
                                        Text("No apps yet")
                                            .foregroundStyle(.secondary)
                                    } else {
                                        ForEach(snapshot.apps) { app in
                                            Label(app.name, systemImage: "app.dashed")
                                                .tag(app.id)
                                        }
                                    }
                                } label: {
                                    Label("Apps", systemImage: "square.stack.3d.up").tag("Apps")
                                }
                                Label("Marketing Content", systemImage: "megaphone").tag("Marketing Content")
                                Label("Websites & Social Accounts", systemImage: "globe").tag("Websites & Social Accounts")
                                Label("Files", systemImage: "folder").tag("Files")
                            }
                        } else if searchResults(snapshot).isEmpty {
                            ContentUnavailableView.search(text: searchText)
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
                                            Image(systemName: result.symbol).foregroundStyle(.secondary)
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
                    .navigationSplitViewColumnWidth(min: 200, ideal: 260)
                } detail: {
                    VStack(spacing: 0) {
                        if !snapshot.errors.isEmpty {
                            DisclosureGroup("\(snapshot.errors.count) workspace file issue(s)") {
                                ForEach(snapshot.errors) { issue in Text("\(issue.path): \(issue.message)").textSelection(.enabled) }
                            }.padding().background(.orange.opacity(0.12))
                        }
                        switch section {
                        case "Marketing Content": ContentLibraryView(snapshot: snapshot, store: store, refresh: session.refresh, initialSelectionID: marketingSelectionID, onUnsavedChangesChange: { hasUnsavedEdits = $0 }, initialCreateKind: contentCreateRequest, onCreateRequestHandled: { contentCreateRequest = nil })
                        case "Files": WorkspaceFilesBrowser(root: store.rootURL)
                        default: ManagementWorkspaceView(initialTab: section == "Apps" ? .apps : .websitesAndSocialAccounts, snapshot: snapshot, store: store, onSnapshotChanged: session.refresh, onUnsavedEditsChanged: { hasUnsavedEdits = $0 }, onOpenMarketingContent: { id in requestRootAction(.content(id)); session.refresh() }, selectionRequest: managementSelectionRequest, createRequest: managementCreateRequest, onExternalRequestHandled: { managementSelectionRequest = nil; managementCreateRequest = nil }).id(section)
                        }
                    }
                    .toolbar {
                        ToolbarItem {
                            Button("Search", systemImage: "magnifyingglass") { searchFocused = true }
                                .help("Search the workspace (⌘F)")
                                .keyboardShortcut("f", modifiers: .command)
                        }
                        ToolbarItem(placement: .primaryAction) {
                            Menu {
                                Button("App", systemImage: "app") { requestCreateManagement(.app) }
                                Button("Blog Article", systemImage: "doc.text") { requestCreateContent(.blog) }
                                    .keyboardShortcut("n", modifiers: .command)
                                    .help("Create a blog article (⌘N)")
                                Button("Social Post", systemImage: "bubble.left.and.bubble.right") { requestCreateContent(.social) }
                                Button("Idea", systemImage: "lightbulb") { requestCreateContent(.idea) }
                                Divider()
                                Button("Website", systemImage: "globe") { requestCreateManagement(.website) }
                                Button("Social Account", systemImage: "person.crop.circle.badge.plus") { requestCreateManagement(.socialAccount) }
                            } label: { Label("Create", systemImage: "plus") }
                                .help("Create a workspace record")
                        }
                        ToolbarItem { Button("Refresh", systemImage: "arrow.clockwise", action: session.refresh) }
                        ToolbarItem { Button("Choose Workspace", systemImage: "folder", action: { if hasUnsavedEdits { pendingWorkspaceChange = true } else { session.choose(create: false) } }) }
                    }
                }
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "folder.badge.gearshape").font(.system(size: 48)).foregroundStyle(.tint)
                    Text("Welcome to Indie Dev Buddy").font(.largeTitle.bold())
                    Text("Your information is saved as ordinary files in this folder. You can edit it with other apps and AI tools.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 430)
                    HStack { Button("Choose a Workspace Folder") { session.choose(create: false) }; Button("Create New Workspace") { session.choose(create: true) }.buttonStyle(.borderedProminent) }
                }.padding(40).frame(minWidth: 620, minHeight: 420)
            }
        }
        .confirmationDialog("Discard unsaved changes?", isPresented: Binding(get: { pendingRootAction != nil || pendingWorkspaceChange }, set: { if !$0 { pendingRootAction = nil; pendingWorkspaceChange = false } })) {
            Button("Discard Changes", role: .destructive) {
                hasUnsavedEdits = false
                if let pendingRootAction {
                    self.pendingRootAction = nil
                    applyRootAction(pendingRootAction)
                } else if pendingWorkspaceChange { session.choose(create: false) }
                pendingWorkspaceChange = false
            }
            Button("Keep Editing", role: .cancel) { pendingRootAction = nil; pendingWorkspaceChange = false }
        } message: { Text("Save your changes before leaving this editor, or discard them.") }
        .task { session.restore() }
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
        case .section(let value): section = value; selectedAppID = nil; managementSelectionRequest = nil
        case .content(let id): section = "Marketing Content"; selectedAppID = nil; marketingSelectionID = id
        case .management(let selection):
            section = selection.type == .app ? "Apps" : "Websites & Social Accounts"
            selectedAppID = selection.type == .app ? selection.id : nil
            managementSelectionRequest = selection
        case .createContent(let kind): section = "Marketing Content"; selectedAppID = nil; contentCreateRequest = kind
        case .createManagement(let kind):
            section = kind == .app ? "Apps" : "Websites & Social Accounts"
            selectedAppID = nil
            managementCreateRequest = kind
        }
    }

    private func requestCreateContent(_ kind: ContentKind) {
        if section == "Marketing Content" { contentCreateRequest = kind }
        else { requestRootAction(.createContent(kind)) }
    }

    private func requestCreateManagement(_ kind: ManagementCreateRequest) {
        let target = kind == .app ? "Apps" : "Websites & Social Accounts"
        if section == target { managementCreateRequest = kind; selectedAppID = nil }
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
            let target = selection.type == .app ? "Apps" : "Websites & Social Accounts"
            if section == target {
                selectedAppID = selection.type == .app ? selection.id : nil
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
            SearchResult(id: "account:\($0.id)", title: [$0.platform, $0.handle].compactMap { $0 }.joined(separator: " · "), detail: "Social Account", symbol: "bubble.left.and.bubble.right", destination: .management(ManagementRecordSelection(type: .socialAccount, id: $0.id)))
        }
        results += snapshot.content.filter { matches($0.title, $0.kind.rawValue, $0.status.rawValue) }.map {
            SearchResult(id: "content:\($0.id)", title: $0.title, detail: "\($0.kind.rawValue.capitalized) · \($0.status.rawValue.capitalized)", symbol: $0.kind == .blog ? "doc.text" : $0.kind == .social ? "bubble.left.and.bubble.right" : "lightbulb", destination: .content($0.id))
        }
        return Array(results.prefix(60))
    }
}
