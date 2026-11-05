import SwiftUI
import AppKit

@MainActor @Observable final class WorkspaceSession {
    var store: WorkspaceStore?
    var snapshot: WorkspaceSnapshot?
    var error: String?
    var workspaceURL: URL?
    private var accessURL: URL?

    func restore() {
        guard let data = UserDefaults.standard.data(forKey: "workspaceBookmark") else { return }
        do {
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
                if let previous = store { await previous.stopWatching() }
                accessURL?.stopAccessingSecurityScopedResource()
                accessURL = scoped ? url : nil
                workspaceURL = url; store = newStore; snapshot = loaded
                UserDefaults.standard.set(bookmark, forKey: "workspaceBookmark")
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
    @State private var pendingSection: String?
    @State private var pendingWorkspaceChange = false
    @State private var marketingSelectionID: String?
    var body: some View {
        Group {
            if let snapshot = session.snapshot, let store = session.store {
                NavigationSplitView {
                    List(selection: Binding(get: { section }, set: { newValue in
                        if newValue != section { if hasUnsavedEdits { pendingSection = newValue } else { section = newValue } }
                    })) {
                        Label("Apps", systemImage: "square.stack.3d.up").tag("Apps")
                        Label("Marketing Content", systemImage: "megaphone").tag("Marketing Content")
                        Label("Websites & Social Accounts", systemImage: "globe").tag("Websites & Social Accounts")
                        Label("Files", systemImage: "folder").tag("Files")
                    }.navigationSplitViewColumnWidth(min: 200, ideal: 230)
                } detail: {
                    VStack(spacing: 0) {
                        if !snapshot.errors.isEmpty {
                            DisclosureGroup("\(snapshot.errors.count) workspace file issue(s)") {
                                ForEach(snapshot.errors) { issue in Text("\(issue.path): \(issue.message)").textSelection(.enabled) }
                            }.padding().background(.orange.opacity(0.12))
                        }
                        switch section {
                        case "Marketing Content": ContentLibraryView(snapshot: snapshot, store: store, refresh: session.refresh, initialSelectionID: marketingSelectionID, onUnsavedChangesChange: { hasUnsavedEdits = $0 })
                        case "Files": WorkspaceFilesBrowser(root: store.rootURL)
                        default: ManagementWorkspaceView(initialTab: section == "Apps" ? .apps : .websitesAndSocialAccounts, snapshot: snapshot, store: store, onSnapshotChanged: session.refresh, onUnsavedEditsChanged: { hasUnsavedEdits = $0 }, onOpenMarketingContent: { id in marketingSelectionID = id; section = "Marketing Content"; session.refresh() }).id(section)
                        }
                    }
                    .toolbar {
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
        .confirmationDialog("Discard unsaved changes?", isPresented: Binding(get: { pendingSection != nil || pendingWorkspaceChange }, set: { if !$0 { pendingSection = nil; pendingWorkspaceChange = false } })) {
            Button("Discard Changes", role: .destructive) {
                hasUnsavedEdits = false
                if let pendingSection { section = pendingSection }
                else if pendingWorkspaceChange { session.choose(create: false) }
                pendingSection = nil; pendingWorkspaceChange = false
            }
            Button("Keep Editing", role: .cancel) { pendingSection = nil; pendingWorkspaceChange = false }
        } message: { Text("Save your changes before leaving this editor, or discard them.") }
        .task { session.restore() }
        .alert("Workspace", isPresented: Binding(get: { session.error != nil }, set: { if !$0 { session.error = nil } })) {
            Button("OK") { session.error = nil }
        } message: { Text(session.error ?? "") }
    }
}
