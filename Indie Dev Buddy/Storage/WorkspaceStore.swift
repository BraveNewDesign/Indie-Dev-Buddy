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

    public var errorDescription: String? {
        switch self {
        case .notWorkspace: return "This folder does not contain a valid Indie Dev Buddy workspace."
        case .workspaceAlreadyExists: return "This folder already contains Indie Dev Buddy workspace data. Choose another folder to avoid overwriting it."
        case .invalidRelativePath(let path): return "The workspace path is invalid: \(path)"
        case .conflict(let path, _): return "\(path) changed outside Indie Dev Buddy. Reload or explicitly resolve the conflict before saving."
        case .unsupportedSchema(let version): return "Workspace schema version \(version) is not supported."
        case .duplicateID(let id): return "Multiple workspace records use the ID \(id)."
        }
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
        let url = try safeURL(relativePath)
        let exists = fileManager.fileExists(atPath: url.path)
        let current = exists ? try Data(contentsOf: url) : nil
        let currentRevision = current.map(Self.revision)
        if expectedRevision != currentRevision { throw WorkspaceStoreError.conflict(path: relativePath, currentRevision: currentRevision) }
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeAtomically(data, to: url)
        return Self.revision(data)
    }

    @discardableResult
    public func save<Record: Encodable & Sendable>(_ record: Record, relativePath: String, expectedRevision: String? = nil) throws -> String {
        try write(encoder.encode(record), relativePath: relativePath, expectedRevision: expectedRevision)
    }

    public func refresh() throws -> WorkspaceSnapshot { try load() }

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
        for category in ["Identities", "Apps", "Websites", "SocialAccounts", "Content"] {
            let categoryURL = rootURL.appendingPathComponent(category, isDirectory: true)
            guard fileManager.fileExists(atPath: categoryURL.path) else { continue }
            guard let enumerator = fileManager.enumerator(at: categoryURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            directories.append(categoryURL)
            while let item = enumerator.nextObject() as? URL {
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
        guard let urls = try? fileManager.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else { return [] }
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

    JSON keys use the Swift property names below. `schemaVersion` is `1` for records this app understands. Every record requires `schemaVersion` and a stable, unique `id`. Required fields are shown; optional fields may be omitted or set to `null`. Dates are ISO-8601 strings. URLs are strings. Relative paths use `/`, are relative to the record's folder for content body/media paths, and must stay inside the workspace.

    ## Record examples

    Identity (`Identities/brave-new-design/record.json`):

    ```json
    { "schemaVersion": 1, "id": "identity-bnd", "name": "Brave New Design", "kind": "business" }
    ```

    App (`Apps/dictate-bar/record.json`):

    ```json
    {
      "schemaVersion": 1, "id": "app-dictate-bar", "name": "Dictate Bar",
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

    Content (`Content/dictate-bar-update/record.json`):

    ```json
    {
      "schemaVersion": 1, "id": "content-update-social", "kind": "social",
      "title": "Dictate Bar update", "appIds": ["app-dictate-bar"], "websiteId": null,
      "sourceContentId": "content-update-blog", "relatedGroupId": null,
      "originalBodyPath": "original.txt", "excerpt": null, "includeSourceLink": true,
      "status": "draft", "publishedURL": null,
      "destinations": [
        { "accountId": "account-threads-business", "bodyPath": null, "status": "draft",
          "publishedURL": null, "publishedDate": null, "mediaPaths": null },
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
      "notesPath": "notes.md", "externalChangelogPath": "/Users/example/Projects/DictateBar/CHANGELOG.md"
    }
    ```

    Release `status` is `planned` or `released`. `releaseDate` is optional and may be `null`. `notesPath` is a Markdown file path relative to that release's folder (normally `notes.md`). `externalChangelogPath` is an optional readable filesystem path; it is a reference and the app does not copy or modify that file. Release folders are under the app folder and commonly use the version as their name.

    Supported `kind` values: `blog`, `social`, `idea`. Supported statuses: `idea`, `draft`, `ready`, `published`. A destination with `bodyPath: null` uses the current `originalBodyPath` contents live; it is not a snapshot. A non-null destination body path is a customized branch. Editing a branch must not edit the original or other branches. `mediaPaths: null` on a destination inherits the record's `mediaPaths`; a list overrides it (an empty list means no media for that destination). `sourceContentId` is a one-way link; reverse related items are derived by finding records whose `sourceContentId` matches this record's ID.

    ## External editing and conflicts

    1. Read `record.json` and referenced body/media files before editing. Preserve unknown keys if your tool round-trips JSON, and do not change IDs to rename records or folders.
    2. Write the complete new contents to a temporary file in the same folder, flush it, then atomically replace the original. Never truncate a live record and rewrite it in place.
    3. Keep all referenced asset and body paths inside the workspace. Do not move or delete referenced files without updating their records. Use relative paths, not absolute paths, for workspace files.
    4. The app watches workspace records and refreshes after external changes. If the app also has unsaved edits, it reports a revision conflict without replacing the changed file. Keep the app editor open to preserve the local draft; Reload intentionally discards that draft. Resolve the two versions explicitly before continuing. The app's revision check catches changes observed before save, but independent file writers should still avoid simultaneous writes.
    5. Future schema versions and malformed JSON are kept as opaque files and reported for repair. Do not downgrade their `schemaVersion` or replace them with a partial record.

    Do not edit `workspace.json` except to intentionally change workspace metadata. Do not put API keys, passwords, OAuth tokens, or other secrets in this workspace.

    """
}
