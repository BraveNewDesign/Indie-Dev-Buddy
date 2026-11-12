import Foundation

nonisolated public enum AssetOwnerKind: String, Codable, Sendable {
    case app, website, identity, shared
}

nonisolated public struct AssetOwner: Codable, Hashable, Sendable {
    public let kind: AssetOwnerKind
    public let id: String

    public init(_ kind: AssetOwnerKind, _ id: String) {
        self.kind = kind
        self.id = id
    }

    public static let shared = Self(.shared, "")
}

nonisolated public enum AppAssetCategory: String, Codable, CaseIterable, Sendable {
    case branding = "App Icons & Branding"
    case marketing = "Marketing Graphics"
    case video = "Videos & App Previews"
    case other = "Documents & Other Files"
}

nonisolated public struct WorkspaceAsset: Identifiable, Codable, Sendable {
    public let id: UUID
    public let fileExtension: String
    public let originalFilename: String?
    public var name: String
    public var owner: AssetOwner
    public var folderID: UUID?
    public var category: AppAssetCategory?
    public var tags: [String] = []
    /// Stable remote identifier for an App Store Connect screenshot import.
    public var appStoreConnectScreenshotID: String? = nil
    public let added: Date

    public var reference: String {
        "asset:" + id.uuidString.lowercased() + (fileExtension.isEmpty ? "" : ".\(fileExtension)")
    }
}

nonisolated public struct AssetFolder: Identifiable, Codable, Sendable {
    public var id = UUID()
    public var name: String
    public var owner: AssetOwner
    public var parentID: UUID?
}

nonisolated public struct ScreenshotSet: Identifiable, Codable, Sendable {
    public var id = UUID()
    public var appID: String
    public var platform: ScreenshotPlatform
    public var categoryID: String
    public var locale: String
    public var version: String
    public var name: String
    public var assetIDs: [UUID] = []
    /// Stable remote identifier for an App Store Connect screenshot set.
    public var appStoreConnectSetID: String? = nil
    /// Original App Store Connect display category (for example, APP_IPHONE_67).
    public var appStoreConnectDisplayType: String? = nil

    public var categoryName: String { ScreenshotSpecifications.category(categoryID)?.title ?? categoryID }
    public var title: String { name.isEmpty ? categoryName : name }
}

nonisolated public struct AssetLibrary: Codable, Sendable {
    public static let directory = "Shared Files/Asset Library"
    static let indexPath = "\(directory)/library.json"

    public var assets: [WorkspaceAsset] = []
    public var folders: [AssetFolder] = []
    public var screenshotSets: [ScreenshotSet] = []

    public mutating func removeFolder(_ id: UUID) {
        let parent = folders.first { $0.id == id }?.parentID
        folders.removeAll { $0.id == id }
        for index in folders.indices where folders[index].parentID == id { folders[index].parentID = parent }
        for index in assets.indices where assets[index].folderID == id { assets[index].folderID = nil }
    }

    public static func managedPath(_ reference: String) -> String? {
        guard reference.hasPrefix("asset:") else { return nil }
        let filename = String(reference.dropFirst("asset:".count))
        let parts = filename.split(separator: ".", omittingEmptySubsequences: false)
        guard let first = parts.first, parts.count <= 2, let id = UUID(uuidString: String(first)),
              first == id.uuidString.lowercased() else { return nil }
        if parts.count == 2 {
            guard parts[1].range(of: "^[a-z0-9]{1,16}$", options: .regularExpression) != nil else { return nil }
        }
        return "\(directory)/Files/\(filename)"
    }
}

extension WorkspaceStore {
    public func loadAssetLibrary() throws -> (library: AssetLibrary, revision: String?) {
        do {
            let file = try read(relativePath: AssetLibrary.indexPath)
            return (try decoder.decode(AssetLibrary.self, from: file.data), file.revision)
        } catch CocoaError.fileReadNoSuchFile {
            return (AssetLibrary(), nil)
        }
    }

    @discardableResult
    public func saveAssetLibrary(_ library: AssetLibrary, revision: String?) throws -> String {
        try withWorkspaceLock { try writeAssetIndex(library, revision: revision) }
    }

    private func writeAssetIndex(_ library: AssetLibrary, revision: String?) throws -> String {
        let path = AssetLibrary.indexPath
        guard try safeURL(path).path == rootURL.appendingPathComponent(path).path else {
            throw WorkspaceStoreError.invalidRelativePath(path)
        }
        return try applyWrites([.init(data: encoder.encode(library), relativePath: path, expectedRevision: revision)])[0]
    }

    public func importAsset(_ source: URL, owner: AssetOwner, folderID: UUID? = nil,
                            displayName: String? = nil, category: AppAssetCategory? = nil, into setID: UUID? = nil,
                            replacing replacedID: UUID? = nil, appStoreConnectScreenshotID: String? = nil,
                            remoteScreenshotOrder: [String]? = nil, remoteScreenshotSet: ScreenshotSet? = nil) throws -> WorkspaceAsset {
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard source.isFileURL, values.isRegularFile == true, values.isSymbolicLink != true else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        return try withWorkspaceLock {
            var (library, revision) = try loadAssetLibrary()
            let ext = source.pathExtension.lowercased()
            let fromManagedFolder = source.standardizedFileURL.deletingLastPathComponent().path ==
                rootURL.appendingPathComponent("\(AssetLibrary.directory)/Files").path
            let existingRemote = appStoreConnectScreenshotID.flatMap { remoteID in
                library.assets.first { $0.owner == owner && $0.appStoreConnectScreenshotID == remoteID }
            }
            let existing = existingRemote ?? (displayName == nil && fromManagedFolder ? library.assets.first { asset in
                guard let path = AssetLibrary.managedPath(asset.reference) else { return false }
                return rootURL.appendingPathComponent(path).path == source.standardizedFileURL.path
            } : nil)
            let asset = existing ?? WorkspaceAsset(
                id: UUID(),
                fileExtension: ext.range(of: "^[a-z0-9]{1,16}$", options: .regularExpression) == nil ? "" : ext,
                originalFilename: source.lastPathComponent,
                name: displayName ?? source.lastPathComponent, owner: owner,
                folderID: library.folders.contains { $0.id == folderID && $0.owner == owner } ? folderID : nil,
                category: category, appStoreConnectScreenshotID: appStoreConnectScreenshotID, added: Date()
            )
            if existing == nil { library.assets.append(asset) }
            if let remoteScreenshotSet {
                var set = library.screenshotSets.first {
                    $0.appID == remoteScreenshotSet.appID && $0.appStoreConnectSetID == remoteScreenshotSet.appStoreConnectSetID
                }
                    ?? remoteScreenshotSet
                set.platform = remoteScreenshotSet.platform
                set.categoryID = remoteScreenshotSet.categoryID
                set.locale = remoteScreenshotSet.locale
                set.version = remoteScreenshotSet.version
                set.appStoreConnectSetID = remoteScreenshotSet.appStoreConnectSetID
                set.appStoreConnectDisplayType = remoteScreenshotSet.appStoreConnectDisplayType
                if !library.screenshotSets.contains(where: { $0.id == set.id }) {
                    library.screenshotSets.append(set)
                }
            }
            if let setID {
                guard let index = library.screenshotSets.firstIndex(where: { $0.id == setID }) else {
                    throw WorkspaceCommandError("The screenshot set is no longer available.")
                }
                if let replacedID {
                    guard let position = library.screenshotSets[index].assetIDs.firstIndex(of: replacedID) else {
                        throw WorkspaceCommandError("The screenshot is no longer in this set.")
                    }
                    guard asset.id == replacedID || !library.screenshotSets[index].assetIDs.contains(asset.id) else {
                        throw WorkspaceCommandError("That image is already in this set.")
                    }
                    library.screenshotSets[index].assetIDs[position] = asset.id
                } else if !library.screenshotSets[index].assetIDs.contains(asset.id) {
                    library.screenshotSets[index].assetIDs.append(asset.id)
                }
            }
            if let remoteScreenshotSet, let remoteScreenshotOrder {
                guard let index = library.screenshotSets.firstIndex(where: {
                    $0.appID == remoteScreenshotSet.appID && $0.appStoreConnectSetID == remoteScreenshotSet.appStoreConnectSetID
                }) else { throw WorkspaceCommandError("The App Store screenshot set could not be created.") }
                let importedByRemoteID = Dictionary(
                    library.assets.compactMap { item -> (String, UUID)? in
                        guard item.owner == owner, let remoteID = item.appStoreConnectScreenshotID else { return nil }
                        return (remoteID, item.id)
                    }, uniquingKeysWith: { first, _ in first }
                )
                let orderedRemoteIDs = remoteScreenshotOrder.compactMap { importedByRemoteID[$0] }
                let orderedRemoteSet = Set(orderedRemoteIDs)
                let preservedAssets = library.screenshotSets[index].assetIDs.filter { !orderedRemoteSet.contains($0) }
                library.screenshotSets[index].assetIDs = orderedRemoteIDs + preservedAssets
            }
            if existing != nil {
                if setID != nil || remoteScreenshotSet != nil { _ = try writeAssetIndex(library, revision: revision) }
                return asset
            }
            let destination = try resolveContentMedia(asset.reference, recordFolder: "")
            let parent = destination.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let staged = parent.appendingPathComponent(".import-\(asset.id.uuidString.lowercased())")
            defer { try? FileManager.default.removeItem(at: staged) }
            try FileManager.default.copyItem(at: source, to: staged)
            try FileManager.default.moveItem(at: staged, to: destination)
            do {
                _ = try writeAssetIndex(library, revision: revision)
            } catch {
                if let current = try? loadAssetLibrary().library, !current.assets.contains(where: { $0.id == asset.id }) {
                    try? FileManager.default.removeItem(at: destination)
                }
                throw error
            }
            return asset
        }
    }

    public func importAssetData(_ data: Data, filename: String, owner: AssetOwner) throws -> WorkspaceAsset {
        guard !filename.isEmpty, URL(fileURLWithPath: filename).lastPathComponent == filename,
              filename != ".", filename != ".." else { throw CocoaError(.fileWriteInvalidFileName) }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent(filename)
        try data.write(to: source)
        return try importAsset(source, owner: owner)
    }

    public func resolveContentMedia(_ reference: String, recordFolder: String) throws -> URL {
        if let managed = AssetLibrary.managedPath(reference) {
            let url = try safeURL(managed)
            guard url.path == rootURL.appendingPathComponent(managed).path else {
                throw WorkspaceStoreError.invalidRelativePath(managed)
            }
            return url
        }
        guard !reference.hasPrefix("asset:"), !reference.hasPrefix("/"), !reference.isEmpty,
              !reference.split(separator: "/").contains(".."), !recordFolder.isEmpty else {
            throw WorkspaceStoreError.invalidRelativePath(reference)
        }
        let folder = try safeURL(recordFolder)
        let url = try safeURL("\(recordFolder)/\(reference)")
        guard url.path.hasPrefix(folder.path + "/"), url.lastPathComponent != "record.json" else {
            throw WorkspaceStoreError.invalidRelativePath(reference)
        }
        return url
    }

    public func trashAsset(_ id: UUID) throws {
        try withWorkspaceLock {
            var (library, revision) = try loadAssetLibrary()
            guard let asset = library.assets.first(where: { $0.id == id }) else { return }
            let snapshot = try load(installAgentGuidance: false)
            guard !snapshot.errors.contains(where: { $0.path.hasPrefix("Content/") }) else {
                throw WorkspaceCommandError("Repair unreadable content records before deleting assets.")
            }
            guard !library.screenshotSets.contains(where: { $0.assetIDs.contains(id) }),
                  !snapshot.content.contains(where: {
                      $0.mediaPaths.contains(asset.reference) || $0.destinations.contains { $0.mediaPaths?.contains(asset.reference) == true }
                  }) else {
                throw WorkspaceCommandError("This asset is used in a screenshot set or saved content. Remove those references before moving it to the Trash.")
            }
            let url = try resolveContentMedia(asset.reference, recordFolder: "")
            library.assets.removeAll { $0.id == id }
            let newRevision = try writeAssetIndex(library, revision: revision)
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } catch {
                library.assets.append(asset)
                _ = try writeAssetIndex(library, revision: newRevision)
                throw error
            }
        }
    }
}

nonisolated public struct ScreenshotSetCheck: Sendable {
    public var summary: [String] = []
    public var images: [UUID: [String]] = [:]
    public var dimensions: [UUID: ScreenshotPixels] = [:]
    public var ready: Bool { summary.isEmpty && images.values.allSatisfy(\.isEmpty) }
}

extension WorkspaceStore {
    public func validateScreenshotSets(_ library: AssetLibrary) -> [UUID: ScreenshotSetCheck] {
        let assets = Dictionary(library.assets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [UUID: ScreenshotSetCheck] = [:]
        var watchSizes: [String: Set<ScreenshotPixels>] = [:]
        for set in library.screenshotSets {
            var check = ScreenshotSetCheck()
            if !ScreenshotSpecifications.count.contains(set.assetIDs.count) {
                check.summary.append("A screenshot set needs 1–10 images.")
            }
            guard let category = ScreenshotSpecifications.category(set.categoryID), category.platform == set.platform else {
                check.summary.append("Choose a display category for \(set.platform.rawValue).")
                result[set.id] = check
                continue
            }
            for id in set.assetIDs {
                let url = assets[id].flatMap { try? resolveContentMedia($0.reference, recordFolder: "") }
                check.images[id] = category.issues(for: url)
                check.dimensions[id] = url.flatMap(ScreenshotSpecifications.dimensions(of:))
                if set.platform == .watch, check.images[id]?.isEmpty == true,
                   let dimensions = check.dimensions[id] {
                    watchSizes[set.appID + "|" + set.version, default: []].insert(dimensions)
                }
            }
            result[set.id] = check
        }
        for set in library.screenshotSets where set.platform == .watch {
            if (watchSizes[set.appID + "|" + set.version]?.count ?? 0) > 1 {
                result[set.id]?.summary.append("Use one Apple Watch screenshot size throughout this release, including across localizations.")
            }
        }
        return result
    }
}

extension WorkspaceStore {
    func validateManagedAttachments(_ record: ContentRecord) throws {
        let references = Set((record.mediaPaths + record.destinations.flatMap { $0.mediaPaths ?? [] })
            .filter { $0.hasPrefix("asset:") })
        guard !references.isEmpty else { return }
        let assets = Set(try loadAssetLibrary().library.assets.map(\.reference))
        for reference in references {
            guard assets.contains(reference),
                  let url = try? resolveContentMedia(reference, recordFolder: ""),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                throw WorkspaceCommandError("An attached library asset is missing. Remove or replace the attachment before saving.")
            }
        }
    }

    public func writeContentWithAttachments(_ record: ContentRecord, operations: [WorkspaceWriteOperation]) throws -> [String] {
        try withWorkspaceLock {
            try validateManagedAttachments(record)
            return try applyWrites(operations)
        }
    }
}
