import SwiftUI
import UniformTypeIdentifiers
import AppKit

private struct StoredRelease: Identifiable {
    var id: String { record.id }
    var record: ReleaseRecord
    var relativeRecordPath: String
    var recordRevision: String
}

private struct ReleaseDraft: Equatable {
    var version: String
    var status: ReleaseStatus
    var releaseDate: Date?
    var notes: String
    var externalChangelogPath: String
}

private enum PendingReleaseAction {
    case create
    case select(String)
}

/// Release list and editor for one app. `appFolderRelativePath` is the path, relative to the
/// selected workspace root, of the app's folder (for example `Apps/dictate-bar`).
/// Embed this in an app's Releases tab and pass the shared WorkspaceStore.
public struct ReleasesView: View {
    public let appID: String
    public let appName: String
    public let appFolderRelativePath: String
    public let workspaceStore: WorkspaceStore
    private let onDirtyStateChange: (Bool) -> Void

    @State private var releases: [StoredRelease] = []
    @State private var selectedID: String?
    @State private var activeReleaseID: String?
    @State private var baselineDraft: ReleaseDraft?
    @State private var pendingAction: PendingReleaseAction?
    @State private var version = ""
    @State private var status: ReleaseStatus = .planned
    @State private var releaseDate = Date()
    @State private var hasReleaseDate = false
    @State private var notes = ""
    @State private var externalChangelogPath = ""
    @State private var draftReleaseID = UUID().uuidString.lowercased()
    @State private var pendingChangelogBookmark: Data?
    @State private var hasChangelogBookmark = false
    @State private var notesRevision: String?
    @State private var notesLoadError: String?
    @State private var selectedNotesRelativePath: String?
    @State private var selectedRecordRevision: String?
    @State private var isCreating = false
    @State private var isSaving = false
    @State private var showingChangelogPicker = false
    @State private var showingUnsavedChangesConfirmation = false
    @State private var errorMessage: String?

    private var releaseFolderPath: String { "\(appFolderRelativePath)/Releases" }
    private var selectedRelease: StoredRelease? { releases.first { $0.id == selectedID } }
    private var currentDraft: ReleaseDraft {
        ReleaseDraft(
            version: version,
            status: status,
            releaseDate: hasReleaseDate ? releaseDate : nil,
            notes: notes,
            externalChangelogPath: externalChangelogPath
        )
    }
    private var hasUnsavedChanges: Bool { baselineDraft.map { $0 != currentDraft } ?? false }

    public init(
        appID: String,
        appName: String,
        appFolderRelativePath: String,
        workspaceStore: WorkspaceStore,
        onDirtyStateChange: @escaping (Bool) -> Void = { _ in }
    ) {
        self.appID = appID
        self.appName = appName
        self.appFolderRelativePath = appFolderRelativePath
        self.workspaceStore = workspaceStore
        self.onDirtyStateChange = onDirtyStateChange
    }

    public var body: some View {
        HStack(spacing: 0) {
            releaseList
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)
            Divider()
            editor
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { await loadReleases() }
        .fileImporter(isPresented: $showingChangelogPicker, allowedContentTypes: [.plainText, .markdown], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                do {
                    defer { url.stopAccessingSecurityScopedResource() }
                    pendingChangelogBookmark = try url.bookmarkData(
                        options: .withSecurityScope,
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    )
                    externalChangelogPath = url.path
                    hasChangelogBookmark = true
                } catch {
                    errorMessage = "Could not save access to the selected changelog. Check the app's bookmark entitlement, then relink the file. \(error.localizedDescription)"
                }
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
        .alert("Release Could Not Be Saved", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog("Discard unsaved release edits?", isPresented: $showingUnsavedChangesConfirmation, titleVisibility: .visible) {
            Button("Discard Edits", role: .destructive) { performPendingAction() }
            Button("Keep Editing", role: .cancel) { cancelPendingAction() }
        } message: {
            Text("Your release edits have not been saved.")
        }
        .onChange(of: currentDraft) { _, _ in reportDirtyState() }
    }

    private var releaseList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Releases").font(.title2.weight(.semibold))
                Spacer()
                Button(action: requestNewRelease) {
                    Label("Add Release", systemImage: "plus")
                }
                .labelStyle(.iconOnly)
                .help("Add Release")
                .accessibilityLabel("Add Release")
            }
            List(selection: $selectedID) {
                ForEach(releases) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.record.version.isEmpty ? "Untitled Version" : item.record.version)
                            .font(.headline)
                        HStack {
                            Text(item.record.status.label)
                            if let date = item.record.releaseDate {
                                Text("· \(date.formatted(date: .abbreviated, time: .omitted))")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .tag(item.id)
                }
            }
            .listStyle(.sidebar)
            .onChange(of: selectedID) { _, id in
                guard let id else { return }
                guard id != activeReleaseID else { return }
                if hasUnsavedChanges {
                    pendingAction = .select(id)
                    selectedID = activeReleaseID
                    showingUnsavedChangesConfirmation = true
                } else {
                    Task { await selectRelease(id) }
                }
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private var editor: some View {
        if isCreating || selectedRelease != nil {
            Form {
                Section("Version") {
                    TextField("Version number", text: $version)
                        .textFieldStyle(.roundedBorder)
                    Picker("Status", selection: $status) {
                        ForEach(ReleaseStatus.allCases) { value in Text(value.label).tag(value) }
                    }
                    Toggle("Release date", isOn: $hasReleaseDate)
                    if hasReleaseDate {
                        DatePicker("Date", selection: $releaseDate, displayedComponents: .date)
                    }
                }

                Section("Changelog") {
                    HStack {
                        TextField("External changelog path (optional)", text: $externalChangelogPath)
                            .textFieldStyle(.roundedBorder)
                            .disabled(true)
                        Button(externalChangelogPath.isEmpty ? "Choose…" : "Relink…") { showingChangelogPicker = true }
                    }
                    if !externalChangelogPath.isEmpty {
                        HStack {
                            Button("Open") { openExternalChangelog() }
                                .disabled(!hasChangelogBookmark)
                            Button("Reveal in Finder") { revealExternalChangelog() }
                                .disabled(!hasChangelogBookmark)
                            if !hasChangelogBookmark {
                                Text("Relink to restore access to this file.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Text("Or write release notes in Markdown below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $notes)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 240)
                        .accessibilityLabel("Markdown release notes")
                    if let notesLoadError {
                        Label(notesLoadError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Button("Create Empty Notes File") { Task { await createEmptyNotesFile() } }
                            .disabled(isSaving)
                    }
                }
            }
            .formStyle(.grouped)
            .padding(20)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save Release", action: { Task { await saveRelease() } })
                        .disabled(isSaving || notesLoadError != nil || version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if selectedRelease != nil && !isCreating {
                    ToolbarItem(placement: .automatic) {
                        Button("Reload", systemImage: "arrow.clockwise") { Task { await selectRelease(selectedID ?? "") } }
                            .help("Discard local edits and reload the saved release")
                    }
                }
            }
        } else {
            ContentUnavailableView("No Release Selected", systemImage: "tag", description: Text("Choose a release or add a version for \(appName)."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func beginNewRelease() {
        isCreating = true
        selectedID = nil
        activeReleaseID = nil
        selectedRecordRevision = nil
        notesRevision = nil
        notesLoadError = nil
        selectedNotesRelativePath = nil
        draftReleaseID = UUID().uuidString.lowercased()
        pendingChangelogBookmark = nil
        hasChangelogBookmark = false
        version = ""
        status = .planned
        releaseDate = Date()
        hasReleaseDate = false
        notes = ""
        externalChangelogPath = ""
        baselineDraft = currentDraft
        reportDirtyState()
    }

    private func requestNewRelease() {
        guard hasUnsavedChanges else {
            beginNewRelease()
            return
        }
        pendingAction = .create
        showingUnsavedChangesConfirmation = true
    }

    @MainActor
    private func performPendingAction() {
        let action = pendingAction
        pendingAction = nil
        switch action {
        case .create:
            beginNewRelease()
        case .select(let id):
            Task { await selectRelease(id) }
        case nil:
            break
        }
    }

    private func cancelPendingAction() {
        pendingAction = nil
        selectedID = activeReleaseID
    }

    private func reportDirtyState() {
        onDirtyStateChange(hasUnsavedChanges)
    }

    @MainActor
    private func loadReleases() async {
        let folderURL = workspaceStore.rootURL.appendingPathComponent(releaseFolderPath, isDirectory: true)
        guard let children = try? FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: [.isDirectoryKey]) else {
            releases = []
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var loaded: [StoredRelease] = []
        for child in children where (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let relativePath = "\(releaseFolderPath)/\(child.lastPathComponent)/record.json"
            guard let stored = try? await workspaceStore.read(relativePath: relativePath),
                  let record = try? decoder.decode(ReleaseRecord.self, from: stored.data),
                  record.appId == appID else { continue }
            loaded.append(StoredRelease(record: record, relativeRecordPath: relativePath, recordRevision: stored.revision))
        }
        releases = loaded.sorted { versionOrder($0.record.version, $1.record.version) }
        if let selectedID, releases.contains(where: { $0.id == selectedID }) {
            await selectRelease(selectedID)
        } else if selectedID == nil, !isCreating {
            activeReleaseID = nil
            baselineDraft = nil
            reportDirtyState()
        }
    }

    @MainActor
    private func selectRelease(_ id: String) async {
        guard let item = releases.first(where: { $0.id == id }) else { return }
        isCreating = false
        selectedID = item.id
        activeReleaseID = item.id
        draftReleaseID = item.id
        pendingChangelogBookmark = nil
        hasChangelogBookmark = (try? loadChangelogBookmark(for: item.id)) != nil
        version = item.record.version
        status = item.record.status
        releaseDate = item.record.releaseDate ?? Date()
        hasReleaseDate = item.record.releaseDate != nil
        externalChangelogPath = item.record.externalChangelogPath ?? ""
        selectedRecordRevision = item.recordRevision
        let releaseFolder = String(item.relativeRecordPath.dropLast("/record.json".count))
        let notesPath = "\(releaseFolder)/\(item.record.notesPath)"
        selectedNotesRelativePath = notesPath
        do {
            let stored = try await workspaceStore.read(relativePath: notesPath)
            notes = String(decoding: stored.data, as: UTF8.self)
            notesRevision = stored.revision
            notesLoadError = nil
        } catch {
            notes = ""
            notesRevision = nil
            notesLoadError = "Could not read \(item.record.notesPath). Saving is paused to protect its contents. Reload after fixing access, or create an empty replacement explicitly."
        }
        baselineDraft = currentDraft
        reportDirtyState()
    }

    @MainActor
    private func saveRelease() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        let cleanVersion = version.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = selectedRelease
        let folderPath: String
        let recordPath: String
        if let existing, !isCreating {
            guard cleanVersion == existing.record.version else {
                errorMessage = "Release versions are used as stable folder names. Create a new release to record a different version."
                return
            }
            recordPath = existing.relativeRecordPath
            folderPath = String(recordPath.dropLast("/record.json".count))
        } else {
            folderPath = "\(releaseFolderPath)/\(folderName(for: cleanVersion))"
            recordPath = "\(folderPath)/record.json"
            guard !FileManager.default.fileExists(atPath: workspaceStore.rootURL.appendingPathComponent(recordPath).path) else {
                errorMessage = "A release record already exists in this version folder. Reload the release list before editing."
                return
            }
        }
        let notesFileName = existing?.record.notesPath ?? "notes.md"
        let notesPath = selectedNotesRelativePath ?? "\(folderPath)/\(notesFileName)"
        let record = ReleaseRecord(
            id: selectedRelease?.record.id ?? draftReleaseID,
            appId: appID,
            version: cleanVersion,
            status: status,
            releaseDate: hasReleaseDate ? releaseDate : nil,
            notesPath: notesFileName,
            externalChangelogPath: externalChangelogPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : externalChangelogPath
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let notesData = Data(notes.utf8)

        do {
            if existing != nil, !isCreating {
                // Check the record before updating its sibling Markdown file so a known metadata
                // conflict leaves both external files untouched and keeps the local draft here.
                let currentRecord = try await workspaceStore.read(relativePath: recordPath)
                guard currentRecord.revision == selectedRecordRevision else {
                    throw WorkspaceStoreError.conflict(path: recordPath, currentRevision: currentRecord.revision)
                }
                _ = try await workspaceStore.write(notesData, relativePath: notesPath, expectedRevision: notesRevision)
                notesRevision = WorkspaceStore.revision(notesData)
                let revision = try await workspaceStore.save(record, relativePath: recordPath, expectedRevision: selectedRecordRevision)
                selectedRecordRevision = revision
            } else {
                guard !releases.contains(where: { $0.record.version.caseInsensitiveCompare(cleanVersion) == .orderedSame }) else {
                    throw WorkspaceStoreError.invalidRelativePath("A release for version \(cleanVersion) already exists.")
                }
                _ = try await workspaceStore.write(notesData, relativePath: notesPath)
                notesRevision = WorkspaceStore.revision(notesData)
                let revision = try await workspaceStore.save(record, relativePath: recordPath)
                selectedRecordRevision = revision
            }
            if let pendingChangelogBookmark {
                try saveChangelogBookmark(pendingChangelogBookmark, for: record.id)
                self.pendingChangelogBookmark = nil
                hasChangelogBookmark = true
            }
            isCreating = false
            await loadReleases()
            selectedID = record.id
            await selectRelease(record.id)
        } catch let WorkspaceStoreError.conflict(path, _) {
            errorMessage = "\(path) changed outside Indie Dev Buddy. The external file was left intact and your local edits remain in the editor. Reload will discard those local edits."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func createEmptyNotesFile() async {
        guard let path = selectedNotesRelativePath else { return }
        do {
            let revision = try await workspaceStore.write(Data(), relativePath: path)
            notesRevision = revision
            notes = ""
            notesLoadError = nil
            baselineDraft = currentDraft
            reportDirtyState()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func openExternalChangelog() {
        withBookmarkedChangelog { url in _ = NSWorkspace.shared.open(url) }
    }

    private func revealExternalChangelog() {
        withBookmarkedChangelog { url in NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    private func withBookmarkedChangelog(_ action: (URL) -> Void) {
        do {
            let bookmark: Data?
            if let pendingChangelogBookmark {
                bookmark = pendingChangelogBookmark
            } else {
                bookmark = try loadChangelogBookmark(for: draftReleaseID)
            }
            guard let bookmark else { throw CocoaError(.fileNoSuchFile) }
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            guard url.startAccessingSecurityScopedResource() else {
                throw CocoaError(.fileReadNoPermission)
            }
            defer { url.stopAccessingSecurityScopedResource() }
            guard FileManager.default.fileExists(atPath: url.path) else { throw CocoaError(.fileNoSuchFile) }
            if isStale {
                let refreshed = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                if pendingChangelogBookmark != nil {
                    pendingChangelogBookmark = refreshed
                } else {
                    try saveChangelogBookmark(refreshed, for: draftReleaseID)
                }
            }
            externalChangelogPath = url.path
            action(url)
        } catch {
            hasChangelogBookmark = false
            errorMessage = "The changelog location is unavailable. Relink the file to restore access. \(error.localizedDescription)"
        }
    }

    private func loadChangelogBookmark(for releaseID: String) throws -> Data? {
        let url = try bookmarkStoreURL(createDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard let bookmarks = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Data] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        return bookmarks[releaseID]
    }

    private func saveChangelogBookmark(_ bookmark: Data, for releaseID: String) throws {
        let url = try bookmarkStoreURL(createDirectory: true)
        var bookmarks: [String: Data] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            guard let decoded = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Data] else {
                throw CocoaError(.propertyListReadCorrupt)
            }
            bookmarks = decoded
        }
        bookmarks[releaseID] = bookmark
        let data = try PropertyListSerialization.data(fromPropertyList: bookmarks, format: .binary, options: 0)
        try data.write(to: url, options: .atomic)
    }

    private func bookmarkStoreURL(createDirectory: Bool) throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: createDirectory)
        let directory = support.appendingPathComponent("Indie Dev Buddy", isDirectory: true)
        if createDirectory { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        return directory.appendingPathComponent("ReleaseChangelogBookmarks.plist")
    }

    private func folderName(for version: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let result = version.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let cleaned = String(result).trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
        return cleaned.isEmpty ? "untitled" : cleaned
    }

    private func versionOrder(_ lhs: String, _ rhs: String) -> Bool {
        let left = lhs.split(separator: ".").compactMap { Int($0) }
        let right = rhs.split(separator: ".").compactMap { Int($0) }
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l > r }
        }
        return lhs.localizedStandardCompare(rhs) == .orderedDescending
    }
}
