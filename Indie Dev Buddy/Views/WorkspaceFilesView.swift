import AppKit
import SwiftUI

private struct WorkspaceBrowserItem: Identifiable {
    var id: String { relativePath }
    let name: String
    let relativePath: String
    let url: URL
    let isDirectory: Bool
}

/// A non-destructive browser for a user-selected workspace folder.
/// Symbolic links are shown as skipped items and are never followed.
public struct WorkspaceFilesBrowser: View {
    public let root: URL

    @State private var currentRelativePath = ""
    @State private var items: [WorkspaceBrowserItem] = []
    @State private var skippedSymlinkCount = 0
    @State private var isCreatingFolder = false
    @State private var newFolderName = ""
    @State private var renameItem: WorkspaceBrowserItem?
    @State private var renamedItemName = ""
    @State private var trashItem: WorkspaceBrowserItem?
    @State private var errorMessage: String?

    private var canonicalRoot: URL { root.standardizedFileURL.resolvingSymlinksInPath() }
    private var currentDirectoryURL: URL {
        currentRelativePath.isEmpty ? canonicalRoot : canonicalRoot.appendingPathComponent(currentRelativePath, isDirectory: true)
    }
    private var pathComponents: [String] {
        currentRelativePath.split(separator: "/").map(String.init)
    }

    public init(root: URL) {
        self.root = root
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Files").font(.largeTitle.bold())
                    Text(canonicalRoot.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                Button("Import Files", systemImage: "square.and.arrow.down") { importFiles() }
                    .disabled(!isSafeDirectory(currentDirectoryURL))
                Button("New Folder", systemImage: "folder.badge.plus") {
                    newFolderName = ""
                    isCreatingFolder = true
                }
                .disabled(!isSafeDirectory(currentDirectoryURL))
                Button("Reveal Workspace", systemImage: "arrow.up.right.square") {
                    reveal(canonicalRoot)
                }
            }

            breadcrumb

            if skippedSymlinkCount > 0 {
                Label("Skipped \(skippedSymlinkCount) symbolic link(s) to keep browsing inside this workspace.", systemImage: "link")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            List {
                if !currentRelativePath.isEmpty {
                    Button {
                        navigateUp()
                    } label: {
                        Label("Parent Folder", systemImage: "arrow.up")
                    }
                    .buttonStyle(.plain)
                }
                ForEach(items) { item in
                    HStack(spacing: 10) {
                        Image(systemName: item.isDirectory ? "folder" : fileSymbol(for: item.url))
                            .foregroundStyle(item.isDirectory ? Color.accentColor : Color.secondary)
                            .frame(width: 20)
                        if item.isDirectory {
                            Button(item.name) { navigate(to: item.relativePath) }
                                .buttonStyle(.plain)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button("Open Folder") { navigate(to: item.relativePath) }
                                .labelStyle(.iconOnly)
                                .help("Open Folder")
                                .accessibilityLabel("Open \(item.name)")
                        } else {
                            Text(item.name)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                            Button("Open") { open(item.url) }
                                .help("Open \(item.name)")
                            Button("Reveal in Finder") { reveal(item.url) }
                                .labelStyle(.iconOnly)
                                .help("Reveal \(item.name) in Finder")
                                .accessibilityLabel("Reveal \(item.name) in Finder")
                        }
                    }
                    .padding(.vertical, 3)
                    .contextMenu {
                        if item.isDirectory {
                            Button("Open Folder") { navigate(to: item.relativePath) }
                            Button("Reveal in Finder") { reveal(item.url) }
                        } else {
                            Button("Open") { open(item.url) }
                            Button("Reveal in Finder") { reveal(item.url) }
                        }
                        if canManage(item) {
                            Divider()
                            Button("Rename…") { renamedItemName = item.name; renameItem = item }
                            Button("Move to Trash…", role: .destructive) { trashItem = item }
                        }
                    }
                }
                if items.isEmpty {
                    ContentUnavailableView("This Folder Is Empty", systemImage: "folder", description: Text("Create a folder or add files with Finder or another app."))
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.inset)
        }
        .padding(24)
        .task(id: currentRelativePath) { loadDirectory() }
        .alert("Create Folder", isPresented: $isCreatingFolder) {
            TextField("Folder name", text: $newFolderName)
            Button("Create") { createFolder() }
                .disabled(!isValidFolderName(newFolderName))
            Button("Cancel", role: .cancel) { isCreatingFolder = false }
        } message: {
            Text("Create a new folder inside \(currentRelativePath.isEmpty ? "the workspace" : currentRelativePath).")
        }
        .alert("Workspace Files", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("Rename Item", isPresented: Binding(get: { renameItem != nil }, set: { if !$0 { renameItem = nil } })) {
            TextField("Name", text: $renamedItemName)
            Button("Rename") { renameSelectedItem() }.disabled(!isValidFolderName(renamedItemName))
            Button("Cancel", role: .cancel) { renameItem = nil }
        } message: {
            Text("References to this path are not updated. Check any content that uses this file after renaming it.")
        }
        .confirmationDialog("Move this item to the Trash?", isPresented: Binding(get: { trashItem != nil }, set: { if !$0 { trashItem = nil } }), titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) { trashSelectedItem() }
            Button("Cancel", role: .cancel) { trashItem = nil }
        } message: {
            Text("Content that refers to this path may no longer find it. You can restore the item from the Trash.")
        }
    }

    private var breadcrumb: some View {
        HStack(spacing: 5) {
            Button("Workspace") { navigate(to: "") }
                .buttonStyle(.link)
            ForEach(Array(pathComponents.enumerated()), id: \.offset) { index, component in
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                Button(component) {
                    navigate(to: pathComponents.prefix(index + 1).joined(separator: "/"))
                }
                .buttonStyle(.link)
            }
            Spacer()
            Button("Refresh", systemImage: "arrow.clockwise") { loadDirectory() }
                .help("Refresh this folder")
            Text("\(items.count) items")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func loadDirectory() {
        guard isSafeDirectory(currentDirectoryURL) else {
            errorMessage = "This folder is outside the selected workspace or is no longer available."
            currentRelativePath = ""
            items = []
            return
        }
        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: currentDirectoryURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            var skipped = 0
            var loaded: [WorkspaceBrowserItem] = []
            for url in urls {
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values.isSymbolicLink == true || !isInsideWorkspace(url) {
                    skipped += 1
                    continue
                }
                let relative = String(url.path.dropFirst(canonicalRoot.path.count + 1))
                loaded.append(WorkspaceBrowserItem(name: url.lastPathComponent, relativePath: relative, url: url, isDirectory: values.isDirectory == true))
            }
            items = loaded.sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            skippedSymlinkCount = skipped
        } catch {
            items = []
            errorMessage = "Could not read this folder: \(error.localizedDescription)"
        }
    }

    private func navigate(to path: String) {
        let candidate = path.isEmpty ? canonicalRoot : canonicalRoot.appendingPathComponent(path, isDirectory: true)
        guard isSafeDirectory(candidate) else {
            errorMessage = "This folder is outside the selected workspace."
            return
        }
        currentRelativePath = path
    }

    private func navigateUp() {
        guard !pathComponents.isEmpty else { return }
        navigate(to: pathComponents.dropLast().joined(separator: "/"))
    }

    private func createFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidFolderName(name), isSafeDirectory(currentDirectoryURL) else { return }
        let target = currentDirectoryURL.appendingPathComponent(name, isDirectory: true)
        guard isInsideWorkspace(target) else {
            errorMessage = "The folder path must stay inside the workspace."
            return
        }
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            isCreatingFolder = false
            loadDirectory()
        } catch {
            errorMessage = "Could not create folder: \(error.localizedDescription)"
        }
    }

    private func importFiles() {
        guard isSafeDirectory(currentDirectoryURL) else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Import"
        guard panel.runModal() == .OK else { return }

        var failures: [String] = []
        for source in panel.urls {
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            let target = currentDirectoryURL.appendingPathComponent(source.lastPathComponent)
            do {
                guard isSafeDirectory(currentDirectoryURL), isInsideWorkspace(target) else {
                    throw CocoaError(.fileWriteNoPermission)
                }
                guard !isSymbolicLink(source) else {
                    failures.append("\(source.lastPathComponent): Symbolic links cannot be imported.")
                    continue
                }
                // copyItem fails if the destination exists; never replace a workspace file.
                try FileManager.default.copyItem(at: source, to: target)
            } catch {
                failures.append("\(source.lastPathComponent): \(error.localizedDescription)")
            }
        }
        loadDirectory()
        if !failures.isEmpty {
            errorMessage = "Some files could not be imported. Existing files were not replaced:\n" + failures.joined(separator: "\n")
        }
    }

    // Structured records and their assets are managed by their editors. Limit direct
    // file operations to the workspace's general-purpose folders.
    private func canManage(_ item: WorkspaceBrowserItem) -> Bool {
        let parts = item.relativePath.split(separator: "/")
        return parts.count > 1 && (parts.first == "Inbox" || parts.first == "Shared Files")
    }

    private func renameSelectedItem() {
        guard let item = renameItem, canManage(item), isSafeDirectory(currentDirectoryURL),
              isInsideWorkspace(item.url), !isSymbolicLink(item.url) else { return }
        let name = renamedItemName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidFolderName(name) else { return }
        let target = currentDirectoryURL.appendingPathComponent(name)
        do {
            guard isInsideWorkspace(target) else { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.moveItem(at: item.url, to: target)
            renameItem = nil
            loadDirectory()
        } catch { errorMessage = "Could not rename \(item.name): \(error.localizedDescription)" }
    }

    private func trashSelectedItem() {
        guard let item = trashItem, canManage(item), isSafeDirectory(currentDirectoryURL),
              isInsideWorkspace(item.url), !isSymbolicLink(item.url) else { return }
        do {
            try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
            trashItem = nil
            loadDirectory()
        } catch { errorMessage = "Could not move \(item.name) to the Trash: \(error.localizedDescription)" }
    }

    private func isValidFolderName(_ name: String) -> Bool {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains(":")
    }

    private func isSafeDirectory(_ url: URL) -> Bool {
        guard isInsideWorkspace(url) else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func isInsideWorkspace(_ url: URL) -> Bool {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        return resolved.path == canonicalRoot.path || resolved.path.hasPrefix(canonicalRoot.path + "/")
    }

    private func open(_ url: URL) {
        guard isInsideWorkspace(url), !isSymbolicLink(url) else {
            errorMessage = "This item is outside the selected workspace or is a symbolic link."
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = "This item is no longer available. Refresh the workspace and try again."
            return
        }
        if !NSWorkspace.shared.open(url) {
            errorMessage = "macOS could not open \(url.lastPathComponent)."
        }
    }

    private func reveal(_ url: URL) {
        guard isInsideWorkspace(url), !isSymbolicLink(url) else {
            errorMessage = "This item is outside the selected workspace or is a symbolic link."
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private func fileSymbol(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "md", "markdown", "txt": "doc.text"
        case "json": "curlybraces"
        case "png", "jpg", "jpeg", "gif", "heic", "webp": "photo"
        case "pdf": "doc.richtext"
        case "mov", "mp4", "m4v": "video"
        default: "doc"
        }
    }
}
