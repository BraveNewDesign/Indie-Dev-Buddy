import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct AppRecordEditor: View {
    let record: AppRecord?
    let opensAppStore: Bool
    let identities: [IdentityRecord]
    let websites: [WebsiteRecord]
    let snapshot: WorkspaceSnapshot
    let workspaceStore: WorkspaceStore
    let onOpenMarketingContent: (String) -> Void
    let onSnapshotChanged: () -> Void
    let onDirtyChange: (Bool) -> Void
    let onSave: (AppRecord) async -> Bool
    @State private var name = ""
    @State private var appDescription = ""
    @State private var bundleIDs = ""
    @State private var developmentStatus = AppDevelopmentStatus.development.rawValue
    @State private var developerID = ""
    @State private var platforms = ""
    @State private var projectPath = ""
    @State private var projectURL: URL?
    @State private var projectAvailable = false
    @State private var projectMessage: String?
    @State private var draftID = UUID().uuidString.lowercased()
    @State private var repositoryURL = ""
    @State private var appStoreURL = ""
    @State private var testFlightURL = ""
    @State private var iconPath: String?
    @State private var iconPreview: NSImage?
    @State private var pendingIconData: Data?
    @State private var pendingIconRevision: String?
    @State private var pendingIconWrittenPath: String?
    @State private var iconError: String?
    @State private var showingIconPicker = false
    @State private var links: [AppWebsiteLink] = []
    @State private var saving = false
    @State private var detailTab = "Overview"
    @State private var editingOverview = false
    @State private var overviewIsDirty = false
    @State private var fileMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            appHeader
                .padding(.horizontal, 20)
                .padding(.top, 16)

            Picker("App detail", selection: $detailTab) {
                Text("Overview").tag("Overview")
                Text("Marketing").tag("Marketing")
                Text("App Store").tag("App Store")
                Text("Files").tag("Files")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 420, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            ZStack(alignment: .topLeading) {
                Group {
                    if record == nil || editingOverview {
                        overviewForm
                    } else {
                        appOverview
                    }
                }
                    .opacity(detailTab == "Overview" ? 1 : 0)
                    .allowsHitTesting(detailTab == "Overview")
                    .accessibilityHidden(detailTab != "Overview")
                if let appID = record?.id {
                    AppMarketingContentPanel(
                        appID: appID, appName: name, snapshot: snapshot, store: workspaceStore,
                        actionsEnabled: !overviewIsDirty,
                        onOpen: onOpenMarketingContent, onCreated: onSnapshotChanged
                    )
                    .opacity(detailTab == "Marketing" ? 1 : 0)
                    .allowsHitTesting(detailTab == "Marketing")
                    .accessibilityHidden(detailTab != "Marketing")
                } else {
                    ContentUnavailableView("Save App First", systemImage: "megaphone", description: Text("Save the app overview before creating related marketing content."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .opacity(detailTab == "Marketing" ? 1 : 0)
                        .allowsHitTesting(detailTab == "Marketing")
                        .accessibilityHidden(detailTab != "Marketing")
                }
                if let record {
                    AppStoreConnectView(app: record, store: workspaceStore,
                                        marketingContent: snapshot.content.filter { $0.appIds.contains(record.id) && $0.releaseId != nil },
                                        isActive: detailTab == "App Store", actionsEnabled: !overviewIsDirty,
                                        onOpenFiles: { detailTab = "Files" },
                                        onOpenMarketingDraft: onOpenMarketingContent,
                                        onConnect: { appStoreConnectID in
                        var updated = record
                        updated.appStoreConnectAppId = appStoreConnectID.isEmpty ? nil : appStoreConnectID
                        Task { await save(updated) }
                    }, onImport: { remoteApp, selection in
                        var updated = record
                        updated.appStoreConnectAppId = remoteApp.id
                        if selection.name { updated.name = remoteApp.name }
                        if selection.bundleID, !remoteApp.bundleID.isEmpty { updated.bundleIDs = [remoteApp.bundleID] }
                        if selection.listingURL { updated.appStoreURL = remoteApp.listingURL }
                        Task { await save(updated) }
                    })
                    .id(record.appStoreConnectAppId)
                    .opacity(detailTab == "App Store" ? 1 : 0)
                    .allowsHitTesting(detailTab == "App Store")
                    .accessibilityHidden(detailTab != "App Store")
                } else {
                    ContentUnavailableView("Save App First", systemImage: "app.badge", description: Text("Save the app overview before linking App Store Connect."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .opacity(detailTab == "App Store" ? 1 : 0)
                        .allowsHitTesting(detailTab == "App Store")
                        .accessibilityHidden(detailTab != "App Store")
                }
                if detailTab == "Files" { appFilesPanel }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle(record == nil ? "New App" : name)
        .onChange(of: opensAppStore, initial: true) { _, open in
            if open { detailTab = "App Store" }
        }
        .focusedSceneValue(\.workspaceSaveAction, overviewIsDirty && canSaveApp ? WorkspaceSaveAction { completion in
            Task { completion(await save()) }
        } : nil)
        .onAppear(perform: load)
        .onChange(of: record) { _, _ in
            if !editingOverview { load() }
        }
        .onChange(of: draftRecord) { _, _ in reportOverviewDirty(isDirty) }
    }

    private var appHeader: some View {
        HStack(spacing: 12) {
            Group {
                if let iconPreview {
                    Image(nsImage: iconPreview).resizable().scaledToFit()
                } else {
                    Image(systemName: "app.dashed").font(.title).foregroundStyle(.secondary)
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(name.isEmpty ? "New App" : name)
                    .font(.title.bold())
                    .accessibilityAddTraits(.isHeader)
                Text([platforms, identities.first(where: { $0.id == developerID })?.name ?? "", AppDevelopmentStatus.allCases.first(where: { $0.rawValue == developmentStatus })?.label ?? ""]
                    .filter { !$0.isEmpty }
                    .joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if record != nil && detailTab == "Overview" && !editingOverview {
                Button("Edit", systemImage: "pencil") { editingOverview = true }
            }
        }
    }

    private var appOverview: some View {
        Form {
            if !appDescription.isEmpty {
                Section("Description") { Text(appDescription).textSelection(.enabled) }
            }
            Section("App Details") {
                LabeledContent("Developer Identity", value: identities.first { $0.id == developerID }?.name ?? "Unassigned")
                LabeledContent("Platforms", value: platforms.isEmpty ? "Unspecified" : platforms)
                if !bundleIDs.isEmpty {
                    LabeledContent("Bundle IDs") { Text(bundleIDs).textSelection(.enabled) }
                }
            }
            Section("Xcode Project") {
                if projectPath.isEmpty {
                    Text("No project linked").foregroundStyle(.secondary)
                } else {
                    Text(URL(fileURLWithPath: projectPath).lastPathComponent)
                    if let projectMessage { Text(projectMessage).foregroundStyle(.secondary) }
                    if projectAvailable {
                        Button("Open Project", systemImage: "arrow.up.right.square", action: openProjectLocation)
                        Button("Reveal in Finder", systemImage: "folder", action: revealProjectLocation)
                    }
                }
            }
            if appFolderRelativePath != nil {
                Section("Workspace") {
                    Button("Reveal Existing App Assets", systemImage: "folder") { revealExistingAppAssets() }
                    if let fileMessage { Text(fileMessage).foregroundStyle(.secondary) }
                }
            }
            Section("Links") {
                if let url = record?.appStoreURL { Link("App Store Listing", destination: url) }
                if let url = record?.testFlightURL { Link("TestFlight Beta", destination: url) }
                if let url = record?.repositoryURL { Link("Source Code Repository", destination: url) }
                ForEach(links) { link in
                    let website = websites.first { $0.id == link.websiteId }
                    let websiteName = website?.name ?? "Website"
                    let purpose = websiteLinkPurposeLabel(link.purpose)
                    let label = "\(websiteName) — \(purpose)"
                    if let url = link.url ?? website?.baseURL {
                        Link(label, destination: url)
                    } else {
                        Text(label).foregroundStyle(.secondary)
                    }
                }
                if record?.appStoreURL == nil, record?.testFlightURL == nil, record?.repositoryURL == nil, links.isEmpty {
                    Text("No links added").foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
    }

    private func websiteLinkPurposeLabel(_ purpose: String) -> String {
        switch purpose.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "product": "Product page"
        case "support": "Support page"
        case "privacy": "Privacy policy"
        case "docs", "documentation": "Documentation"
        default: purpose.capitalized
        }
    }

    private func reportOverviewDirty(_ value: Bool) {
        overviewIsDirty = value
        onDirtyChange(overviewIsDirty)
    }

    @ViewBuilder private var appFilesPanel: some View {
        if let record {
            AssetLibraryView(store: workspaceStore, snapshot: snapshot,
                             scope: AssetOwner(.app, record.id), embedded: true)
                .id(record.id)
        } else {
            ContentUnavailableView("Save App First", systemImage: "folder",
                                   description: Text("Save this app before adding its assets."))
        }
    }

    private func revealExistingAppAssets() {
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
            NSWorkspace.shared.activateFileViewerSelecting([assets])
            fileMessage = nil
        } catch { fileMessage = error.localizedDescription }
    }

    private var overviewForm: some View {
        Form {
            Section("App") {
                HStack(spacing: 14) {
                    Group {
                        if let iconPreview { Image(nsImage: iconPreview).resizable().scaledToFit() }
                        else { Image(systemName: "app.dashed").resizable().scaledToFit().foregroundStyle(.secondary) }
                    }
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel(iconPreview == nil ? "No app icon selected" : "App icon preview")
                    VStack(alignment: .leading, spacing: 8) {
                        Button(iconPath == nil ? "Choose App Icon…" : "Replace App Icon…") { showingIconPicker = true }
                        if iconPath != nil {
                            Button("Clear App Icon", role: .destructive) {
                                iconPath = nil
                                iconPreview = nil
                                pendingIconData = nil
                                pendingIconRevision = nil
                                pendingIconWrittenPath = nil
                                iconError = nil
                            }
                        }
                        if let iconError { Text(iconError).font(.caption).foregroundStyle(.red) }
                        else { Text("Optional artwork copied into this app’s workspace Assets folder.").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                TextField("Name", text: $name)
                Picker("Developer identity", selection: $developerID) {
                    Text("None").tag("")
                    ForEach(identities) { Text($0.name).tag($0.id) }
                }
                TextField("Platforms (comma separated)", text: $platforms, prompt: Text("macOS, iOS"))
                Picker("Development state", selection: $developmentStatus) {
                    ForEach(AppDevelopmentStatus.allCases) { status in Text(status.label).tag(status.rawValue) }
                }
                TextField("Bundle IDs (comma separated, optional)", text: $bundleIDs, prompt: Text("com.example.app"))
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
                VStack(alignment: .leading, spacing: 6) {
                    Text("Description")
                        .font(.headline)
                    TextEditor(text: $appDescription)
                        .font(.body)
                        .frame(minHeight: 80)
                        .accessibilityLabel("App description")
                    Text("A short summary shown with this app in the workspace.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Links") {
                TextField("Repository URL", text: $repositoryURL)
                TextField("App Store URL", text: $appStoreURL)
                TextField("TestFlight URL", text: $testFlightURL)
                HStack {
                    if let url = optionalWebURL(repositoryURL) {
                        Button("Open Repository", systemImage: "arrow.up.right.square") { NSWorkspace.shared.open(url) }
                    }
                    if let url = optionalWebURL(appStoreURL) {
                        Button("Open App Store", systemImage: "arrow.up.right.square") { NSWorkspace.shared.open(url) }
                    }
                    if let url = optionalWebURL(testFlightURL) {
                        Button("Open TestFlight", systemImage: "arrow.up.right.square") { NSWorkspace.shared.open(url) }
                    }
                }
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
                        if let url = link.url {
                            Button("Open Page", systemImage: "arrow.up.right.square") { NSWorkspace.shared.open(url) }
                        }
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .fileImporter(isPresented: $showingIconPicker, allowedContentTypes: [.image], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task { await importAppIcon(from: url) }
            case .failure(let error): iconError = error.localizedDescription
            }
        }
    }

    /// Resolve the app's workspace folder by stable record ID so folder names can change safely.
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

    private var canSaveApp: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !saving
    }

    private var saveBar: some View {
        Section {
            HStack {
                Spacer()
                if record != nil {
                    Button("Done") { editingOverview = false }
                        .disabled(isDirty || saving)
                        .help("Save your changes before closing the editor.")
                }
                Button("Save App") { Task { await save() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSaveApp)
            }
        }
    }
    private func load() {
        guard let record else { return }
        name = record.name; appDescription = record.description ?? ""; bundleIDs = record.bundleIDs?.joined(separator: ", ") ?? ""
        developmentStatus = (record.developmentStatus ?? .development).rawValue
        developerID = record.developerIdentityId ?? ""; platforms = record.platforms.joined(separator: ", ")
        draftID = record.id
        projectPath = record.projectPath ?? ""; repositoryURL = record.repositoryURL?.absoluteString ?? ""; appStoreURL = record.appStoreURL?.absoluteString ?? ""; testFlightURL = record.testFlightURL?.absoluteString ?? ""; links = record.websiteLinks
        iconPath = record.iconPath
        if iconPath != nil { Task { await loadAppIconPreview() } }
        resolveProjectLocation()
    }
    @discardableResult
    private func save(_ requestedRecord: AppRecord? = nil) async -> Bool {
        guard !saving else { return false }
        if requestedRecord == nil && !canSaveApp { return false }
        saving = true
        defer { saving = false }
        do {
            if let pendingIconData, let iconPath {
                guard let appFolder = targetAppFolderRelativePath else { throw CocoaError(.fileNoSuchFile) }
                let destination = "\(appFolder)/\(iconPath)"
                pendingIconRevision = try await workspaceStore.write(
                    pendingIconData,
                    relativePath: destination,
                    expectedRevision: pendingIconWrittenPath == destination ? pendingIconRevision : nil
                )
                pendingIconWrittenPath = destination
            }
            if await onSave(requestedRecord ?? draftRecord) {
                pendingIconData = nil
                pendingIconRevision = nil
                pendingIconWrittenPath = nil
                iconError = nil
                editingOverview = false
                reportOverviewDirty(false)
                return true
            }
        } catch {
            iconError = "Could not save the app icon: \(error.localizedDescription)"
        }
        return false
    }

    private var targetAppFolderRelativePath: String? {
        if let appFolderRelativePath { return appFolderRelativePath }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return "Apps/\(Self.folderSlug(name))-\((record?.id ?? draftID).prefix(8))"
    }

    private static func folderSlug(_ text: String) -> String {
        let pieces = text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let value = pieces.prefix(8).joined(separator: "-")
        return value.isEmpty ? "record" : value
    }

    private func importAppIcon(from sourceURL: URL) async {
        let access = sourceURL.startAccessingSecurityScopedResource()
        defer { if access { sourceURL.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: sourceURL)
            guard !data.isEmpty, data.count <= 20 * 1_024 * 1_024,
                  let image = NSImage(data: data),
                  let type = UTType(filenameExtension: sourceURL.pathExtension), type.conforms(to: .image) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let ext = type.preferredFilenameExtension ?? sourceURL.pathExtension.lowercased()
            guard !ext.isEmpty, ext.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) else {
                throw CocoaError(.fileReadInvalidFileName)
            }
            iconPath = "Assets/app-icon-\(UUID().uuidString.lowercased()).\(ext)"
            pendingIconData = data
            pendingIconRevision = nil
            pendingIconWrittenPath = nil
            iconPreview = image
            iconError = nil
        } catch {
            iconError = "Could not import this app icon: \(error.localizedDescription)"
        }
    }

    private func safeAppIconRelativePath(_ iconPath: String) -> String? {
        guard !iconPath.isEmpty, !iconPath.hasPrefix("/"),
              !iconPath.split(separator: "/").contains(".."),
              let appFolderRelativePath else { return nil }
        let root = workspaceStore.rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let folder = workspaceStore.rootURL.appendingPathComponent(appFolderRelativePath, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let image = folder.appendingPathComponent(iconPath).standardizedFileURL.resolvingSymlinksInPath()
        let folderPrefix = folder.path.hasSuffix("/") ? folder.path : folder.path + "/"
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard folder.path.hasPrefix(rootPrefix), image.path.hasPrefix(folderPrefix) else { return nil }
        return "\(appFolderRelativePath)/\(iconPath)"
    }

    private func loadAppIconPreview() async {
        guard let iconPath, let safeRelativePath = safeAppIconRelativePath(iconPath) else { return }
        do {
            let data = try await workspaceStore.read(relativePath: safeRelativePath).data
            guard self.iconPath == iconPath else { return }
            iconPreview = NSImage(data: data)
            if iconPreview == nil { iconError = "The linked icon file is not a readable image. Replace or clear it." }
        } catch {
            guard self.iconPath == iconPath else { return }
            iconPreview = nil
            iconError = "The linked icon is unavailable. Replace or clear it. \(error.localizedDescription)"
        }
    }

    private var draftRecord: AppRecord {
        let parsedBundleIDs = bundleIDs.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return AppRecord(
            id: record?.id ?? draftID,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            description: appDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : appDescription,
            bundleIDs: parsedBundleIDs.isEmpty ? nil : parsedBundleIDs,
            developmentStatus: AppDevelopmentStatus(rawValue: developmentStatus) ?? .development,
            iconPath: iconPath,
            developerIdentityId: developerID.isEmpty ? nil : developerID,
            platforms: platforms.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) },
            projectPath: projectPath.isEmpty ? nil : projectPath,
            repositoryURL: optionalWebURL(repositoryURL), appStoreURL: optionalWebURL(appStoreURL),
            testFlightURL: optionalWebURL(testFlightURL),
            appStoreConnectAppId: record?.appStoreConnectAppId,
            websiteLinks: links
        )
    }

    private var isDirty: Bool {
        if var record {
            // Older records omit the state; the editor displays the same default.
            if record.developmentStatus == nil { record.developmentStatus = .development }
            if record.bundleIDs?.isEmpty == true { record.bundleIDs = nil }
            return draftRecord != record
        }
        return !draftRecord.name.isEmpty || !appDescription.isEmpty || !bundleIDs.isEmpty || developmentStatus != AppDevelopmentStatus.development.rawValue || developerID != "" || !platforms.isEmpty || !projectPath.isEmpty || !repositoryURL.isEmpty || !appStoreURL.isEmpty || !testFlightURL.isEmpty || iconPath != nil || !links.isEmpty
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
            try WorkspaceRegistry.setBookmark(bookmark, forKey: bookmarkKey)
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
        do {
            guard let bookmark = try WorkspaceRegistry.bookmark(forKey: bookmarkKey) else {
                projectURL = nil; projectAvailable = false
                projectMessage = "Access to this location is unavailable. Relink the project to continue."
                return
            }
            var isStale = false
            let url = try URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)
            guard url.startAccessingSecurityScopedResource() else {
                projectURL = nil; projectAvailable = false
                projectMessage = "macOS could not restore access to this location. Relink the project."
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }
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
                try WorkspaceRegistry.setBookmark(refreshed, forKey: bookmarkKey)
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
                Label("Save or discard app changes before opening or creating marketing content.", systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            }
            if records.isEmpty {
                ContentUnavailableView("No Marketing Content", systemImage: "megaphone", description: Text("Create an article, social post, or idea for this app."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
