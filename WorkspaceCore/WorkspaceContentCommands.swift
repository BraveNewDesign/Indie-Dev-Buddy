import Foundation

nonisolated struct WorkspaceCommandError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

nonisolated enum WorkspaceRecordKind: String, CaseIterable, Sendable {
    case identities, apps, websites, accounts, content

    var directory: String {
        switch self {
        case .identities: "Identities"
        case .apps: "Apps"
        case .websites: "Websites"
        case .accounts: "SocialAccounts"
        case .content: "Content"
        }
    }
}

nonisolated struct WorkspaceRecordRead: Sendable {
    let path: String
    let data: Data
    let revision: String
    var body: String?
    var bodyRevision: String?
    var relatedFiles: [WorkspaceFileRead] = []
    var backupDirectory: String?
}

nonisolated struct WorkspaceFileRead: Sendable {
    let path: String
    let revision: String
    let text: String?
}

extension WorkspaceStore {
    /// Saves a model-backed workspace record by stable ID. `expectedRevision == nil` is
    /// reserved for creation; updates must present the revision observed by `read`.
    func saveRecord(_ kind: WorkspaceRecordKind, id: String, json: Data, expectedRevision: String?, fileWrites: [WorkspaceWriteOperation] = []) throws -> WorkspaceRecordRead {
        try withWorkspaceLock {
            guard UUID(uuidString: id) != nil else { throw WorkspaceCommandError("Record IDs must be UUIDs.") }
            let snapshot = try load(installAgentGuidance: false)
            let path = snapshot.recordPaths[kind.directory]?[id] ?? "\(kind.directory)/\(id)/record.json"
            let existing = snapshot.recordPaths[kind.directory]?[id] != nil
            if existing && expectedRevision == nil { throw WorkspaceCommandError("Updating a record requires its current --revision from read.") }
            if !existing && expectedRevision != nil { throw WorkspaceCommandError("Cannot update missing \(kind.rawValue) record \(id).") }
            let current = existing ? try read(relativePath: path) : nil
            guard current?.revision == expectedRevision else {
                throw WorkspaceStoreError.conflict(path: path, currentRevision: current?.revision)
            }
            guard var object = try JSONSerialization.jsonObject(with: json) as? [String: Any],
                  object["id"] as? String == id,
                  (object["schemaVersion"] as? Int ?? 1) == 1 else {
                throw WorkspaceCommandError("Record JSON must be a schema 1 object whose id matches \(id).")
            }
            object["schemaVersion"] = 1
            let normalized = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            let preservedDestinationIDs: Set<String>
            if kind == .content, let current,
               let old = try? decoder.decode(ContentRecord.self, from: current.data) {
                preservedDestinationIDs = Set(old.destinations.map(\.accountId))
            } else {
                preservedDestinationIDs = []
            }
            var allowedFilePaths = Set<String>()
            if kind == .content {
                let content = try decoder.decode(ContentRecord.self, from: normalized)
                let folder = (path as NSString).deletingLastPathComponent
                let localMedia = (content.mediaPaths + content.destinations.flatMap { $0.mediaPaths ?? [] })
                    .filter { !$0.hasPrefix("asset:") }
                for reference in content.destinations.compactMap(\.bodyPath) + localMedia {
                    allowedFilePaths.insert(try contentFile(reference, recordPath: path))
                }
                let originalBody = try contentFile(content.originalBodyPath ?? "original.txt", recordPath: path)
                guard !fileWrites.contains(where: { $0.relativePath == originalBody }) else {
                    throw WorkspaceCommandError("Original body changes must use update with its --body-revision.")
                }
                guard fileWrites.allSatisfy({ allowedFilePaths.contains($0.relativePath) && $0.relativePath.hasPrefix(folder + "/") }) else {
                    throw WorkspaceCommandError("Content file writes must target a referenced destination variant or media file inside the content folder.")
                }
            } else if !fileWrites.isEmpty {
                throw WorkspaceCommandError("Related file writes are supported only for content records.")
            }
            try validateRecord(kind, json: normalized, path: path, snapshot: snapshot, preservedDestinationIDs: preservedDestinationIDs,
                               pendingFiles: Dictionary(fileWrites.map { ($0.relativePath, $0.data) }, uniquingKeysWith: { first, _ in first }))
            let backup = existing ? ".indiedevbuddy/backups/\(UUID().uuidString.lowercased())" : nil
            var operations = fileWrites
            operations.append(.init(data: normalized, relativePath: path, expectedRevision: expectedRevision))
            let revisions = try applyWrites(operations, backupDirectory: backup)
            let revision = revisions[revisions.count - 1]
            var result = WorkspaceRecordRead(path: path, data: normalized, revision: revision, backupDirectory: backup)
            if kind == .content, let record = try? decoder.decode(ContentRecord.self, from: normalized),
               let body = try originalBody(for: record, recordPath: path) {
                result.body = body.text
                result.bodyRevision = body.revision
            }
            if kind == .content, let record = try? decoder.decode(ContentRecord.self, from: normalized) {
                result.relatedFiles = contentRelatedFiles(record, recordPath: path)
            }
            return result
        }
    }

    func deleteRecord(_ kind: WorkspaceRecordKind, id: String, expectedRevision: String) throws -> String {
        try withWorkspaceLock {
            let snapshot = try load(installAgentGuidance: false)
            guard let path = snapshot.recordPaths[kind.directory]?[id] else { throw WorkspaceCommandError("No readable \(kind.rawValue) record with ID \(id).") }
            try rejectSymbolicLinks(path)
            let current = try read(relativePath: path)
            guard current.revision == expectedRevision else {
                throw WorkspaceStoreError.conflict(path: path, currentRevision: current.revision)
            }
            let folder = (path as NSString).deletingLastPathComponent
            let folderURL = try safeURL(folder)
            guard folderURL.path != rootURL.path else { throw WorkspaceStoreError.invalidRelativePath(folder) }
            try rejectSymbolicLinks(folder)
            try FileManager.default.removeItem(at: folderURL)
            return folder
        }
    }

    private func validateRecord(_ kind: WorkspaceRecordKind, json: Data, path: String, snapshot: WorkspaceSnapshot,
                                preservedDestinationIDs: Set<String>, pendingFiles: [String: Data] = [:]) throws {
        switch kind {
        case .identities:
            let record = try decoder.decode(IdentityRecord.self, from: json)
            guard !record.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WorkspaceCommandError("Identity name must not be empty.") }
            try validateAsset(record.photoPath)
        case .apps:
            let record = try decoder.decode(AppRecord.self, from: json)
            guard !record.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WorkspaceCommandError("App name must not be empty.") }
            if let id = record.developerIdentityId, snapshot.identities.filter({ $0.id == id }).count != 1 { throw WorkspaceCommandError("Unknown or ambiguous identity ID \(id).") }
            for link in record.websiteLinks {
                guard snapshot.websites.filter({ $0.id == link.websiteId }).count == 1 else { throw WorkspaceCommandError("Unknown or ambiguous website ID \(link.websiteId).") }
                if let url = link.url { try validateWebURL(url, field: "Website link URL") }
            }
            if let url = record.repositoryURL { try validateWebURL(url, field: "Repository URL") }
            if let url = record.appStoreURL { try validateWebURL(url, field: "App Store URL") }
            if let url = record.testFlightURL { try validateWebURL(url, field: "TestFlight URL") }
            try validateAsset(record.iconPath.map { "\((path as NSString).deletingLastPathComponent)/\($0)" })
        case .websites:
            let record = try decoder.decode(WebsiteRecord.self, from: json)
            guard !record.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WorkspaceCommandError("Website name must not be empty.") }
            let owners = record.owner.type == .app ? snapshot.apps.map(\.id) : snapshot.identities.map(\.id)
            guard owners.filter({ $0 == record.owner.id }).count == 1 else { throw WorkspaceCommandError("Unknown \(record.owner.type.rawValue) owner \(record.owner.id).") }
            try validateWebURL(record.baseURL, field: "Website base URL")
            if let url = record.blogIndexURL { try validateWebURL(url, field: "Blog index URL") }
        case .accounts:
            let record = try decoder.decode(SocialAccountRecord.self, from: json)
            guard !record.platform.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WorkspaceCommandError("Social account platform must not be empty.") }
            guard let owner = record.owner else { throw WorkspaceCommandError("Social accounts require an identity or app owner.") }
            let owners = owner.type == .app ? snapshot.apps.map(\.id) : snapshot.identities.map(\.id)
            guard owners.filter({ $0 == owner.id }).count == 1 else { throw WorkspaceCommandError("Unknown \(owner.type.rawValue) owner \(owner.id).") }
            guard record.handle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false || record.profileURL != nil else { throw WorkspaceCommandError("Social accounts require a handle or profile URL.") }
            if let url = record.profileURL { try validateWebURL(url, field: "Social profile URL") }
            try validateAsset(record.avatarPath)
        case .content:
            let record = try decoder.decode(ContentRecord.self, from: json)
            try validateContent(record, path: path, in: snapshot, pendingFiles: pendingFiles, preservedUnavailableAccountIDs: preservedDestinationIDs)
        }
    }

    private func validateAsset(_ path: String?) throws {
        guard let path else { return }
        let url = try safeURL(path)
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw WorkspaceCommandError("Expected an asset file at \(path).") }
    }

    private func validateWebURL(_ url: URL, field: String) throws {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil else {
            throw WorkspaceCommandError("\(field) must be an absolute http or https URL.")
        }
    }

    func readRecord(_ kind: WorkspaceRecordKind, id: String) throws -> WorkspaceRecordRead {
        try withWorkspaceLock(exclusive: false) {
            let snapshot = try load(installAgentGuidance: false)
            return try readRecord(kind, id: id, in: snapshot)
        }
    }

    private func readRecord(_ kind: WorkspaceRecordKind, id: String, in snapshot: WorkspaceSnapshot,
                            includeRelatedFiles: Bool = true) throws -> WorkspaceRecordRead {
        guard !snapshot.errors.contains(where: { $0.path == kind.errorLabel }) else {
            throw WorkspaceCommandError("Resolve duplicate IDs in \(kind.rawValue) before reading by ID.")
        }
        guard let path = snapshot.recordPaths[kind.directory]?[id] else {
            throw WorkspaceCommandError("No readable \(kind.rawValue) record with ID \(id). Run validate to inspect workspace errors.")
        }
        let file = try read(relativePath: path)
        guard let object = try JSONSerialization.jsonObject(with: file.data) as? [String: Any],
              object["id"] as? String == id, object["schemaVersion"] as? Int == 1 else {
            throw WorkspaceCommandError("\(path) changed while it was being read. Retry the command.")
        }
        var result = WorkspaceRecordRead(path: path, data: file.data, revision: file.revision)
        if kind == .content {
            let content = try decoder.decode(ContentRecord.self, from: file.data)
            if let body = try originalBody(for: content, recordPath: path) {
                result.body = body.text
                result.bodyRevision = body.revision
            }
            if includeRelatedFiles { result.relatedFiles = contentRelatedFiles(content, recordPath: path) }
        }
        return result
    }

    @discardableResult
    func createContent(_ record: ContentRecord, body: String) throws -> WorkspaceRecordRead {
        try withWorkspaceLock {
            let snapshot = try load(installAgentGuidance: false)
            guard UUID(uuidString: record.id) != nil, snapshot.contentByID[record.id] == nil,
                  let bodyName = record.originalBodyPath else {
                throw WorkspaceCommandError("New content requires a unique UUID and an original body path.")
            }
            let path = "Content/\(record.id)/record.json"
            let bodyPath = try contentFile(bodyName, recordPath: path)
            try validateContent(record, path: path, in: snapshot, pendingBody: bodyName)
            let data = try encoder.encode(record)
            let revisions = try applyWrites([
                .init(data: Data(body.utf8), relativePath: bodyPath),
                .init(data: data, relativePath: path)
            ])
            return WorkspaceRecordRead(path: path, data: data, revision: revisions[1], body: body, bodyRevision: revisions[0])
        }
    }

    func moveContent(id: String, to stage: ContentStage) throws {
        try withWorkspaceLock {
            let snapshot = try load(installAgentGuidance: false)
            guard !snapshot.errors.contains(where: { $0.path == WorkspaceRecordKind.content.errorLabel }),
                  let path = snapshot.recordPaths[WorkspaceRecordKind.content.directory]?[id] else {
                throw WorkspaceCommandError("The content record is missing or its ID is ambiguous.")
            }
            guard try safeURL(path).path == rootURL.appendingPathComponent(path).path else {
                throw WorkspaceStoreError.invalidRelativePath(path)
            }
            let current = try read(relativePath: path)
            let item = try decoder.decode(ContentRecord.self, from: current.data)
            guard item.id == id, let status = stage.editorialStatus, stage.allowsMove(from: item) else {
                throw WorkspaceCommandError("This item can no longer move to \(stage.rawValue).")
            }
            // Patch only the workflow field, including for records with extension metadata.
            guard var object = try JSONSerialization.jsonObject(with: current.data) as? [String: Any] else {
                throw WorkspaceCommandError("Expected a JSON object in \(path).")
            }
            object["status"] = status.rawValue
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            _ = try applyWrites([.init(data: data, relativePath: path, expectedRevision: current.revision)])
        }
    }

    func updateContent(id: String, title: String?, body: String?, expectedRevision: String,
                       expectedBodyRevision: String?) throws -> WorkspaceRecordRead {
        try withWorkspaceLock {
            let snapshot = try load(installAgentGuidance: false)
            let current = try readRecord(.content, id: id, in: snapshot, includeRelatedFiles: false)
            guard current.revision == expectedRevision else {
                throw WorkspaceStoreError.conflict(path: current.path, currentRevision: current.revision)
            }
            guard try safeURL(current.path).path == rootURL.appendingPathComponent(current.path).path else {
                throw WorkspaceStoreError.invalidRelativePath(current.path)
            }
            var record = try decoder.decode(ContentRecord.self, from: current.data)
            guard title != nil || body != nil else { throw WorkspaceCommandError("Provide --title or --body-file.") }
            if let title { record.title = title }
            var data = current.data
            var writes: [WorkspaceWriteOperation] = []
            if let body {
                guard current.bodyRevision != nil, let expectedBodyRevision else {
                    throw WorkspaceCommandError("Body updates require an existing original body and its --body-revision from read.")
                }
                let path = try contentFile(record.originalBodyPath ?? "original.txt", recordPath: current.path)
                let otherFiles = record.destinations.compactMap(\.bodyPath) + (record.mediaPaths + record.destinations.flatMap { $0.mediaPaths ?? [] }).filter { !$0.hasPrefix("asset:") }
                let originalURL = try safeURL(path)
                for reference in otherFiles {
                    let file = try contentFile(reference, recordPath: current.path)
                    guard try safeURL(file) != originalURL else {
                        throw WorkspaceCommandError("The original body is also referenced as media or a separate variant. Repair that reference before editing.")
                    }
                }
                writes.append(.init(data: Data(body.utf8), relativePath: path, expectedRevision: expectedBodyRevision))
            }
            try validateContent(record, path: current.path, in: snapshot)
            if let title {
                // Preserve extension fields, including fields on nested destinations.
                guard var object = try JSONSerialization.jsonObject(with: current.data) as? [String: Any] else {
                    throw WorkspaceCommandError("Expected a JSON object in \(current.path).")
                }
                object["title"] = title
                data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            }
            // Include the record in preflight even when only the body changes.
            writes.append(.init(data: data, relativePath: current.path, expectedRevision: expectedRevision))
            let backup = ".indiedevbuddy/backups/\(UUID().uuidString.lowercased())"
            let revisions: [String]
            do {
                revisions = try applyWrites(writes, backupDirectory: backup)
            } catch let error as WorkspaceStoreError {
                if case .partialWriteRecovery = error {
                    throw WorkspaceCommandError("\(error.localizedDescription) Previous bytes are in \(backup).")
                }
                throw error
            }
            return WorkspaceRecordRead(path: current.path, data: data, revision: revisions[writes.count - 1],
                                       body: body ?? current.body, bodyRevision: body == nil ? current.bodyRevision : revisions[0],
                                       backupDirectory: backup)
        }
    }

    func validateWorkspace() throws -> [WorkspaceFileError] {
        let snapshot = try load(installAgentGuidance: false)
        var issues = snapshot.errors
        func check(_ path: String, _ action: () throws -> Void) {
            do { try action() }
            catch { issues.append(.init(path: path, message: error.localizedDescription)) }
        }
        func requireOwner(_ owner: RecordOwner) throws {
            let kind: WorkspaceRecordKind = owner.type == .app ? .apps : .identities
            guard snapshot.recordPaths[kind.directory]?[owner.id] != nil else {
                throw WorkspaceCommandError("Unknown \(owner.type.rawValue) owner \(owner.id).")
            }
        }
        func path(_ kind: WorkspaceRecordKind, _ id: String) -> String {
            snapshot.recordPaths[kind.directory]?[id] ?? id
        }
        func checkAsset(_ relativePath: String?) throws {
            guard let relativePath else { return }
            let url = try safeURL(relativePath)
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw WorkspaceCommandError("Expected an asset file at \(relativePath).")
            }
        }
        // The library index is managed workspace data, so corruption and broken
        // references must be visible even when no content record currently uses them.
        let assetLibrary: AssetLibrary?
        do {
            assetLibrary = try loadAssetLibrary().library
        } catch {
            issues.append(.init(path: AssetLibrary.indexPath, message: error.localizedDescription))
            assetLibrary = nil
        }
        if let assetLibrary {
            let assetsByID = Dictionary(grouping: assetLibrary.assets, by: \.id)
            for asset in assetLibrary.assets {
                guard let relativePath = AssetLibrary.managedPath(asset.reference) else {
                    issues.append(.init(path: AssetLibrary.indexPath, message: "Invalid managed asset reference \(asset.reference)."))
                    continue
                }
                if assetsByID[asset.id]?.count != 1 {
                    issues.append(.init(path: AssetLibrary.indexPath, message: "Duplicate managed asset ID \(asset.id)."))
                }
                check(relativePath) {
                    let url = try resolveContentMedia(asset.reference, recordFolder: "")
                    guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                        throw WorkspaceCommandError("Expected a managed asset file at \(relativePath).")
                    }
                }
            }
            let knownIDs = Set(assetsByID.keys)
            for set in assetLibrary.screenshotSets {
                for assetID in set.assetIDs where !knownIDs.contains(assetID) {
                    issues.append(.init(path: AssetLibrary.indexPath, message: "Screenshot set \(set.id) references missing asset \(assetID)."))
                }
            }
        }
        for app in snapshot.apps {
            let recordPath = path(.apps, app.id)
            check(recordPath) {
                if let id = app.developerIdentityId { try requireOwner(.init(type: .identity, id: id)) }
                for link in app.websiteLinks where snapshot.recordPaths["Websites"]?[link.websiteId] == nil {
                    throw WorkspaceCommandError("Unknown linked website \(link.websiteId).")
                }
                if let icon = app.iconPath { try checkAsset(try contentFile(icon, recordPath: recordPath)) }
            }
        }
        for website in snapshot.websites { check(path(.websites, website.id)) { try requireOwner(website.owner) } }
        for account in snapshot.socialAccounts {
            check(path(.accounts, account.id)) {
                if let owner = account.owner { try requireOwner(owner) }
                try checkAsset(account.avatarPath)
            }
        }
        for identity in snapshot.identities {
            check(path(.identities, identity.id)) { try checkAsset(identity.photoPath) }
        }
        for content in snapshot.content {
            let recordPath = path(.content, content.id)
            check(recordPath) { try validateContent(content, path: recordPath, in: snapshot) }
        }
        return issues
    }

    private func validateContent(_ record: ContentRecord, path: String, in snapshot: WorkspaceSnapshot,
                                 pendingBody: String? = nil, pendingFiles: [String: Data] = [:],
                                 preservedUnavailableAccountIDs: Set<String> = []) throws {
        guard record.schemaVersion == 1, !record.id.isEmpty,
              !record.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorkspaceCommandError("Content requires schema 1, a stable ID, and a non-empty title.")
        }
        guard Set(record.appIds).count == record.appIds.count else {
            throw WorkspaceCommandError("Each app association can appear only once.")
        }
        for id in record.appIds where snapshot.apps.filter({ $0.id == id }).count != 1 {
            throw WorkspaceCommandError("Unknown or ambiguous app ID \(id).")
        }
        if let id = record.websiteId {
            let sites = snapshot.websites.filter { $0.id == id }
            guard sites.count == 1, record.kind != .blog || sites[0].blogEnabled else {
                throw WorkspaceCommandError("Website \(id) is missing, ambiguous, or does not have a blog enabled.")
            }
        }
        if let url = record.publishedURL { try validateWebURL(url, field: "Published URL") }
        var visited = Set([record.id])
        var source = record.sourceContentId
        let sources = Dictionary(grouping: snapshot.content, by: \.id)
        while let id = source {
            guard visited.insert(id).inserted, let matches = sources[id], matches.count == 1 else {
                throw WorkspaceCommandError("Invalid source content relationship at \(id).")
            }
            source = matches[0].sourceContentId
        }
        let accounts = record.destinations.map(\.accountId)
        guard Set(accounts).count == accounts.count else {
            throw WorkspaceCommandError("Each destination account can appear only once.")
        }
        let unavailable = snapshot.socialDestinationSelection(for: record).unavailableAccountIDs
        let ambiguous = Set(accounts.filter { id in snapshot.socialAccounts.filter { $0.id == id }.count > 1 })
        let invalidAccounts = unavailable.subtracting(preservedUnavailableAccountIDs).union(ambiguous)
        guard invalidAccounts.isEmpty else {
            throw WorkspaceCommandError("Unavailable or ambiguous destination accounts: \(invalidAccounts.sorted().joined(separator: ", ")).")
        }
        if pendingBody == nil { _ = try originalBody(for: record, recordPath: path) }
        for destination in record.destinations {
            if let url = destination.publishedURL { try validateWebURL(url, field: "Destination published URL") }
            if let variant = destination.bodyPath {
                let file = try contentFile(variant, recordPath: path)
                if let pending = pendingFiles[file] {
                    guard String(data: pending, encoding: .utf8) != nil else { throw WorkspaceCommandError("Destination variant \(file) must be UTF-8 text.") }
                } else { _ = try readText(file) }
            }
        }
        try validateManagedAttachments(record)
        for media in record.mediaPaths + record.destinations.flatMap({ $0.mediaPaths ?? [] }) where !media.hasPrefix("asset:") {
            let file = try contentFile(media, recordPath: path)
            if pendingFiles[file] == nil {
                guard try safeURL(file).resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                    throw WorkspaceCommandError("Expected a media file at \(file).")
                }
            }
        }
    }

    private func originalBody(for record: ContentRecord, recordPath: String) throws -> (path: String, text: String, revision: String)? {
        let name = record.originalBodyPath ?? "original.txt"
        let path = try contentFile(name, recordPath: recordPath)
        if record.originalBodyPath == nil, !FileManager.default.fileExists(atPath: try safeURL(path).path) { return nil }
        let body = try readText(path)
        return (path, body.text, body.revision)
    }

    private func readText(_ path: String) throws -> (text: String, revision: String) {
        let file = try read(relativePath: path)
        guard let text = String(data: file.data, encoding: .utf8) else {
            throw WorkspaceCommandError("\(path) is not UTF-8 text.")
        }
        return (text, file.revision)
    }

    private func contentRelatedFiles(_ record: ContentRecord, recordPath: String) -> [WorkspaceFileRead] {
        let references = Set(record.destinations.compactMap(\.bodyPath) + record.mediaPaths + record.destinations.flatMap { $0.mediaPaths ?? [] })
        let variantReferences = Set(record.destinations.compactMap(\.bodyPath))
        return references.sorted().compactMap { reference in
            let path = variantReferences.contains(reference) ? try? contentFile(reference, recordPath: recordPath)
                : AssetLibrary.managedPath(reference) ?? (try? contentFile(reference, recordPath: recordPath))
            guard let path, let file = try? read(relativePath: path) else { return nil }
            let text = variantReferences.contains(reference) ? String(data: file.data, encoding: .utf8) : nil
            return WorkspaceFileRead(path: path, revision: file.revision, text: text)
        }
    }

    private func contentFile(_ name: String, recordPath: String) throws -> String {
        let folder = (recordPath as NSString).deletingLastPathComponent
        guard !name.isEmpty, !name.hasPrefix("/"), !name.split(separator: "/").contains("..") else {
            throw WorkspaceStoreError.invalidRelativePath(name)
        }
        let path = "\(folder)/\(name)"
        let url = try safeURL(path)
        // Avoid aliases to another record, media file, or management document.
        guard url.path == rootURL.appendingPathComponent(path).path,
              url.lastPathComponent != "record.json" else {
            throw WorkspaceStoreError.invalidRelativePath(path)
        }
        return path
    }
}

private extension WorkspaceRecordKind {
    nonisolated var errorLabel: String {
        switch self {
        case .identities: "identity"
        case .apps: "app"
        case .websites: "website"
        case .accounts: "social account"
        case .content: "content"
        }
    }
}
