import SwiftUI
import AppKit

struct ContentLibraryView: View {
    let snapshot: WorkspaceSnapshot
    let store: WorkspaceStore
    let refresh: () -> Void
    var initialSelectionID: String? = nil
    var onUnsavedChangesChange: (Bool) -> Void = { _ in }
    @State private var selectedID: String?
    @State private var filter = "All Content"
    @State private var search = ""
    @State private var error: String?
    @State private var editorHasUnsavedChanges = false
    @State private var requestedNavigationID: String?
    @State private var pendingCreateKind: ContentKind?
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
                HStack { Text("Marketing Content").font(.title2.bold()); Spacer(); Menu("Create", systemImage: "plus") {
                    Button("Blog Article") { requestCreate(.blog) }
                    Button("Social Post") { requestCreate(.social) }
                    Button("Idea") { requestCreate(.idea) }
                } }
                Picker("Filter", selection: $filter) { ForEach(["All Content", "Blog Articles", "Social Posts", "Draft", "Ready", "Published", "Ideas / Inbox"], id: \.self) { Text($0) } }
                TextField("Search content", text: $search).textFieldStyle(.roundedBorder)
                List(records, selection: Binding(get: { selectedID }, set: { value in
                    guard let value, value != selectedID else { return }
                    requestSelection(value)
                })) { item in
                    VStack(alignment: .leading) { Text(item.title).font(.headline); Text("\(item.kind.rawValue.capitalized) · \(displayStatus(item))").foregroundStyle(.secondary).font(.caption) }.tag(item.id)
                }
            }.padding().frame(minWidth: 250, idealWidth: 300)
            if let item = snapshot.content.first(where: { $0.id == selectedID }) {
                ContentRecordEditor(
                    record: item, snapshot: snapshot, store: store, refresh: refresh,
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
                ).id(item.id)
            } else {
                ContentUnavailableView("Choose Marketing Content", systemImage: "doc.text", description: Text("Select an item or create a blog article, social post, or idea."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .alert("Could not create content", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
        .onAppear { if selectedID == nil { selectedID = initialSelectionID } }
        .onChange(of: initialSelectionID) { _, value in if let value { requestSelection(value) } }
        .onChange(of: requestedNavigationID) { _, value in if value == nil { pendingCreateKind = nil } }
    }
    private func displayStatus(_ item: ContentRecord) -> String {
        guard item.kind == .social, !item.destinations.isEmpty else { return item.status.rawValue.capitalized }
        let published = item.destinations.filter { $0.status == .published }.count
        if published == item.destinations.count { return "Published" }
        if published > 0 { return "Partially Published" }
        return item.status == .published ? "Draft" : item.status.rawValue.capitalized
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
}

struct ContentRecordEditor: View {
    let record: ContentRecord
    let snapshot: WorkspaceSnapshot
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
    @State private var baselineRecord: ContentRecord?
    @State private var baselineBodyText = ""
    @State private var baselineVariantText: [String: String] = [:]
    @State private var showUnsavedChanges = false
    @State private var showConflictResolution = false
    @State private var conflictMessage: String?
    @State private var isSaving = false
    private var hasUnsavedChanges: Bool {
        loaded && (edited != baselineRecord || bodyText != baselineBodyText || variantText != baselineVariantText)
    }
    var body: some View {
        Group {
            if !loaded { ProgressView("Opening content…") }
            else if record.kind == .social, let edited {
                MarketingComposerView(
                    snapshot: snapshot, content: edited,
                    contentFolderURL: store.rootURL.appendingPathComponent(path),
                    originalText: bodyText, customizedText: variantText,
                    characterGuidelines: ["threads": 500, "instagram": 2200, "x": 280, "facebook": 63206, "linkedin": 3000],
                    requestedNavigationID: $requestedNavigationID,
                    onSave: saveSocial, onOpenRelated: open,
                    onNavigationConfirmed: onNavigationConfirmed,
                    onDirtyChange: onDirtyChange
                )
            } else if let value = Binding($edited) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(record.kind == .blog ? "Blog Article" : "Idea").font(.largeTitle.bold())
                        TextField("Title", text: value.title).textFieldStyle(.roundedBorder)
                        Picker("Status", selection: value.status) { ForEach([ContentStatus.idea, .draft, .ready, .published], id: \.self) { Text($0.rawValue.capitalized).tag($0) } }
                        Picker("App", selection: Binding(get: { value.wrappedValue.appIds.first ?? "" }, set: { value.wrappedValue.appIds = $0.isEmpty ? [] : [$0] })) {
                            Text("None").tag(""); ForEach(snapshot.apps) { Text($0.name).tag($0.id) }
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
                        let related = snapshot.content.filter { $0.sourceContentId == record.id }
                        if !related.isEmpty { Text("Related Content").font(.headline); ForEach(related) { item in Button(item.title) { requestedNavigationID = item.id } } }
                    }.padding(24).frame(maxWidth: 800, alignment: .leading)
                }
            }
        }
        .task { await load() }
        .onAppear { onDirtyChange(hasUnsavedChanges) }
        .onChange(of: hasUnsavedChanges) { _, dirty in onDirtyChange(dirty) }
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
        .alert("Content could not be saved", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
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
                onDirtyChange(false)
                return
            }
            throw CocoaError(.fileNoSuchFile)
        } catch { self.error = error.localizedDescription }
    }
    private func save(_ item: ContentRecord, body: String, completion: ((Bool) -> Void)? = nil) {
        guard !isSaving else { completion?(false); return }
        isSaving = true
        Task { do {
            try await verifyCurrentRevisions(item)
            let newBody = try await store.write(Data(body.utf8), relativePath: "\(path)/\(item.originalBodyPath ?? "original.txt")", expectedRevision: bodyRevision)
            bodyRevision = newBody
            let newRecord = try await store.save(item, relativePath: "\(path)/record.json", expectedRevision: recordRevision)
            recordRevision = newRecord
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
            if case WorkspaceStoreError.conflict(let conflictPath, _) = error {
                conflictMessage = "\(conflictPath) changed outside the app. Earlier writes may already have saved some files. Keep your local version or reload the workspace copy."
                showConflictResolution = true
            } else {
                self.error = "\(error.localizedDescription) Some files may already have been saved. Your edits remain open; review the workspace before retrying."
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
        guard var item = edited else { completion(false); return }
        item.title = draft.title; item.includeSourceLink = draft.includeArticleLink
        item.appIds = draft.appIDs
        item.status = ContentStatus(rawValue: draft.status.lowercased()) ?? .draft
        Task { do {
            try await verifyCurrentRevisions(item)
            var destinations: [ContentDestination] = item.destinations.filter { draft.preservedDestinationIDs.contains($0.accountId) }
            for id in draft.selectedAccountIDs {
                var dest = item.destinations.first { $0.accountId == id } ?? ContentDestination(accountId: id)
                dest.mediaPaths = draft.destinationMediaOverrides[id]
                dest.status = ContentStatus(rawValue: (draft.destinationStatuses[id] ?? "Draft").lowercased()) ?? .draft
                dest.publishedURL = draft.destinationURLs[id].flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : URL(string: $0) }
                if dest.status == .published && dest.publishedDate == nil { dest.publishedDate = Date() }
                if let text = draft.customizedText[id] {
                    let p = dest.bodyPath ?? "Variants/\(id).txt"
                    let revision = try await store.write(Data(text.utf8), relativePath: "\(path)/\(p)", expectedRevision: variantRevisions[id])
                    variantRevisions[id] = revision
                    dest.bodyPath = p
                } else { dest.bodyPath = nil }
                destinations.append(dest)
            }
            item.destinations = destinations
            item.mediaPaths = draft.sharedMediaPaths
            if !destinations.isEmpty && destinations.allSatisfy({ $0.status == .published }) { item.status = .published }
            else if item.status == .published { item.status = .draft }
            edited = item
            variantText = draft.customizedText
            save(item, body: draft.originalText, completion: completion)
        } catch {
            if case WorkspaceStoreError.conflict(let conflictPath, _) = error {
                conflictMessage = "\(conflictPath) changed outside the app. Earlier writes may already have saved some files. Keep your local version or reload the workspace copy."
                showConflictResolution = true
            } else { self.error = "\(error.localizedDescription) Some files may already have been saved. Your edits remain open; review the workspace before retrying." }
            completion(false)
        } }
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
        baselineRecord = nil
        baselineBodyText = ""
        baselineVariantText = [:]
        await load()
        showConflictResolution = false
        conflictMessage = nil
        if loaded, let destinationID = requestedNavigationID { onNavigationConfirmed(destinationID) }
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
