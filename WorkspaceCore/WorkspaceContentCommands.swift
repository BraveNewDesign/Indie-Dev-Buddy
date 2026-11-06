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
    var backupDirectory: String?
}

extension WorkspaceStore {
    func readRecord(_ kind: WorkspaceRecordKind, id: String) throws -> WorkspaceRecordRead {
        try withWorkspaceLock(exclusive: false) {
            let snapshot = try load(installAgentGuidance: false)
            return try readRecord(kind, id: id, in: snapshot)
        }
    }

    private func readRecord(_ kind: WorkspaceRecordKind, id: String, in snapshot: WorkspaceSnapshot) throws -> WorkspaceRecordRead {
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

    func updateContent(id: String, title: String?, body: String?, expectedRevision: String,
                       expectedBodyRevision: String?) throws -> WorkspaceRecordRead {
        try withWorkspaceLock {
            let snapshot = try load(installAgentGuidance: false)
            let current = try readRecord(.content, id: id, in: snapshot)
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
                let otherFiles = record.mediaPaths + record.destinations.flatMap { ($0.mediaPaths ?? []) + [$0.bodyPath].compactMap { $0 } }
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
                                 pendingBody: String? = nil) throws {
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
        let invalidAccounts = unavailable.union(ambiguous)
        guard invalidAccounts.isEmpty else {
            throw WorkspaceCommandError("Unavailable or ambiguous destination accounts: \(invalidAccounts.sorted().joined(separator: ", ")).")
        }
        if pendingBody == nil { _ = try originalBody(for: record, recordPath: path) }
        for destination in record.destinations {
            if let variant = destination.bodyPath {
                let file = try contentFile(variant, recordPath: path)
                _ = try readText(file)
            }
        }
        for media in record.mediaPaths + record.destinations.flatMap({ $0.mediaPaths ?? [] }) {
            let file = try contentFile(media, recordPath: path)
            guard try safeURL(file).resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw WorkspaceCommandError("Expected a media file at \(file).")
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
