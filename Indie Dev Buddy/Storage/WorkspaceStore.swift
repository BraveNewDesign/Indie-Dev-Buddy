import Foundation
import CryptoKit
import Darwin

public enum WorkspaceStoreError: Error, LocalizedError {
    case notWorkspace
    case workspaceAlreadyExists
    case invalidRelativePath(String)
    case conflict(path: String, currentRevision: String?)
    case unsupportedSchema(Int)
    case duplicateID(String)
    case duplicateWritePath(String)
    case partialWriteRecovery(paths: [String])

    public var errorDescription: String? {
        switch self {
        case .notWorkspace: return "This folder does not contain a valid Indie Dev Buddy workspace."
        case .workspaceAlreadyExists: return "This folder already contains Indie Dev Buddy workspace data. Choose another folder to avoid overwriting it."
        case .invalidRelativePath(let path): return "The workspace path is invalid: \(path)"
        case .conflict(let path, _): return "\(path) changed outside Indie Dev Buddy. Reload or explicitly resolve the conflict before saving."
        case .unsupportedSchema(let version): return "Workspace schema version \(version) is not supported."
        case .duplicateID(let id): return "Multiple workspace records use the ID \(id)."
        case .duplicateWritePath(let path): return "A workspace batch contains the path more than once: \(path)."
        case .partialWriteRecovery(let paths): return "A save was only partially recovered. Review these workspace files before continuing: \(paths.joined(separator: ", "))."
        }
    }
}

nonisolated public struct WorkspaceWriteOperation: Sendable {
    public let data: Data
    public let relativePath: String
    public let expectedRevision: String?

    public init(data: Data, relativePath: String, expectedRevision: String? = nil) {
        self.data = data
        self.relativePath = relativePath
        self.expectedRevision = expectedRevision
    }
}

/// Revision is a SHA-256 digest of the bytes last loaded. Pass it back on save to prevent
/// overwriting edits made by another app while a local editor is open.
public actor WorkspaceStore {
    public let rootURL: URL
    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var watchSources: [Int32: DispatchSourceFileSystemObject] = [:]
    private var changeHandler: (@Sendable () -> Void)?
    private var pendingChange: Task<Void, Never>?
    private var writeFailurePathForTesting: String?

    public init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]; e.dateEncodingStrategy = .iso8601
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        encoder = e; decoder = d
    }

    @discardableResult
    public func createWorkspace(at url: URL, name: String = "Indie Dev Buddy Workspace") throws -> WorkspaceManifest {
        let root = url.standardizedFileURL.resolvingSymlinksInPath()
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        guard !fileManager.fileExists(atPath: root.appendingPathComponent("workspace.json").path),
              !fileManager.fileExists(atPath: root.appendingPathComponent("AGENTS.md").path) else {
            throw WorkspaceStoreError.workspaceAlreadyExists
        }
        let manifest = WorkspaceManifest(name: name)
        for path in ["Identities", "Apps", "Websites", "SocialAccounts", "Content", "Inbox", "Shared Files"] {
            try fileManager.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        // Exclusive creation ensures another process or a pre-existing file is never replaced.
        try writeExclusively(Data(Self.agentInstructions.utf8), to: root.appendingPathComponent("AGENTS.md"))
        do { try writeExclusively(encoder.encode(manifest), to: root.appendingPathComponent("workspace.json")) }
        catch {
            // Roll back only the marker created above; never remove user data.
            try? fileManager.removeItem(at: root.appendingPathComponent("AGENTS.md"))
            throw error
        }
        return manifest
    }

    public func load() throws -> WorkspaceSnapshot {
        let manifestURL = rootURL.appendingPathComponent("workspace.json")
        guard let manifestData = try? Data(contentsOf: manifestURL) else { throw WorkspaceStoreError.notWorkspace }
        let manifest = try decoder.decode(WorkspaceManifest.self, from: manifestData)
        guard manifest.schemaVersion == 1 else { throw WorkspaceStoreError.unsupportedSchema(manifest.schemaVersion) }
        var errors: [WorkspaceFileError] = []
        var opaque: [OpaqueWorkspaceRecord] = []
        let identities: [IdentityRecord] = scan("Identities", errors: &errors, opaque: &opaque)
        let apps: [AppRecord] = scan("Apps", errors: &errors, opaque: &opaque)
        let websites: [WebsiteRecord] = scan("Websites", errors: &errors, opaque: &opaque)
        let accounts: [SocialAccountRecord] = scan("SocialAccounts", errors: &errors, opaque: &opaque)
        let content: [ContentRecord] = scan("Content", errors: &errors, opaque: &opaque)
        for (label, ids) in [("identity", identities.map(\.id)), ("app", apps.map(\.id)), ("website", websites.map(\.id)), ("social account", accounts.map(\.id)), ("content", content.map(\.id))] {
            var seen = Set<String>()
            for id in ids where !seen.insert(id).inserted { errors.append(.init(path: label, message: WorkspaceStoreError.duplicateID(id).localizedDescription)) }
        }
        return WorkspaceSnapshot(manifest: manifest, identities: identities, apps: apps, websites: websites, socialAccounts: accounts, content: content, errors: errors, opaqueRecords: opaque)
    }

    public func read(relativePath: String) throws -> (data: Data, revision: String) {
        let url = try safeURL(relativePath)
        let data = try Data(contentsOf: url)
        return (data, Self.revision(data))
    }

    /// Atomic same-volume replacement. A non-nil expectedRevision enables optimistic conflict detection.
    /// Pass nil only for creating a new file; existing files then produce a conflict.
    @discardableResult
    public func write(_ data: Data, relativePath: String, expectedRevision: String? = nil) throws -> String {
        try writeBatch([WorkspaceWriteOperation(data: data, relativePath: relativePath, expectedRevision: expectedRevision)])[0]
    }

    /// Applies a related set of file updates with revision preflight and best-effort rollback.
    /// This is not a filesystem transaction: a process crash can leave a partial set, and writers
    /// that ignore the revision protocol can still race. On an ordinary write failure, files already
    /// written are restored only when their current bytes still match this batch's output.
    @discardableResult
    public func writeBatch(_ operations: [WorkspaceWriteOperation]) throws -> [String] {
        guard !operations.isEmpty else { return [] }
        var seen = Set<String>()
        for operation in operations where !seen.insert(operation.relativePath).inserted {
            throw WorkspaceStoreError.duplicateWritePath(operation.relativePath)
        }

        struct Prepared {
            let operation: WorkspaceWriteOperation
            let url: URL
            let oldData: Data?
            let newRevision: String
        }
        var prepared: [Prepared] = []
        prepared.reserveCapacity(operations.count)

        // Check every input and revision before changing any file.
        for operation in operations {
            let url = try safeURL(operation.relativePath)
            let oldData = fileManager.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
            let currentRevision = oldData.map(Self.revision)
            guard operation.expectedRevision == currentRevision else {
                throw WorkspaceStoreError.conflict(path: operation.relativePath, currentRevision: currentRevision)
            }
            prepared.append(Prepared(operation: operation, url: url, oldData: oldData, newRevision: Self.revision(operation.data)))
        }

        for item in prepared {
            try fileManager.createDirectory(at: item.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }

        var attempted: [Prepared] = []
        do {
            for item in prepared {
                let currentData = fileManager.fileExists(atPath: item.url.path) ? try Data(contentsOf: item.url) : nil
                let currentRevision = currentData.map(Self.revision)
                guard currentRevision == item.operation.expectedRevision else {
                    throw WorkspaceStoreError.conflict(path: item.operation.relativePath, currentRevision: currentRevision)
                }
                if writeFailurePathForTesting == item.operation.relativePath {
                    writeFailurePathForTesting = nil
                    attempted.append(item)
                    throw CocoaError(.fileWriteUnknown)
                }
                attempted.append(item)
                try writeAtomically(item.operation.data, to: item.url)
            }
        } catch {
            var unrecovered: [String] = []
            for item in attempted.reversed() {
                do {
                    let current = fileManager.fileExists(atPath: item.url.path) ? try Data(contentsOf: item.url) : nil
                    let currentRevision = current.map(Self.revision)
                    let oldRevision = item.oldData.map(Self.revision)
                    if currentRevision == oldRevision { continue }
                    guard currentRevision == item.newRevision else {
                        unrecovered.append(item.operation.relativePath)
                        continue
                    }
                    if let oldData = item.oldData {
                        try writeAtomically(oldData, to: item.url)
                    } else {
                        try fileManager.removeItem(at: item.url)
                    }
                } catch {
                    unrecovered.append(item.operation.relativePath)
                }
            }
            if !unrecovered.isEmpty { throw WorkspaceStoreError.partialWriteRecovery(paths: unrecovered.reversed()) }
            throw error
        }
        return prepared.map { $0.newRevision }
    }

    @discardableResult
    public func save<Record: Encodable & Sendable>(_ record: Record, relativePath: String, expectedRevision: String? = nil) throws -> String {
        try write(encoder.encode(record), relativePath: relativePath, expectedRevision: expectedRevision)
    }

    public func refresh() throws -> WorkspaceSnapshot { try load() }

    /// Internal deterministic fault hook for exercising rollback behavior in unit tests.
    func setWriteFailureInjectionForTesting(at relativePath: String?) {
        writeFailurePathForTesting = relativePath
    }

    /// Watches the workspace's record folders and coalesces filesystem notifications.
    /// Call again after creating/removing record folders to refresh the watched directory set.
    public func startWatching(onChange: @escaping @Sendable () -> Void) {
        stopWatching()
        changeHandler = onChange
        installWatchers()
    }

    private func installWatchers() {
        for source in watchSources.values { source.cancel() }
        watchSources.removeAll()
        var directories = [rootURL]
        for category in ["Identities", "Apps", "Websites", "SocialAccounts", "Content", "Inbox", "Shared Files"] {
            let categoryURL = rootURL.appendingPathComponent(category, isDirectory: true)
            guard fileManager.fileExists(atPath: categoryURL.path),
                  (try? categoryURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false else { continue }
            guard let enumerator = fileManager.enumerator(at: categoryURL, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { continue }
            directories.append(categoryURL)
            while let item = enumerator.nextObject() as? URL {
                if (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != false {
                    enumerator.skipDescendants()
                    continue
                }
                // Watch both directories (for added/removed children) and files (for in-place
                // Markdown/text edits that do not necessarily change the parent directory).
                directories.append(item)
            }
        }
        for directory in directories {
            let fd = open(directory.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename, .attrib], queue: .global(qos: .utility))
            source.setEventHandler { [weak self] in
                Task { await self?.watcherDidObserveChange() }
            }
            source.setCancelHandler { close(fd) }
            watchSources[fd] = source
            source.resume()
        }
    }

    public func stopWatching() {
        pendingChange?.cancel()
        pendingChange = nil
        for source in watchSources.values { source.cancel() }
        watchSources.removeAll()
        changeHandler = nil
    }

    private func scheduleChangeNotification() {
        pendingChange?.cancel()
        pendingChange = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self?.deliverChangeNotification()
        }
    }

    private func deliverChangeNotification() { changeHandler?() }

    private func watcherDidObserveChange() {
        // Refresh registrations so newly-created nested record folders are observed too.
        installWatchers()
        scheduleChangeNotification()
    }

    public static func revision(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private func scan<T: Decodable>(_ directory: String, errors: inout [WorkspaceFileError], opaque: inout [OpaqueWorkspaceRecord]) -> [T] {
        let base = rootURL.appendingPathComponent(directory, isDirectory: true)
        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)
        } catch {
            errors.append(.init(path: base.path, message: "Could not read workspace records in \(directory): \(error.localizedDescription)"))
            return []
        }
        var result: [T] = []
        for dir in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let file = dir.appendingPathComponent("record.json")
            guard fileManager.fileExists(atPath: file.path) else { continue }
            do {
                let raw = try Data(contentsOf: file)
                if let object = try JSONSerialization.jsonObject(with: raw) as? [String: Any],
                   let version = object["schemaVersion"] as? Int, version > 1 {
                    let reason = WorkspaceStoreError.unsupportedSchema(version).localizedDescription
                    errors.append(.init(path: file.path, message: reason))
                    opaque.append(.init(relativePath: String(file.path.dropFirst(rootURL.path.count + 1)), data: raw, reason: reason))
                    continue
                }
                result.append(try decoder.decode(T.self, from: raw))
            } catch {
                errors.append(.init(path: file.path, message: error.localizedDescription))
                if let raw = try? Data(contentsOf: file) {
                    opaque.append(.init(relativePath: String(file.path.dropFirst(rootURL.path.count + 1)), data: raw, reason: error.localizedDescription))
                }
            }
        }
        return result
    }

    private func safeURL(_ relativePath: String) throws -> URL {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"), !relativePath.split(separator: "/").contains("..") else { throw WorkspaceStoreError.invalidRelativePath(relativePath) }
        let url = rootURL.appendingPathComponent(relativePath).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path == rootURL.path || url.path.hasPrefix(rootURL.path + "/") else { throw WorkspaceStoreError.invalidRelativePath(relativePath) }
        return url
    }

    private func writeAtomically(_ data: Data, to url: URL) throws { try data.write(to: url, options: .atomic) }

    private func writeExclusively(_ data: Data, to url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            if errno == EEXIST { throw WorkspaceStoreError.workspaceAlreadyExists }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(fd) }
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, base.advanced(by: offset), buffer.count - offset)
                guard written > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                offset += written
            }
        }
        guard fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private static let agentInstructions = """
    # Indie Dev Buddy Workspace

    This workspace is the source of truth. Records are ordinary UTF-8 JSON, Markdown, and text files. Do not store credentials, tokens, or secrets here. Keep names in their owning records and reference records elsewhere by stable `id`; do not use folder names as IDs.

    ## Layout

    - `workspace.json`: workspace metadata (`schemaVersion`, `id`, `name`).
    - `Identities/<slug>/record.json`
    - `Apps/<slug>/record.json` (plus optional `Assets/` and `Releases/<version>/record.json`).
    - Each release can keep `notes.md` next to `Releases/<version>/record.json`.
    - `Websites/<slug>/record.json`
    - `SocialAccounts/<slug>/record.json`
    - `Content/<slug>/record.json`, with body text in the path named by `originalBodyPath` and optional `Variants/` and `Assets/` files.
    - `Inbox/` and `Shared Files/` for user-managed material.

    JSON keys use the Swift property names below. `schemaVersion` is `1` for records this app understands. Every record requires `schemaVersion` and a stable, unique `id`. Required fields are shown; optional fields may be omitted or set to `null`. Dates are ISO-8601 strings. URLs are strings. Relative paths use `/` and must stay inside the workspace. Content body/media paths are relative to the content folder; `iconPath` is relative to the app folder; release notes/assets are relative to that release folder; `avatarPath` is relative to the workspace root.

    ## Record examples

    Identity (`Identities/brave-new-design/record.json`):

    ```json
    { "schemaVersion": 1, "id": "identity-bnd", "name": "Brave New Design", "kind": "business" }
    ```

    App (`Apps/dictate-bar/record.json`):

    ```json
    {
      "schemaVersion": 1, "id": "app-dictate-bar", "name": "Dictate Bar",
      "iconPath": "Assets/app-icon.png",
      "description": "Voice dictation for macOS.", "bundleIDs": ["com.example.DictateBar"],
      "developmentStatus": "released", "testFlightURL": "https://testflight.apple.com/join/example",
      "developerIdentityId": "identity-bnd", "platforms": ["macOS"],
      "projectPath": "/Users/example/Projects/DictateBar",
      "repositoryURL": "https://example.com/dictate-bar", "appStoreURL": null,
      "websiteLinks": [
        { "websiteId": "website-bnd", "purpose": "product", "url": "https://example.com/software/dictate-bar", "isPrimary": true }
      ]
    }
    ```

    Website (`Websites/brave-new-design/record.json`):

    ```json
    {
      "schemaVersion": 1, "id": "website-bnd", "name": "Brave New Design",
      "owner": { "type": "identity", "id": "identity-bnd" },
      "baseURL": "https://example.com", "blogEnabled": true, "blogIndexURL": "https://example.com/blog"
    }
    ```

    Social account (`SocialAccounts/threads-business/record.json`):

    ```json
    {
      "schemaVersion": 1, "id": "account-threads-business", "platform": "threads",
      "owner": { "type": "identity", "id": "identity-bnd" },
      "handle": "@example", "profileURL": "https://threads.net/@example",
      "avatarPath": null, "enabled": true
    }
    ```

    `avatarPath` is an optional workspace-relative image path (for example,
    `SocialAccounts/threads-business/Assets/avatar-example.png`). Clearing or replacing
    it does not delete the previous file.

    Content (`Content/dictate-bar-update/record.json`):

    ```json
    {
      "schemaVersion": 1, "id": "content-update-social", "kind": "social",
      "title": "Dictate Bar update", "appIds": ["app-dictate-bar"], "websiteId": null,
      "sourceContentId": "content-update-blog", "releaseId": "release-dictate-bar-1-3",
      "plannedDate": "2026-11-12T15:00:00Z", "relatedGroupId": null,
      "originalBodyPath": "original.txt", "excerpt": null, "includeSourceLink": true,
      "status": "draft", "publishedURL": null,
      "destinations": [
        { "accountId": "account-threads-business", "bodyPath": null, "status": "draft",
          "publishedURL": null, "publishedDate": "2026-11-13T18:30:00Z", "mediaPaths": null },
        { "accountId": "account-threads-personal", "bodyPath": "Variants/threads-personal.txt",
          "status": "draft", "publishedURL": null, "publishedDate": null,
          "mediaPaths": ["Assets/personal-image.png"] }
      ],
      "mediaPaths": ["Assets/announcement.png"]
    }
    ```

    Release (`Apps/dictate-bar/Releases/1.3/record.json`):

    ```json
    {
      "schemaVersion": 1, "id": "release-dictate-bar-1-3", "appId": "app-dictate-bar",
      "version": "1.3", "status": "released", "releaseDate": "2026-11-05T12:00:00Z",
      "notesPath": "notes.md", "assetPaths": ["Assets/release-banner.png"],
      "externalChangelogPath": "/Users/example/Projects/DictateBar/CHANGELOG.md"
    }
    ```

    Release `status` is `planned` or `released`. `releaseDate` is optional and may be `null`. `notesPath` is a Markdown file path relative to that release's folder (normally `notes.md`). `assetPaths` is an optional array of paths relative to that release's folder; release assets are copied into its `Assets/` directory. `externalChangelogPath` is an optional readable filesystem path; it is a reference and the app does not copy or modify that file. Release folders are under the app folder and commonly use the version as their name.

    `iconPath` is an optional path relative to the app folder for the app's icon image, normally under `Assets/`. The app copies selected artwork into the workspace and keeps the original source file unchanged.

    App `developmentStatus` is one of `development`, `beta`, `released`, `maintenance`, or `archived`. `description`, `bundleIDs`, `developmentStatus`, and `testFlightURL` are optional and may be omitted or `null`.

    Supported `kind` values: `blog`, `social`, `idea`. Supported statuses: `idea`, `draft`, `ready`, `published`. `releaseId` is an optional stable ID reference to a release record; it is not a folder name or version string. `plannedDate` is an optional ISO-8601 date for the content schedule. A destination's `publishedDate` is optional and records the manually entered publication date for that account. A destination with `bodyPath: null` uses the current `originalBodyPath` contents live; it is not a snapshot. A non-null destination body path is a customized branch. Editing a branch must not edit the original or other branches. `mediaPaths: null` on a destination inherits the record's `mediaPaths`; a list overrides it (an empty list means no media for that destination). `sourceContentId` is a one-way link; reverse related items are derived by finding records whose `sourceContentId` matches this record's ID.

    ## External editing and conflicts

    1. Read `record.json` and referenced body/media files before editing. Preserve unknown keys if your tool round-trips JSON, and do not change IDs to rename records or folders.
    2. Write the complete new contents to a temporary file in the same folder, flush it, then atomically replace the original. Never truncate a live record and rewrite it in place. Each individual replacement is atomic; a save that updates several files is not one atomic filesystem transaction.
    3. Keep all referenced asset and body paths inside the workspace. Do not move or delete referenced files without updating their records. Use relative paths, not absolute paths, for workspace files.
    4. The app watches workspace records and refreshes after external changes. If the app also has unsaved edits, it reports a revision conflict without replacing the changed file. Keep the app editor open to preserve the local draft; Reload intentionally discards that draft. Resolve the two versions explicitly before continuing. Multi-file saves preflight revisions and, on a reported write failure, attempt to restore files written by that save only if their current bytes still match the save output. If rollback cannot be done safely, the app names the files needing review. This is best-effort recovery, not crash recovery or a transaction; a crash or an independent writer racing the final check can still leave a partial save. Independent writers should avoid simultaneous writes.
    5. Future schema versions and malformed JSON are kept as opaque files and reported for repair. Do not downgrade their `schemaVersion` or replace them with a partial record.

    Do not edit `workspace.json` except to intentionally change workspace metadata. Do not put API keys, passwords, OAuth tokens, or other secrets in this workspace.

    """
}
