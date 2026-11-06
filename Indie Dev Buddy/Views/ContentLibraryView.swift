import SwiftUI
import AppKit

struct ContentLibraryView: View {
    let snapshot: WorkspaceSnapshot
    let snapshotGeneration: Int
    let store: WorkspaceStore
    let refresh: () -> Void
    var initialSelectionID: String? = nil
    var onUnsavedChangesChange: (Bool) -> Void = { _ in }
    var initialCreateKind: ContentKind? = nil
    var onCreateRequestHandled: () -> Void = {}
    @AppStorage("selectedContentID") private var selectedID: String?
    @State private var filter = "All Content"
    @State private var search = ""
    @State private var error: String?
    @State private var editorHasUnsavedChanges = false
    @State private var requestedNavigationID: String?
    @State private var pendingCreateKind: ContentKind?
    @State private var confirmingDelete = false
    private let createRequestMarker = "__indie_dev_buddy_create__"
    private var records: [ContentRecord] {
        snapshot.content.filter { item in
            let matchesFilter = filter == "All Content" || (filter == "Blog Articles" && item.kind == .blog) || (filter == "Social Posts" && item.kind == .social) || (filter == "Ideas / Inbox" && item.status == .idea) || item.status.rawValue.capitalized == filter
            return matchesFilter && (search.isEmpty || item.title.localizedCaseInsensitiveContains(search))
        }
    }
    var body: some View {
        HSplitView {
            VStack(alignment: .leading) {
                HStack { Text("Marketing Content").font(.title2.bold()); Spacer();
                    if selectedID != nil {
                        Button("Delete", systemImage: "trash", role: .destructive) { confirmingDelete = true }
                            .help("Delete the selected post, idea, or article")
                    }
                    Menu("Create", systemImage: "plus") {
                    Button("Blog Article") { requestCreate(.blog) }
                    Button("Social Post") { requestCreate(.social) }
                    Button("Idea") { requestCreate(.idea) }
                } }
                Picker("Filter", selection: $filter) { ForEach(["All Content", "Blog Articles", "Social Posts", "Draft", "Ready", "Published", "Ideas / Inbox"], id: \.self) { Text($0) } }
                TextField("Search content", text: $search).textFieldStyle(.roundedBorder)
                if records.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: snapshot.content.isEmpty ? "text.bubble" : "magnifyingglass")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)
                        Text(emptyStateTitle)
                            .font(.headline)
                        Text(emptyStateMessage)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        if snapshot.content.isEmpty {
                            Button("Create Blog Article") { requestCreate(.blog) }
                                .buttonStyle(.borderedProminent)
                            Button("Create Social Post") { requestCreate(.social) }
                                .buttonStyle(.bordered)
                        } else {
                            Button("Clear Search and Filters") {
                                search = ""
                                filter = "All Content"
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                } else {
                    List(records, selection: Binding(get: { selectedID }, set: { value in
                        guard let value, value != selectedID else { return }
                        requestSelection(value)
                    })) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title).font(.headline)
                            Text("\(item.kind.rawValue.capitalized) · \(displayStatus(item))")
                                .foregroundStyle(.secondary).font(.caption)
                            if let plannedDate = item.plannedDate {
                                Text("Planned · \(plannedDate.formatted(date: .abbreviated, time: .omitted))")
                                    .foregroundStyle(.secondary).font(.caption)
                            }
                        }
                        .tag(item.id)
                    }
                }
            }.padding().frame(minWidth: 250, idealWidth: 300)
            if let item = snapshot.content.first(where: { $0.id == selectedID }) {
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
                            selectedID = destinationID
                            requestedNavigationID = nil
                            onUnsavedChangesChange(false)
                        }
                    },
                    onDirtyChange: { dirty in
                        editorHasUnsavedChanges = dirty
                        onUnsavedChangesChange(dirty)
                    }
                )
                .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
                .id(item.id)
            } else {
                ContentUnavailableView("Choose Marketing Content", systemImage: "doc.text", description: Text("Select an item or create a blog article, social post, or idea."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .alert("Could not create content", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
        .alert("Delete this content?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { deleteSelectedContent() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("\(snapshot.content.first(where: { $0.id == selectedID })?.title ?? "This item") and its workspace files will be permanently deleted. This also discards any unsaved edits.")
        }
        .onAppear {
            if selectedID == nil || !snapshot.content.contains(where: { $0.id == selectedID }) {
                selectedID = initialSelectionID.flatMap { id in snapshot.content.contains(where: { $0.id == id }) ? id : nil }
            }
            if let initialCreateKind { requestCreate(initialCreateKind); onCreateRequestHandled() }
        }
        .onChange(of: initialSelectionID) { _, value in if let value { requestSelection(value) } }
        .onChange(of: initialCreateKind) { _, value in if let value { requestCreate(value); onCreateRequestHandled() } }
        .onChange(of: requestedNavigationID) { _, value in if value == nil { pendingCreateKind = nil } }
    }
    private func displayStatus(_ item: ContentRecord) -> String {
        guard item.kind == .social, !item.destinations.isEmpty else { return item.status.rawValue.capitalized }
        let published = item.destinations.filter { $0.status == .published }.count
        if published == item.destinations.count { return "Published" }
        if published > 0 { return "Partially Published" }
        return item.status == .published ? "Draft" : item.status.rawValue.capitalized
    }
    private var emptyStateTitle: String {
        snapshot.content.isEmpty ? "No Marketing Content Yet" : "No Matching Content"
    }
    private var emptyStateMessage: String {
        snapshot.content.isEmpty
            ? "Create an article or social post to start planning your marketing."
            : "Try a different search or filter, or show all content."
    }
    private func requestSelection(_ id: String) {
        guard id != selectedID else { return }
        pendingCreateKind = nil
        if editorHasUnsavedChanges { requestedNavigationID = id }
        else { selectedID = id }
    }
    private func requestCreate(_ kind: ContentKind) {
        guard editorHasUnsavedChanges, selectedID != nil else { create(kind); return }
        pendingCreateKind = kind
        requestedNavigationID = createRequestMarker
    }
    private func create(_ kind: ContentKind, completion: ((String?) -> Void)? = nil) {
        let record = ContentRecord(kind: kind, title: kind == .blog ? "Untitled Article" : kind == .social ? "Untitled Social Post" : "New Idea", originalBodyPath: kind == .blog ? "body.md" : "original.txt", status: kind == .idea ? .idea : .draft)
        let folder = "Content/\(record.id)"
        Task { do {
            _ = try await store.write(Data(), relativePath: "\(folder)/\(record.originalBodyPath!)")
            _ = try await store.save(record, relativePath: "\(folder)/record.json")
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
    @State private var releaseReferences: [ComposerReleaseReference] = []
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
                        contentFolderURL: store.rootURL.appendingPathComponent(path),
                        originalText: bodyText, customizedText: variantText,
                        releases: releaseReferences,
                        characterGuidelines: ["threads": 500, "instagram": 2200, "x": 280, "facebook": 63206, "linkedin": 3000],
                        requestedNavigationID: $requestedNavigationID,
                        onSave: saveSocial, onOpenRelated: open,
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
                        Text(record.kind == .blog ? "Blog Article" : "Idea").font(.largeTitle.bold())
                        TextField("Title", text: value.title).textFieldStyle(.roundedBorder)
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
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .accessibilityLabel("Apps mentioned")
                        .accessibilityValue(appAssociationNames(for: value.wrappedValue.appIds))
                        Picker("Related release", selection: Binding(get: { value.wrappedValue.releaseId }, set: { value.wrappedValue.releaseId = $0 })) {
                            Text("None").tag(String?.none)
                            ForEach(releaseReferences.filter { $0.id == value.wrappedValue.releaseId || value.wrappedValue.appIds.isEmpty || value.wrappedValue.appIds.contains($0.appID) }) { release in
                                Text(release.displayName).tag(Optional(release.id))
                            }
                        }
                        if let releaseID = value.wrappedValue.releaseId, !releaseReferences.contains(where: { $0.id == releaseID }) {
                            Label("The linked release is unavailable. Choose another release or clear this association.", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(.orange)
                        } else if let releaseID = value.wrappedValue.releaseId,
                                  let release = releaseReferences.first(where: { $0.id == releaseID }),
                                  !value.wrappedValue.appIds.isEmpty, !value.wrappedValue.appIds.contains(release.appID) {
                            Label("This release belongs to an app not selected above. Keep the association or select its app.", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(.orange)
                        }
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
                        Text(record.kind == .blog ? "Article (Markdown)" : "Notes").font(.headline)
                        TextEditor(text: $bodyText).font(.body).frame(minHeight: 260).overlay(RoundedRectangle(cornerRadius: 5).stroke(.secondary.opacity(0.3)))
                        ContentMediaView(contentFolderURL: store.rootURL.appendingPathComponent(path), assetPaths: value.mediaPaths)
                        HStack {
                            Button(isSaving ? "Saving…" : "Save") { save(value.wrappedValue, body: bodyText) }
                                .buttonStyle(.borderedProminent).disabled(isSaving)
                            if record.kind == .blog {
                                Button("Create Related Social Post") {
                                    save(value.wrappedValue, body: bodyText) { success in
                                        if success { createRelated(value.wrappedValue) }
                                    }
                                }.disabled(isSaving)
                            }
                        }
                        let related = snapshot.relatedFamily(to: record.id)
                        if !related.isEmpty { Text("Related Content").font(.headline); ForEach(related) { item in Button(item.title) { requestedNavigationID = item.id } } }
                    }.padding(24).frame(maxWidth: 800, alignment: .leading)
                }
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
            releaseReferences = await loadReleaseReferences()
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
        item.releaseId = draft.releaseID
        item.plannedDate = draft.plannedDate
        item.status = ContentStatus(rawValue: draft.status.lowercased()) ?? .draft
        Task { do {
            try await verifyCurrentRevisions(item)
            var destinations: [ContentDestination] = item.destinations.filter { draft.preservedDestinationIDs.contains($0.accountId) }
            var pendingWrites: [WorkspaceWriteOperation] = []
            var pendingVariantAccounts: [String] = []
            for id in draft.selectedAccountIDs {
                var dest = item.destinations.first { $0.accountId == id } ?? ContentDestination(accountId: id)
                dest.mediaPaths = draft.destinationMediaOverrides[id]
                dest.status = ContentStatus(rawValue: (draft.destinationStatuses[id] ?? "Draft").lowercased()) ?? .draft
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
            item.destinations = destinations
            item.mediaPaths = draft.sharedMediaPaths
            if !destinations.isEmpty && destinations.allSatisfy({ $0.status == .published }) { item.status = .published }
            else if item.status == .published { item.status = .draft }
            pendingWrites.append(WorkspaceWriteOperation(data: Data(draft.originalText.utf8), relativePath: "\(path)/\(item.originalBodyPath ?? "original.txt")", expectedRevision: bodyRevision))
            pendingWrites.append(WorkspaceWriteOperation(data: try encodedContentRecord(item), relativePath: "\(path)/record.json", expectedRevision: recordRevision))
            let revisions = try await store.writeBatch(pendingWrites)
            for (index, accountID) in pendingVariantAccounts.enumerated() { variantRevisions[accountID] = revisions[index] }
            bodyRevision = revisions[pendingVariantAccounts.count]
            recordRevision = revisions[pendingVariantAccounts.count + 1]
            edited = item
            variantText = draft.customizedText
            baselineRecord = item
            baselineBodyText = draft.originalText
            baselineVariantText = draft.customizedText
            error = nil
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
    private func encodedContentRecord(_ item: ContentRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(item)
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
        let post = ContentRecord(kind: .social, title: "\(source.title) — Social", appIds: source.appIds, sourceContentId: source.id, releaseId: source.releaseId, originalBodyPath: "original.txt")
        Task { do {
            let folder = "Content/\(post.id)"
            _ = try await store.write(Data(), relativePath: "\(folder)/original.txt")
            _ = try await store.save(post, relativePath: "\(folder)/record.json")
            refresh(); open(post.id)
        } catch { self.error = error.localizedDescription } }
    }

    private func loadReleaseReferences() async -> [ComposerReleaseReference] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var result: [ComposerReleaseReference] = []
        for app in snapshot.apps {
            let appsURL = store.rootURL.appendingPathComponent("Apps", isDirectory: true)
            guard let appFolders = try? FileManager.default.contentsOfDirectory(at: appsURL, includingPropertiesForKeys: [.isDirectoryKey]),
                  let appFolder = appFolders.first(where: { folder in
                      guard let data = try? Data(contentsOf: folder.appendingPathComponent("record.json")),
                            let stored = try? decoder.decode(AppRecord.self, from: data) else { return false }
                      return stored.id == app.id
                  }) else { continue }
            let releasesURL = appFolder.appendingPathComponent("Releases", isDirectory: true)
            // Resolve folders by reading records and checking appId; folder names are not IDs.
            guard let folders = try? FileManager.default.contentsOfDirectory(at: releasesURL, includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
            for folder in folders where (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                let path = "Apps/\(appFolder.lastPathComponent)/Releases/\(folder.lastPathComponent)/record.json"
                guard let stored = try? await store.read(relativePath: path),
                      let release = try? decoder.decode(ReleaseRecord.self, from: stored.data), release.appId == app.id else { continue }
                result.append(ComposerReleaseReference(id: release.id, appID: app.id, appName: app.name, version: release.version, status: release.status.label, releaseDate: release.releaseDate))
            }
        }
        return result.sorted { lhs, rhs in
            let names = lhs.appName.localizedCaseInsensitiveCompare(rhs.appName)
            if names != .orderedSame { return names == .orderedAscending }
            return lhs.version.localizedStandardCompare(rhs.version) == .orderedDescending
        }
    }
}
