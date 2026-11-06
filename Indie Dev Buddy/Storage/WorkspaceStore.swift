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
    private var writeInterferenceForTesting: (path: String, data: Data)?

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
        // The manifest is the workspace marker; never replace an existing file.
        try writeExclusively(encoder.encode(manifest), to: root.appendingPathComponent("workspace.json"))
        installGuidance(at: root)
        return manifest
    }

    public func load() throws -> WorkspaceSnapshot {
        let manifestURL = rootURL.appendingPathComponent("workspace.json")
        guard let manifestData = try? Data(contentsOf: manifestURL) else { throw WorkspaceStoreError.notWorkspace }
        let manifest = try decoder.decode(WorkspaceManifest.self, from: manifestData)
        guard manifest.schemaVersion == 1 else { throw WorkspaceStoreError.unsupportedSchema(manifest.schemaVersion) }
        installGuidance(at: rootURL)
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

    /// Removes one workspace item after resolving and validating its path inside the workspace.
    public func deleteItem(relativePath: String) throws {
        let url = try safeURL(relativePath)
        guard url.path != rootURL.path, fileManager.fileExists(atPath: url.path) else {
            throw WorkspaceStoreError.invalidRelativePath(relativePath)
        }
        try fileManager.removeItem(at: url)
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
                    if let interference = writeInterferenceForTesting,
                       let previouslyWritten = attempted.last(where: { $0.operation.relativePath == interference.path }) {
                        writeInterferenceForTesting = nil
                        try writeAtomically(interference.data, to: previouslyWritten.url)
                    }
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

    /// Simulates an independent writer racing a batch before its rollback pass.
    func setWriteInterferenceInjectionForTesting(at relativePath: String, data: Data) {
        writeInterferenceForTesting = (relativePath, data)
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
        let base: URL
        do {
            base = try safeURL(directory)
        } catch {
            errors.append(.init(path: rootURL.appendingPathComponent(directory, isDirectory: true).path, message: error.localizedDescription))
            return []
        }
        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)
        } catch {
            errors.append(.init(path: base.path, message: "Could not read workspace records in \(directory): \(error.localizedDescription)"))
            return []
        }
        var result: [T] = []
        for dir in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let relativePath = "\(directory)/\(dir.lastPathComponent)/record.json"
            let file: URL
            do {
                // Loading must obey the same workspace boundary as ordinary reads.
                // In particular, a record folder may itself be a symlink.
                file = try safeURL(relativePath)
            } catch {
                errors.append(.init(path: rootURL.appendingPathComponent(relativePath).path, message: error.localizedDescription))
                continue
            }
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
        var completed = false
        defer {
            close(fd)
            if !completed { unlink(url.path) }
        }
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
        completed = true
    }

    /// Guidance is optional to workspace access. Each file is installed independently,
    /// with exclusive creation so existing or concurrently created instructions survive.
    private func installGuidance(at root: URL) {
        for (path, content) in WorkspaceGuidance.files {
            let destination = root.appendingPathComponent(path).standardizedFileURL
            guard !fileManager.fileExists(atPath: destination.path) else { continue }
            do {
                let parent = destination.deletingLastPathComponent()
                // Resolve existing ancestors before and after creation, including a symlinked
                // parent when the final file does not yet exist.
                guard parent.resolvingSymlinksInPath().path == root.path || parent.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else { continue }
                try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
                let resolvedParent = parent.resolvingSymlinksInPath()
                guard resolvedParent.path == root.path || resolvedParent.path.hasPrefix(root.path + "/") else { continue }
                try writeExclusively(Data(content.utf8), to: resolvedParent.appendingPathComponent(destination.lastPathComponent))
            } catch {
                // A read-only workspace, conflicting path, or concurrent creator must not block loading.
            }
        }
        // Future guidance versions can place a new reference alongside an older marked
        // document; the original, including any user edits, is never replaced.
        let format = root.appendingPathComponent("docs/DATA_FORMAT.md")
        if let text = try? String(contentsOf: format, encoding: .utf8),
           let range = text.range(of: #"<!-- Indie Dev Buddy guidance version: ([0-9]+) -->"#, options: .regularExpression),
           let version = Int(text[range].filter(\.isNumber)), version < WorkspaceGuidance.version,
           let reference = WorkspaceGuidance.files.first(where: { $0.path == "docs/DATA_FORMAT.md" })?.contents {
            let path = "docs/DATA_FORMAT.v\(WorkspaceGuidance.version).md"
            let destination = root.appendingPathComponent(path).standardizedFileURL
            let parent = destination.deletingLastPathComponent().resolvingSymlinksInPath()
            if parent.path.hasPrefix(root.path + "/"), !fileManager.fileExists(atPath: destination.path) {
                try? writeExclusively(Data(reference.utf8), to: parent.appendingPathComponent(destination.lastPathComponent))
            }
        }
    }
}
