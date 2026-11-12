import AppKit
import Quartz
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

struct AssetLibraryView: View {
    let store: WorkspaceStore
    let snapshot: WorkspaceSnapshot
    var scope: AssetOwner? = nil
    var defaultOwner: AssetOwner? = nil
    var allowedTypes: [UTType] = []
    var selectionLimit: Int? = nil
    var selectionTitle = "Add to Post"
    var onSelect: (([WorkspaceAsset]) -> Void)? = nil
    var embedded = false
    var refreshID = 0

    enum Location: Hashable {
        case all, recent, unfiled, screenshots, owner(AssetOwner), folder(UUID), category(AppAssetCategory)
    }

    @Environment(\.dismiss) private var dismiss
    @State private var library = AssetLibrary()
    @State private var revision: String?
    @State private var location: Location? = .all
    @State private var selected = Set<UUID>()
    @State private var search = ""
    @State private var tag = ""
    @State private var sort = "Name"
    @State private var grid = true
    @State private var importer = false
    @State private var inspector = false
    @State private var preview: URL?
    @State private var error: String?
    @State private var folderEditor = false
    @State private var folderName = ""
    @State private var editingFolder: AssetFolder?
    @State private var removingFolder: AssetFolder?
    @State private var removingAsset: WorkspaceAsset?
    @State private var editingAsset: WorkspaceAsset?
    @State private var working = false

    private var ownerGroups: [(String, [(AssetOwner, String)])] {
        [
            ("Apps", snapshot.apps.map { (AssetOwner(.app, $0.id), $0.name) }),
            ("Websites", snapshot.websites.map { (AssetOwner(.website, $0.id), $0.name) }),
            ("Identities", snapshot.identities.map { (AssetOwner(.identity, $0.id), $0.name) }),
            ("Shared", [(.shared, "Shared Files")])
        ]
    }

    private var owners: [(AssetOwner, String)] { ownerGroups.flatMap { $0.1 } }
    private var currentFolder: AssetFolder? {
        guard case .folder(let id) = location else { return nil }
        return library.folders.first { $0.id == id }
    }
    private var importOwner: AssetOwner {
        if let currentFolder { return currentFolder.owner }
        if case .owner(let owner) = location { return owner }
        return scope ?? defaultOwner ?? .shared
    }
    private var visibleAssets: [WorkspaceAsset] {
        library.assets.filter { asset in
            if let scope, asset.owner != scope { return false }
            switch location {
            case .owner(let owner): if asset.owner != owner { return false }
            case .folder(let id): if asset.folderID != id { return false }
            case .category(let category): if appCategory(asset) != category { return false }
            case .unfiled: if asset.folderID != nil { return false }
            case .recent: if asset.added < Date().addingTimeInterval(-30 * 86_400) { return false }
            default: break
            }
            if !allowedTypes.isEmpty {
                guard let type = UTType(filenameExtension: asset.fileExtension),
                      allowedTypes.contains(where: { type.conforms(to: $0) }) else { return false }
            }
            return (tag.isEmpty || asset.tags.contains(tag)) &&
                (search.isEmpty || ([asset.name] + asset.tags).contains { $0.localizedStandardContains(search) })
        }.sorted {
            sort == "Date Added" || location == .recent
                ? $0.added > $1.added
                : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if embedded || onSelect != nil {
                HStack {
                    controls
                    TextField("Search files and tags", text: $search)
                        .textFieldStyle(.roundedBorder)
                        .frame(idealWidth: 175, maxWidth: 240)
                        .disabled(location == .screenshots)
                }
                .padding(8)
                Divider()
            }
            HSplitView {
                sidebar.frame(minWidth: 145, idealWidth: 185, maxWidth: 240)
                Group {
                    if location == .screenshots, onSelect == nil {
                        ScreenshotSetsView(store: store, snapshot: snapshot, scope: scope)
                    } else if visibleAssets.isEmpty {
                        ContentUnavailableView("No Files", systemImage: "folder",
                                               description: Text("Import files or change your search and filters."))
                    } else if grid {
                        assetGrid
                    } else {
                        assetTable
                    }
                }
                .frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)
                .dropDestination(for: URL.self) { urls, _ in
                    guard location != .screenshots else { return false }
                    importFiles(urls)
                    return true
                }
            }
            if let onSelect {
                Divider()
                HStack {
                    Text("\(selected.count) selected").foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button(selectionTitle) {
                        onSelect(library.assets.filter { selected.contains($0.id) })
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty || selected.count > (selectionLimit ?? Int.max))
                }
                .padding()
            }
        }
        .modifier(AssetLibrarySearch(enabled: !embedded && onSelect == nil && location != .screenshots, search: $search))
        .toolbar {
            if !embedded && onSelect == nil { ToolbarItem { controls } }
        }
        .task(id: store.rootURL) {
            if let defaultOwner, scope == nil { location = .owner(defaultOwner) }
            await reload()
        }
        .onChange(of: refreshID) { _, _ in Task { await reload() } }
        .onChange(of: location) { old, _ in
            if onSelect == nil { selected.removeAll() }
            if old == .screenshots { Task { await reload() } }
        }
        .fileImporter(isPresented: $importer, allowedContentTypes: allowedTypes.isEmpty ? [.data] : allowedTypes,
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): importFiles(urls)
            case .failure(let failure): error = failure.localizedDescription
            }
        }
        .assetQuickLook($preview)
        .onKeyPress(.space) {
            guard let asset = visibleAssets.first(where: { selected.contains($0.id) }), let url = url(for: asset) else { return .ignored }
            preview = url
            return .handled
        }
        .inspector(isPresented: $inspector) {
            if let asset = library.assets.first(where: { selected.contains($0.id) }) {
                details(asset)
            } else {
                ContentUnavailableView("Select a File", systemImage: "info.circle")
            }
        }
        .alert("Asset Library", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
        .alert(editingFolder == nil ? "New Folder" : "Rename Folder", isPresented: $folderEditor) {
            TextField("Name", text: $folderName)
            Button("Save") {
                let name = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
                if var folder = editingFolder {
                    folder.name = name
                    let updatedFolder = folder
                    update { value in
                        if let index = value.folders.firstIndex(where: { $0.id == updatedFolder.id }) {
                            value.folders[index] = updatedFolder
                        }
                    }
                } else {
                    let folder = AssetFolder(name: name, owner: importOwner, parentID: currentFolder?.id)
                    update { $0.folders.append(folder) }
                }
            }
            .disabled(folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete virtual folder?", isPresented: Binding(
            get: { removingFolder != nil }, set: { if !$0 { removingFolder = nil } }
        )) {
            Button("Delete Folder", role: .destructive) {
                guard let folder = removingFolder else { return }
                if location == .folder(folder.id) { location = .unfiled }
                update { $0.removeFolder(folder.id) }
            }
        } message: { Text("Files in this folder become unfiled. Subfolders move up one level.") }
        .confirmationDialog("Move managed file to the Trash?", isPresented: Binding(
            get: { removingAsset != nil }, set: { if !$0 { removingAsset = nil } }
        )) {
            Button("Move to Trash", role: .destructive) {
                guard let id = removingAsset?.id else { return }
                run { try await store.trashAsset(id); await reload() }
            }
        } message: { Text("Assets used by saved content or screenshot sets must be removed from those collections first.") }
        .sheet(item: $editingAsset) { asset in
            AssetMetadataEditor(asset: asset, owners: owners, folders: library.folders) { updated in
                update { value in
                    if let index = value.assets.firstIndex(where: { $0.id == updated.id }) { value.assets[index] = updated }
                }
            }
        }
    }

    private var controls: some View {
        HStack {
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await reload() } }
                .disabled(working)
            Button("Import Files", systemImage: "square.and.arrow.down") { importer = true }
                .disabled(working)
            if onSelect == nil {
                AppStoreScreenshotImportEntry(
                    apps: snapshot.apps.filter { scope == nil || scope == AssetOwner(.app, $0.id) },
                    store: store,
                    onImportFinished: { Task { await reload() } }
                )
                .disabled(working)
            }
            if onSelect == nil {
                Button("New Folder", systemImage: "folder.badge.plus") {
                    editingFolder = nil
                    folderName = ""
                    folderEditor = true
                }
                .disabled(working)
            }
            Spacer(minLength: 0)
            Picker("View", selection: $grid) {
                Image(systemName: "square.grid.2x2").accessibilityLabel("Grid").tag(true)
                Image(systemName: "list.bullet").accessibilityLabel("List").tag(false)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Menu("Filters", systemImage: "line.3.horizontal.decrease.circle") {
                Picker("Sort", selection: $sort) {
                    Text("Name").tag("Name")
                    Text("Date Added").tag("Date Added")
                }
                Picker("Tag", selection: $tag) {
                    Text("All Tags").tag("")
                    ForEach(Set(library.assets.flatMap(\.tags)).sorted(), id: \.self) { Text($0).tag($0) }
                }
            }.labelStyle(.iconOnly)
            Button("Inspector", systemImage: "sidebar.trailing") { inspector.toggle() }.labelStyle(.iconOnly)
            if onSelect == nil {
                Menu("Finder", systemImage: "folder") {
                    Button("Open Workspace in Finder") { NSWorkspace.shared.open(store.rootURL) }
                }
                .labelStyle(.iconOnly)
            }
        }
        .disabled(location == .screenshots)
    }

    private var sidebar: some View {
        List(selection: $location) {
            Label("All Files", systemImage: "tray").tag(Location.all)
            Label("Recent", systemImage: "clock").tag(Location.recent)
            Label("Unfiled", systemImage: "tray.and.arrow.down")
                .tag(Location.unfiled)
                .dropDestination(for: String.self) { payloads, _ in
                    guard onSelect == nil else { return false }
                    let ids = Set(payloads.compactMap { UUID(uuidString: $0) })
                    guard !ids.isEmpty else { return false }
                    unfile(ids)
                    return true
                }
            if onSelect == nil && (scope == nil || scope?.kind == .app) {
                Label("App Store Screenshot Sets", systemImage: "rectangle.on.rectangle").tag(Location.screenshots)
            }
            if let scope {
                if scope.kind == .app {
                    Section("Collections") {
                        ForEach(AppAssetCategory.allCases, id: \.self) { category in
                            Label(category.rawValue, systemImage: "folder").tag(Location.category(category))
                        }
                    }
                }
                ForEach(folderNodes(owner: scope)) { node in folderBranch(node) }
            } else {
                ForEach(ownerGroups, id: \.0) { group, items in
                    Section(group) {
                        ForEach(items, id: \.0) { owner, name in
                            let nodes = folderNodes(owner: owner)
                            if nodes.isEmpty {
                                Label(name, systemImage: "folder").tag(Location.owner(owner))
                            } else {
                                DisclosureGroup {
                                    ForEach(nodes) { node in folderBranch(node) }
                                } label: { Label(name, systemImage: "folder") }
                                .tag(Location.owner(owner))
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private struct FolderNode: Identifiable {
        let folder: AssetFolder
        let children: [FolderNode]
        var id: UUID { folder.id }
    }

    private func folderNodes(owner: AssetOwner, parent: UUID? = nil, visited: Set<UUID> = []) -> [FolderNode] {
        library.folders.filter { $0.owner == owner && $0.parentID == parent && !visited.contains($0.id) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { FolderNode(folder: $0, children: folderNodes(owner: owner, parent: $0.id, visited: visited.union([$0.id]))) }
    }

    private func folderBranch(_ node: FolderNode) -> AnyView {
        let label = Label(node.folder.name, systemImage: "folder")
        let row = node.children.isEmpty ? AnyView(label) : AnyView(DisclosureGroup {
            ForEach(node.children) { folderBranch($0) }
        } label: { label })
        return AnyView(row.tag(Location.folder(node.id))
            .contextMenu {
                if onSelect == nil {
                    Button("Rename Folder") {
                        editingFolder = node.folder
                        folderName = node.folder.name
                        folderEditor = true
                    }
                    Button("Delete Folder", role: .destructive) { removingFolder = node.folder }
                }
            }
            .dropDestination(for: String.self) { payloads, _ in
                let ids = payloads.compactMap { UUID(uuidString: $0) }
                guard !ids.isEmpty else { return false }
                guard onSelect == nil else { return false }
                update { library in
                    for index in library.assets.indices where ids.contains(library.assets[index].id) {
                        library.assets[index].owner = node.folder.owner
                        library.assets[index].folderID = node.id
                    }
                }
                return true
            })
    }

    private var assetGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 12)], spacing: 12) {
                ForEach(visibleAssets) { asset in
                    Button {
                        let modifiers = NSEvent.modifierFlags
                        if onSelect != nil || modifiers.contains(.command) {
                            if !selected.insert(asset.id).inserted { selected.remove(asset.id) }
                        } else if modifiers.contains(.shift), let anchor = visibleAssets.firstIndex(where: { selected.contains($0.id) }),
                                  let end = visibleAssets.firstIndex(where: { $0.id == asset.id }) {
                            selected.formUnion(visibleAssets[min(anchor, end)...max(anchor, end)].map(\.id))
                        } else {
                            selected = [asset.id]
                        }
                    } label: {
                        VStack {
                            AssetThumbnail(url: url(for: asset)).frame(height: 86)
                            Text(asset.name).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(6)
                        .background(selected.contains(asset.id) ? Color.accentColor.opacity(0.25) : .clear, in: .rect(cornerRadius: 6))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected.contains(asset.id) ? .isSelected : [])
                    .contextMenu { actions(asset) }
                    .draggable(asset.id.uuidString)
                }
            }
            .padding(12)
        }
    }

    private var assetTable: some View {
        Table(visibleAssets, selection: $selected) {
            TableColumn("Name") { asset in Text(asset.name).draggable(asset.id.uuidString) }
            TableColumn("Type") { Text($0.fileExtension.uppercased()) }
            TableColumn("Owner") { Text(ownerName($0.owner)) }
            TableColumn("Date Modified") { asset in
                if let date = try? url(for: asset)?.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                    Text(date, style: .date)
                } else { Text("—") }
            }
            TableColumn("Size") { Text(fileSize($0)) }
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if ids.count == 1, let asset = visibleAssets.first(where: { ids.contains($0.id) }) {
                actions(asset)
            } else if ids.count > 1 && onSelect == nil {
                Button("Move to Unfiled") { unfile(ids) }
            }
        } primaryAction: { ids in
            preview = visibleAssets.first(where: { ids.contains($0.id) }).flatMap(url)
        }
    }

    @ViewBuilder private func actions(_ asset: WorkspaceAsset) -> some View {
        Button("Quick Look") { preview = url(for: asset) }
        if let url = url(for: asset) {
            Button("Open") { NSWorkspace.shared.open(url) }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.path, forType: .string)
            }
            if onSelect == nil {
                Button("Duplicate") {
                    run {
                        _ = try await store.importAsset(url, owner: asset.owner, folderID: asset.folderID, displayName: asset.name, category: asset.category)
                        await reload()
                    }
                }
            }
        }
        if onSelect == nil {
            Button("Edit Name, Folder, or Tags…") { editingAsset = asset }
            Button("Move to Trash…", role: .destructive) { removingAsset = asset }
        }
    }

    private func details(_ asset: WorkspaceAsset) -> some View {
        let file = url(for: asset)
        return Form {
            AssetThumbnail(url: file).frame(height: 120)
            LabeledContent("Name", value: asset.name)
            LabeledContent("Type", value: asset.fileExtension.uppercased())
            if let original = asset.originalFilename { LabeledContent("Original Filename", value: original) }
            if let file, let pixels = ScreenshotSpecifications.dimensions(of: file) {
                LabeledContent("Dimensions", value: "\(pixels) px")
            }
            LabeledContent("Size", value: fileSize(asset))
            LabeledContent("Owner", value: ownerName(asset.owner))
            LabeledContent("Folder", value: library.folders.first { $0.id == asset.folderID }?.name ?? "Unfiled")
            LabeledContent("Tags", value: asset.tags.joined(separator: ", "))
            LabeledContent("Added", value: asset.added.formatted(date: .abbreviated, time: .omitted))
            if let file { LabeledContent("Location", value: file.path).textSelection(.enabled) }
            ForEach(library.screenshotSets.filter { $0.assetIDs.contains(asset.id) }) { set in
                LabeledContent("Screenshot Set", value: set.title)
            }
            ForEach(snapshot.content.filter { record in
                record.mediaPaths.contains(asset.reference) || record.destinations.contains { $0.mediaPaths?.contains(asset.reference) == true }
            }) { record in LabeledContent("Used in Content", value: record.title) }
        }
        .formStyle(.grouped)
        .inspectorColumnWidth(min: 210, ideal: 270)
    }

    private func unfile(_ ids: Set<UUID>) {
        update { value in
            for index in value.assets.indices where ids.contains(value.assets[index].id) {
                value.assets[index].folderID = nil
            }
        }
    }

    private func appCategory(_ asset: WorkspaceAsset) -> AppAssetCategory {
        if let category = asset.category { return category }
        if ["icns", "ico", "icon"].contains(asset.fileExtension) { return .branding }
        guard let type = UTType(filenameExtension: asset.fileExtension) else { return .other }
        if type.conforms(to: .movie) { return .video }
        if type.conforms(to: .image) { return .marketing }
        return .other
    }

    private func fileSize(_ asset: WorkspaceAsset) -> String {
        guard let bytes = try? url(for: asset)?.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func ownerName(_ owner: AssetOwner) -> String {
        owners.first { $0.0 == owner }?.1 ?? owner.id
    }

    private func url(for asset: WorkspaceAsset) -> URL? {
        managedAssetURL(asset.reference, root: store.rootURL)
    }

    private func reload() async {
        do { (library, revision) = try await store.loadAssetLibrary() }
        catch { self.error = error.localizedDescription }
    }

    private func importFiles(_ urls: [URL]) {
        let owner = importOwner
        let folder = currentFolder?.id
        let category: AppAssetCategory? = if case .category(let value) = location { value } else { nil }
        run {
            var failures: [String] = []
            for url in urls {
                do {
                    if !allowedTypes.isEmpty {
                        guard let type = UTType(filenameExtension: url.pathExtension),
                              allowedTypes.contains(where: { type.conforms(to: $0) }) else {
                            throw WorkspaceCommandError("This file type is unavailable here.")
                        }
                    }
                    let asset = try await store.importAsset(url, owner: owner, folderID: folder, category: category)
                    if onSelect != nil { selected.insert(asset.id) }
                } catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            }
            await reload()
            if !failures.isEmpty { error = failures.joined(separator: "\n") }
        }
    }

    private func update(_ change: (inout AssetLibrary) -> Void) {
        var next = library
        change(&next)
        run {
            revision = try await store.saveAssetLibrary(next, revision: revision)
            library = next
        }
    }

    private func run(_ action: @escaping () async throws -> Void) {
        guard !working else { return }
        working = true
        Task {
            defer { working = false }
            do { try await action() }
            catch {
                await reload()
                self.error = error.localizedDescription
            }
        }
    }
}

struct ScopedAssetLibraryButton: View {
    let store: WorkspaceStore
    let snapshot: WorkspaceSnapshot
    let owner: AssetOwner
    @State private var showing = false

    var body: some View {
        Button("Files", systemImage: "folder") { showing = true }
            .sheet(isPresented: $showing) {
                VStack(spacing: 0) {
                    AssetLibraryView(store: store, snapshot: snapshot, scope: owner, embedded: true)
                    Divider()
                    Button("Done") { showing = false }
                        .keyboardShortcut(.cancelAction)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding()
                }
                .frame(minWidth: 650, minHeight: 440)
            }
    }
}

private struct AssetLibrarySearch: ViewModifier {
    let enabled: Bool
    @Binding var search: String

    func body(content: Content) -> some View {
        if enabled { content.searchable(text: $search, prompt: "Search files and tags") }
        else { content }
    }
}

nonisolated func managedAssetURL(_ reference: String, root: URL) -> URL? {
    guard let path = AssetLibrary.managedPath(reference) else { return nil }
    let candidate = root.appendingPathComponent(path)
    guard candidate.resolvingSymlinksInPath().path == candidate.path,
          (try? candidate.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
    return candidate
}

struct AssetThumbnail: View {
    let url: URL?
    @State private var image: NSImage?
    private static let cache: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 180
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()

    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else { Image(systemName: url == nil ? "exclamationmark.triangle" : "doc").font(.title2).foregroundStyle(.secondary) }
        }
        .accessibilityHidden(true)
        .task(id: url) {
            image = nil
            guard let url else { return }
            if let cached = Self.cache.object(forKey: url as NSURL) {
                image = cached
                return
            }
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 240, height: 160),
                                                       scale: 2, representationTypes: .all)
            if let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request),
               !Task.isCancelled {
                image = representation.nsImage
                let cgImage = representation.cgImage
                Self.cache.setObject(representation.nsImage, forKey: url as NSURL, cost: cgImage.bytesPerRow * cgImage.height)
            }
        }
    }
}

private struct AssetMetadataEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var asset: WorkspaceAsset
    let owners: [(AssetOwner, String)]
    let folders: [AssetFolder]
    let save: (WorkspaceAsset) -> Void
    @State private var tags = ""

    var body: some View {
        Form {
            TextField("Name", text: $asset.name)
            Picker("Owner", selection: $asset.owner) {
                if !owners.contains(where: { $0.0 == asset.owner }) {
                    Text("Missing Owner").tag(asset.owner)
                }
                ForEach(owners, id: \.0) { owner, name in Text(name).tag(owner) }
            }
            Picker("Folder", selection: $asset.folderID) {
                Text("Unfiled").tag(nil as UUID?)
                ForEach(folders.filter { $0.owner == asset.owner }) { Text($0.name).tag(Optional($0.id)) }
            }
            if asset.owner.kind == .app {
                Picker("App Collection", selection: $asset.category) {
                    Text("Automatic").tag(nil as AppAssetCategory?)
                    ForEach(AppAssetCategory.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
                }
            }
            TextField("Tags (comma-separated)", text: $tags)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    asset.name = asset.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    asset.tags = Array(Set(tags.split(separator: ",").map {
                        $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    }.filter { !$0.isEmpty })).sorted()
                    save(asset)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(asset.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { tags = asset.tags.joined(separator: ", ") }
        .onChange(of: asset.owner) { _, _ in asset.folderID = nil }
    }
}
