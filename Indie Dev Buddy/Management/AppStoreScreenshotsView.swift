import AppKit
import SwiftUI

/// Inspects screenshots already present in App Store Connect and imports selected images into Files.
struct AppStoreScreenshotsView: View {
    let app: AppRecord
    let versions: [ASCVersion]
    let executablePath: String
    let store: WorkspaceStore
    var refreshID = 0
    var importOnly = false
    var defaultPlatform: String? = nil
    var onOpenFiles: () -> Void = {}

    @State private var collections: [RemoteScreenshotCollection] = []
    @State private var selectedVersionID: String?
    @State private var selectedCollectionID: String?
    @State private var selectedScreenshotIDs = Set<String>()
    @State private var loading = false
    @State private var importing = false
    @State private var progress = 0
    @State private var error: String?
    @State private var notice: String?
    @State private var previewName: String?
    @State private var loadingPreview = false
    @State private var previewImage: NSImage?
    @State private var previewScreenshotID: String?

    private var selectedCollection: RemoteScreenshotCollection? {
        collections.first { $0.id == selectedCollectionID }
    }
    private var orderedVersions: [ASCVersion] {
        versions.sorted { ($0.createdDate ?? .distantPast) > ($1.createdDate ?? .distantPast) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(importOnly ? "Import App Store Screenshots" : "App Store Screenshots")
                    .font(.title3.weight(.semibold))
                Spacer()
                if versions.count > 1 {
                    Picker("Version", selection: $selectedVersionID) {
                        ForEach(orderedVersions) { version in
                            Text("\(version.number) · \(ASCDisplay.platform(version.platform))").tag(Optional(version.id))
                        }
                    }
                    .frame(maxWidth: 260)
                }
                if loading { ProgressView().controlSize(.small) }
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await loadCollections() } }
                    .disabled(loading || importing)
            }

            if collections.isEmpty && !loading {
                ContentUnavailableView("No App Store Screenshots", systemImage: "rectangle.stack",
                    description: Text("No screenshots were found for the linked app’s available versions."))
            } else {
                HSplitView {
                    List(selection: $selectedCollectionID) {
                        ForEach(collections) { collection in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(collection.title).fontWeight(.medium)
                                Text("\(collection.platformTitle) · Version \(collection.version) · \(collection.screenshots.count) images")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .tag(Optional(collection.id))
                            .padding(.vertical, 3)
                        }
                    }
                    .frame(minWidth: 175, idealWidth: 250)

                    collectionDetail
                        .frame(minWidth: 240, maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(minHeight: 420, idealHeight: 520)
            }

            if importing {
                ProgressView(value: Double(progress), total: Double(max(selectedScreenshotIDs.count, 1)))
                    .accessibilityLabel("Importing screenshots")
            }
            if let notice { Label(notice, systemImage: "checkmark.circle").foregroundStyle(.secondary) }
            if !importOnly {
                Button("View in Files", systemImage: "folder") { onOpenFiles() }
                    .disabled(importing)
            }
        }
        .padding(14)
        .task(id: "\(refreshID)-\(selectedVersionID ?? "latest")") { await loadCollections() }
        .onChange(of: selectedCollectionID) { _, _ in
            selectedScreenshotIDs = Set(selectedCollection?.screenshots.map(\.id) ?? [])
        }
        .sheet(isPresented: Binding(get: { previewImage != nil }, set: { if !$0 { previewImage = nil } })) {
            VStack(spacing: 12) {
                if let previewImage {
                    Image(nsImage: previewImage).resizable().scaledToFit().padding()
                        .accessibilityLabel(previewName ?? "App Store screenshot")
                }
                HStack {
                    if let previewName { Text(previewName).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Done") { previewImage = nil }.keyboardShortcut(.cancelAction)
                }
                .padding([.horizontal, .bottom])
            }
            .frame(minWidth: 420, minHeight: 360)
        }
        .alert("App Store Screenshots", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    @ViewBuilder private var collectionDetail: some View {
        if let collection = selectedCollection {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(collection.title).font(.headline)
                        Text("Version \(collection.version)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Import Selected (\(selectedScreenshotIDs.intersection(Set(collection.screenshots.map(\.id))).count))",
                           systemImage: "square.and.arrow.down") {
                        Task { await importSelection(collection) }
                    }
                    .disabled(importing || selectedScreenshotIDs.intersection(Set(collection.screenshots.map(\.id))).isEmpty)
                }
                if collection.screenshots.isEmpty {
                    ContentUnavailableView("No Images in This Collection", systemImage: "photo")
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 12)], spacing: 12) {
                            ForEach(Array(collection.screenshots.enumerated()), id: \.element.id) { index, screenshot in
                                VStack(alignment: .leading, spacing: 6) {
                                    Button { Task { await showPreview(screenshot) } } label: {
                                        Group {
                                            if screenshot.id == previewScreenshotID, let image = previewImage {
                                                Image(nsImage: image).resizable().scaledToFit()
                                            } else if let url = screenshot.previewURL {
                                                AsyncImage(url: url) { phase in
                                                    if let image = phase.image {
                                                        image.resizable().scaledToFit()
                                                    } else if phase.error != nil {
                                                        Image(systemName: "photo").font(.title).foregroundStyle(.secondary)
                                                    } else {
                                                        ProgressView().controlSize(.small)
                                                    }
                                                }
                                            } else {
                                                RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                                                    .overlay(Image(systemName: "photo").font(.title).foregroundStyle(.secondary))
                                            }
                                        }
                                        .frame(height: 180)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Preview \(screenshot.filename)")
                                    .disabled(loadingPreview || importing)
                                    Toggle(isOn: selectionBinding(screenshot.id)) {
                                        Text("\(index + 1). \(screenshot.filename)").lineLimit(2)
                                            .font(.caption)
                                    }
                                    .toggleStyle(.checkbox)
                                }
                            }
                        }
                    }
                }
            }
            .padding(12)
        } else {
            ContentUnavailableView("Select a Collection", systemImage: "rectangle.stack")
        }
    }

    private func selectionBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { selectedScreenshotIDs.contains(id) }, set: { value in
            if value { selectedScreenshotIDs.insert(id) } else { selectedScreenshotIDs.remove(id) }
        })
    }

    private func loadCollections() async {
        guard let remoteAppID = app.appStoreConnectAppId, !remoteAppID.isEmpty else {
            collections = []; error = "Link this workspace app to an App Store Connect app first."; return
        }
        if selectedVersionID == nil {
            let preferred = orderedVersions.first(where: { $0.platform == defaultPlatform }) ?? orderedVersions.first
            guard let preferred else { collections = []; return }
            selectedVersionID = preferred.id
            return
        }
        guard let version = versions.first(where: { $0.id == selectedVersionID }) else { collections = []; return }
        loading = true
        defer { loading = false }
        do {
            try Task.checkCancellation()
            let arguments = ["screenshots", "list", "--app", remoteAppID, "--version", version.id,
                             "--platform", version.platform.uppercased(), "--output", "json"]
            let data = try await ASCIntegration.run(executablePath: executablePath, arguments: arguments)
            try Task.checkCancellation()
            let fetched = try RemoteScreenshotCollection.decode(data, version: version)
            collections = fetched.sorted {
                if $0.locale != $1.locale { return $0.locale < $1.locale }
                return $0.displayType < $1.displayType
            }
            if selectedCollectionID == nil || !collections.contains(where: { $0.id == selectedCollectionID }) {
                selectedCollectionID = collections.first?.id
            }
            selectedScreenshotIDs = Set(selectedCollection?.screenshots.map(\.id) ?? [])
        } catch is CancellationError {
            return
        } catch {
            self.error = ASCIntegration.userMessage(for: error)
        }
    }

    private func download(_ screenshot: RemoteScreenshot) async throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("IndieDevBuddy-ASC-Screenshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let filename = Self.safeFilename(screenshot.filename)
        let destination = folder.appendingPathComponent(filename)
        do {
            _ = try await ASCIntegration.run(executablePath: executablePath, arguments: [
                "screenshots", "download", "--id", screenshot.id, "--output", destination.path
            ])
            guard FileManager.default.fileExists(atPath: destination.path) else {
                throw ASCIntegrationError.invalidResponse
            }
            return destination
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    private func showPreview(_ screenshot: RemoteScreenshot) async {
        guard !loadingPreview else { return }
        loadingPreview = true
        defer { loadingPreview = false }
        do {
            let file = try await download(screenshot)
            defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
            guard let image = NSImage(contentsOf: file) else { throw ASCIntegrationError.invalidResponse }
            previewName = screenshot.filename
            previewScreenshotID = screenshot.id
            previewImage = image
        } catch { self.error = ASCIntegration.userMessage(for: error) }
    }

    private func importSelection(_ collection: RemoteScreenshotCollection) async {
        let chosen = collection.screenshots.filter { selectedScreenshotIDs.contains($0.id) }
        guard !chosen.isEmpty else { return }
        importing = true; progress = 0; notice = nil
        defer { importing = false }
        let owner = AssetOwner(.app, app.id)
        let set = ScreenshotSet(appID: app.id, platform: collection.platform, categoryID: collection.categoryID,
                                locale: collection.locale, version: collection.version, name: "App Store Connect",
                                appStoreConnectSetID: collection.remoteSetID,
                                appStoreConnectDisplayType: collection.displayType)
        let order = collection.screenshots.map(\.id)
        var failures: [String] = []
        for screenshot in chosen {
            defer { progress += 1 }
            do {
                let file = try await download(screenshot)
                defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
                _ = try await store.importAsset(
                    file, owner: owner, displayName: screenshot.filename, category: .marketing,
                    appStoreConnectScreenshotID: screenshot.id,
                    remoteScreenshotOrder: order, remoteScreenshotSet: set
                )
            } catch { failures.append("\(screenshot.filename): \(ASCIntegration.userMessage(for: error))") }
        }
        let imported = chosen.count - failures.count
        if failures.isEmpty {
            notice = imported == 1 ? "1 screenshot available in Files." : "\(imported) screenshots available in Files."
        } else {
            notice = "\(imported) available in Files. \(failures.count) failed."
            error = failures.joined(separator: "\n")
        }
    }

    private static func safeFilename(_ input: String) -> String {
        let leaf = URL(fileURLWithPath: input).lastPathComponent
        return leaf.isEmpty || leaf == "." ? "screenshot.png" : leaf
    }
}

nonisolated struct RemoteScreenshot: Identifiable, Sendable {
    let id: String
    let filename: String
    let previewURL: URL?
}

/// Entry point embedded in the app's Files panel. Versions are resolved only when the user opens the importer.
struct AppStoreScreenshotImportEntry: View {
    let apps: [AppRecord]
    let store: WorkspaceStore
    var onImportFinished: () -> Void = {}
    @AppStorage("appStoreConnectCLIPath") private var savedCLIPath = ""
    @State private var versions: [ASCVersion] = []
    @State private var executablePath: String?
    @State private var selectedApp: AppRecord?
    @State private var loading = false
    @State private var presenting = false
    @State private var error: String?

    private var linkedApps: [AppRecord] { apps.filter { !($0.appStoreConnectAppId ?? "").isEmpty } }

    @ViewBuilder var body: some View {
        Group {
            if linkedApps.count == 1 {
                Button("Import from App Store Connect", systemImage: "arrow.down.app") {
                    Task { await prepare(linkedApps[0]) }
                }
            } else {
                Menu {
                    ForEach(linkedApps) { app in
                        Button(app.name) { Task { await prepare(app) } }
                    }
                } label: {
                    Label("Import from App Store Connect", systemImage: "arrow.down.app")
                }
            }
        }
        .disabled(loading || linkedApps.isEmpty)
        .help(linkedApps.isEmpty ? "Link an app to App Store Connect before importing its screenshots." : "Browse remote screenshots and import selected images into Files.")
        .overlay(alignment: .trailing) { if loading { ProgressView().controlSize(.small).padding(.trailing, 8) } }
        .sheet(isPresented: $presenting, onDismiss: onImportFinished) {
            if let executablePath, let selectedApp {
                NavigationStack {
                    AppStoreScreenshotsView(app: selectedApp, versions: versions, executablePath: executablePath,
                                            store: store, importOnly: true)
                        .frame(minWidth: 620, minHeight: 480)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { presenting = false }
                            }
                        }
                }
            }
        }
        .alert("App Store Connect", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private func prepare(_ app: AppRecord) async {
        guard let appID = app.appStoreConnectAppId, !appID.isEmpty else { return }
        let savedExecutable = !savedCLIPath.isEmpty && FileManager.default.isExecutableFile(atPath: savedCLIPath)
            ? URL(fileURLWithPath: savedCLIPath) : nil
        guard let executable = savedExecutable ?? ASCIntegration.installedExecutable() else {
            error = "Install the asc command line tool to import screenshots."
            return
        }
        loading = true
        defer { loading = false }
        do {
            selectedApp = app
            versions = try await ASCIntegration.versions(executablePath: executable.path, appID: appID)
            guard !versions.isEmpty else { error = "No App Store versions are available for this app."; return }
            executablePath = executable.path
            presenting = true
        } catch { self.error = ASCIntegration.userMessage(for: error) }
    }
}

nonisolated struct RemoteScreenshotCollection: Identifiable, Sendable {
    let remoteSetID: String
    let version: String
    let locale: String
    let platform: ScreenshotPlatform
    let displayType: String
    let categoryID: String
    let screenshots: [RemoteScreenshot]
    var id: String { "\(remoteSetID)-\(locale)-\(version)" }
    var platformTitle: String { platform.rawValue }
    var title: String {
        let language = Locale.current.localizedString(forIdentifier: locale) ?? locale
        return "\(displayName) · \(language)"
    }

    private var displayName: String {
        if displayType == "APP_DESKTOP" { return "Mac" }
        let parts = displayType.split(separator: "_")
        if parts.count == 3, let size = Double(parts[2]) {
            if parts[1] == "IPHONE" { return "iPhone \((size / 10).formatted())″" }
            if parts[1] == "IPAD" { return "iPad \((size > 20 ? size / 10 : size).formatted())″" }
        }
        return ScreenshotSpecifications.category(categoryID)?.title ?? platformTitle
    }

    static func decode(_ data: Data, version: ASCVersion) throws -> [Self] {
        let response = try JSONDecoder().decode(RemoteScreenshotList.self, from: data)
        guard response.localizations != nil || response.sets != nil else { throw ASCIntegrationError.invalidResponse }
        let localizations = response.localizations ?? [RemoteScreenshotLocalization(locale: response.locale ?? "Unknown locale", sets: response.sets ?? [])]
        return localizations.flatMap { localization in
            localization.sets.compactMap { set in
                guard let id = set.id else { return nil }
                let display = set.displayType ?? "Screenshots"
                let platform = Self.platform(display: display, version: version)
                return Self(remoteSetID: id, version: version.number, locale: localization.locale ?? "Unknown locale",
                            platform: platform, displayType: display,
                            categoryID: Self.categoryID(display: display, platform: platform),
                            screenshots: set.screenshots.compactMap { item in
                                guard let imageID = item.id else { return nil }
                                return RemoteScreenshot(id: imageID,
                                    filename: item.filename ?? "Screenshot \(imageID.prefix(8)).png",
                                    previewURL: item.imageAsset.flatMap(Self.previewURL))
                            })
            }
        }
    }

    private static func platform(display: String, version: ASCVersion) -> ScreenshotPlatform {
        if display.localizedCaseInsensitiveContains("IPAD") { return .iPad }
        switch version.platform.uppercased() {
        case "MAC_OS": return .mac
        case "TV_OS": return .tv
        case "VISION_OS": return .vision
        default: return .iPhone
        }
    }

    private static func categoryID(display: String, platform: ScreenshotPlatform) -> String {
        let value = display.uppercased()
        switch platform {
        case .iPhone:
            if value.contains("67") || value.contains("69") { return "iphone-island-large" }
            if value.contains("65") { return "iphone-face-large" }
            if value.contains("61") || value.contains("55") { return "iphone-face-medium" }
            return "iphone-island-large"
        case .iPad:
            if value.contains("129") || value.contains("13") { return "ipad-13" }
            if value.contains("11") { return "ipad-11" }
            return "ipad-13"
        case .mac: return "mac"
        case .watch:
            return ScreenshotSpecifications.all.first(where: { $0.platform == .watch })?.id ?? "watch-series-12-10"
        case .tv: return "tv"
        case .vision: return "vision"
        }
    }

    private static func previewURL(_ asset: RemoteScreenshotImageAsset) -> URL? {
        let probe = asset.templateURL.replacingOccurrences(of: "{w}x{h}bb.{f}", with: "20x20bb.jpg")
            .replacingOccurrences(of: "{w}", with: "20")
            .replacingOccurrences(of: "{h}", with: "20")
            .replacingOccurrences(of: "{f}", with: "jpg")
        guard let components = URLComponents(string: probe), components.scheme == "https",
              let host = components.host?.lowercased(),
              (host == "mzstatic.com" || host.hasSuffix(".mzstatic.com")) else { return nil }
        let width = max(asset.width ?? 420, 1)
        let height = max(asset.height ?? 420, 1)
        let scale = min(min(420.0 / Double(width), 420.0 / Double(height)), 1)
        let targetWidth = max(Int((Double(width) * scale).rounded()), 1)
        let targetHeight = max(Int((Double(height) * scale).rounded()), 1)
        let urlString = asset.templateURL
            .replacingOccurrences(of: "{w}x{h}bb.{f}", with: "\(targetWidth)x\(targetHeight)bb.jpg")
            .replacingOccurrences(of: "{w}", with: String(targetWidth))
            .replacingOccurrences(of: "{h}", with: String(targetHeight))
            .replacingOccurrences(of: "{f}", with: "jpg")
        guard let url = URL(string: urlString), url.scheme == "https",
              let finalHost = url.host?.lowercased(), finalHost == "mzstatic.com" || finalHost.hasSuffix(".mzstatic.com") else { return nil }
        return url
    }
}

private nonisolated struct RemoteScreenshotList: Decodable, Sendable {
    let localizations: [RemoteScreenshotLocalization]?
    let locale: String?
    let sets: [RemoteScreenshotSet]?
}

private nonisolated struct RemoteScreenshotLocalization: Decodable, Sendable {
    let locale: String?
    let sets: [RemoteScreenshotSet]
    private enum CodingKeys: String, CodingKey { case locale, sets, attributes }
    private struct Attributes: Decodable { let locale: String? }
    init(locale: String?, sets: [RemoteScreenshotSet]) { self.locale = locale; self.sets = sets }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let attributes = try container.decodeIfPresent(Attributes.self, forKey: .attributes)
        locale = try container.decodeIfPresent(String.self, forKey: .locale) ?? attributes?.locale
        sets = try container.decodeIfPresent([RemoteScreenshotSet].self, forKey: .sets) ?? []
    }
}

private nonisolated struct RemoteScreenshotSet: Decodable, Sendable {
    let id: String?
    let displayType: String?
    let screenshots: [RemoteScreenshotItem]
    private enum CodingKeys: String, CodingKey { case id, displayType, screenshotDisplayType, screenshots, attributes, set }
    private struct Attributes: Decodable { let displayType: String?; let screenshotDisplayType: String? }
    private struct Core: Decodable {
        let id: String?
        let displayType: String?
        private enum CodingKeys: String, CodingKey { case id, displayType, screenshotDisplayType, attributes }
        private struct Attributes: Decodable { let displayType: String?; let screenshotDisplayType: String? }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let attributes = try container.decodeIfPresent(Attributes.self, forKey: .attributes)
            id = try container.decodeIfPresent(String.self, forKey: .id)
            displayType = try container.decodeIfPresent(String.self, forKey: .displayType)
                ?? container.decodeIfPresent(String.self, forKey: .screenshotDisplayType)
                ?? attributes?.displayType ?? attributes?.screenshotDisplayType
        }
    }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let attributes = try container.decodeIfPresent(Attributes.self, forKey: .attributes)
        let core = try container.decodeIfPresent(Core.self, forKey: .set)
        let directID = try container.decodeIfPresent(String.self, forKey: .id)
        let directDisplayType = try container.decodeIfPresent(String.self, forKey: .displayType)
        let directScreenshotDisplayType = try container.decodeIfPresent(String.self, forKey: .screenshotDisplayType)
        id = core?.id ?? directID
        displayType = core?.displayType ?? directDisplayType ?? directScreenshotDisplayType
            ?? attributes?.displayType ?? attributes?.screenshotDisplayType
        screenshots = try container.decodeIfPresent([RemoteScreenshotItem].self, forKey: .screenshots) ?? []
    }
}

private nonisolated struct RemoteScreenshotItem: Decodable, Sendable {
    let id: String?
    let filename: String?
    let imageAsset: RemoteScreenshotImageAsset?
    private enum CodingKeys: String, CodingKey { case id, fileName, imageAsset, attributes }
    private struct Attributes: Decodable { let fileName: String?; let imageAsset: RemoteScreenshotImageAsset? }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let attributes = try container.decodeIfPresent(Attributes.self, forKey: .attributes)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        filename = try container.decodeIfPresent(String.self, forKey: .fileName) ?? attributes?.fileName
        imageAsset = try container.decodeIfPresent(RemoteScreenshotImageAsset.self, forKey: .imageAsset) ?? attributes?.imageAsset
    }
}

private nonisolated struct RemoteScreenshotImageAsset: Decodable, Sendable {
    let templateURL: String
    let width: Int?
    let height: Int?
    private enum CodingKeys: String, CodingKey { case templateUrl, width, height }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        templateURL = try container.decode(String.self, forKey: .templateUrl)
        width = try container.decodeIfPresent(Int.self, forKey: .width)
        height = try container.decodeIfPresent(Int.self, forKey: .height)
    }
}
