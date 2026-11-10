import AppKit
import SwiftUI
import UniformTypeIdentifiers

nonisolated struct ASCAppSummary: Sendable, Equatable, Identifiable {
    let id: String
    let name: String
    let bundleID: String
    let primaryLocale: String?

    var listingURL: URL? { URL(string: "https://apps.apple.com/app/id\(id)") }
    var pickerTitle: String {
        bundleID.isEmpty ? name : "\(name) · \(bundleID)"
    }
}

nonisolated struct ASCImportSelection: Sendable {
    var name = true
    var bundleID = true
    var listingURL = true
}

nonisolated struct ASCStatusSnapshot: Sendable {
    let releaseDashboard: String
    let reviewStatus: String
    let reviewHistory: String
}

nonisolated struct ASCReleaseNotes: Sendable {
    let version: String
    let localizedNotes: [String: String]
}

nonisolated enum ASCIntegrationError: LocalizedError {
    case invalidResponse
    case appNotFound
    case releaseNotesUnavailable
    case processFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "The asc command returned data Indie Dev Buddy couldn’t read."
        case .appNotFound:
            "No matching App Store Connect app was found. Check the bundle ID and the asc account."
        case .releaseNotesUnavailable:
            "App Store Connect returned no What's New text for the selected version."
        case .processFailed(let detail): detail
        }
    }
}

nonisolated enum ASCIntegration {
    static func installedExecutable() -> URL? {
        let manager = FileManager.default
        let home = manager.homeDirectoryForCurrentUser
        let commonPaths = [
            home.appendingPathComponent(".local/bin/asc").path,
            "/opt/homebrew/bin/asc",
            "/usr/local/bin/asc",
            "/usr/bin/asc"
        ]
        let environmentPaths = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0), isDirectory: true).appendingPathComponent("asc").path }
        return (commonPaths + environmentPaths)
            .first(where: { manager.isExecutableFile(atPath: $0) })
            .map { URL(fileURLWithPath: $0) }
    }

    static func findApps(executablePath: String, bundleIDs: [String], name: String) async throws -> [ASCAppSummary] {
        var arguments = ["apps", "list"]
        let ids = bundleIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !ids.isEmpty {
            arguments += ["--bundle-id", ids.joined(separator: ",")]
        } else if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments += ["--name", name]
        }
        arguments += ["--paginate", "--output", "json"]
        let data = try await run(executablePath: executablePath, arguments: arguments)
        let summaries = try decodeApps(data)
        if !summaries.isEmpty { return summaries }

        if !ids.isEmpty, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let fallback = try await run(executablePath: executablePath, arguments: [
                "apps", "list", "--name", name, "--paginate", "--output", "json"
            ])
            return try decodeApps(fallback)
        }
        return []
    }

    static func fetchStatus(executablePath: String, appID: String, platform: String) async -> ASCStatusSnapshot {
        async let dashboard = runText(executablePath: executablePath, arguments: [
            "status", "--app", appID, "--platform", platform,
            "--include", "builds,appstore,submission,review", "--output", "table"
        ])
        async let review = runText(executablePath: executablePath, arguments: [
            "review", "status", "--app", appID, "--platform", platform, "--output", "table"
        ])
        async let history = runText(executablePath: executablePath, arguments: [
            "review", "history", "--app", appID, "--platform", platform, "--limit", "10", "--output", "table"
        ])
        return await ASCStatusSnapshot(releaseDashboard: dashboard, reviewStatus: review, reviewHistory: history)
    }

    static func fetchReleaseNotes(executablePath: String, appID: String, platform: String) async throws -> ASCReleaseNotes {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IndieDevBuddy-ASC-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        _ = try await run(executablePath: executablePath, arguments: [
            "metadata", "pull", "--app", appID, "--platform", platform,
            "--dir", directory.path, "--output", "json"
        ])

        let versionRoot = directory.appendingPathComponent("version", isDirectory: true)
        let versionFolders = (try? FileManager.default.contentsOfDirectory(at: versionRoot, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        let versionFolder = versionFolders
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }
            .first
        guard let versionFolder else { throw ASCIntegrationError.appNotFound }

        let files = (try? FileManager.default.contentsOfDirectory(at: versionFolder, includingPropertiesForKeys: nil)) ?? []
        var localizedNotes: [String: String] = [:]
        for file in files where file.pathExtension.lowercased() == "json" {
            guard let data = try? Data(contentsOf: file),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let notes = object["whatsNew"] as? String,
                  !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            localizedNotes[file.deletingPathExtension().lastPathComponent] = notes
        }
        guard !localizedNotes.isEmpty else { throw ASCIntegrationError.releaseNotesUnavailable }
        return ASCReleaseNotes(version: versionFolder.lastPathComponent, localizedNotes: localizedNotes)
    }

    static func generateReleaseNotes(executablePath: String, projectPath: String, sinceReference: String) async throws -> String {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: projectPath, isDirectory: &isDirectory) else {
            throw ASCIntegrationError.processFailed("The linked project location is unavailable. Relink it before generating notes.")
        }
        let workingDirectory = isDirectory.boolValue ? projectPath : URL(fileURLWithPath: projectPath).deletingLastPathComponent().path
        let data = try await run(
            executablePath: executablePath,
            arguments: ["release-notes", "generate", "--since-ref", sinceReference, "--until-ref", "HEAD", "--max-chars", "4000", "--output", "markdown"],
            workingDirectory: workingDirectory
        )
        let draft = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.isEmpty else { throw ASCIntegrationError.invalidResponse }
        return draft
    }

    private static func runText(executablePath: String, arguments: [String]) async -> String {
        do {
            let data = try await run(executablePath: executablePath, arguments: arguments)
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "No data returned." : text
        } catch {
            return error.localizedDescription
        }
    }

    private static func run(executablePath: String, arguments: [String], workingDirectory: String? = nil) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            try execute(executablePath: executablePath, arguments: arguments, workingDirectory: workingDirectory)
        }.value
    }

    private static func execute(executablePath: String, arguments: [String], workingDirectory: String?) throws -> Data {
        let process = Process()
        let output = Pipe()
        let errorURL = FileManager.default.temporaryDirectory.appendingPathComponent("IndieDevBuddy-ASC-error-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: errorURL.path, contents: nil),
              let errorFile = try? FileHandle(forWritingTo: errorURL) else {
            throw ASCIntegrationError.processFailed("Could not prepare a temporary error log for asc.")
        }
        defer {
            try? errorFile.close()
            try? FileManager.default.removeItem(at: errorURL)
        }
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["--read-only"] + arguments
        process.environment = ProcessInfo.processInfo.environment.merging(["ASC_READ_ONLY": "1"]) { _, new in new }
        if let workingDirectory { process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true) }
        process.standardOutput = output
        process.standardError = errorFile
        do {
            try process.run()
        } catch {
            throw ASCIntegrationError.processFailed("Could not start asc: \(error.localizedDescription)")
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            try? errorFile.synchronize()
            let errorData = try? Data(contentsOf: errorURL)
            let detail = String(decoding: errorData ?? Data(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ASCIntegrationError.processFailed(detail.isEmpty ? "asc exited with code \(process.terminationStatus)." : detail)
        }
        return data
    }

    private static func decodeApps(_ data: Data) throws -> [ASCAppSummary] {
        let root = try JSONSerialization.jsonObject(with: data)
        let objects: [[String: Any]]
        if let dictionary = root as? [String: Any] {
            objects = (dictionary["data"] as? [[String: Any]])
                ?? (dictionary["apps"] as? [[String: Any]])
                ?? (dictionary["items"] as? [[String: Any]])
                ?? []
        } else {
            objects = root as? [[String: Any]] ?? []
        }
        return objects.compactMap { object in
            let attributes = object["attributes"] as? [String: Any] ?? object
            guard let id = (object["id"] as? String) ?? (attributes["id"] as? String),
                  let name = attributes["name"] as? String else { return nil }
            let bundleID = (attributes["bundleId"] as? String) ?? (attributes["bundleID"] as? String) ?? ""
            return ASCAppSummary(id: id, name: name, bundleID: bundleID, primaryLocale: attributes["primaryLocale"] as? String)
        }
    }
}

struct AppStoreConnectView: View {
    let app: AppRecord
    let onConnect: (String) -> Void
    let onImport: (ASCAppSummary, ASCImportSelection) -> Void

    @AppStorage("appStoreConnectCLIPath") private var savedCLIPath = ""
    @State private var candidates: [ASCAppSummary] = []
    @State private var selectedCandidateID = ""
    @State private var includeName = true
    @State private var includeBundleID = true
    @State private var includeListingURL = true
    @State private var isSearching = false
    @State private var isRefreshing = false
    @State private var isFetchingNotes = false
    @State private var isGeneratingDraft = false
    @State private var status: ASCStatusSnapshot?
    @State private var lastStatusRefresh: Date?
    @State private var notes: ASCReleaseNotes?
    @State private var selectedLocale = ""
    @State private var editedNotes = ""
    @State private var sinceReference = ""
    @State private var generatedDraft = ""
    @State private var errorMessage: String?
    @State private var showingExecutablePicker = false

    private var executableURL: URL? {
        if !savedCLIPath.isEmpty, FileManager.default.isExecutableFile(atPath: savedCLIPath) {
            return URL(fileURLWithPath: savedCLIPath)
        }
        return ASCIntegration.installedExecutable()
    }
    private var selectedCandidate: ASCAppSummary? { candidates.first { $0.id == selectedCandidateID } }
    private var connectedAppID: String? { app.appStoreConnectAppId }
    private var platform: String {
        let platforms = app.platforms.joined(separator: " ").lowercased()
        if platforms.contains("vision") { return "VISION_OS" }
        if platforms.contains("tv") { return "TV_OS" }
        if platforms.contains("mac") { return "MAC_OS" }
        return "IOS"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if executableURL == nil {
                    ContentUnavailableView {
                        Label("App Store Connect CLI Not Found", systemImage: "terminal")
                    } description: {
                        Text("Install asc and configure its authentication, or choose the asc executable on this Mac.")
                    } actions: {
                        Button("Choose asc…", systemImage: "folder") { chooseExecutable() }
                    }
                } else {
                    connectionSection
                    if connectedAppID != nil {
                        liveStatusSection
                        releaseNotesSection
                    }
                    gitDraftSection
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
                Text("Indie Dev Buddy uses your existing asc authentication. These actions only read App Store Connect; importing details updates this workspace after you choose the fields.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 820, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .fileImporter(isPresented: $showingExecutablePicker, allowedContentTypes: [.executable], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first, FileManager.default.isExecutableFile(atPath: url.path) else {
                    errorMessage = "The selected file is not executable."
                    return
                }
                savedCLIPath = url.path
                errorMessage = nil
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
        .task(id: connectedAppID) {
            if connectedAppID != nil { await refreshStatus() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("App Store Connect").font(.title2.bold())
            Text("Link this workspace app to its App Store Connect record, check review progress, and reuse release notes.")
                .foregroundStyle(.secondary)
        }
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(connectedAppID == nil ? "App Record" : "Linked App Record", systemImage: "app.badge")
                    .font(.headline)
                Spacer()
                Button("Choose asc…") { chooseExecutable() }
                    .controlSize(.small)
            }
            if let connectedAppID {
                LabeledContent("App Store Connect ID", value: connectedAppID)
                    .textSelection(.enabled)
                Button("Find a different app…", systemImage: "arrow.triangle.2.circlepath") {
                    onConnect("")
                    candidates = []
                    status = nil
                    notes = nil
                }
                .controlSize(.small)
                .disabled(isSearching || isRefreshing)
            } else {
                Text("Indie Dev Buddy can match by bundle ID, then show the account’s app name and bundle ID before linking.")
                    .font(.callout).foregroundStyle(.secondary)
                Button {
                    Task { await searchApps() }
                } label: {
                    if isSearching { ProgressView().controlSize(.small) }
                    else { Label("Find App Store Connect App", systemImage: "magnifyingglass") }
                }
                .disabled(isSearching)
            }

            if !candidates.isEmpty {
                Picker("App Store Connect app", selection: $selectedCandidateID) {
                    ForEach(candidates) { item in Text(item.pickerTitle).tag(item.id) }
                }
                .frame(maxWidth: 520)
                if let selectedCandidate {
                    GroupBox("Import preview") {
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("App name: \(selectedCandidate.name)", isOn: $includeName)
                            Toggle("Bundle ID: \(selectedCandidate.bundleID.isEmpty ? "Unavailable" : selectedCandidate.bundleID)", isOn: $includeBundleID)
                                .disabled(selectedCandidate.bundleID.isEmpty)
                            Toggle("App Store listing URL", isOn: $includeListingURL)
                                .disabled(selectedCandidate.listingURL == nil)
                            Text("Developer identity, project folder, website links, and your workspace description are kept as they are.")
                                .font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("Link App") { onConnect(selectedCandidate.id) }
                                Button("Link and Import Selected") {
                                    onImport(selectedCandidate, ASCImportSelection(name: includeName, bundleID: includeBundleID, listingURL: includeListingURL))
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(!includeName && !includeBundleID && !includeListingURL)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }

    private var liveStatusSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Review and Release Status", systemImage: "checkmark.seal")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await refreshStatus() }
                } label: {
                    if isRefreshing { ProgressView().controlSize(.small) }
                    else { Label("Refresh", systemImage: "arrow.clockwise") }
                }
                .disabled(isRefreshing)
            }
            if let status {
                if let lastStatusRefresh {
                    Text("Last refreshed \(lastStatusRefresh.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                statusBlock("Release dashboard", text: status.releaseDashboard)
                statusBlock("App Review", text: status.reviewStatus)
                statusBlock("Recent review history", text: status.reviewHistory)
            } else {
                Text("Refresh to read the current App Store Connect status.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }

    private var releaseNotesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("What's New", systemImage: "text.alignleft")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await fetchNotes() }
                } label: {
                    if isFetchingNotes { ProgressView().controlSize(.small) }
                    else { Label("Fetch Release Notes", systemImage: "arrow.down.doc") }
                }
                .disabled(isFetchingNotes)
            }
            if let notes {
                Text("Version \(notes.version) · loaded from App Store Connect")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Language", selection: $selectedLocale) {
                    ForEach(notes.localizedNotes.keys.sorted(), id: \.self) { locale in Text(locale).tag(locale) }
                }
                .frame(maxWidth: 240)
                TextEditor(text: $editedNotes)
                    .font(.body)
                    .frame(minHeight: 120)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                    .accessibilityLabel("What's New draft")
                HStack {
                    Button("Copy Draft", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(editedNotes, forType: .string)
                    }
                    Text("Edit the copied text here; uploading it to App Store Connect is not part of this action.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Fetch the current version’s localized release notes into a private draft for review and reuse.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        .onChange(of: selectedLocale) { _, locale in
            editedNotes = notes?.localizedNotes[locale] ?? ""
        }
    }

    private var gitDraftSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Draft from Project History", systemImage: "arrow.triangle.branch")
                .font(.headline)
            Text("Use the linked project’s git history to prepare a What's New draft. Choose the previous release tag or commit so unrelated changes stay out.")
                .foregroundStyle(.secondary)
            HStack {
                TextField("Previous release tag or commit", text: $sinceReference, prompt: Text("v1.2.3 or commit SHA"))
                    .textFieldStyle(.roundedBorder)
                Button {
                    Task { await generateDraft() }
                } label: {
                    if isGeneratingDraft { ProgressView().controlSize(.small) }
                    else { Label("Generate Draft", systemImage: "sparkles") }
                }
                .disabled(isGeneratingDraft || app.projectPath == nil || sinceReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if app.projectPath == nil {
                Text("Link the app’s project folder in Overview to enable this action.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !generatedDraft.isEmpty {
                TextEditor(text: $generatedDraft)
                    .font(.body)
                    .frame(minHeight: 120)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                    .accessibilityLabel("Generated What's New draft")
                Button("Copy Draft", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(generatedDraft, forType: .string)
                }
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }

    private func statusBlock(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.background, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func searchApps() async {
        guard let executableURL else { chooseExecutable(); return }
        isSearching = true
        errorMessage = nil
        defer { isSearching = false }
        do {
            let found = try await ASCIntegration.findApps(
                executablePath: executableURL.path,
                bundleIDs: app.bundleIDs ?? [],
                name: app.name
            )
            candidates = found
            selectedCandidateID = found.first?.id ?? ""
            if found.isEmpty { errorMessage = ASCIntegrationError.appNotFound.localizedDescription }
        } catch { errorMessage = error.localizedDescription }
    }

    private func refreshStatus() async {
        guard let executableURL, let connectedAppID else { return }
        isRefreshing = true
        errorMessage = nil
        defer { isRefreshing = false }
        status = await ASCIntegration.fetchStatus(executablePath: executableURL.path, appID: connectedAppID, platform: platform)
        lastStatusRefresh = .now
    }

    private func fetchNotes() async {
        guard let executableURL, let connectedAppID else { return }
        isFetchingNotes = true
        errorMessage = nil
        defer { isFetchingNotes = false }
        do {
            let result = try await ASCIntegration.fetchReleaseNotes(executablePath: executableURL.path, appID: connectedAppID, platform: platform)
            notes = result
            selectedLocale = result.localizedNotes.keys.sorted().first ?? ""
            editedNotes = result.localizedNotes[selectedLocale] ?? ""
        } catch { errorMessage = error.localizedDescription }
    }

    private func generateDraft() async {
        guard let executableURL, let projectPath = app.projectPath else { return }
        isGeneratingDraft = true
        errorMessage = nil
        defer { isGeneratingDraft = false }
        do {
            generatedDraft = try await ASCIntegration.generateReleaseNotes(
                executablePath: executableURL.path,
                projectPath: projectPath,
                sinceReference: sinceReference.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        } catch { errorMessage = error.localizedDescription }
    }

    private func chooseExecutable() {
        showingExecutablePicker = true
    }
}
