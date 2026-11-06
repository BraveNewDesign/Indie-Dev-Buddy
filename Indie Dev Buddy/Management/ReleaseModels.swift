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
