import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AppStoreConnectView: View {
    let app: AppRecord
    let store: WorkspaceStore
    let marketingContent: [ContentRecord]
    let isActive: Bool
    let actionsEnabled: Bool
    let onOpenFiles: () -> Void
    let onOpenMarketingDraft: (String) -> Void
    let onConnect: (String) -> Void
    let onImport: (ASCAppSummary, ASCImportSelection) -> Void

    @AppStorage("appStoreConnectCLIPath") private var savedCLIPath = ""
    @State private var candidates: [ASCAppSummary] = []
    @State private var selectedCandidateID = ""
    @State private var includeName = true
    @State private var includeBundleID = true
    @State private var includeListingURL = true
    @State private var isSearching = false
    @State private var isGeneratingDraft = false
    @State private var platform = ""
    @State private var area = Area.releases
    @State private var refreshID = 0
    @State private var versions: [ASCVersion]?
    @State private var releaseStates: [String: ReleaseState] = [:]
    @State private var localizations: [String: [ASCVersionLocalization]] = [:]
    @State private var selectedVersionID: String?
    @State private var selectedLocale = ""
    @State private var editedNotes: [String: [String: String]] = [:]
    @State private var versionsError: String?
    @State private var notesError: String?
    @State private var loadingVersions = false
    @State private var loadingStatus = false
    @State private var loadingNotes = false
    @State private var creatingMarketingDraft = false

    private enum Area: String, CaseIterable {
        case releases = "Releases"
        case listing = "Listing"
        case screenshots = "Screenshots"
        case feedback = "Feedback"
        case analytics = "Analytics"
    }

    private struct ReleaseState {
        var status: ASCReleaseStatus?
        var history: [ASCReviewHistoryEntry]?
        var statusError: String?
        var historyError: String?
        var refreshedAt: Date?
    }

    private struct Request: Equatable {
        let executable: String
        let appID: String
        let refreshID: Int
    }

    private struct PlatformRequest: Equatable {
        let request: Request
        let platform: String
    }

    private struct NotesRequest: Equatable {
        let request: Request
        let versionID: String
    }

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
    private var configuredPlatforms: [String] {
        app.platforms.compactMap { name in
            switch name.lowercased().filter(\.isLetter) {
            case "ios", "iphone", "ipados", "ipad": "IOS"
            case "macos", "mac", "osx": "MAC_OS"
            case "tvos", "appletv": "TV_OS"
            case "visionos", "visionpro": "VISION_OS"
            default: nil
            }
        }
    }

    private var platforms: [String] {
        let discovered = Set(versions?.map(\.platform) ?? [])
        let values = discovered.union(configuredPlatforms)
        return values.isEmpty ? ["IOS"] : values.sorted()
    }
    private var currentPlatform: String {
        if !platform.isEmpty, platforms.contains(platform) { return platform }
        let discovered = versions?.map(\.platform) ?? []
        return configuredPlatforms.first { discovered.isEmpty || discovered.contains($0) }
            ?? discovered.sorted().first
            ?? platforms[0]
    }
    private var platformVersions: [ASCVersion] { (versions ?? []).filter { $0.platform == currentPlatform } }
    private var selectedVersion: ASCVersion? {
        platformVersions.first { $0.id == selectedVersionID } ?? platformVersions.first
    }
    private var release: ReleaseState { releaseStates[currentPlatform] ?? ReleaseState() }
    private var request: Request? {
        guard isActive, let executableURL, let connectedAppID else { return nil }
        return Request(executable: executableURL.path, appID: connectedAppID, refreshID: refreshID)
    }
    private var platformRequest: PlatformRequest? {
        request.map { PlatformRequest(request: $0, platform: currentPlatform) }
    }
    private var notesRequest: NotesRequest? {
        guard area == .releases || area == .listing, let request, let selectedVersion else { return nil }
        return NotesRequest(request: request, versionID: selectedVersion.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let connectedAppID, executableURL != nil {
                VStack(alignment: .leading, spacing: 12) {
                    linkedHeader(appID: connectedAppID)
                    Picker("App Store section", selection: $area) {
                        ForEach(Area.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                .frame(maxWidth: 980, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let executableURL {
                        if let connectedAppID {
                            if isActive { connectedArea(appID: connectedAppID, executable: executableURL.path) }
                        } else {
                            connectionSection
                            gitDraftDisclosure
                        }
                    } else {
                        ContentUnavailableView {
                            Label("App Store Connect CLI Not Found", systemImage: "terminal")
                        } description: {
                            Text("Install asc and configure its authentication, or choose the asc executable on this Mac.")
                        } actions: {
                            Button("Choose asc…", systemImage: "folder") { chooseExecutable() }
                        }
                    }
                    if !actionsEnabled {
                        issue("Save or discard your app edits before changing the link or opening marketing content.")
                    }
                    if let errorMessage { issue(errorMessage) }
                }
                .frame(maxWidth: 980, alignment: .leading)
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .defaultScrollAnchor(.top, for: .sizeChanges)
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
        .task(id: request) {
            if let request { await loadVersions(request) }
        }
        .task(id: platformRequest) {
            if let platformRequest { await loadStatus(platformRequest) }
        }
        .task(id: notesRequest) {
            if let notesRequest { await loadNotes(notesRequest) }
        }
    }

    private func linkedHeader(appID: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(release.status?.app?.name ?? app.name)
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if loadingStatus || loadingVersions {
                    ProgressView().controlSize(.small).accessibilityLabel("Refreshing releases")
                }
                Button("Refresh", systemImage: "arrow.clockwise") { refreshID += 1 }
                    .help("Refresh App Store Connect")
                Menu("Connection", systemImage: "ellipsis.circle") {
                    Button("Choose asc…") { chooseExecutable() }
                    Button("Unlink App", role: .destructive) { onConnect("") }
                        .disabled(!actionsEnabled)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            HStack {
                if platforms.count > 1 {
                    Picker("Platform", selection: Binding(get: { currentPlatform }, set: {
                        platform = $0
                        selectedVersionID = nil
                    })) {
                        ForEach(platforms, id: \.self) { Text(ASCDisplay.platform($0)).tag($0) }
                    }
                    .fixedSize()
                } else {
                    Text(ASCDisplay.platform(currentPlatform)).foregroundStyle(.secondary)
                }
                Spacer()
                if let url = URL(string: "https://appstoreconnect.apple.com/apps/\(appID)") {
                    Link("App Store Connect", destination: url)
                }
                if let url = app.appStoreURL ?? URL(string: "https://apps.apple.com/app/id\(appID)"),
                   platformVersions.contains(where: \.isLive) || app.appStoreURL != nil {
                    Link("View in App Store", destination: url)
                }
            }
            .font(.callout)
        }
    }

    @ViewBuilder private func connectedArea(appID: String, executable: String) -> some View {
        switch area {
        case .releases:
            overview
            Divider()
            releaseHistory
            Divider()
            gitDraftDisclosure
        case .listing:
            if let version = selectedVersion {
                versionPicker
                if let notesError { issue(notesError) }
                AppStoreListingView(executablePath: executable, appID: appID, platform: currentPlatform,
                                    versionID: version.id, version: version.number,
                                    primaryLocale: release.status?.app?.primaryLocale, refreshID: refreshID,
                                    localizations: localizations[version.id], mode: .listing)
            } else {
                Text(loadingVersions ? "Loading versions…" : versionsError ?? "No App Store versions for this platform.")
                    .foregroundStyle(.secondary)
            }
        case .screenshots:
            if let versions {
                AppStoreScreenshotsView(app: app, versions: versions, executablePath: executable, store: store,
                                        refreshID: refreshID, defaultPlatform: currentPlatform, onOpenFiles: onOpenFiles)
            } else {
                Text(loadingVersions ? "Loading versions…" : versionsError ?? "No App Store versions are available.")
                    .foregroundStyle(.secondary)
            }
        case .feedback:
            AppStoreListingView(executablePath: executable, appID: appID, platform: currentPlatform,
                                versionID: nil, version: nil, primaryLocale: nil, refreshID: refreshID,
                                localizations: nil, mode: .feedback)
        case .analytics:
            AppStoreAnalyticsView(executablePath: executable, appID: appID, refreshID: refreshID)
        }
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Link App Store Connect", systemImage: "app.badge").font(.headline)
                Spacer()
                Button("Choose asc…") { chooseExecutable() }
            }
            Text("Find the App Store Connect record by bundle ID or app name using your existing asc authentication.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Find App Store Connect App", systemImage: "magnifyingglass") {
                    Task { await searchApps() }
                }
                .disabled(isSearching)
                if isSearching { ProgressView().controlSize(.small) }
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
                                    .disabled(!actionsEnabled)
                                Button("Link and Import Selected") {
                                    onImport(selectedCandidate, ASCImportSelection(name: includeName, bundleID: includeBundleID, listingURL: includeListingURL))
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(!actionsEnabled || (!includeName && !includeBundleID && !includeListingURL))
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

    private var overview: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Release status").font(.headline).accessibilityAddTraits(.isHeader)
            if let error = release.statusError {
                issue(release.status == nil ? error : "Couldn’t refresh release status. Showing the previous result. \(error)")
            }
            if let versions {
                let live = versions.first { $0.platform == currentPlatform && $0.isLive }
                LabeledContent("Live version", value: live?.number ?? "None reported")
            }
            if let status = release.status {
                if let current = status.appstore {
                    LabeledContent("Latest version", value: [current.version, ASCDisplay.state(current.state)].compactMap { $0 }.joined(separator: " · "))
                }
                if let build = status.builds?.latest {
                    let identifier = [build.version, build.buildNumber.map { "build \($0)" }].compactMap { $0 }.joined(separator: " · ")
                    LabeledContent("Latest build", value: [identifier.isEmpty ? nil : identifier, ASCDisplay.state(build.processingState)].compactMap { $0 }.joined(separator: " · "))
                }
                if let review = status.review, let state = review.state {
                    LabeledContent("App Review", value: ASCDisplay.state(state))
                    if let date = ASCDisplay.date(review.submittedDate) {
                        LabeledContent("Submitted", value: date.formatted(date: .abbreviated, time: .shortened))
                    }
                } else if status.submission?.inFlight == true {
                    LabeledContent("Submission", value: "In progress")
                }
                if status.appstore?.state == "PENDING_DEVELOPER_RELEASE" {
                    Label("This version is ready for you to release in App Store Connect.", systemImage: "arrow.up.circle")
                        .foregroundStyle(.secondary)
                } else if status.summary?.health == "red" || !(status.submission?.blockingIssues ?? []).isEmpty {
                    Label("Action required in App Store Connect", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            if let refreshedAt = release.refreshedAt {
                Text("Last refreshed \(refreshedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            } else if loadingStatus {
                Text("Loading release status…").foregroundStyle(.secondary)
            }
            DisclosureGroup("Connection details") {
                if let connectedAppID { LabeledContent("App ID", value: connectedAppID) }
                if let bundleID = release.status?.app?.bundleId { LabeledContent("Bundle ID", value: bundleID) }
            }
            .font(.callout)
            .textSelection(.enabled)
        }
    }

    private var releaseHistory: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Version history").font(.headline).accessibilityAddTraits(.isHeader)
            if let versionsError {
                issue(versions == nil ? versionsError : "Couldn’t refresh versions. Showing the previous result. \(versionsError)")
            }
            if let selectedVersion {
                Table(platformVersions, selection: Binding(
                    get: { self.selectedVersion?.id },
                    set: { selectedVersionID = $0 }
                )) {
                    TableColumn("Version") { version in Text(version.number) }
                    TableColumn("Release state") { version in
                        Text(ASCDisplay.state(version.state))
                    }
                    TableColumn("Created") { version in
                        if let date = version.createdDate {
                            Text(date, format: .dateTime.year().month().day())
                        }
                    }
                }
                .frame(height: min(220, CGFloat(30 + 26 * platformVersions.count)))
                .accessibilityLabel("App Store version history")
                if let date = selectedVersion.earliestReleaseDate {
                    LabeledContent("Earliest release", value: date.formatted(date: .abbreviated, time: .shortened))
                }
                if let historyError = release.historyError {
                    issue(release.history == nil ? historyError : "Couldn’t refresh review history. \(historyError)")
                }
                let submissions = release.history?.filter { $0.matches(selectedVersion) } ?? []
                if !submissions.isEmpty {
                    DisclosureGroup("Review submissions (\(submissions.count))") {
                        ForEach(submissions) { submission in
                            HStack {
                                Text(ASCDisplay.state(submission.state))
                                if let outcome = submission.outcome, ["approved", "rejected"].contains(outcome.lowercased()) {
                                    Text(outcome.capitalized).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if let date = ASCDisplay.date(submission.submittedDate) {
                                    Text(date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
                releaseNotes(for: selectedVersion)
                let linkedDrafts = marketingContent.filter { $0.releaseId == selectedVersion.id }
                if !linkedDrafts.isEmpty {
                    DisclosureGroup("Marketing content (\(linkedDrafts.count))") {
                        ForEach(linkedDrafts) { draft in
                            Button(draft.title, systemImage: "arrow.up.right.square") {
                                onOpenMarketingDraft(draft.id)
                            }
                            .buttonStyle(.link)
                            .disabled(!actionsEnabled)
                        }
                    }
                }
            } else if loadingVersions {
                Text("Loading version history…").foregroundStyle(.secondary)
            } else if versions != nil {
                Text("No App Store versions for this platform.").foregroundStyle(.secondary)
            }
        }
    }

    private var versionPicker: some View {
        Picker("Version", selection: Binding(get: { selectedVersion?.id ?? "" }, set: { selectedVersionID = $0 })) {
            ForEach(platformVersions) { version in
                Text("\(version.number) · \(ASCDisplay.state(version.state))").tag(version.id)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func releaseNotes(for version: ASCVersion) -> some View {
        let notes = (localizations[version.id] ?? []).filter {
            !($0.whatsNew ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let locale = notes.first { $0.locale == selectedLocale }
            ?? notes.first { $0.locale == release.status?.app?.primaryLocale }
            ?? notes.first
        return VStack(alignment: .leading, spacing: 8) {
            Text("What’s New").font(.subheadline.weight(.semibold))
            if let notesError { issue(notesError) }
            if let locale {
                let draft = Binding(
                    get: { editedNotes[version.id]?[locale.locale] ?? locale.whatsNew ?? "" },
                    set: { editedNotes[version.id, default: [:]][locale.locale] = $0 }
                )
                Picker("Language", selection: Binding(get: { locale.locale }, set: { selectedLocale = $0 })) {
                    ForEach(notes) { note in
                        Text(Locale.current.localizedString(forIdentifier: note.locale) ?? note.locale).tag(note.locale)
                    }
                }
                .fixedSize()
                TextEditor(text: draft)
                    .font(.body)
                    .frame(minHeight: 110)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                    .accessibilityLabel("What’s New draft")
                HStack {
                    Button("Copy", systemImage: "doc.on.doc") { copy(draft.wrappedValue) }
                    Button("Create Marketing Draft", systemImage: "square.and.pencil") {
                        let text = draft.wrappedValue
                        Task { await createMarketingDraft(version: version, text: text) }
                    }
                    .disabled(!actionsEnabled || creatingMarketingDraft || draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if creatingMarketingDraft { ProgressView().controlSize(.small) }
                }
            } else if loadingNotes {
                Text("Loading localized release notes…").foregroundStyle(.secondary)
            } else if localizations[version.id] != nil {
                Text("This version has no What’s New text.").foregroundStyle(.secondary)
            }
        }
        .padding(.top, 4)
    }

    private var gitDraftDisclosure: some View {
        DisclosureGroup("Draft from Project History") { gitDraftSection.padding(.top, 6) }
    }

    private func issue(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.callout)
            .foregroundStyle(.orange)
            .textSelection(.enabled)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private var gitDraftSection: some View {
        VStack(alignment: .leading, spacing: 12) {
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
        } catch { errorMessage = ASCIntegration.userMessage(for: error) }
    }

    private func loadVersions(_ request: Request) async {
        loadingVersions = true
        versionsError = nil
        defer { if self.request == request { loadingVersions = false } }
        do {
            let result = try await ASCIntegration.versions(executablePath: request.executable, appID: request.appID)
            guard !Task.isCancelled, self.request == request else { return }
            versions = result
        } catch {
            guard !Task.isCancelled, self.request == request else { return }
            versionsError = ASCIntegration.userMessage(for: error)
        }
    }

    private func loadStatus(_ key: PlatformRequest) async {
        loadingStatus = true
        releaseStates[key.platform, default: ReleaseState()].statusError = nil
        releaseStates[key.platform, default: ReleaseState()].historyError = nil
        defer { if platformRequest == key { loadingStatus = false } }
        let request = key.request
        async let status: Void = loadSummary(key)
        do {
            let history = try await ASCIntegration.reviewHistory(executablePath: request.executable, appID: request.appID, platform: key.platform)
            if !Task.isCancelled, platformRequest == key {
                releaseStates[key.platform, default: ReleaseState()].history = history
            }
        } catch {
            if !Task.isCancelled, platformRequest == key {
                releaseStates[key.platform, default: ReleaseState()].historyError = ASCIntegration.userMessage(for: error)
            }
        }
        await status
    }

    private func loadSummary(_ key: PlatformRequest) async {
        do {
            let status = try await ASCIntegration.releaseStatus(executablePath: key.request.executable, appID: key.request.appID, platform: key.platform)
            guard !Task.isCancelled, platformRequest == key else { return }
            releaseStates[key.platform, default: ReleaseState()].status = status
            releaseStates[key.platform, default: ReleaseState()].refreshedAt = .now
        } catch {
            guard !Task.isCancelled, platformRequest == key else { return }
            releaseStates[key.platform, default: ReleaseState()].statusError = ASCIntegration.userMessage(for: error)
        }
    }

    private func loadNotes(_ key: NotesRequest) async {
        loadingNotes = true
        notesError = nil
        defer { if notesRequest == key { loadingNotes = false } }
        do {
            let result = try await ASCIntegration.localizations(executablePath: key.request.executable, versionID: key.versionID)
            guard !Task.isCancelled, notesRequest == key else { return }
            localizations[key.versionID] = result
        } catch {
            guard !Task.isCancelled, notesRequest == key else { return }
            notesError = ASCIntegration.userMessage(for: error)
        }
    }

    private func createMarketingDraft(version: ASCVersion, text: String) async {
        guard !creatingMarketingDraft, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        creatingMarketingDraft = true
        errorMessage = nil
        defer { creatingMarketingDraft = false }
        let record = Self.marketingDraft(app: app, version: version)
        do {
            _ = try await store.createContent(record, body: text)
            onOpenMarketingDraft(record.id)
        } catch { errorMessage = error.localizedDescription }
    }

    static func marketingDraft(app: AppRecord, version: ASCVersion) -> ContentRecord {
        var record = ContentRecord.draft(kind: .social, title: "\(app.name) \(version.number) · \(ASCDisplay.platform(version.platform))",
                                         appIDs: [app.id])
        record.releaseId = version.id
        return record
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
        } catch { errorMessage = ASCIntegration.userMessage(for: error) }
    }

    private func chooseExecutable() {
        showingExecutablePicker = true
    }
}
