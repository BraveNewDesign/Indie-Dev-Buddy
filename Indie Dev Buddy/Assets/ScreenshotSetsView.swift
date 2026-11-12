import SwiftUI
import Quartz
import UniformTypeIdentifiers

struct ScreenshotSetsView: View {
    let store: WorkspaceStore
    let snapshot: WorkspaceSnapshot
    let scope: AssetOwner?

    @State private var library = AssetLibrary()
    @State private var revision: String?
    @State private var selected: UUID?
    @State private var editor: ScreenshotSet?
    @State private var selecting = false
    @State private var importing = false
    @State private var replacement: UUID?
    @State private var deleting = false
    @State private var preview: URL?
    @State private var error: String?
    @State private var working = false
    @State private var checks: [UUID: ScreenshotSetCheck] = [:]

    private var apps: [AppRecord] { snapshot.apps.filter { scope == nil || scope?.id == $0.id } }
    private var sets: [ScreenshotSet] {
        library.screenshotSets.filter { scope == nil || $0.appID == scope?.id }
    }
    private var active: ScreenshotSet? { sets.first { $0.id == selected } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Screenshot Set", selection: $selected) {
                    Text("Choose a Set").tag(nil as UUID?)
                    ForEach(sets) { Text(label($0)).tag(Optional($0.id)) }
                }
                Button("New Set", systemImage: "plus") { create() }.disabled(apps.isEmpty || working)
                if let set = active {
                    Menu("Set Actions", systemImage: "ellipsis.circle") {
                        Button("Edit Details…") { editor = set }
                        Button("Revalidate Screenshots") { run { await reload() } }
                        Button("Duplicate Set…") {
                            var copy = set
                            copy.id = UUID()
                            copy.name = "\(set.title) Copy"
                            editor = copy
                        }
                        Button("Delete Set…", role: .destructive) { deleting = true }
                    }
                    .labelStyle(.iconOnly)
                    .disabled(working)
                }
            }
            if let set = active {
                setDetails(set)
            } else {
                ContentUnavailableView("App Store Screenshot Sets", systemImage: "rectangle.on.rectangle",
                                       description: Text(apps.isEmpty ? "Create an app to prepare its screenshots." : "Create or select a set to organize screenshots."))
            }
        }
        .padding(10)
        .task(id: store.rootURL) { await reload() }
        .assetQuickLook($preview)
        .sheet(item: $editor) { set in
            ScreenshotSetEditor(set: set, apps: apps, existing: library.screenshotSets) { value in
                update {
                    if let index = $0.screenshotSets.firstIndex(where: { $0.id == value.id }) {
                        $0.screenshotSets[index] = value
                    } else {
                        $0.screenshotSets.append(value)
                    }
                } onSave: { selected = value.id }
            }
        }
        .sheet(isPresented: $selecting) {
            if let set = active {
                AssetLibraryView(store: store, snapshot: snapshot, defaultOwner: AssetOwner(.app, set.appID),
                                 allowedTypes: [.image], selectionLimit: replacement == nil ? nil : 1,
                                 selectionTitle: replacement == nil ? "Add to Set" : "Replace Screenshot") { assets in
                    let ids = assets.map(\.id)
                    let replacing = replacement
                    run {
                        let (latest, currentRevision) = try await store.loadAssetLibrary()
                        var next = latest
                        guard let index = next.screenshotSets.firstIndex(where: { $0.id == set.id }) else { return }
                        var order = next.screenshotSets[index].assetIDs
                        if let replacing, let id = ids.first, let position = order.firstIndex(of: replacing) {
                            guard id == replacing || !order.contains(id) else {
                                throw WorkspaceCommandError("That image is already in this set.")
                            }
                            order[position] = id
                        } else if replacing == nil {
                            order.append(contentsOf: ids.filter { !order.contains($0) })
                        }
                        next.screenshotSets[index].assetIDs = order
                        _ = try await store.saveAssetLibrary(next, revision: currentRevision)
                        await reload()
                    }
                }
                .frame(minWidth: 650, minHeight: 440)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image],
                      allowsMultipleSelection: replacement == nil) { result in
            switch result {
            case .success(let urls): importFiles(urls)
            case .failure(let failure): error = failure.localizedDescription
            }
        }
        .confirmationDialog("Delete screenshot set?", isPresented: $deleting) {
            Button("Delete Set", role: .destructive) {
                guard let selected else { return }
                update { $0.screenshotSets.removeAll { $0.id == selected } }
            }
        } message: { Text("The images stay in the asset library.") }
        .alert("Screenshot Sets", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private func label(_ set: ScreenshotSet) -> String {
        let app = snapshot.apps.first { $0.id == set.appID }?.name ?? set.appID
        return [app, set.platform.rawValue, set.categoryName, set.locale, set.version,
                set.name].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func setDetails(_ set: ScreenshotSet) -> some View {
        let check = checks[set.id] ?? ScreenshotSetCheck(summary: ["Checking images…"])
        let spec = ScreenshotSpecifications.category(set.categoryID)
        return VStack(alignment: .leading, spacing: 8) {
            Text(label(set)).font(.headline)
            let count = set.assetIDs.count
            let readyTitle = count == 1 ? "Set Ready · 1 Screenshot" : "Set Ready · \(count) Screenshots"
            Label(check.ready ? readyTitle : "Set Needs Attention",
                  systemImage: check.ready ? "checkmark.circle.fill" : "exclamationmark.triangle")
                .foregroundStyle(check.ready ? Color.green : Color.orange)
            ForEach(check.summary, id: \.self) { Text($0).font(.callout).foregroundStyle(.secondary) }
            if let spec {
                Text("Accepted sizes (px)  \(spec.sizes.map(\.description).joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            coverage(set)
            HStack {
                Button("Add from Library", systemImage: "plus") { replacement = nil; selecting = true }
                Button("Import Screenshots", systemImage: "square.and.arrow.down") { replacement = nil; importing = true }
            }.disabled(working)
            List {
                ForEach(Array(set.assetIDs.enumerated()), id: \.element) { index, id in
                    let asset = library.assets.first { $0.id == id }
                    let url = asset.flatMap { managedAssetURL($0.reference, root: store.rootURL) }
                    HStack(alignment: .top) {
                        Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary)
                        AssetThumbnail(url: url).frame(width: 72, height: 56)
                        VStack(alignment: .leading) {
                            Text(asset?.name ?? "Missing Asset")
                            if let issues = check.images[id], !issues.isEmpty {
                                ForEach(issues, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                            } else if let pixels = check.dimensions[id] {
                                Label("Valid · \(pixels.description) px", systemImage: "checkmark").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Menu("Screenshot Actions", systemImage: "ellipsis") {
                            Button("Quick Look") { preview = url }.disabled(url == nil)
                            Button("Move Up") { move(id, to: index - 1, in: set) }.disabled(index == 0)
                            Button("Move Down") { move(id, to: index + 1, in: set) }.disabled(index == set.assetIDs.count - 1)
                            Button("Replace from Library…") { replacement = id; selecting = true }
                            Button("Import Replacement…") { replacement = id; importing = true }
                            Button("Remove from Set", role: .destructive) { editOrder(set) { $0.removeAll { $0 == id } } }
                        }.labelStyle(.iconOnly).disabled(working)
                    }
                    .draggable("\(set.id.uuidString)/\(id.uuidString)")
                    .dropDestination(for: String.self) { values, _ in
                        guard let first = values.first, first.hasPrefix(set.id.uuidString + "/"),
                              let moved = UUID(uuidString: String(first.split(separator: "/").last ?? "")),
                              set.assetIDs.contains(moved) else { return false }
                        move(moved, to: index, in: set)
                        return true
                    }
                }
                .onMove { offsets, index in editOrder(set) { $0.move(fromOffsets: offsets, toOffset: index) } }
            }
            .overlay {
                if set.assetIDs.isEmpty {
                    ContentUnavailableView("No Screenshots", systemImage: "photo.on.rectangle",
                                           description: Text("Add images from the library or import screenshots."))
                }
            }
            .dropDestination(for: URL.self) { urls, _ in replacement = nil; importFiles(urls); return true }
        }
    }

    private func coverage(_ set: ScreenshotSet) -> some View {
        let valid = Set(library.screenshotSets.filter {
            $0.appID == set.appID && $0.platform == set.platform &&
            $0.locale.caseInsensitiveCompare(set.locale) == .orderedSame && $0.version == set.version &&
            checks[$0.id]?.ready == true
        }.map(\.categoryID))
        let required = ScreenshotSpecifications.requiredCategories(for: set.platform, available: valid)
        let missing = required.filter { !valid.contains($0) && ScreenshotSpecifications.scalingSource(for: $0, available: valid) == nil }
        let scaled = ScreenshotSpecifications.all.filter {
            $0.platform == set.platform && !valid.contains($0.id) &&
            ScreenshotSpecifications.scalingSource(for: $0.id, available: valid) != nil
        }.map(\.title)
        return DisclosureGroup(missing.isEmpty ? "Required Displays Covered · \(set.locale)" : "Required Displays Missing · \(set.locale)") {
            if missing.isEmpty {
                Text("Required display coverage is available.").foregroundStyle(.secondary)
            } else if set.platform == .watch {
                Text("Provide a valid Apple Watch screenshot set for this localization.")
                    .foregroundStyle(.orange)
            } else {
                Text("Required coverage missing: \(missing.compactMap { ScreenshotSpecifications.category($0)?.title }.joined(separator: ", "))")
                    .foregroundStyle(.orange)
            }
            if !scaled.isEmpty {
                Text("App Store Connect can scale for: \(scaled.joined(separator: ", "))").foregroundStyle(.secondary)
            }
            if set.platform == .iPhone { Text(ScreenshotSpecifications.iPhoneDuoRequirement).foregroundStyle(.secondary) }
        }.font(.caption)
    }

    private func create() {
        guard let app = apps.first else { return }
        let platform = ScreenshotPlatform.supported(by: app.platforms).first ?? .iPhone
        let category = ScreenshotSpecifications.requiredCategories(for: platform, available: []).first ?? ""
        editor = ScreenshotSet(appID: app.id, platform: platform, categoryID: category, locale: "en-US", version: "", name: "")
    }

    private func move(_ id: UUID, to position: Int, in set: ScreenshotSet) {
        editOrder(set) { order in
            guard let index = order.firstIndex(of: id), order.indices.contains(position) else { return }
            order.remove(at: index)
            order.insert(id, at: position)
        }
    }

    private func editOrder(_ set: ScreenshotSet, _ change: (inout [UUID]) -> Void) {
        update {
            guard let index = $0.screenshotSets.firstIndex(where: { $0.id == set.id }) else { return }
            change(&$0.screenshotSets[index].assetIDs)
        }
    }

    private func importFiles(_ urls: [URL]) {
        guard let set = active else { return }
        let replacing = replacement
        run {
            var failures: [String] = []
            for url in urls {
                do {
                    guard UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true else {
                        throw WorkspaceCommandError("Choose an image file.")
                    }
                    _ = try await store.importAsset(url, owner: AssetOwner(.app, set.appID),
                                                    into: set.id, replacing: replacing)
                } catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            }
            await reload()
            if !failures.isEmpty { error = failures.joined(separator: "\n") }
        }
    }

    private func reload() async {
        do {
            (library, revision) = try await store.loadAssetLibrary()
            await refreshChecks()
            if active == nil { selected = sets.first?.id }
        } catch { self.error = error.localizedDescription }
    }

    private func refreshChecks() async {
        checks = await store.validateScreenshotSets(library)
    }

    private func update(_ change: (inout AssetLibrary) -> Void, onSave: (() -> Void)? = nil) {
        var next = library
        change(&next)
        run {
            revision = try await store.saveAssetLibrary(next, revision: revision)
            library = next
            await refreshChecks()
            onSave?()
            if active == nil { selected = sets.first?.id }
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

private struct ScreenshotSetEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var set: ScreenshotSet
    let apps: [AppRecord]
    let existing: [ScreenshotSet]
    let save: (ScreenshotSet) -> Void
    @State private var showAll = false

    private var supported: [ScreenshotPlatform] {
        ScreenshotPlatform.supported(by: apps.first { $0.id == set.appID }?.platforms ?? [])
    }
    private var platforms: [ScreenshotPlatform] {
        showAll || supported.isEmpty ? ScreenshotPlatform.allCases : supported
    }
    private var categories: [ScreenshotSpecification] {
        ScreenshotSpecifications.all.filter { $0.platform == set.platform }
    }

    private var duplicate: Bool {
        existing.contains { other in
            other.id != set.id && other.appID == set.appID && other.platform == set.platform &&
                other.categoryID == set.categoryID && same(other.locale, set.locale) &&
                same(other.version, set.version) && same(other.name, set.name)
        }
    }

    private func same(_ lhs: String, _ rhs: String) -> Bool {
        lhs.caseInsensitiveCompare(rhs.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
    }

    var body: some View {
        Form {
            Picker("App", selection: $set.appID) {
                if !apps.contains(where: { $0.id == set.appID }) {
                    Text("Missing App").tag(set.appID)
                }
                ForEach(apps) { Text($0.name).tag($0.id) }
            }
            Toggle("Show All Platforms", isOn: $showAll)
            Picker("Platform", selection: $set.platform) {
                ForEach(platforms, id: \.self) { Text($0.rawValue).tag($0) }
            }
            Picker("Display Category", selection: $set.categoryID) {
                ForEach(categories) { Text($0.title).tag($0.id) }
            }
            TextField("Localization", text: $set.locale, prompt: Text("en-US"))
            TextField("Release Version (optional)", text: $set.version)
            TextField("Set Name (optional)", text: $set.name)
            if duplicate {
                Text("A set with these details already exists. Choose a different name or version.")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    set.locale = set.locale.trimmingCharacters(in: .whitespacesAndNewlines)
                    set.version = set.version.trimmingCharacters(in: .whitespacesAndNewlines)
                    set.name = set.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    save(set)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(duplicate || set.locale.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                          set.categoryID.isEmpty || !apps.contains { $0.id == set.appID })
            }
        }
        .padding(20)
        .frame(width: 490)
        .onAppear { showAll = !supported.isEmpty && !supported.contains(set.platform) }
        .onChange(of: set.appID) { _, _ in normalize() }
        .onChange(of: showAll) { _, _ in normalize() }
        .onChange(of: set.platform) { _, _ in normalize() }
    }

    private func normalize() {
        if !platforms.contains(set.platform), let first = platforms.first { set.platform = first }
        if !categories.contains(where: { $0.id == set.categoryID }) {
            set.categoryID = ScreenshotSpecifications.requiredCategories(for: set.platform, available: []).first ?? ""
        }
    }
}
