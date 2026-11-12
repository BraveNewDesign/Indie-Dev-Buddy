import AppKit
import SwiftUI

nonisolated struct ASCStoreReview: Sendable, Equatable, Identifiable {
    let id: String
    let rating: Int?
    let title: String?
    let body: String?
    let reviewer: String?
    let territory: String?
    let createdAt: Date?
    let hasResponse: Bool

    var responseLabel: String { hasResponse ? "Replied" : "No reply" }

    static func decode(_ data: Data) throws -> [ASCStoreReview] {
        try ASCListingDecoder.decodeReviews(data)
    }
}

nonisolated struct ASCTestFlightFeedback: Sendable, Equatable, Identifiable {
    let id: String
    let comment: String
    let email: String?
    let device: String?
    let operatingSystem: String?
    let createdAt: Date?
    let screenshotURL: URL?

    static func decode(_ data: Data) throws -> [ASCTestFlightFeedback] {
        try ASCListingDecoder.decodeFeedback(data)
    }
}

nonisolated struct ASCReadinessFinding: Sendable, Equatable, Identifiable {
    let id: String
    let severity: Severity
    let message: String
    let remediation: String?
    let resourceURL: URL?

    enum Severity: String, Sendable, Equatable {
        case error, warning, info, unknown

        var title: String {
            switch self {
            case .error: "Action required"
            case .warning: "Warning"
            case .info: "Information"
            case .unknown: "Finding"
            }
        }

        var symbol: String {
            switch self {
            case .error: "xmark.octagon.fill"
            case .warning: "exclamationmark.triangle.fill"
            case .info: "info.circle.fill"
            case .unknown: "questionmark.circle.fill"
            }
        }
    }
}

nonisolated struct ASCReadinessReport: Sendable, Equatable {
    let version: String?
    let errors: Int
    let warnings: Int
    let infos: Int
    let findings: [ASCReadinessFinding]

    static func decode(_ data: Data) throws -> ASCReadinessReport {
        try ASCListingDecoder.decodeReadiness(data)
    }
}

nonisolated struct ASCAppInfoLocalization: Sendable, Equatable, Identifiable {
    let id: String
    let locale: String
    let name: String?
    let subtitle: String?

    static func decode(_ data: Data) throws -> [ASCAppInfoLocalization] {
        let value = try JSONSerialization.jsonObject(with: data)
        guard let root = value as? [String: Any] else { throw ASCIntegrationError.invalidResponse }
        guard let resources = root["data"] as? [[String: Any]] else { throw ASCIntegrationError.invalidResponse }
        return resources.compactMap { resource in
            let attrs = resource["attributes"] as? [String: Any] ?? [:]
            guard let id = resource["id"] as? String, let locale = attrs["locale"] as? String else { return nil }
            return ASCAppInfoLocalization(id: id, locale: locale, name: attrs["name"] as? String, subtitle: attrs["subtitle"] as? String)
        }
    }
}

enum AppStoreListingMode {
    case listing
    case feedback
}

nonisolated enum ASCListingDecoder {
    static func decodeReviews(_ data: Data) throws -> [ASCStoreReview] {
        let root = try jsonObject(data)
        return try resourceArray(root).compactMap { resource in
            let attributes = resource["attributes"] as? [String: Any] ?? resource
            guard let id = string(resource["id"] ?? attributes["id"]) else { return nil }
            let relationships = resource["relationships"] as? [String: Any] ?? [:]
            let responseData = ((relationships["response"] as? [String: Any])?["data"] as? [String: Any])
            let responseIncluded = ((root["included"] as? [[String: Any]]) ?? []).contains {
                ($0["type"] as? String) == "customerReviewResponses" && ($0["id"] as? String) == (responseData?["id"] as? String)
            }
            let hasResponse = attributes["response"] is [String: Any] || responseData != nil || responseIncluded
            return ASCStoreReview(
                id: id,
                rating: integer(attributes["rating"]),
                title: string(attributes["title"]),
                body: string(attributes["body"]),
                reviewer: string(attributes["reviewerNickname"] ?? attributes["reviewer"]),
                territory: string(attributes["territory"] ?? attributes["reviewTerritory"]),
                createdAt: date(attributes["createdDate"] ?? attributes["createdAt"]),
                hasResponse: hasResponse
            )
        }
    }

    static func decodeFeedback(_ data: Data) throws -> [ASCTestFlightFeedback] {
        let root = try jsonObject(data)
        return try resourceArray(root).compactMap { resource in
            let attributes = resource["attributes"] as? [String: Any] ?? resource
            guard let id = string(resource["id"] ?? attributes["id"]) else { return nil }
            let comment = string(attributes["comment"] ?? attributes["feedback"] ?? attributes["text"]) ?? ""
            let screenshots = (attributes["screenshots"] as? [[String: Any]]) ?? []
            let screenshot = screenshots.lazy.compactMap { string($0["url"]) }.first
                ?? string(attributes["screenshotUrl"] ?? attributes["screenshotURL"])
            return ASCTestFlightFeedback(
                id: id,
                comment: comment,
                email: string(attributes["email"]),
                device: string(attributes["deviceModel"] ?? attributes["device"]),
                operatingSystem: string(attributes["osVersion"] ?? attributes["operatingSystem"]),
                createdAt: date(attributes["createdDate"] ?? attributes["createdAt"]),
                screenshotURL: screenshot.flatMap(URL.init(string:))
            )
        }
    }

    static func decodeReadiness(_ data: Data) throws -> ASCReadinessReport {
        let root = try jsonObject(data)
        guard let summary = root["summary"] as? [String: Any],
              let checkObjects = (root["checks"] ?? root["findings"]) as? [[String: Any]] else {
            throw ASCIntegrationError.invalidResponse
        }
        let findings = checkObjects.compactMap { item -> ASCReadinessFinding? in
            guard let id = string(item["id"] ?? item["checkId"]),
                  let message = string(item["message"] ?? item["title"]) else { return nil }
            let severityRaw = string(item["severity"])?.lowercased() ?? "unknown"
            return ASCReadinessFinding(
                id: id,
                severity: ASCReadinessFinding.Severity(rawValue: severityRaw) ?? .unknown,
                message: message,
                remediation: string(item["remediation"]),
                resourceURL: string(item["url"] ?? item["link"]).flatMap(URL.init(string:))
            )
        }
        return ASCReadinessReport(
            version: string(root["versionString"] ?? root["version"]),
            errors: integer(summary["errors"]) ?? findings.filter { $0.severity == .error }.count,
            warnings: integer(summary["warnings"]) ?? findings.filter { $0.severity == .warning }.count,
            infos: integer(summary["infos"]) ?? findings.filter { $0.severity == .info }.count,
            findings: findings
        )
    }

    private static func jsonObject(_ data: Data) throws -> [String: Any] {
        let value = try JSONSerialization.jsonObject(with: data)
        guard let object = value as? [String: Any] else { throw ASCIntegrationError.invalidResponse }
        return object
    }

    private static func resourceArray(_ root: [String: Any]) throws -> [[String: Any]] {
        guard let data = root["data"] as? [[String: Any]] else { throw ASCIntegrationError.invalidResponse }
        return data
    }

    private static func string(_ value: Any?) -> String? {
        guard let value = value as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func date(_ value: Any?) -> Date? {
        guard let value = string(value) else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = fractional.date(from: value) { return parsed }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }
}

struct AppStoreListingView: View {
    let executablePath: String
    let appID: String
    let platform: String
    let versionID: String?
    let version: String?
    let primaryLocale: String?
    let refreshID: Int
    let localizations: [ASCVersionLocalization]?
    let mode: AppStoreListingMode

    @State private var reviews: [ASCStoreReview] = []
    @State private var feedback: [ASCTestFlightFeedback] = []
    @State private var readiness: ASCReadinessReport?
    @State private var appInfoLocalizations: [ASCAppInfoLocalization]?
    @State private var loading = false
    @State private var error: String?
    @State private var selectedLocalization = ""
    @State private var categories: ASCListingCategories?
    @State private var readinessVersionID: String?
    @AppStorage("ascSeenFeedback") private var seenFeedbackData = Data()
    @State private var expandedFeedback = Set<String>()

    private var taskKey: String {
        [executablePath, appID, mode == .listing ? versionID ?? "" : platform, String(refreshID)].joined(separator: "|")
    }

    private var seenFeedback: Set<String> {
        Set((try? JSONDecoder().decode([String].self, from: seenFeedbackData)) ?? [])
    }

    private func feedbackExpansion(_ id: String) -> Binding<Bool> {
        Binding(get: { expandedFeedback.contains(id) }, set: { expanded in
            if expanded {
                expandedFeedback.insert(id)
                var recent = (try? JSONDecoder().decode([String].self, from: seenFeedbackData)) ?? []
                recent.removeAll { $0 == id }
                recent.append(id)
                if let data = try? JSONEncoder().encode(Array(recent.suffix(500))) { seenFeedbackData = data }
            } else {
                expandedFeedback.remove(id)
            }
        })
    }

    private var primaryLocalization: ASCVersionLocalization? {
        guard let localizations, !localizations.isEmpty else { return nil }
        return localizations.first(where: { $0.locale == selectedLocalization })
            ?? localizations.first(where: { $0.locale == primaryLocale })
            ?? localizations.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if mode == .listing {
                listingSection
                readinessSection
            } else {
                feedbackSection
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
        }
        .task(id: taskKey) { await refresh() }
    }

    private var listingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("App Store Listing", systemImage: "text.book.closed")
                    .font(.headline)
                Spacer()
                if let localizations, let primaryLocalization {
                    Picker("Language", selection: Binding(get: { primaryLocalization.locale }, set: { selectedLocalization = $0 })) {
                        ForEach(localizations) { item in
                            Text(Locale.current.localizedString(forIdentifier: item.locale) ?? item.locale).tag(item.locale)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 180)
                }
            }
            if let listing = primaryLocalization {
                if let appInfo = selectedAppInfo {
                    if let name = appInfo.name { labeledValue("App Name", name) }
                    if let subtitle = appInfo.subtitle { labeledValue("Subtitle", subtitle) }
                }
                if let description = listing.description, !description.isEmpty {
                    DisclosureGroup("Description") {
                        Text(description).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                    }
                }
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
                    listingValue("Primary Category", categories?.primary)
                    listingValue("Secondary Category", categories?.secondary)
                    listingValue("Keywords", listing.keywords)
                    listingValue("Promotional Text", listing.promotionalText)
                    if let url = listing.supportUrl, url.scheme == "https" || url.scheme == "http" {
                        GridRow {
                            Text("Support").foregroundStyle(.secondary)
                            Link(url.absoluteString, destination: url)
                        }
                    }
                    if let url = listing.marketingUrl, url.scheme == "https" || url.scheme == "http" {
                        GridRow {
                            Text("Marketing").foregroundStyle(.secondary)
                            Link(url.absoluteString, destination: url)
                        }
                    }
                }
                .font(.callout)
                if let notes = listing.whatsNew, !notes.isEmpty {
                    DisclosureGroup("What’s New") { Text(notes).textSelection(.enabled).padding(.vertical, 4) }
                }
            } else if localizations == nil {
                Label(loading ? "Loading listing metadata…" : "Listing metadata unavailable", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            } else {
                ContentUnavailableView("No listing localizations", systemImage: "character.bubble")
            }
            if let localizations, !localizations.isEmpty {
                Text("\(localizations.count) localization\(localizations.count == 1 ? "" : "s") · version \(version ?? "—")")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }

    private var feedbackSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Customer Reviews and TestFlight Feedback", systemImage: "bubble.left.and.bubble.right")
                .font(.headline)
            if loading && reviews.isEmpty && feedback.isEmpty {
                ProgressView("Loading feedback…")
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    feedbackColumn(title: "App Store Reviews", empty: "No customer reviews are available.") {
                        ForEach(reviews) { review in reviewRow(review) }
                    }
                    feedbackColumn(title: "TestFlight", empty: "No TestFlight feedback is available.") {
                        ForEach(feedback) { item in testFlightRow(item) }
                    }
                }
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }

    private var readinessSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Submission Readiness", systemImage: "checkmark.seal")
                    .font(.headline)
                Spacer()
                if loading && readiness == nil { ProgressView().controlSize(.small) }
            }
            if let readiness, readinessVersionID == versionID {
                HStack(spacing: 12) {
                    readinessCount("Errors", readiness.errors, color: .red)
                    readinessCount("Warnings", readiness.warnings, color: .orange)
                    readinessCount("Info", readiness.infos, color: .secondary)
                    if let version = readiness.version { Text("Version \(version)").foregroundStyle(.secondary) }
                }
                if readiness.findings.isEmpty {
                    Label("No findings returned by asc.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    ForEach(readiness.findings) { finding in findingRow(finding) }
                }
            } else {
                Text("Readiness checks have not run yet.").foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }

    private func listingValue(_ label: String, _ value: String?) -> some View {
        Group {
            if let value, !value.isEmpty {
                GridRow(alignment: .top) {
                    Text(label).foregroundStyle(.secondary)
                    Text(value).textSelection(.enabled)
                }
            }
        }
    }

    private var selectedAppInfo: ASCAppInfoLocalization? {
        guard let appInfoLocalizations, !appInfoLocalizations.isEmpty else { return nil }
        return appInfoLocalizations.first { $0.locale == primaryLocalization?.locale }
    }

    private func labeledValue(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
        .font(.callout)
    }

    private func feedbackColumn<Content: View>(title: String, empty: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))
            content()
            if (title == "App Store Reviews" && reviews.isEmpty) || (title == "TestFlight" && feedback.isEmpty) {
                Text(empty).font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func reviewRow(_ review: ASCStoreReview) -> some View {
        let key = "\(appID):review:\(review.id)"
        return DisclosureGroup(isExpanded: feedbackExpansion(key)) {
            VStack(alignment: .leading, spacing: 6) {
                if let body = review.body { Text(body).textSelection(.enabled) }
                Button("Copy Review", systemImage: "doc.on.doc") {
                    copy([review.title, review.body].compactMap { $0 }.joined(separator: "\n\n"))
                }
            }
            .padding(.vertical, 6)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(review.title ?? "Untitled review").fontWeight(.medium)
                    if !seenFeedback.contains(key) { Text("Unread").font(.caption).foregroundStyle(.secondary) }
                    Spacer(minLength: 0)
                    if let rating = review.rating {
                        Label("\(rating) of 5", systemImage: "star.fill").foregroundStyle(.orange)
                    }
                }
                HStack(spacing: 8) {
                    if let territory = review.territory { Text(territory) }
                    if let date = review.createdAt { Text(date.formatted(date: .abbreviated, time: .omitted)) }
                    Text(review.responseLabel)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func testFlightRow(_ item: ASCTestFlightFeedback) -> some View {
        let key = "\(appID):testflight:\(item.id)"
        return DisclosureGroup(isExpanded: feedbackExpansion(key)) {
            VStack(alignment: .leading, spacing: 6) {
                if !item.comment.isEmpty {
                    Text(item.comment).textSelection(.enabled)
                    Button("Copy Feedback", systemImage: "doc.on.doc") { copy(item.comment) }
                }
                if let screenshotURL = item.screenshotURL, screenshotURL.scheme == "https" {
                    Link("Open Screenshot", destination: screenshotURL)
                }
            }
            .padding(.vertical, 6)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(item.comment.isEmpty ? "Feedback without text" : item.comment).lineLimit(1)
                    if !seenFeedback.contains(key) { Text("Unread").font(.caption).foregroundStyle(.secondary) }
                }
                HStack(spacing: 8) {
                    if let device = item.device { Text(device) }
                    if let os = item.operatingSystem { Text(os) }
                    if let date = item.createdAt { Text(date.formatted(date: .abbreviated, time: .omitted)) }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func findingRow(_ finding: ASCReadinessFinding) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: finding.severity.symbol)
                .foregroundStyle(finding.severity == .error ? .red : (finding.severity == .warning ? .orange : .secondary))
            VStack(alignment: .leading, spacing: 3) {
                Text(finding.message)
                if let remediation = finding.remediation { Text(remediation).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
            if let url = finding.resourceURL { Link("Open", destination: url).font(.caption) }
        }
        .font(.callout)
    }

    private func readinessCount(_ title: String, _ count: Int, color: Color) -> some View {
        Text("\(title): \(count)").font(.caption.weight(.medium)).foregroundStyle(color)
    }

    private func refresh() async {
        guard !appID.isEmpty else { return }
        loading = true
        error = nil
        defer { if !Task.isCancelled { loading = false } }
        switch mode {
        case .listing:
            async let appInfoData = ASCIntegration.run(executablePath: executablePath, arguments: [
                "localizations", "list", "--app", appID, "--type", "app-info", "--paginate", "--output", "json"
            ])
            async let categoryData = ASCIntegration.run(executablePath: executablePath, arguments: [
                "apps", "info", "view", "--app", appID, "--include", "primaryCategory,secondaryCategory", "--output", "json"
            ])
            if let versionID {
                do {
                    let data = try await ASCIntegration.run(executablePath: executablePath, arguments: [
                        "validate", "--app", appID, "--version-id", versionID, "--platform", platform, "--output", "json"
                    ])
                    guard !Task.isCancelled else { return }
                    readiness = try ASCReadinessReport.decode(data)
                    readinessVersionID = versionID
                } catch { reportFailure("Submission readiness", error) }
            }
            do {
                let data = try await appInfoData
                guard !Task.isCancelled else { return }
                appInfoLocalizations = try ASCAppInfoLocalization.decode(data)
            } catch { reportFailure("Listing name and subtitle", error) }
            if let data = try? await categoryData, !Task.isCancelled {
                categories = try? JSONDecoder().decode(ASCListingCategories.self, from: data)
            }
        case .feedback:
            async let reviewData = ASCIntegration.run(executablePath: executablePath, arguments: [
                "reviews", "list", "--app", appID, "--sort", "-createdDate", "--limit", "50", "--include-response", "--output", "json"
            ])
            async let feedbackData = ASCIntegration.run(executablePath: executablePath, arguments: [
                "testflight", "feedback", "list", "--app", appID, "--app-platform", platform, "--sort", "-createdDate",
                "--limit", "50", "--include-screenshots", "--output", "json"
            ])
            do {
                let data = try await reviewData
                guard !Task.isCancelled else { return }
                reviews = try ASCStoreReview.decode(data)
            } catch { reportFailure("Customer reviews", error) }
            do {
                let data = try await feedbackData
                guard !Task.isCancelled else { return }
                feedback = try ASCTestFlightFeedback.decode(data)
            } catch { reportFailure("TestFlight feedback", error) }
        }
    }

    private func reportFailure(_ section: String, _ failure: Error) {
        guard !Task.isCancelled else { return }
        error = [error, "\(section) · \(ASCIntegration.userMessage(for: failure))"].compactMap { $0 }.joined(separator: "\n")
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}


private nonisolated struct ASCListingCategories: Decodable, Sendable {
    struct Resource: Decodable, Sendable {
        struct Relationships: Decodable, Sendable {
            struct Category: Decodable, Sendable {
                struct Identifier: Decodable, Sendable { let id: String }
                let data: Identifier?
            }
            let primaryCategory: Category?
            let secondaryCategory: Category?
        }
        let relationships: Relationships?
    }

    let data: Resource
    var primary: String? { label(data.relationships?.primaryCategory?.data?.id) }
    var secondary: String? { label(data.relationships?.secondaryCategory?.data?.id) }

    private func label(_ id: String?) -> String? {
        id.map { ASCDisplay.state($0).replacingOccurrences(of: " And ", with: " & ") }
    }
}
