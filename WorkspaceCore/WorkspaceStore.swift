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
    let encoder: JSONEncoder
    let decoder: JSONDecoder
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

    func readManifest() throws -> WorkspaceManifest {
        let manifestData: Data
        do { manifestData = try read(relativePath: "workspace.json").data }
        catch CocoaError.fileReadNoSuchFile { throw WorkspaceStoreError.notWorkspace }
        let manifest = try decoder.decode(WorkspaceManifest.self, from: manifestData)
        guard manifest.schemaVersion == 1 else { throw WorkspaceStoreError.unsupportedSchema(manifest.schemaVersion) }
        guard !manifest.id.isEmpty, !manifest.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorkspaceStoreError.notWorkspace
        }
        return manifest
    }

    public func load(installAgentGuidance: Bool = true) throws -> WorkspaceSnapshot {
        let manifest = try readManifest()
        if installAgentGuidance { installGuidance(at: rootURL) }
        var recordPaths: [String: [String: String]] = [:]
        var errors: [WorkspaceFileError] = []
        var opaque: [OpaqueWorkspaceRecord] = []
        let identities: [IdentityRecord] = scan("Identities", errors: &errors, opaque: &opaque, recordPaths: &recordPaths)
        let apps: [AppRecord] = scan("Apps", errors: &errors, opaque: &opaque, recordPaths: &recordPaths)
        let websites: [WebsiteRecord] = scan("Websites", errors: &errors, opaque: &opaque, recordPaths: &recordPaths)
        let accounts: [SocialAccountRecord] = scan("SocialAccounts", errors: &errors, opaque: &opaque, recordPaths: &recordPaths)
        let content: [ContentRecord] = scan("Content", errors: &errors, opaque: &opaque, recordPaths: &recordPaths)
        for (label, ids) in [("identity", identities.map(\.id)), ("app", apps.map(\.id)), ("website", websites.map(\.id)), ("social account", accounts.map(\.id)), ("content", content.map(\.id))] {
            var seen = Set<String>()
            for id in ids where !seen.insert(id).inserted { errors.append(.init(path: label, message: WorkspaceStoreError.duplicateID(id).localizedDescription)) }
        }
        return WorkspaceSnapshot(manifest: manifest, identities: identities, apps: apps, websites: websites, socialAccounts: accounts, content: content, errors: errors, opaqueRecords: opaque, recordPaths: recordPaths)
    }

    public func read(relativePath: String) throws -> (data: Data, revision: String) {
        let url = try safeURL(relativePath)
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw WorkspaceStoreError.invalidRelativePath(relativePath)
        }
        let data = try Data(contentsOf: url)
        return (data, Self.revision(data))
    }

    /// Removes one workspace item after resolving and validating its path inside the workspace.
    public func deleteItem(relativePath: String) throws {
        try withWorkspaceLock {
            let url = try safeURL(relativePath)
            guard url.path != rootURL.path, fileManager.fileExists(atPath: url.path) else {
                throw WorkspaceStoreError.invalidRelativePath(relativePath)
            }
            try fileManager.removeItem(at: url)
        }
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
        return try withWorkspaceLock { try applyWrites(operations) }
    }

    func withWorkspaceLock<Result>(exclusive: Bool = true, _ action: () throws -> Result) throws -> Result {
        // The directory inode remains stable across atomic replacements of record files.
        let descriptor = open(rootURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        while flock(descriptor, exclusive ? LOCK_EX : LOCK_SH) != 0 {
            guard errno == EINTR else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        return try action()
    }

    func applyWrites(_ operations: [WorkspaceWriteOperation], backupDirectory: String? = nil) throws -> [String] {
        var seen = Set<URL>()

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
            guard seen.insert(url).inserted else { throw WorkspaceStoreError.duplicateWritePath(operation.relativePath) }
            let oldData = fileManager.fileExists(atPath: url.path) ? try read(relativePath: operation.relativePath).data : nil
            let currentRevision = oldData.map(Self.revision)
            guard operation.expectedRevision == currentRevision else {
                throw WorkspaceStoreError.conflict(path: operation.relativePath, currentRevision: currentRevision)
            }
            prepared.append(Prepared(operation: operation, url: url, oldData: oldData, newRevision: Self.revision(operation.data)))
        }

        for item in prepared {
            try fileManager.createDirectory(at: item.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }

        if let backupDirectory {
            for item in prepared {
                guard let oldData = item.oldData else { continue }
                let path = "\(backupDirectory)/\(item.operation.relativePath)"
                let backup = try safeURL(path)
                guard backup.path == rootURL.appendingPathComponent(path).path else {
                    throw WorkspaceStoreError.invalidRelativePath(path)
                }
                try fileManager.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard try safeURL(path).path == backup.path else { throw WorkspaceStoreError.invalidRelativePath(path) }
                try writeExclusively(oldData, to: backup)
            }
        }

        var attempted: [Prepared] = []
        do {
            for item in prepared {
                guard try safeURL(item.operation.relativePath).path == item.url.path else {
                    throw WorkspaceStoreError.invalidRelativePath(item.operation.relativePath)
                }
                let currentData = fileManager.fileExists(atPath: item.url.path) ? try read(relativePath: item.operation.relativePath).data : nil
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
                if item.oldData == nil {
                    try writeNewAtomically(item.operation.data, to: item.url)
                } else {
                    try writeAtomically(item.operation.data, to: item.url)
                }
                attempted.append(item)
            }
        } catch {
            var unrecovered: [String] = []
            for item in attempted.reversed() {
                do {
                    guard try safeURL(item.operation.relativePath).path == item.url.path else {
                        unrecovered.append(item.operation.relativePath)
                        continue
                    }
                    let current = fileManager.fileExists(atPath: item.url.path) ? try read(relativePath: item.operation.relativePath).data : nil
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

    private func scan<T: Decodable & Identifiable>(
        _ directory: String, errors: inout [WorkspaceFileError],
        opaque: inout [OpaqueWorkspaceRecord], recordPaths: inout [String: [String: String]]
    ) -> [T] where T.ID == String {
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
                let raw = try read(relativePath: relativePath).data
                if let object = try JSONSerialization.jsonObject(with: raw) as? [String: Any],
                   let version = object["schemaVersion"] as? Int, version != 1 {
                    let reason = WorkspaceStoreError.unsupportedSchema(version).localizedDescription
                    errors.append(.init(path: file.path, message: reason))
                    opaque.append(.init(relativePath: String(file.path.dropFirst(rootURL.path.count + 1)), data: raw, reason: reason))
                    continue
                }
                let record = try decoder.decode(T.self, from: raw)
                if recordPaths[directory, default: [:]][record.id] == nil {
                    recordPaths[directory, default: [:]][record.id] = relativePath
                }
                result.append(record)
            } catch {
                errors.append(.init(path: file.path, message: error.localizedDescription))
                if let raw = try? read(relativePath: relativePath).data {
                    opaque.append(.init(relativePath: String(file.path.dropFirst(rootURL.path.count + 1)), data: raw, reason: error.localizedDescription))
                }
            }
        }
        return result
    }

    func safeURL(_ relativePath: String) throws -> URL {
        try safeURL(relativePath, inside: rootURL)
    }

    private func safeURL(_ relativePath: String, inside root: URL) throws -> URL {
        let components = relativePath.split(separator: "/")
        guard !components.isEmpty, !relativePath.contains("\0"), !relativePath.hasPrefix("/"),
              !components.contains("..") else {
            throw WorkspaceStoreError.invalidRelativePath(relativePath)
        }
        var url = root
        for component in components where component != "." {
            let candidate = url.appendingPathComponent(String(component))
            // Resolve each existing ancestor before appending a potentially missing suffix.
            // Resolving only the complete URL can leave a symlinked ancestor unresolved.
            url = candidate.resolvingSymlinksInPath()
            if url.path == candidate.path,
               (try? fileManager.destinationOfSymbolicLink(atPath: candidate.path)) != nil {
                throw WorkspaceStoreError.invalidRelativePath(relativePath)
            }
            guard url.path == root.path || url.path.hasPrefix(root.path + "/") else {
                throw WorkspaceStoreError.invalidRelativePath(relativePath)
            }
        }
        return url
    }

    private func writeAtomically(_ data: Data, to url: URL) throws { try data.write(to: url, options: .atomic) }

    private func writeNewAtomically(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".idb-\(UUID().uuidString)")
        try writeExclusively(data, to: temporary)
        defer { try? fileManager.removeItem(at: temporary) }
        guard link(temporary.path, url.path) == 0 else {
            if errno == EEXIST { throw WorkspaceStoreError.conflict(path: url.path, currentRevision: nil) }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

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
            do {
                let destination = try safeURL(path, inside: root)
                if fileManager.fileExists(atPath: destination.path) {
                    if root == rootURL, let prior = WorkspaceGuidance.priorCLIRevisions[path],
                       destination.path == root.appendingPathComponent(path).path,
                       let current = try? read(relativePath: path), current.revision == prior {
                        _ = try? write(Data(content.utf8), relativePath: path, expectedRevision: prior)
                    }
                    continue
                }
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard try safeURL(path, inside: root).path == destination.path else { continue }
                try writeExclusively(Data(content.utf8), to: destination)
            } catch {
                // A read-only workspace, conflicting path, or concurrent creator must not block loading.
            }
        }
        // Keep older data-format references intact and install updates alongside them.
        if let format = try? safeURL("docs/DATA_FORMAT.md", inside: root),
           let text = try? String(contentsOf: format, encoding: .utf8),
           let range = text.range(of: #"<!-- Indie Dev Buddy guidance version: ([0-9]+) -->"#, options: .regularExpression),
           let version = Int(text[range].filter(\.isNumber)), version < WorkspaceGuidance.version,
           let reference = WorkspaceGuidance.files.first(where: { $0.path == "docs/DATA_FORMAT.md" })?.contents,
           let destination = try? safeURL("docs/DATA_FORMAT.v\(WorkspaceGuidance.version).md", inside: root),
           !fileManager.fileExists(atPath: destination.path) {
            try? writeExclusively(Data(reference.utf8), to: destination)
        }
    }
}
