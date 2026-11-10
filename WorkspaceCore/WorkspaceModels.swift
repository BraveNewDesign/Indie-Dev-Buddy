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
    /// Image path relative to the workspace root.
    public var photoPath: String?
    public init(id: String = UUID().uuidString.lowercased(), name: String, kind: String? = nil, photoPath: String? = nil) { self.id = id; self.name = name; self.kind = kind; self.photoPath = photoPath }
}

nonisolated public struct RecordOwner: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case identity, app }
    public var type: Kind
    public var id: String
    public init(type: Kind, id: String) { self.type = type; self.id = id }
}

nonisolated public struct AppWebsiteLink: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var websiteId: String
    public var purpose: String
    public var url: URL?
    public var isPrimary: Bool
    public init(id: String = UUID().uuidString.lowercased(), websiteId: String, purpose: String, url: URL? = nil, isPrimary: Bool = false) {
        self.id = id
        self.websiteId = websiteId
        self.purpose = purpose
        self.url = url
        self.isPrimary = isPrimary
    }

    private enum CodingKeys: String, CodingKey { case id, websiteId, purpose, url, isPrimary }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString.lowercased()
        websiteId = try values.decode(String.self, forKey: .websiteId)
        purpose = try values.decode(String.self, forKey: .purpose)
        url = try values.decodeIfPresent(URL.self, forKey: .url)
        isPrimary = try values.decodeIfPresent(Bool.self, forKey: .isPrimary) ?? false
    }
}

nonisolated public enum AppDevelopmentStatus: String, Codable, CaseIterable, Sendable, Identifiable {
    case development
    case beta
    case released
    case maintenance
    case archived

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .development: "In Development"
        case .beta: "Beta Testing"
        case .released: "Released"
        case .maintenance: "Maintenance"
        case .archived: "Archived"
        }
    }
}

nonisolated public struct AppRecord: Codable, Sendable, Identifiable, Equatable {
    public var schemaVersion: Int = 1
    public var id: String
    public var name: String
    public var description: String?
    public var bundleIDs: [String]?
    public var developmentStatus: AppDevelopmentStatus?
    /// Image path relative to this app's folder, normally under `Assets/`.
    public var iconPath: String?
    public var developerIdentityId: String?
    public var platforms: [String]
    public var projectPath: String?
    public var repositoryURL: URL?
    public var appStoreURL: URL?
    public var testFlightURL: URL?
    public var websiteLinks: [AppWebsiteLink]
    public init(id: String = UUID().uuidString.lowercased(), name: String, description: String? = nil, bundleIDs: [String]? = nil, developmentStatus: AppDevelopmentStatus? = nil, iconPath: String? = nil, developerIdentityId: String? = nil, platforms: [String] = [], projectPath: String? = nil, repositoryURL: URL? = nil, appStoreURL: URL? = nil, testFlightURL: URL? = nil, websiteLinks: [AppWebsiteLink] = []) {
        self.id = id; self.name = name; self.description = description; self.bundleIDs = bundleIDs; self.developmentStatus = developmentStatus; self.iconPath = iconPath; self.developerIdentityId = developerIdentityId; self.platforms = platforms; self.projectPath = projectPath; self.repositoryURL = repositoryURL; self.appStoreURL = appStoreURL; self.testFlightURL = testFlightURL; self.websiteLinks = websiteLinks
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
    /// Verified SocialKit identity bound during account connection. Editable profile metadata is not an API recipient key.
    public var providerIdentity: ContentRecipientIdentity?
    public var enabled: Bool
    public init(id: String = UUID().uuidString.lowercased(), platform: String, owner: RecordOwner? = nil, handle: String? = nil, profileURL: URL? = nil, avatarPath: String? = nil, providerIdentity: ContentRecipientIdentity? = nil, enabled: Bool = true) {
        self.id = id; self.platform = platform; self.owner = owner; self.handle = handle; self.profileURL = profileURL; self.avatarPath = avatarPath; self.providerIdentity = providerIdentity; self.enabled = enabled
    }
    public var isEligibleDestination: Bool {
        enabled && owner != nil && !platform.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (handle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false || profileURL != nil)
    }
}

nonisolated public enum ContentKind: String, Codable, Sendable { case blog, social, idea }
nonisolated public enum ContentStatus: String, Codable, Sendable {
    case idea, draft, ready, scheduled, manuallyScheduled, published

    public var displayTitle: String {
        self == .manuallyScheduled ? "Manually Scheduled" : rawValue.capitalized
    }

    public init?(displayTitle: String) {
        let cleaned = displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.caseInsensitiveCompare("Manually Scheduled") == .orderedSame {
            self = .manuallyScheduled
            return
        }
        let normalized = cleaned.lowercased()
        self.init(rawValue: normalized)
    }
}

nonisolated public enum ContentScheduleMode: String, Codable, Sendable { case api, manual }
nonisolated public enum ContentDeliveryState: String, Codable, Sendable {
    case queued, sending, failed, outcomeUnknown, overdue, delivered, canceled

    public var displayTitle: String {
        switch self {
        case .queued: "Queued"
        case .sending: "Sending"
        case .failed: "Failed"
        case .outcomeUnknown: "Needs Review"
        case .overdue: "Overdue"
        case .delivered: "Sent"
        case .canceled: "Canceled"
        }
    }
}

nonisolated public struct ContentRecipientIdentity: Codable, Sendable, Equatable, Hashable {
    public var platform: String
    public var server: URL
    public var remoteID: String

    public init(platform: String, server: URL, remoteID: String) {
        self.platform = platform
        self.server = server
        self.remoteID = remoteID
    }
}

nonisolated public enum ContentScheduledMediaKind: String, Codable, Sendable { case image, video }

nonisolated public struct ContentScheduledMedia: Codable, Sendable, Equatable {
    public var kind: ContentScheduledMediaKind
    public var publicURL: URL

    public init(kind: ContentScheduledMediaKind, publicURL: URL) {
        self.kind = kind
        self.publicURL = publicURL
    }
}

/// Immutable, provider-neutral payload captured when a person explicitly schedules delivery.
nonisolated public struct ContentDeliveryIntent: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var workspaceID: String
    public var workspaceRootPath: String
    public var contentID: String
    public var destinationID: String
    public var recipient: ContentRecipientIdentity
    public var scheduledDate: Date
    public var draftID: UUID
    public var draftCreatedAt: Date
    public var text: String
    public var media: [ContentScheduledMedia]

    public init(id: UUID = UUID(), workspaceID: String, workspaceRootPath: String,
                contentID: String, destinationID: String, recipient: ContentRecipientIdentity,
                scheduledDate: Date, draftID: UUID, draftCreatedAt: Date, text: String,
                media: [ContentScheduledMedia] = []) {
        self.id = id
        self.workspaceID = workspaceID
        self.workspaceRootPath = workspaceRootPath
        self.contentID = contentID
        self.destinationID = destinationID
        self.recipient = recipient
        self.scheduledDate = scheduledDate
        self.draftID = draftID
        self.draftCreatedAt = draftCreatedAt
        self.text = text
        self.media = media
    }
}

nonisolated public struct ContentDeliveryAttempt: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var intentID: UUID
    public var state: ContentDeliveryState
    public var startedAt: Date
    public var finishedAt: Date?
    public var providerPostID: String?
    public var publishedURL: URL?
    /// Sanitized user-facing detail only. Never store raw provider bodies or credentials.
    public var message: String?

    public init(id: UUID = UUID(), intentID: UUID, state: ContentDeliveryState,
                startedAt: Date, finishedAt: Date? = nil, providerPostID: String? = nil,
                publishedURL: URL? = nil, message: String? = nil) {
        self.id = id
        self.intentID = intentID
        self.state = state
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.providerPostID = providerPostID
        self.publishedURL = publishedURL
        self.message = message
    }
}

nonisolated public struct ContentDeliveryResult: Codable, Sendable, Equatable {
    public var state: ContentDeliveryState
    public var providerPostID: String?
    public var publishedURL: URL?
    public var message: String?

    public init(state: ContentDeliveryState, providerPostID: String? = nil,
                publishedURL: URL? = nil, message: String? = nil) {
        self.state = state
        self.providerPostID = providerPostID
        self.publishedURL = publishedURL
        self.message = message
    }
}

nonisolated public struct ContentSchedule: Codable, Sendable, Equatable {
    public var mode: ContentScheduleMode
    public var scheduledDate: Date
    public var state: ContentDeliveryState
    /// Effective account-specific text captured when an API delivery is queued.
    public var textSnapshot: String?
    /// Public HTTPS URLs only; local media files are not uploaded automatically.
    public var mediaURLs: [URL]
    /// Media type is captured so provider requirements can be checked at both schedule and send time.
    public var media: [ContentScheduledMedia]?
    /// Identity returned by SocialKit at connection time, independent of editable workspace handle data.
    public var recipient: ContentRecipientIdentity?
    /// Stable source draft metadata required by providers that derive record IDs from creation time.
    public var draftID: UUID?
    public var draftCreatedAt: Date?
    /// Preserve the same key when reconciling an uncertain provider write.
    public var idempotencyKey: UUID
    public var lastError: String?

    public init(
        mode: ContentScheduleMode,
        scheduledDate: Date,
        state: ContentDeliveryState = .queued,
        textSnapshot: String? = nil,
        mediaURLs: [URL] = [],
        media: [ContentScheduledMedia]? = nil,
        recipient: ContentRecipientIdentity? = nil,
        draftID: UUID? = nil,
        draftCreatedAt: Date? = nil,
        idempotencyKey: UUID = UUID(),
        lastError: String? = nil
    ) {
        self.mode = mode
        self.scheduledDate = scheduledDate
        self.state = state
        self.textSnapshot = textSnapshot
        self.mediaURLs = mediaURLs
        self.media = media
        self.recipient = recipient
        self.draftID = draftID
        self.draftCreatedAt = draftCreatedAt
        self.idempotencyKey = idempotencyKey
        self.lastError = lastError
    }
}

nonisolated public struct ContentDestination: Codable, Sendable, Identifiable, Equatable {
    public var id: String { accountId }
    public var accountId: String
    public var bodyPath: String?
    public var status: ContentStatus
    public var publishedURL: URL?
    public var publishedDate: Date?
    public var mediaPaths: [String]?
    public var schedule: ContentSchedule?
    public var deliveryHistory: [ContentDeliveryAttempt]?
    public init(accountId: String, bodyPath: String? = nil, status: ContentStatus = .draft, publishedURL: URL? = nil, publishedDate: Date? = nil, mediaPaths: [String]? = nil, schedule: ContentSchedule? = nil, deliveryHistory: [ContentDeliveryAttempt]? = nil) {
        self.accountId = accountId; self.bodyPath = bodyPath; self.status = status; self.publishedURL = publishedURL; self.publishedDate = publishedDate; self.mediaPaths = mediaPaths; self.schedule = schedule; self.deliveryHistory = deliveryHistory
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
    /// Legacy association retained so existing workspace records remain readable.
    /// The current UI does not create, resolve, or display release associations.
    public var releaseId: String?
    public var relatedGroupId: String?
    public var originalBodyPath: String?
    public var excerpt: String?
    public var includeSourceLink: Bool
    public var status: ContentStatus
    public var plannedDate: Date?
    public var publishedURL: URL?
    public var destinations: [ContentDestination]
    public var mediaPaths: [String]
    public init(id: String = UUID().uuidString.lowercased(), kind: ContentKind, title: String, appIds: [String] = [], websiteId: String? = nil, sourceContentId: String? = nil, releaseId: String? = nil, relatedGroupId: String? = nil, originalBodyPath: String? = nil, excerpt: String? = nil, includeSourceLink: Bool = false, status: ContentStatus = .draft, plannedDate: Date? = nil, publishedURL: URL? = nil, destinations: [ContentDestination] = [], mediaPaths: [String] = []) {
        self.id = id; self.kind = kind; self.title = title; self.appIds = appIds; self.websiteId = websiteId; self.sourceContentId = sourceContentId; self.releaseId = releaseId; self.relatedGroupId = relatedGroupId; self.originalBodyPath = originalBodyPath; self.excerpt = excerpt; self.includeSourceLink = includeSourceLink; self.status = status; self.plannedDate = plannedDate; self.publishedURL = publishedURL; self.destinations = destinations; self.mediaPaths = mediaPaths
    }

    static func draft(kind: ContentKind, title: String, appIDs: [String] = [], websiteID: String? = nil,
                      sourceID: String? = nil, accountIDs: [String] = []) -> Self {
        ContentRecord(kind: kind, title: title, appIds: appIDs, websiteId: websiteID, sourceContentId: sourceID,
                      originalBodyPath: kind == .blog ? "body.md" : "original.txt",
                      status: kind == .idea ? .idea : .draft, destinations: accountIDs.map { ContentDestination(accountId: $0) })
    }

    public mutating func setAppAssociation(_ appID: String, selected: Bool) {
        guard !appID.isEmpty else { return }
        if selected {
            if !appIds.contains(appID) { appIds.append(appID) }
        } else {
            appIds.removeAll { $0 == appID }
        }
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
    var recordPaths: [String: [String: String]] = [:]

    public var contentByID: [String: ContentRecord] { Dictionary(content.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }) }
    public var socialAccountsByID: [String: SocialAccountRecord] { Dictionary(socialAccounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }) }
    public func socialDestinationSelection(for record: ContentRecord) -> SocialDestinationSelection {
        let referencedIDs = Set(record.destinations.map(\.accountId))
        let eligibleIDs = Set(socialAccounts.compactMap { account -> String? in
            guard account.isEligibleDestination, let owner = account.owner else { return nil }
            let hasResolvedOwner: Bool
            switch owner.type {
            case .identity: hasResolvedOwner = identities.contains { $0.id == owner.id }
            case .app: hasResolvedOwner = apps.contains { $0.id == owner.id }
            }
            return hasResolvedOwner ? account.id : nil
        })
        return SocialDestinationSelection(
            selectedAccountIDs: referencedIDs.intersection(eligibleIDs),
            unavailableAccountIDs: referencedIDs.subtracting(eligibleIDs)
        )
    }
    public func relatedContent(to recordID: String) -> [ContentRecord] {
        content.filter { $0.id != recordID && $0.sourceContentId == recordID }
    }
    /// Derives the complete visible family from one-way source links and optional group IDs.
    /// No reverse relationship list is persisted, so external editors only update one record.
    public func relatedFamily(to recordID: String) -> [ContentRecord] {
        guard let record = contentByID[recordID] else { return [] }
        return content.filter { candidate in
            guard candidate.id != recordID else { return false }
            if candidate.id == record.sourceContentId || candidate.sourceContentId == recordID { return true }
            if let sourceID = record.sourceContentId, candidate.sourceContentId == sourceID { return true }
            if let groupID = record.relatedGroupId, candidate.relatedGroupId == groupID { return true }
            return false
        }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }
}

nonisolated public struct OpaqueWorkspaceRecord: Sendable, Identifiable {
    public var id: String { relativePath }
    public let relativePath: String
    public let data: Data
    public let reason: String
}

nonisolated public struct WorkspaceFileListItem: Sendable {
    public let name: String
    public let path: String
    public let isDirectory: Bool
    public let revision: String?
    public init(name: String, path: String, isDirectory: Bool, revision: String? = nil) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.revision = revision
    }
}

nonisolated public struct WorkspaceFileError: Sendable, Identifiable {
    public var id: String { path }
    public let path: String
    public let message: String
}

nonisolated public struct SocialDestinationSelection: Sendable, Equatable {
    public let selectedAccountIDs: Set<String>
    public let unavailableAccountIDs: Set<String>

    public init(selectedAccountIDs: Set<String>, unavailableAccountIDs: Set<String>) {
        self.selectedAccountIDs = selectedAccountIDs
        self.unavailableAccountIDs = unavailableAccountIDs
    }
}
