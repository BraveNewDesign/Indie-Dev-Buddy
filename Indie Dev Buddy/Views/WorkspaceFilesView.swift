import AppKit
import SwiftUI
import UniformTypeIdentifiers

private struct WorkspaceBrowserItem: Identifiable {
    var id: String { relativePath }
    let name: String
    let relativePath: String
    let url: URL
    let isDirectory: Bool
}

nonisolated func workspaceRelativePath(for url: URL, root: URL) -> String? {
    let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
    let resolvedPath = url.standardizedFileURL.resolvingSymlinksInPath().path
    guard resolvedPath.hasPrefix(rootPath + "/") else { return nil }
    return String(resolvedPath.dropFirst(rootPath.count + 1))
}

nonisolated func workspaceBrowserCanManageItem(relativePath: String) -> Bool {
    let components = relativePath.split(separator: "/")
    guard components.count > 1, let name = components.last else { return false }
    // The store requires record.json and the root workspace markers to stay put.
    return name != "record.json" && name != "workspace.json" && name != "AGENTS.md"
}

nonisolated enum WorkspaceFileImportError: LocalizedError {
    case unsafeDestination
    case symbolicLink
    case directory

    var errorDescription: String? {
        switch self {
        case .unsafeDestination: "The destination folder is outside the selected workspace or is unavailable."
        case .symbolicLink: "Symbolic links cannot be imported."
        case .directory: "Only files can be imported."
        }
    }
}

/// Copies user-selected files into a workspace without replacing any existing item.
/// URLs from SwiftUI's file importer already have security-scoped access; this
/// function balances that access after each copy attempt.
nonisolated func importWorkspaceFiles(
    _ sources: [URL],
    into destination: URL,
    workspaceRoot: URL,
    fileManager: FileManager = .default
) -> [String] {
    let canonicalRoot = workspaceRoot.standardizedFileURL.resolvingSymlinksInPath()
    let canonicalDestination = destination.standardizedFileURL.resolvingSymlinksInPath()
    var isDirectory: ObjCBool = false
    let destinationIsDirectory = fileManager.fileExists(atPath: canonicalDestination.path, isDirectory: &isDirectory)
        && isDirectory.boolValue
    let destinationIsInsideWorkspace = canonicalDestination.path == canonicalRoot.path
        || canonicalDestination.path.hasPrefix(canonicalRoot.path + "/")

    guard destinationIsInsideWorkspace, destinationIsDirectory else {
        for source in sources { source.stopAccessingSecurityScopedResource() }
        return [WorkspaceFileImportError.unsafeDestination.localizedDescription]
    }

    var failures: [String] = []
    for source in sources {
        defer { source.stopAccessingSecurityScopedResource() }
        let target = canonicalDestination.appendingPathComponent(source.lastPathComponent)
        do {
            let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw WorkspaceFileImportError.symbolicLink }
            guard values.isDirectory != true else { throw WorkspaceFileImportError.directory }
            let resolvedTarget = target.standardizedFileURL.resolvingSymlinksInPath()
            guard resolvedTarget.path.hasPrefix(canonicalRoot.path + "/") else {
                throw WorkspaceFileImportError.unsafeDestination
            }
            // copyItem fails if the destination exists; never replace workspace data.
            try fileManager.copyItem(at: source, to: target)
        } catch {
            failures.append("\(source.lastPathComponent): \(error.localizedDescription)")
        }
    }
    return failures
}

/// A non-destructive browser for a user-selected workspace folder.
/// Symbolic links are shown as skipped items and are never followed.
public struct WorkspaceFilesBrowser: View {
    public let root: URL

    @State private var currentRelativePath = ""
    @State private var items: [WorkspaceBrowserItem] = []
    @State private var skippedSymlinkCount = 0
    @State private var showingImportPicker = false
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
            VStack(alignment: .leading, spacing: 6) {
                Text(canonicalRoot.lastPathComponent).font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                Text(canonicalRoot.path)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .help(canonicalRoot.path)
                breadcrumb
            }

            if skippedSymlinkCount > 0 {
                Label("Skipped \(skippedSymlinkCount) symbolic link(s) to keep browsing inside this workspace.", systemImage: "link")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if items.isEmpty {
                ContentUnavailableView("This Folder Is Empty", systemImage: "folder", description: Text("Use Import Files or New Folder to add items."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                    if !currentRelativePath.isEmpty {
                        Button {
                            navigateUp()
                        } label: {
                            Label("Parent Folder", systemImage: "arrow.up")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 10)
                        Divider()
                    }
                    ForEach(items) { item in
                        Group {
                            if item.isDirectory {
                                Button { navigate(to: item.relativePath) } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: "folder")
                                            .foregroundStyle(Color.accentColor)
                                            .frame(width: 20)
                                        Text(item.name)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        Image(systemName: "chevron.right").accessibilityHidden(true)
                                            .foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Open \(item.name)")
                                .accessibilityHint("Opens this folder in the workspace browser.")
                                .accessibilityIdentifier("workspace-open-folder-\(item.relativePath)")
                            } else {
                                HStack(spacing: 10) {
                                    Image(systemName: fileSymbol(for: item.url))
                                        .foregroundStyle(Color.secondary)
                                        .frame(width: 20)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.name).textSelection(.enabled)
                                        if ["AGENTS.md", "record.json", "workspace.json"].contains(item.name) {
                                            Text("Workspace metadata").font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    Button("Open") { open(item.url) }
                                        .help("Open \(item.name)")
                                    Button("Reveal in Finder", systemImage: "folder") { reveal(item.url) }
                                        .labelStyle(.iconOnly)
                                        .help("Reveal \(item.name) in Finder")
                                        .accessibilityLabel("Reveal \(item.name) in Finder")
                                }
                            }
                        }
                        .padding(.vertical, 10)
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
                        Divider()
                    }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 8)
                }
            }
        }
        .padding(16)
        .navigationTitle("Files")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Import Files", systemImage: "square.and.arrow.down") { showingImportPicker = true }
                    .disabled(!isSafeDirectory(currentDirectoryURL))
                    .labelStyle(.iconOnly)
                    .help("Import Files")
            }
            ToolbarItem {
                Button("New Folder", systemImage: "folder.badge.plus") {
                    newFolderName = ""
                    isCreatingFolder = true
                }
                .disabled(!isSafeDirectory(currentDirectoryURL))
                .labelStyle(.iconOnly)
                .help("New Folder")
            }
            ToolbarItem {
                Menu("Folder Actions", systemImage: "ellipsis.circle") {
                    Button("Reveal in Finder", systemImage: "folder") { reveal(currentDirectoryURL) }
                    Button("Refresh Folder", systemImage: "arrow.clockwise") { loadDirectory() }
                }
                .labelStyle(.iconOnly)
            }
        }
        .task(id: currentRelativePath) { loadDirectory() }
        .fileImporter(isPresented: $showingImportPicker, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                let failures = importWorkspaceFiles(urls, into: currentDirectoryURL, workspaceRoot: canonicalRoot)
                loadDirectory()
                if !failures.isEmpty {
                    errorMessage = "Some files could not be imported. Existing files were not replaced:\n" + failures.joined(separator: "\n")
                }
            case .failure(let error):
                errorMessage = "Could not select files for import: \(error.localizedDescription)"
            }
        }
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
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                Button("Workspace") { navigate(to: "") }
                    .buttonStyle(.link)
                ForEach(Array(pathComponents.enumerated()), id: \.offset) { index, component in
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    if index == pathComponents.count - 1 {
                        Text(component).fontWeight(.medium)
                    } else {
                        Button(component) {
                            navigate(to: pathComponents.prefix(index + 1).joined(separator: "/"))
                        }
                        .buttonStyle(.link)
                    }
                }
                Text("· \(items.count) items").foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .scrollIndicators(.hidden)
        .defaultScrollAnchor(.trailing)
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
                let resolvedURL = url.standardizedFileURL.resolvingSymlinksInPath()
                guard values.isSymbolicLink != true,
                      let relative = workspaceRelativePath(for: url, root: canonicalRoot) else {
                    skipped += 1
                    continue
                }
                loaded.append(WorkspaceBrowserItem(name: resolvedURL.lastPathComponent, relativePath: relative, url: resolvedURL, isDirectory: values.isDirectory == true))
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

    private func canManage(_ item: WorkspaceBrowserItem) -> Bool {
        workspaceBrowserCanManageItem(relativePath: item.relativePath)
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
