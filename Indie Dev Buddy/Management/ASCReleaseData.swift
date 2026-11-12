import Foundation

nonisolated struct ASCResourceList<Attributes: Decodable & Sendable>: Decodable, Sendable {
    struct Resource: Decodable, Sendable {
        let id: String
        let attributes: Attributes
    }
    let data: [Resource]
}

nonisolated struct ASCVersion: Identifiable, Sendable {
    struct Attributes: Decodable, Sendable {
        let versionString: String
        let platform: String
        let appVersionState: String?
        let appStoreState: String?
        let createdDate: String?
        let earliestReleaseDate: String?
    }

    let id: String
    let attributes: Attributes

    var number: String { attributes.versionString }
    var platform: String { attributes.platform }
    var state: String? { attributes.appVersionState ?? attributes.appStoreState }
    var isLive: Bool {
        if let current = attributes.appVersionState { return current == "READY_FOR_DISTRIBUTION" }
        return attributes.appStoreState == "READY_FOR_SALE"
    }
    var createdDate: Date? { ASCDisplay.date(attributes.createdDate) }
    var earliestReleaseDate: Date? { ASCDisplay.date(attributes.earliestReleaseDate) }

    static func decode(_ data: Data) throws -> [Self] {
        try JSONDecoder().decode(ASCResourceList<Attributes>.self, from: data).data
            .map { Self(id: $0.id, attributes: $0.attributes) }
            .sorted {
                let lhs = $0.createdDate ?? .distantPast
                let rhs = $1.createdDate ?? .distantPast
                if lhs != rhs { return lhs > rhs }
                return $0.number.compare($1.number, options: .numeric) == .orderedDescending
            }
    }
}

nonisolated struct ASCVersionLocalization: Decodable, Identifiable, Sendable {
    let locale: String
    let whatsNew: String?
    let description: String?
    let keywords: String?
    let promotionalText: String?
    let supportUrl: URL?
    let marketingUrl: URL?

    var id: String { locale }
}

nonisolated struct ASCReleaseStatus: Decodable, Sendable {
    struct App: Decodable, Sendable {
        let name: String
        let bundleId: String?
        let primaryLocale: String?
    }
    struct Summary: Decodable, Sendable {
        let health: String?
        let nextAction: String?
    }
    struct Builds: Decodable, Sendable {
        struct Build: Decodable, Sendable {
            let version: String?
            let buildNumber: String?
            let processingState: String?
            let uploadedDate: String?
        }
        let latest: Build?
    }
    struct Store: Decodable, Sendable {
        let versionId: String?
        let version: String?
        let state: String?
    }
    struct Submission: Decodable, Sendable {
        let inFlight: Bool?
        let blockingIssues: [String]?
    }
    struct Review: Decodable, Sendable {
        let state: String?
        let submittedDate: String?
    }

    let app: App?
    let summary: Summary?
    let builds: Builds?
    let appstore: Store?
    let submission: Submission?
    let review: Review?
}

nonisolated struct ASCReviewHistoryEntry: Decodable, Identifiable, Sendable {
    struct Item: Decodable, Sendable {
        let type: String?
        let resourceId: String?
    }

    let submissionId: String
    let versionString: String?
    let platform: String?
    let state: String?
    let submittedDate: String?
    let outcome: String?
    let items: [Item]?

    var id: String { submissionId }

    func matches(_ version: ASCVersion) -> Bool {
        let versionIDs = (items ?? []).filter { $0.type == "appStoreVersion" }.compactMap(\.resourceId)
        if !versionIDs.isEmpty { return versionIDs.contains(version.id) }
        return platform == version.platform && versionString == version.number
    }
}

nonisolated enum ASCDisplay {
    static func platform(_ value: String) -> String {
        switch value {
        case "IOS": "iOS"
        case "MAC_OS": "macOS"
        case "TV_OS": "tvOS"
        case "VISION_OS": "visionOS"
        default: state(value)
        }
    }

    static func state(_ value: String?) -> String {
        switch value?.uppercased() {
        case "READY_FOR_DISTRIBUTION", "READY_FOR_SALE": "Ready for distribution"
        case "ACCEPTED": "Accepted"
        case "COMPLETE": "Review complete"
        case "WAITING_FOR_REVIEW": "Waiting for review"
        case "IN_REVIEW": "In review"
        case "READY_FOR_REVIEW": "Ready for review"
        case "UNRESOLVED_ISSUES": "Unresolved review issues"
        case "PENDING_DEVELOPER_RELEASE": "Waiting for developer release"
        case "PENDING_APPLE_RELEASE": "Waiting for Apple release"
        case "PROCESSING_FOR_DISTRIBUTION": "Processing for distribution"
        case "VALID": "Processed"
        case "PREPARE_FOR_SUBMISSION": "Preparing for submission"
        case "WAITING_FOR_EXPORT_COMPLIANCE": "Waiting for export compliance"
        case "DEVELOPER_REMOVED_FROM_SALE": "Removed by developer"
        case "REMOVED_FROM_SALE": "Removed from sale"
        case "SUPERSEDED": "Superseded"
        case "METADATA_REJECTED": "Metadata rejected"
        case "DEVELOPER_REJECTED": "Withdrawn by developer"
        case nil, "": "Unknown"
        default: value?.replacingOccurrences(of: "_", with: " ").lowercased().capitalized ?? "Unknown"
        }
    }

    static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value))
            ?? (try? Date.ISO8601FormatStyle().parse(value))
    }
}

extension ASCIntegration {
    static func versions(executablePath: String, appID: String) async throws -> [ASCVersion] {
        let data = try await run(executablePath: executablePath, arguments: [
            "versions", "list", "--app", appID, "--paginate", "--output", "json"
        ])
        return try ASCVersion.decode(data)
    }

    static func releaseStatus(executablePath: String, appID: String, platform: String) async throws -> ASCReleaseStatus {
        let data = try await run(executablePath: executablePath, arguments: [
            "status", "--app", appID, "--platform", platform,
            "--include", "app,builds,appstore,submission,review", "--output", "json"
        ])
        let status = try JSONDecoder().decode(ASCReleaseStatus.self, from: data)
        guard status.app != nil || status.summary != nil else { throw ASCIntegrationError.invalidResponse }
        return status
    }

    static func reviewHistory(executablePath: String, appID: String, platform: String) async throws -> [ASCReviewHistoryEntry] {
        let data = try await run(executablePath: executablePath, arguments: [
            "review", "history", "--app", appID, "--platform", platform, "--paginate", "--output", "json"
        ])
        return try JSONDecoder().decode([ASCReviewHistoryEntry].self, from: data)
    }

    static func localizations(executablePath: String, versionID: String) async throws -> [ASCVersionLocalization] {
        let data = try await run(executablePath: executablePath, arguments: [
            "localizations", "list", "--version", versionID, "--paginate", "--output", "json"
        ])
        return try JSONDecoder().decode(ASCResourceList<ASCVersionLocalization>.self, from: data).data
            .map(\.attributes)
            .sorted { $0.locale < $1.locale }
    }
}
