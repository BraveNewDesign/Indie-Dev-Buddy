import Foundation

nonisolated public struct WorkspaceManifest: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var id: String
    public var name: String

    public init(schemaVersion: Int = 1, id: String = UUID().uuidString.lowercased(), name: String = "Indie Dev Buddy Workspace") {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
    }
}

nonisolated public struct IdentityRecord: Codable, Sendable, Identifiable, Equatable {
    public var schemaVersion: Int = 1
    public var id: String
    public var name: String
    public var kind: String?
    public init(id: String = UUID().uuidString.lowercased(), name: String, kind: String? = nil) { self.id = id; self.name = name; self.kind = kind }
}

nonisolated public struct RecordOwner: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case identity, app }
    public var type: Kind
    public var id: String
    public init(type: Kind, id: String) { self.type = type; self.id = id }
}

nonisolated public struct AppWebsiteLink: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(websiteId):\(purpose)" }
    public var websiteId: String
    public var purpose: String
    public var url: URL?
    public var isPrimary: Bool
    public init(websiteId: String, purpose: String, url: URL? = nil, isPrimary: Bool = false) { self.websiteId = websiteId; self.purpose = purpose; self.url = url; self.isPrimary = isPrimary }
}

nonisolated public struct AppRecord: Codable, Sendable, Identifiable, Equatable {
    public var schemaVersion: Int = 1
    public var id: String
    public var name: String
    public var developerIdentityId: String?
    public var platforms: [String]
    public var projectPath: String?
    public var repositoryURL: URL?
    public var appStoreURL: URL?
    public var websiteLinks: [AppWebsiteLink]
    public init(id: String = UUID().uuidString.lowercased(), name: String, developerIdentityId: String? = nil, platforms: [String] = [], projectPath: String? = nil, repositoryURL: URL? = nil, appStoreURL: URL? = nil, websiteLinks: [AppWebsiteLink] = []) {
        self.id = id; self.name = name; self.developerIdentityId = developerIdentityId; self.platforms = platforms; self.projectPath = projectPath; self.repositoryURL = repositoryURL; self.appStoreURL = appStoreURL; self.websiteLinks = websiteLinks
    }
}

nonisolated public struct WebsiteRecord: Codable, Sendable, Identifiable, Equatable {
    public var schemaVersion: Int = 1
    public var id: String
    public var name: String
    public var owner: RecordOwner
    public var baseURL: URL
    public var blogEnabled: Bool
    public var blogIndexURL: URL?
    public init(id: String = UUID().uuidString.lowercased(), name: String, owner: RecordOwner, baseURL: URL, blogEnabled: Bool = false, blogIndexURL: URL? = nil) {
        self.id = id; self.name = name; self.owner = owner; self.baseURL = baseURL; self.blogEnabled = blogEnabled; self.blogIndexURL = blogIndexURL
    }
}

nonisolated public struct SocialAccountRecord: Codable, Sendable, Identifiable, Equatable {
    public var schemaVersion: Int = 1
    public var id: String
    public var platform: String
    public var owner: RecordOwner?
    public var handle: String?
    public var profileURL: URL?
    public var avatarPath: String?
    public var enabled: Bool
    public init(id: String = UUID().uuidString.lowercased(), platform: String, owner: RecordOwner? = nil, handle: String? = nil, profileURL: URL? = nil, avatarPath: String? = nil, enabled: Bool = true) {
        self.id = id; self.platform = platform; self.owner = owner; self.handle = handle; self.profileURL = profileURL; self.avatarPath = avatarPath; self.enabled = enabled
    }
    public var isEligibleDestination: Bool { enabled && owner != nil && (!platform.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) && ((handle?.isEmpty == false) || profileURL != nil) }
}

nonisolated public enum ContentKind: String, Codable, Sendable { case blog, social, idea }
nonisolated public enum ContentStatus: String, Codable, Sendable { case idea, draft, ready, published }

nonisolated public struct ContentDestination: Codable, Sendable, Identifiable, Equatable {
    public var id: String { accountId }
    public var accountId: String
    public var bodyPath: String?
    public var status: ContentStatus
    public var publishedURL: URL?
    public var publishedDate: Date?
    public var mediaPaths: [String]?
    public init(accountId: String, bodyPath: String? = nil, status: ContentStatus = .draft, publishedURL: URL? = nil, publishedDate: Date? = nil, mediaPaths: [String]? = nil) {
        self.accountId = accountId; self.bodyPath = bodyPath; self.status = status; self.publishedURL = publishedURL; self.publishedDate = publishedDate; self.mediaPaths = mediaPaths
    }
}

nonisolated public struct ContentRecord: Codable, Sendable, Identifiable, Equatable {
    public var schemaVersion: Int = 1
    public var id: String
    public var kind: ContentKind
    public var title: String
    public var appIds: [String]
    public var websiteId: String?
    public var sourceContentId: String?
    public var relatedGroupId: String?
    public var originalBodyPath: String?
    public var excerpt: String?
    public var includeSourceLink: Bool
    public var status: ContentStatus
    public var publishedURL: URL?
    public var destinations: [ContentDestination]
    public var mediaPaths: [String]
    public init(id: String = UUID().uuidString.lowercased(), kind: ContentKind, title: String, appIds: [String] = [], websiteId: String? = nil, sourceContentId: String? = nil, relatedGroupId: String? = nil, originalBodyPath: String? = nil, excerpt: String? = nil, includeSourceLink: Bool = false, status: ContentStatus = .draft, publishedURL: URL? = nil, destinations: [ContentDestination] = [], mediaPaths: [String] = []) {
        self.id = id; self.kind = kind; self.title = title; self.appIds = appIds; self.websiteId = websiteId; self.sourceContentId = sourceContentId; self.relatedGroupId = relatedGroupId; self.originalBodyPath = originalBodyPath; self.excerpt = excerpt; self.includeSourceLink = includeSourceLink; self.status = status; self.publishedURL = publishedURL; self.destinations = destinations; self.mediaPaths = mediaPaths
    }
}

nonisolated public struct WorkspaceSnapshot: Sendable {
    public var manifest: WorkspaceManifest
    public var identities: [IdentityRecord]
    public var apps: [AppRecord]
    public var websites: [WebsiteRecord]
    public var socialAccounts: [SocialAccountRecord]
    public var content: [ContentRecord]
    public var errors: [WorkspaceFileError]
    /// Raw bytes for records the current app cannot decode or safely interpret. Keep these
    /// files untouched when saving other records; surface errors so the user can repair them.
    public var opaqueRecords: [OpaqueWorkspaceRecord]

    public var contentByID: [String: ContentRecord] { Dictionary(content.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }) }
    public var socialAccountsByID: [String: SocialAccountRecord] { Dictionary(socialAccounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }) }
    public func relatedContent(to recordID: String) -> [ContentRecord] {
        content.filter { $0.id != recordID && $0.sourceContentId == recordID }
    }
}

nonisolated public struct OpaqueWorkspaceRecord: Sendable, Identifiable {
    public var id: String { relativePath }
    public let relativePath: String
    public let data: Data
    public let reason: String
}

nonisolated public struct WorkspaceFileError: Sendable, Identifiable {
    public var id: String { path }
    public let path: String
    public let message: String
}
