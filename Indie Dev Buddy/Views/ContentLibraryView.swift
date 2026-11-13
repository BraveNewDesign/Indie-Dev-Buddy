import SwiftUI
import AppKit
import SocialKit

struct ContentLibraryView: View {
    let snapshot: WorkspaceSnapshot
    let snapshotGeneration: Int
    let store: WorkspaceStore
    let refresh: () -> Void
    var initialSelectionID: String? = nil
    var onInitialSelectionHandled: () -> Void = {}
    var listResetGeneration: Int = 0
    var destination: ContentDestinationView = .calendar
    var onUnsavedChangesChange: (Bool) -> Void = { _ in }
    var initialCreateKind: ContentKind? = nil
    var onCreateRequestHandled: () -> Void = {}
    @AppStorage("selectedContentID") private var selectedID: String?
    @State private var error: String?
    @State private var editorHasUnsavedChanges = false
    @State private var requestedNavigationID: String?
    @State private var pendingCreateKind: ContentKind?
    @State private var confirmingDelete = false
    @State private var copyError: String?
    private let createRequestMarker = "__indie_dev_buddy_create__"
    private var selectedItem: ContentRecord? {
        snapshot.content.first { $0.id == selectedID }
    }

    var body: some View {
        ZStack {
            browser
                .opacity(selectedItem == nil ? 1 : 0)
                .disabled(selectedItem != nil)
                .accessibilityHidden(selectedItem != nil)
            if let item = selectedItem {
                ContentRecordEditor(
                    record: item, snapshot: snapshot, snapshotGeneration: snapshotGeneration, store: store, refresh: refresh,
                    open: requestSelection,
                    requestedNavigationID: $requestedNavigationID,
                    onNavigationConfirmed: { destinationID in
                        if destinationID == createRequestMarker, let kind = pendingCreateKind {
                            pendingCreateKind = nil
                            create(kind) { createdID in
                                guard let createdID else { return }
                                editorHasUnsavedChanges = false
                                selectedID = createdID
                                requestedNavigationID = nil
                                onUnsavedChangesChange(false)
                            }
                        } else {
                            editorHasUnsavedChanges = false
                            selectedID = destinationID == listRequestMarker ? nil : destinationID
                            requestedNavigationID = nil
                            onUnsavedChangesChange(false)
                        }
                    },
                    onDirtyChange: { dirty in
                        editorHasUnsavedChanges = dirty
                        onUnsavedChangesChange(dirty)
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(item.id)
            }
        }
        .navigationTitle(destination.rawValue)
        .toolbar {
            if selectedItem != nil {
                ToolbarItem(placement: .navigation) {
                    Button(destination.rawValue, systemImage: "chevron.left") {
                        returnToList()
                    }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu("New Content", systemImage: "plus") {
                    Button("Blog Article") { requestCreate(.blog) }
                        .keyboardShortcut("n", modifiers: .command)
                    Button("Social Post") { requestCreate(.social) }
                    Button("Idea") { requestCreate(.idea) }
                }
                .labelStyle(.iconOnly)
                .help("New Content")
            }
            if selectedItem != nil {
                ToolbarItem {
                    Menu("Content Actions", systemImage: "ellipsis.circle") {
                        Button("Delete Content…", role: .destructive) { confirmingDelete = true }
                    }
                    .labelStyle(.iconOnly)
                }
            }
        }
        .alert("Could not update content", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
        .alert("Could not copy text", isPresented: Binding(get: { copyError != nil }, set: { if !$0 { copyError = nil } })) {
            Button("OK") { copyError = nil }
        } message: {
            Text(copyError ?? "")
        }
        .alert("Delete this content?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { deleteSelectedContent() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("\(snapshot.content.first(where: { $0.id == selectedID })?.title ?? "This item") and its workspace files will be permanently deleted. This also discards any unsaved edits.")
        }
        .onAppear {
            if selectedID == nil || !snapshot.content.contains(where: { $0.id == selectedID }) {
                selectedID = nil
            }
            applyInitialSelection()
            if let initialCreateKind { requestCreate(initialCreateKind); onCreateRequestHandled() }
        }
        .onChange(of: initialSelectionID) { _, _ in applyInitialSelection() }
        .onChange(of: snapshotGeneration) { _, _ in applyInitialSelection() }
        .onChange(of: listResetGeneration) { _, _ in resetToListAfterSidebarRequest() }
        .onChange(of: initialCreateKind) { _, value in if let value { requestCreate(value); onCreateRequestHandled() } }
        .onChange(of: requestedNavigationID) { _, value in if value == nil { pendingCreateKind = nil } }
    }
    private func applyInitialSelection() {
        guard let initialSelectionID, snapshot.content.contains(where: { $0.id == initialSelectionID }) else { return }
        if selectedID != initialSelectionID { requestSelection(initialSelectionID) }
        onInitialSelectionHandled()
    }

    private let listRequestMarker = "__all_content__"

    @ViewBuilder
    private var browser: some View {
        switch destination {
        case .calendar:
            ContentCalendarView(records: snapshot.content, snapshot: snapshot, showsControls: selectedItem == nil, open: requestSelection) { kind, date in
                create(kind, plannedDate: date)
            }
        case .board:
            ContentBoardView(records: snapshot.content, snapshot: snapshot, open: requestSelection, move: move)
        default:
            ContentListView(snapshot: snapshot, stage: destination.stage, showsControls: selectedItem == nil, open: requestSelection,
                            create: requestCreate, rowActions: contentRowActions)
        }
    }

    private func move(_ id: String, to stage: ContentStage) {
        Task {
            do {
                try await store.moveContent(id: id, to: stage)
                refresh()
            } catch {
                self.error = error.localizedDescription
                refresh()
            }
        }
    }

    @ViewBuilder
    private func contentRowActions(_ item: ContentRecord) -> some View {
        Button("Open", systemImage: "arrow.right") { requestSelection(item.id) }
        Button("Copy Original Text", systemImage: "doc.on.doc") {
            Task { await copyOriginalText(item.id) }
        }
        let publishedURLs = publishedLinks(for: item)
        if publishedURLs.count == 1, let link = publishedURLs.first {
            Divider()
            Link("View Published Post", destination: link.id)
        } else if !publishedURLs.isEmpty {
            Divider()
            Menu("View Published Posts") {
                ForEach(publishedURLs) { link in
                    Link(link.title, destination: link.id)
                }
            }
        }
    }

    private struct PublishedLink: Identifiable {
        let id: URL
        let title: String
    }

    private func publishedLinks(for item: ContentRecord) -> [PublishedLink] {
        var links: [PublishedLink] = []
        if item.status == .published, let url = item.publishedURL, isWebLink(url) {
            links.append(PublishedLink(id: url, title: "Original Post"))
        }
        for destination in item.destinations where destination.status == .published {
            guard let url = destination.publishedURL, isWebLink(url),
                  !links.contains(where: { $0.id == url }) else { continue }
            let account = snapshot.socialAccountsByID[destination.accountId]
            let title = account?.displayName ?? account?.handle ?? account?.platform ?? url.absoluteString
            links.append(PublishedLink(id: url, title: title))
        }
        return links
    }

    private func isWebLink(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host != nil
    }

    private func copyOriginalText(_ id: String) async {
        do {
            let record = try await store.readRecord(.content, id: id)
            guard let body = record.body, !body.isEmpty else {
                copyError = "This item has no saved original text."
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(body, forType: .string)
        } catch {
            copyError = error.localizedDescription
        }
    }

    private func requestSelection(_ id: String) {
        guard id != selectedID else { return }
        pendingCreateKind = nil
        if editorHasUnsavedChanges { requestedNavigationID = id }
        else { selectedID = id }
    }
    private func returnToList() {
        if editorHasUnsavedChanges { requestedNavigationID = listRequestMarker }
        else {
            selectedID = nil
            requestedNavigationID = nil
            onUnsavedChangesChange(false)
        }
    }
    private func resetToListAfterSidebarRequest() {
        editorHasUnsavedChanges = false
        selectedID = nil
        requestedNavigationID = nil
        onUnsavedChangesChange(false)
    }
    private func requestCreate(_ kind: ContentKind) {
        guard editorHasUnsavedChanges, selectedID != nil else { create(kind); return }
        pendingCreateKind = kind
        requestedNavigationID = createRequestMarker
    }
    private func create(_ kind: ContentKind, plannedDate: Date? = nil, completion: ((String?) -> Void)? = nil) {
        var record = ContentRecord.draft(kind: kind, title: kind == .blog ? "Untitled Article" : kind == .social ? "Untitled Social Post" : "New Idea")
        record.plannedDate = plannedDate
        Task { do {
            try await store.createContent(record, body: "")
            refresh()
            if completion == nil { selectedID = record.id }
            completion?(record.id)
        } catch { self.error = error.localizedDescription; completion?(nil) } }
    }

    private func deleteSelectedContent() {
        guard let selectedID else { return }
        let root = store.rootURL.appendingPathComponent("Content", isDirectory: true)
        Task {
            do {
                let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
                guard let folder = folders.first(where: { candidate in
                    guard let data = try? Data(contentsOf: candidate.appendingPathComponent("record.json")),
                          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
                    return object["id"] as? String == selectedID
                }) else { throw CocoaError(.fileNoSuchFile) }
                try await store.deleteItem(relativePath: "Content/\(folder.lastPathComponent)")
                self.selectedID = nil
                editorHasUnsavedChanges = false
                onUnsavedChangesChange(false)
                refresh()
            } catch { self.error = "Could not delete this content: \(error.localizedDescription)" }
        }
    }
}

struct ContentRecordEditor: View {
    @Environment(SocialPublishingRuntime.self) private var socialPublishingRuntime
    let record: ContentRecord
    let snapshot: WorkspaceSnapshot
    let snapshotGeneration: Int
    let store: WorkspaceStore
    let refresh: () -> Void
    let open: (String) -> Void
    @Binding var requestedNavigationID: String?
    let onNavigationConfirmed: (String) -> Void
    let onDirtyChange: (Bool) -> Void
    @State private var path = ""
    @State private var recordRevision: String?
    @State private var bodyRevision: String?
    @State private var bodyText = ""
    @State private var edited: ContentRecord?
    @State private var variantText: [String: String] = [:]
    @State private var variantRevisions: [String: String] = [:]
    @State private var error: String?
    @State private var loaded = false
    @State private var socialComposerHasUnsavedChanges = false
    @State private var baselineRecord: ContentRecord?
    @State private var baselineBodyText = ""
    @State private var baselineVariantText: [String: String] = [:]
    @State private var showUnsavedChanges = false
    @State private var showConflictResolution = false
    @State private var conflictMessage: String?
    @State private var isSaving = false
    private var hasUnsavedChanges: Bool {
        loaded && (socialComposerHasUnsavedChanges || edited != baselineRecord || bodyText != baselineBodyText || variantText != baselineVariantText)
    }
    private func appAssociationNames(for ids: [String]) -> String {
        ids.compactMap { id in snapshot.apps.first(where: { $0.id == id })?.name }.joined(separator: ", ")
    }
    private func appAssociationSummary(for ids: [String]) -> String {
        switch ids.count {
        case 0: "None"
        case 1: appAssociationNames(for: ids)
        default: "\(ids.count) apps"
        }
    }
    private var editedRecordBinding: Binding<ContentRecord> {
        Binding(get: { edited ?? record }, set: { edited = $0 })
    }
    var body: some View {
        Group {
            if !loaded, let error {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                    Text("Content Could Not Be Loaded").font(.headline)
                    Text(error).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    Button("Try Again") {
                        self.error = nil
                        Task { await load() }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            }
            else if !loaded { ProgressView("Opening content…") }
            else if record.kind == .social {
                if let edited {
                    MarketingComposerView(
                        snapshot: snapshot, content: edited,
                        contentFolderURL: store.rootURL.appendingPathComponent(path), assetStore: store,
                        originalText: bodyText, customizedText: variantText,
                        characterGuidelines: ["threads": 500, "instagram": 2200, "x": 280, "facebook": 63206, "linkedin": 3000],
                        requestedNavigationID: $requestedNavigationID,
                        onSave: saveSocial, onPublishNow: publishNow, onOpenRelated: open,
                        onNavigationConfirmed: onNavigationConfirmed,
                        onDirtyChange: { dirty in
                            socialComposerHasUnsavedChanges = dirty
                            onDirtyChange(dirty)
                        }
                    )
                } else {
                    ProgressView("Opening content…")
                }
            } else {
                let value = editedRecordBinding
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text(record.kind == .blog ? "Blog Article" : "Idea")
                                .font(.headline).foregroundStyle(.secondary)
                            Spacer()
                            Button(isSaving ? "Saving…" : "Save") { save(value.wrappedValue, body: bodyText) }
                                .buttonStyle(.borderedProminent)
                                .disabled(isSaving)
                        }
                        TextField("Title", text: value.title).font(.title2.bold()).textFieldStyle(.roundedBorder)
                        Text(record.kind == .blog ? "Article (Markdown)" : "Notes").font(.headline)
                        TextEditor(text: $bodyText)
                            .font(.body)
                            .frame(minHeight: 240)
                            .border(.quaternary)
                            .accessibilityLabel(record.kind == .blog ? "Article" : "Notes")
                        ContentMediaView(contentFolderURL: store.rootURL.appendingPathComponent(path), assetPaths: value.mediaPaths)
                        Divider()
                        Text("Details").font(.headline)
                        Picker("Status", selection: value.status) { ForEach([ContentStatus.idea, .draft, .ready, .published], id: \.self) { Text($0.rawValue.capitalized).tag($0) } }
                        Toggle("Planned date", isOn: Binding(
                            get: { value.wrappedValue.plannedDate != nil },
                            set: { value.wrappedValue.plannedDate = $0 ? (value.wrappedValue.plannedDate ?? Date()) : nil }
                        ))
                        if value.wrappedValue.plannedDate != nil {
                            DatePicker("Planned", selection: Binding(
                                get: { value.wrappedValue.plannedDate ?? Date() },
                                set: { value.wrappedValue.plannedDate = $0 }
                            ), displayedComponents: .date)
                        }
                        Menu {
                            ForEach(snapshot.apps) { app in
                                Toggle(app.name, isOn: Binding(
                                    get: { value.wrappedValue.appIds.contains(app.id) },
                                    set: { selected in
                                        var updated = value.wrappedValue
                                        updated.setAppAssociation(app.id, selected: selected)
                                        value.wrappedValue = updated
                                    }
                                ))
                            }
                        } label: {
                            HStack {
                                Text("Apps mentioned")
                                Spacer()
                                Text(appAssociationSummary(for: value.wrappedValue.appIds))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .contentShape(Rectangle())
                        }
                        .accessibilityLabel("Apps mentioned")
                        .accessibilityValue(appAssociationNames(for: value.wrappedValue.appIds))
                        if record.kind == .blog {
                            Picker("Blog website", selection: Binding(get: { value.wrappedValue.websiteId ?? "" }, set: { value.wrappedValue.websiteId = $0.isEmpty ? nil : $0 })) {
                                Text("None").tag(""); ForEach(snapshot.websites.filter(\.blogEnabled)) { Text($0.name).tag($0.id) }
                            }
                            if let websiteID = value.wrappedValue.websiteId,
                               let website = snapshot.websites.first(where: { $0.id == websiteID }) {
                                Button("Open Website") {
                                    NSWorkspace.shared.open(website.blogIndexURL ?? website.baseURL)
                                }
                            }
                            TextField("Published URL", text: Binding(get: { value.wrappedValue.publishedURL?.absoluteString ?? "" }, set: { value.wrappedValue.publishedURL = $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : URL(string: $0) }))
                            TextField("Excerpt (optional)", text: Binding(
                                get: { value.wrappedValue.excerpt ?? "" },
                                set: { value.wrappedValue.excerpt = $0.isEmpty ? nil : $0 }
                            ), axis: .vertical)
                            .lineLimit(2...4)
                        }
                        if record.kind == .blog {
                            Button("Create Related Social Post") {
                                save(value.wrappedValue, body: bodyText) { success in
                                    if success { createRelated(value.wrappedValue) }
                                }
                            }.disabled(isSaving)
                        }
                        let related = snapshot.relatedFamily(to: record.id)
                        if !related.isEmpty { Text("Related Content").font(.headline); ForEach(related) { item in Button(item.title) { requestedNavigationID = item.id } } }
                    }
                    .padding(20)
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                }
                .focusedSceneValue(\.workspaceSaveAction, isSaving ? nil : WorkspaceSaveAction(saveCurrent))
            }
        }
        .task { await load() }
        .onAppear { onDirtyChange(hasUnsavedChanges) }
        .onChange(of: hasUnsavedChanges) { _, dirty in onDirtyChange(dirty) }
        .onChange(of: snapshotGeneration) { _, _ in
            guard loaded else { return }
            Task { await handleWorkspaceRefresh() }
        }
        .onChange(of: requestedNavigationID) { _, destinationID in
            guard record.kind != .social, destinationID != nil else { return }
            if hasUnsavedChanges { showUnsavedChanges = true }
            else if let destinationID { onNavigationConfirmed(destinationID) }
        }
        .confirmationDialog("Unsaved content changes", isPresented: $showUnsavedChanges, titleVisibility: .visible) {
            Button("Save and Continue") {
                guard let destinationID = requestedNavigationID else { return }
                saveCurrent { success in if success { onNavigationConfirmed(destinationID) } }
            }
            Button("Discard and Continue", role: .destructive) {
                if let destinationID = requestedNavigationID { onNavigationConfirmed(destinationID) }
            }
            Button("Cancel", role: .cancel) { requestedNavigationID = nil }
        } message: {
            Text("Save your edits before leaving, or discard them and continue.")
        }
        .confirmationDialog("Workspace content changed", isPresented: $showConflictResolution, titleVisibility: .visible) {
            Button("Keep My Local Changes") { Task { await keepLocalChanges() } }
            Button("Reload from Workspace", role: .destructive) { Task { await reloadFromWorkspace() } }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(conflictMessage ?? "The workspace changed outside the app. Choose how to continue.")
        }
        .alert("Content needs attention", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
    }
    private func load() async {
        do {
            let base = store.rootURL.appendingPathComponent("Content")
            let dirs = try FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)
            for dir in dirs {
                guard let data = try? Data(contentsOf: dir.appendingPathComponent("record.json")), let item = try? JSONSerialization.jsonObject(with: data) as? [String: Any], item["id"] as? String == record.id else { continue }
                path = "Content/\(dir.lastPathComponent)"
                let r = try await store.read(relativePath: "\(path)/record.json"); recordRevision = r.revision
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                let current = try decoder.decode(ContentRecord.self, from: r.data)
                let b = try await store.read(relativePath: "\(path)/\(current.originalBodyPath ?? "original.txt")"); guard let text = String(data: b.data, encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }; bodyText = text; bodyRevision = b.revision
                for destination in current.destinations {
                    if let p = destination.bodyPath {
                        let data = try await store.read(relativePath: "\(path)/\(p)")
                        guard let text = String(data: data.data, encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
                        variantText[destination.accountId] = text; variantRevisions[destination.accountId] = data.revision
                    }
                }
                edited = current
                baselineRecord = current
                baselineBodyText = text
                baselineVariantText = variantText
                loaded = true
                error = nil
                onDirtyChange(false)
                return
            }
            throw CocoaError(.fileNoSuchFile)
        } catch {
            let location = path.isEmpty ? "the selected workspace files" : path
            self.error = "Could not open \(record.title) from \(location): \(error.localizedDescription)"
        }
    }
    private func save(_ item: ContentRecord, body: String, completion: ((Bool) -> Void)? = nil) {
        guard !isSaving else { completion?(false); return }
        isSaving = true
        Task { do {
            try await verifyCurrentRevisions(item)
            let revisions = try await store.writeBatch([
                WorkspaceWriteOperation(data: Data(body.utf8), relativePath: "\(path)/\(item.originalBodyPath ?? "original.txt")", expectedRevision: bodyRevision),
                WorkspaceWriteOperation(data: try encodedContentRecord(item), relativePath: "\(path)/record.json", expectedRevision: recordRevision)
            ])
            bodyRevision = revisions[0]
            recordRevision = revisions[1]
            edited = item
            baselineRecord = item
            baselineBodyText = body
            baselineVariantText = variantText
            loaded = true
            error = nil
            conflictMessage = nil
            refresh()
            completion?(true)
        } catch {
            if case WorkspaceStoreError.partialWriteRecovery(let paths) = error {
                conflictMessage = "A save failed and some files could not be safely rolled back: \(paths.joined(separator: ", ")). Your local edits remain open. Review both the workspace files and this draft before continuing."
                showConflictResolution = true
            } else if case WorkspaceStoreError.conflict(let conflictPath, _) = error {
                conflictMessage = "\(conflictPath) changed outside the app. This save left the workspace version intact and kept your local edits open. Keep My Local Changes to explicitly replace it on a later save, or reload the workspace copy."
                showConflictResolution = true
            } else {
                self.error = "\(error.localizedDescription) The save was canceled or rolled back. Your edits remain open; review the workspace before retrying."
            }
            completion?(false)
        }
        isSaving = false
        }
    }
    private func saveCurrent(completion: @escaping (Bool) -> Void) {
        guard let item = edited else { completion(false); return }
        save(item, body: bodyText, completion: completion)
    }
    private func saveSocial(_ draft: ComposerDraft, completion: @escaping (Bool) -> Void) {
        guard !isSaving else { completion(false); return }
        guard var item = edited else { completion(false); return }
        isSaving = true
        item.title = draft.title; item.includeSourceLink = draft.includeArticleLink
        item.appIds = draft.appIDs
        item.plannedDate = draft.plannedDate
        item.status = ContentStatus(displayTitle: draft.status) ?? .draft
        Task { do {
            try await verifyCurrentRevisions(item)
            var destinations: [ContentDestination] = item.destinations.filter { draft.preservedDestinationIDs.contains($0.accountId) }
            var pendingWrites: [WorkspaceWriteOperation] = []
            var pendingVariantAccounts: [String] = []
            var pendingDeliveryIntents: [ContentDeliveryIntent] = []
            let workspaceRoot = store.rootURL
            let history = await socialPublishingRuntime.history(workspaceID: snapshot.manifest.id, workspaceRoot: workspaceRoot)
            let journalEntries = Dictionary(uniqueKeysWithValues: history.map { ($0.intent.id, $0) })
            for id in draft.selectedAccountIDs {
                var dest = item.destinations.first { $0.accountId == id } ?? ContentDestination(accountId: id)
                dest.mediaPaths = draft.destinationMediaOverrides[id]
                dest.status = ContentStatus(displayTitle: draft.destinationStatuses[id] ?? "Draft") ?? .draft
                if dest.status == .manuallyScheduled {
                    let date = draft.destinationScheduleDates[id] ?? Date().addingTimeInterval(3600)
                    if dest.schedule?.mode != .manual || dest.schedule?.scheduledDate != date {
                        dest.schedule = ContentSchedule(mode: .manual, scheduledDate: date)
                    }
                } else if dest.status == .scheduled {
                    let existing = dest.schedule
                    if existing?.mode == .api && !draft.rescheduleAccountIDs.contains(id) {
                        // The approved send payload is immutable across ordinary draft edits.
                        // Only the explicit Reschedule action may replace it.
                    } else {
                    let selectedDate = draft.destinationScheduleDates[id] ?? Date().addingTimeInterval(3600)
                    let scheduledDate = Date(timeIntervalSince1970: floor(selectedDate.timeIntervalSince1970))
                    let mediaLink = draft.destinationMediaLinks[id] ?? ComposerMediaLink()
                    let media = try scheduledMedia(mediaLink)
                    var candidateText = draft.customizedText[id] ?? draft.originalText
                    if draft.includeArticleLink,
                       let sourceID = item.sourceContentId,
                       let source = snapshot.content.first(where: { $0.id == sourceID }),
                       source.status == .published, let url = source.publishedURL {
                        candidateText = candidateText.isEmpty ? url.absoluteString : "\(candidateText)\n\n\(url.absoluteString)"
                    }
                    let candidateResolution = draft.mentionResolutions[id]
                    let isBluesky = snapshot.socialAccounts.first(where: { $0.id == id }).flatMap { SocialPlatform.workspacePlatform($0.platform) } == .bluesky
                    let candidateRecipient = snapshot.socialAccounts.first(where: { $0.id == id })?.providerIdentity
                    let candidateMentions = isBluesky && candidateResolution?.textSnapshot == candidateText
                        ? (candidateResolution?.mentions ?? []) : []
                    let hasSameSchedule = existing?.mode == .api && existing?.scheduledDate == scheduledDate &&
                        existing?.textSnapshot == candidateText && (existing?.media ?? []) == media &&
                        (existing?.mentions ?? []) == candidateMentions && existing?.recipient == candidateRecipient
                    if !hasSameSchedule {
                        guard scheduledDate > Date() else {
                            throw WorkspaceCommandError("Choose a future date for API delivery.")
                        }
                        let existingJournalState = existing.flatMap { journalEntries[$0.idempotencyKey]?.state }
                        guard existing?.state != .outcomeUnknown, existing?.state != .sending,
                              existingJournalState != .outcomeUnknown, existingJournalState != .sending else {
                            throw WorkspaceCommandError("Check the provider for the previous post before scheduling another delivery.")
                        }
                        guard let account = snapshot.socialAccounts.first(where: { $0.id == id }),
                              account.isEligibleDestination,
                              let platform = SocialPlatform.workspacePlatform(account.platform),
                              let identity = account.providerIdentity,
                              identity.platform == platform.rawValue else {
                            throw SocialError.invalidConfiguration
                        }
                        if media.isEmpty && !(dest.mediaPaths ?? draft.sharedMediaPaths).isEmpty {
                            throw WorkspaceCommandError("Choose manual delivery for local attachments or enter an eligible public HTTPS media link.")
                        }
                        let capabilities = try await socialPublishingRuntime.connections.capabilities(for: identity)
                        if media.isEmpty {
                            guard platform != .instagram else { throw WorkspaceCommandError("Instagram requires a public image or video link.") }
                            guard capabilities.contains(.publishText) else { throw SocialError.permissionDenied }
                        } else {
                            try Self.validateMedia(media, for: platform)
                            guard capabilities.contains(.publishMedia) else { throw SocialError.permissionDenied }
                        }
                        let key = UUID()
                        let createdAt = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
                        let text = candidateText
                        let mentions = platform == .bluesky ? candidateMentions : []
                        if platform == .bluesky {
                            let pattern = #"(?<![A-Za-z0-9._-])@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+"#
                            let expression = try NSRegularExpression(pattern: pattern)
                            let expected = expression.numberOfMatches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
                            guard mentions.count == expected else {
                                throw WorkspaceCommandError("Resolve Bluesky @mentions before API scheduling so each mention stays linked to the verified account.")
                            }
                        }
                        guard !media.isEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            throw SocialError.invalidInput
                        }
                        let intent = ContentDeliveryIntent(
                            id: key, workspaceID: snapshot.manifest.id,
                            workspaceRootPath: workspaceRoot.path,
                            contentID: item.id, destinationID: id, recipient: identity,
                            scheduledDate: scheduledDate, draftID: key, draftCreatedAt: createdAt, text: text,
                            media: media, mentions: mentions
                        )
                        dest.schedule = ContentSchedule(mode: .api, scheduledDate: scheduledDate,
                            state: .queued, textSnapshot: text, mediaURLs: media.map(\.publicURL), media: media,
                            mentions: mentions, recipient: identity,
                            draftID: key, draftCreatedAt: createdAt, idempotencyKey: key)
                        pendingDeliveryIntents.append(intent)
                    }
                    }
                } else {
                    dest.schedule = nil
                }
                dest.publishedURL = draft.destinationURLs[id].flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : URL(string: $0) }
                dest.publishedDate = draft.destinationPublicationDates[id]
                if let text = draft.customizedText[id] {
                    // A branch previously switched back to the shared original can leave an
                    // unreferenced file behind. Give a new branch a fresh path instead of
                    // resetting its revision and risking an overwrite of that orphan.
                    let p = dest.bodyPath ?? "Variants/\(id)-\(UUID().uuidString.lowercased()).txt"
                    pendingWrites.append(WorkspaceWriteOperation(data: Data(text.utf8), relativePath: "\(path)/\(p)", expectedRevision: dest.bodyPath == nil ? nil : variantRevisions[id]))
                    pendingVariantAccounts.append(id)
                    dest.bodyPath = p
                } else { dest.bodyPath = nil }
                destinations.append(dest)
            }
            let retainedSchedules = Set(destinations.compactMap { $0.schedule?.idempotencyKey })
            let canceledSchedules: Set<UUID> = Set(item.destinations.compactMap { destination in
                destination.schedule.flatMap { schedule in
                    guard schedule.mode == .api, !retainedSchedules.contains(schedule.idempotencyKey),
                          let state = journalEntries[schedule.idempotencyKey]?.state,
                          [.queued, .overdue, .sending].contains(state) else { return nil }
                    return schedule.idempotencyKey
                }
            })
            item.destinations = destinations
            item.mediaPaths = draft.sharedMediaPaths
            if !destinations.isEmpty && destinations.allSatisfy({ $0.status == .published }) { item.status = .published }
            else if !destinations.isEmpty && destinations.allSatisfy({ $0.status == .manuallyScheduled }) { item.status = .manuallyScheduled }
            else if !destinations.isEmpty && destinations.allSatisfy({ $0.status == .scheduled }) { item.status = .scheduled }
            else if item.status == .published || item.status == .scheduled || item.status == .manuallyScheduled { item.status = .draft }
            pendingWrites.append(WorkspaceWriteOperation(data: Data(draft.originalText.utf8), relativePath: "\(path)/\(item.originalBodyPath ?? "original.txt")", expectedRevision: bodyRevision))
            pendingWrites.append(WorkspaceWriteOperation(data: try encodedContentRecord(item), relativePath: "\(path)/record.json", expectedRevision: recordRevision))
            let revisions = try await store.writeContentWithAttachments(item, operations: pendingWrites)
            for (index, accountID) in pendingVariantAccounts.enumerated() { variantRevisions[accountID] = revisions[index] }
            bodyRevision = revisions[pendingVariantAccounts.count]
            recordRevision = revisions[pendingVariantAccounts.count + 1]
            edited = item
            variantText = draft.customizedText
            baselineRecord = item
            baselineBodyText = draft.originalText
            baselineVariantText = draft.customizedText
            do {
                try await socialPublishingRuntime.authorize(pendingDeliveryIntents)
                error = nil
            } catch {
                let message = "The draft was saved, but API delivery could not be authorized on this Mac. Choose a new future time to try again."
                self.error = message
                let unarmedIDs = Set(pendingDeliveryIntents.map(\.id))
                for index in item.destinations.indices {
                    guard var schedule = item.destinations[index].schedule, unarmedIDs.contains(schedule.idempotencyKey) else { continue }
                    schedule.state = .failed
                    schedule.lastError = message
                    item.destinations[index].schedule = schedule
                }
                if let newRevision = try? await store.save(item, relativePath: "\(path)/record.json", expectedRevision: recordRevision) {
                    recordRevision = newRevision
                    edited = item
                    baselineRecord = item
                }
            }
            do {
                try await socialPublishingRuntime.cancel(canceledSchedules)
            } catch {
                let cancelError = "The workspace was saved, but an older API schedule could not be retired yet. It will not send unless it still matches the saved workspace. Review delivery history before rescheduling."
                self.error = [self.error, cancelError].compactMap { $0 }.joined(separator: " ")
            }
            conflictMessage = nil
            refresh()
            isSaving = false
            completion(true)
        } catch {
            if case WorkspaceStoreError.partialWriteRecovery(let paths) = error {
                conflictMessage = "A save failed and some files could not be safely rolled back: \(paths.joined(separator: ", ")). Your local edits remain open. Review both the workspace files and this draft before continuing."
                showConflictResolution = true
            } else if case WorkspaceStoreError.conflict(let conflictPath, _) = error {
                conflictMessage = "\(conflictPath) changed outside the app. This save left the workspace version intact and kept your local edits open. Keep My Local Changes to explicitly replace it on a later save, or reload the workspace copy."
                showConflictResolution = true
            } else { self.error = "\(error.localizedDescription) The save was canceled or rolled back. Your edits remain open; review the workspace before retrying." }
            isSaving = false
            completion(false)
        } }
    }

    private func publishNow(_ draft: ComposerDraft, accountID: String, completion: @escaping (String?) -> Void) {
        saveSocial(draft) { success in
            guard success, let item = edited,
                  let account = snapshot.socialAccountsByID[accountID],
                  let identity = account.providerIdentity,
                  let platform = SocialPlatform.workspacePlatform(account.platform) else {
                completion("Save the post before publishing.")
                return
            }
            Task {
                do {
                    var media = try scheduledMedia(draft.destinationMediaLinks[accountID] ?? ComposerMediaLink())
                    try Self.validateMedia(media, for: platform)
                    let attachments = draft.destinationMediaOverrides[accountID] ?? draft.sharedMediaPaths
                    let canHost = platform == .instagram || platform == .threads
                    if !media.isEmpty || (canHost && !attachments.isEmpty) {
                        let capabilities = try await socialPublishingRuntime.connections.capabilities(for: identity)
                        guard capabilities.contains(.publishMedia) else { throw SocialError.permissionDenied }
                    }
                    if media.isEmpty && !attachments.isEmpty {
                        guard canHost else {
                            throw WorkspaceCommandError("Use a public media URL where supported, or publish manually.")
                        }
                        guard attachments.count == 1, let attachment = attachments.first,
                              !attachment.hasPrefix("/") else {
                            throw WorkspaceCommandError("Publish Now supports one local image. Select one attachment or enter a public media URL.")
                        }
                        guard let hosting = try ImageHosting.load() else {
                            throw WorkspaceCommandError("Connect your R2 bucket in Settings → Image Hosting, or enter a public media URL.")
                        }
                        let file = try await store.resolveContentMedia(attachment, recordFolder: path)
                        media = [ContentScheduledMedia(kind: .image, publicURL: try await hosting.uploadImage(at: file))]
                    }
                    if platform == .instagram && media.isEmpty {
                        throw WorkspaceCommandError("Instagram requires a public image or video URL.")
                    }
                    let text: String
                    var candidate = draft.customizedText[accountID] ?? draft.originalText
                    if draft.includeArticleLink,
                       let sourceID = item.sourceContentId,
                       let source = snapshot.contentByID[sourceID], source.status == .published,
                       let url = source.publishedURL {
                        candidate = candidate.isEmpty ? url.absoluteString : "\(candidate)\n\n\(url.absoluteString)"
                    }
                    text = candidate
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !media.isEmpty else {
                        throw SocialError.invalidInput
                    }
                    let key = UUID()
                    let createdAt = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
                    let resolved = draft.mentionResolutions[accountID]
                    let mentions = platform == .bluesky && resolved?.textSnapshot == text ? (resolved?.mentions ?? []) : []
                    if platform == .bluesky {
                        let expression = try NSRegularExpression(pattern: #"(?<![A-Za-z0-9._-])@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+"#)
                        let expected = expression.numberOfMatches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
                        guard expected == mentions.count else {
                            throw WorkspaceCommandError("Resolve Bluesky @mentions before publishing through the API.")
                        }
                    }
                    let intent = ContentDeliveryIntent(
                        id: key, workspaceID: snapshot.manifest.id,
                        workspaceRootPath: store.rootURL.standardizedFileURL.resolvingSymlinksInPath().path,
                        contentID: item.id, destinationID: accountID, recipient: identity,
                        scheduledDate: Date(), draftID: key, draftCreatedAt: createdAt,
                        text: text, media: media, mentions: mentions
                    )
                    let result = try await socialPublishingRuntime.publishNow(intent)
                    if result.state == .delivered {
                        refresh()
                        error = nil
                        completion(nil)
                    } else {
                        error = result.message ?? "The post was not confirmed as published. Review the delivery history before retrying."
                        completion(error)
                    }
                } catch {
                    self.error = error.localizedDescription
                    completion(error.localizedDescription)
                }
            }
        }
    }
    private func encodedContentRecord(_ item: ContentRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(item)
    }
    private static func validateMedia(_ media: [ContentScheduledMedia], for platform: SocialPlatform) throws {
        guard !media.isEmpty else { return }
        switch platform {
        case .facebookPages:
            guard media.count == 1, media.first?.kind == .image else {
                throw WorkspaceCommandError("Facebook Pages supports one hosted photo per API post.")
            }
        case .instagram, .threads:
            break
        default:
            throw SocialError.unsupported(.publishMedia)
        }
    }
    private func scheduledMedia(_ link: ComposerMediaLink) throws -> [ContentScheduledMedia] {
        let value = link.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return [] }
        guard let url = URL(string: value), url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else {
            throw WorkspaceCommandError("Enter a public HTTPS media URL without credentials, a query, or a fragment.")
        }
        return [ContentScheduledMedia(kind: link.kind, publicURL: url)]
    }
    private func verifyCurrentRevisions(_ item: ContentRecord) async throws {
        let recordPath = "\(path)/record.json"
        let diskRecord = try await store.read(relativePath: recordPath)
        guard diskRecord.revision == recordRevision else { throw WorkspaceStoreError.conflict(path: recordPath, currentRevision: diskRecord.revision) }
        let bodyPath = "\(path)/\(item.originalBodyPath ?? "original.txt")"
        let diskBody = try await store.read(relativePath: bodyPath)
        guard diskBody.revision == bodyRevision else { throw WorkspaceStoreError.conflict(path: bodyPath, currentRevision: diskBody.revision) }
        for destination in item.destinations {
            guard let variantPath = destination.bodyPath else { continue }
            let filePath = "\(path)/\(variantPath)"
            let variant = try await store.read(relativePath: filePath)
            guard variant.revision == variantRevisions[destination.accountId] else { throw WorkspaceStoreError.conflict(path: filePath, currentRevision: variant.revision) }
        }
    }
    private func keepLocalChanges() async {
        do {
            guard let item = edited else { return }
            let currentRecord = try await store.read(relativePath: "\(path)/record.json")
            let currentBody = try await store.read(relativePath: "\(path)/\(item.originalBodyPath ?? "original.txt")")
            recordRevision = currentRecord.revision
            bodyRevision = currentBody.revision
            var latestVariants: [String: String] = [:]
            for destination in item.destinations {
                guard let variantPath = destination.bodyPath else { continue }
                let latest = try await store.read(relativePath: "\(path)/\(variantPath)")
                latestVariants[destination.accountId] = latest.revision
            }
            variantRevisions = latestVariants
            conflictMessage = nil
            error = nil
            showConflictResolution = false
        } catch { self.error = "Could not refresh workspace revisions: \(error.localizedDescription)" }
    }

    private func reloadFromWorkspace() async {
        loaded = false
        edited = nil
        bodyText = ""
        variantText = [:]
        variantRevisions = [:]
        socialComposerHasUnsavedChanges = false
        baselineRecord = nil
        baselineBodyText = ""
        baselineVariantText = [:]
        await load()
        showConflictResolution = false
        conflictMessage = nil
        if loaded, let destinationID = requestedNavigationID { onNavigationConfirmed(destinationID) }
    }
    private func handleWorkspaceRefresh() async {
        guard let item = edited else { return }
        do {
            try await verifyCurrentRevisions(item)
        } catch WorkspaceStoreError.conflict(let conflictPath, _) {
            if hasUnsavedChanges {
                conflictMessage = "\(conflictPath) changed outside Indie Dev Buddy. Your local draft remains open. Keep My Local Changes to replace the workspace copy explicitly, or reload the workspace version."
                showConflictResolution = true
            } else {
                await reloadFromWorkspace()
            }
        } catch {
            if hasUnsavedChanges {
                conflictMessage = "Could not verify the workspace files after an external change. Your local draft remains open. Review the workspace file issue, then choose whether to keep this draft or reload. \(error.localizedDescription)"
                showConflictResolution = true
            } else {
                await reloadFromWorkspace()
            }
        }
    }
    private func createRelated(_ source: ContentRecord) {
        let post = ContentRecord(kind: .social, title: "\(source.title) — Social", appIds: source.appIds, sourceContentId: source.id, originalBodyPath: "original.txt")
        Task { do {
            let folder = "Content/\(post.id)"
            _ = try await store.write(Data(), relativePath: "\(folder)/original.txt")
            _ = try await store.save(post, relativePath: "\(folder)/record.json")
            refresh(); open(post.id)
        } catch { self.error = error.localizedDescription } }
    }
}
