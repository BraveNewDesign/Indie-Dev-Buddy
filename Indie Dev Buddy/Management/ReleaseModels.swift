import Foundation

nonisolated public enum ReleaseStatus: String, Codable, CaseIterable, Sendable, Identifiable {
    case planned
    case released

    public var id: String { rawValue }
    public var label: String { rawValue.capitalized }
}

/// One release belonging to an app. `notesPath` is relative to the release folder;
/// `externalChangelogPath` is a readable path outside or inside the workspace.
nonisolated public struct ReleaseRecord: Codable, Identifiable, Equatable, Sendable {
    public var schemaVersion: Int
    public var id: String
    public var appId: String
    public var version: String
    public var status: ReleaseStatus
    public var releaseDate: Date?
    public var notesPath: String
    /// Optional workspace-relative file paths, stored relative to this release folder.
    public var assetPaths: [String]?
    public var externalChangelogPath: String?

    public init(
        schemaVersion: Int = 1,
        id: String = UUID().uuidString.lowercased(),
        appId: String,
        version: String,
        status: ReleaseStatus = .planned,
        releaseDate: Date? = nil,
        notesPath: String = "notes.md",
        assetPaths: [String]? = nil,
        externalChangelogPath: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.appId = appId
        self.version = version
        self.status = status
        self.releaseDate = releaseDate
        self.notesPath = notesPath
        self.assetPaths = assetPaths
        self.externalChangelogPath = externalChangelogPath
    }
}

func workspaceReleaseReferences(apps: [AppRecord], store: WorkspaceStore) async -> [ComposerReleaseReference] {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    var result: [ComposerReleaseReference] = []
    for app in apps {
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
