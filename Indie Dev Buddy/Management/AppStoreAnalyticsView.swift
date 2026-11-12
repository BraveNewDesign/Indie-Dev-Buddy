import Charts
import CryptoKit
import Foundation
import SwiftUI

nonisolated enum ASCAnalyticsMetric: String, Codable, CaseIterable, Identifiable, Sendable {
    case firstTimeDownloads
    case redownloads
    case totalDownloads
    case productPageViews
    case impressionEvents

    var id: String { rawValue }
    var title: String {
        switch self {
        case .firstTimeDownloads: "First-Time Downloads"
        case .redownloads: "Redownloads"
        case .totalDownloads: "Total Downloads"
        case .productPageViews: "Product Page Views"
        case .impressionEvents: "Impression Events"
        }
    }
    var symbol: String {
        switch self {
        case .firstTimeDownloads, .redownloads, .totalDownloads: "arrow.down.app"
        case .productPageViews: "eye"
        case .impressionEvents: "sparkle.magnifyingglass"
        }
    }
}

nonisolated struct ASCAnalyticsPoint: Codable, Equatable, Identifiable, Sendable {
    var id: Date { date }
    let date: Date
    var firstTimeDownloads: Double?
    var redownloads: Double?
    var totalDownloads: Double?
    var productPageViews: Double?
    var impressionEvents: Double?

    func value(for metric: ASCAnalyticsMetric) -> Double? {
        switch metric {
        case .firstTimeDownloads: firstTimeDownloads
        case .redownloads: redownloads
        case .totalDownloads: totalDownloads
        case .productPageViews: productPageViews
        case .impressionEvents: impressionEvents
        }
    }

    mutating func setValue(_ value: Double?, for metric: ASCAnalyticsMetric) {
        switch metric {
        case .firstTimeDownloads: firstTimeDownloads = value
        case .redownloads: redownloads = value
        case .totalDownloads: totalDownloads = value
        case .productPageViews: productPageViews = value
        case .impressionEvents: impressionEvents = value
        }
    }
}

nonisolated struct ASCAnalyticsSnapshot: Codable, Equatable, Sendable {
    let points: [ASCAnalyticsPoint]
    let fetchedAt: Date
    let reportNames: [String]
    let periodDescription: String?

    var availableMetrics: [ASCAnalyticsMetric] {
        ASCAnalyticsMetric.allCases.filter { metric in points.contains { $0.value(for: metric) != nil } }
    }

    func latestValue(for metric: ASCAnalyticsMetric) -> Double? {
        points.reversed().compactMap { $0.value(for: metric) }.first
    }
}

nonisolated struct ASCAnalyticsRawReport: Sendable {
    let name: String
    let contents: String
    let periodDescription: String?
}

private nonisolated struct ASCAnalyticsReportPage: Decodable {
    let data: [Report]

    struct Report: Decodable {
        let id: String
        let name: String
        let granularity: String?
        let instances: [Instance]?
    }

    struct Instance: Decodable {
        let id: String
        let reportDate: String?
        let processingDate: String?
        let granularity: String?
        let version: String?
        let segments: [Segment]?
    }

    struct Segment: Decodable {
        let id: String
    }
}

nonisolated enum ASCAnalyticsReportParser {
    static func supportsReportName(_ name: String) -> Bool {
        let normalized = normalizeHeader(name).replacingOccurrences(of: "&", with: "and")
        return normalized.contains("app store downloads") ||
            (normalized.contains("discovery") && normalized.contains("engagement"))
    }

    static func parse(_ reports: [ASCAnalyticsRawReport], fetchedAt: Date = .now) -> ASCAnalyticsSnapshot {
        var valuesByDate: [Date: [ASCAnalyticsMetric: Double]] = [:]
        var seenRows: Set<String> = []
        var recognizedReports: [String] = []
        var periods: [String] = []

        for report in reports {
            let rows = delimitedRows(report.contents)
            guard let header = rows.first else { continue }
            let normalizedHeader = header.map(normalizeHeader)
            guard let dateIndex = normalizedHeader.firstIndex(where: { ["date", "day", "report date", "date key"].contains($0) }) else { continue }
            guard let countIndex = normalizedHeader.firstIndex(of: "counts") else { continue }
            let downloadTypeIndex = normalizedHeader.firstIndex(of: "download type")
            let eventIndex = normalizedHeader.firstIndex(of: "event")
            let pageTypeIndex = normalizedHeader.firstIndex(of: "page type")
            let normalizedReportName = normalizeHeader(report.name).replacingOccurrences(of: "&", with: "and")
            let isDownloadsReport = normalizedReportName.contains("app store downloads") && downloadTypeIndex != nil
            let isDiscoveryReport = normalizedReportName.contains("discovery") && normalizedReportName.contains("engagement") && eventIndex != nil
            guard isDownloadsReport || isDiscoveryReport else { continue }
            recognizedReports.append(report.name)
            if let period = report.periodDescription, !periods.contains(period) { periods.append(period) }

            for row in rows.dropFirst() {
                guard row.indices.contains(dateIndex), row.indices.contains(countIndex),
                      let date = parseDate(row[dateIndex]), let count = parseNumber(row[countIndex]) else { continue }
                let metric: ASCAnalyticsMetric?
                if isDownloadsReport, let downloadTypeIndex, row.indices.contains(downloadTypeIndex) {
                    switch normalizeHeader(row[downloadTypeIndex]) {
                    case "first-time download", "first time download": metric = .firstTimeDownloads
                    case "redownload", "re-download": metric = .redownloads
                    default: metric = nil // Updates and unknown future types are not downloads.
                    }
                } else if isDiscoveryReport, let eventIndex, row.indices.contains(eventIndex) {
                    switch normalizeHeader(row[eventIndex]) {
                    case "impression": metric = .impressionEvents
                    case "page view":
                        if let pageTypeIndex, row.indices.contains(pageTypeIndex), normalizeHeader(row[pageTypeIndex]) == "product page" {
                            metric = .productPageViews
                        } else { metric = nil }
                    default: metric = nil
                    }
                } else { metric = nil }
                guard let metric else { continue }

                // These reports contain dimension rows. Sum distinct rows, while de-duplicating exact repeats
                // that can appear when Apple splits the same report across downloadable segments.
                let rowKey = "\(normalizedHeader.joined(separator: "\u{1f}"))|\(row.map(normalizeHeader).joined(separator: "\u{1f}"))"
                guard seenRows.insert(rowKey).inserted else { continue }
                valuesByDate[date, default: [:]][metric, default: 0] += count
            }
        }
        let points = valuesByDate.map { date, values -> ASCAnalyticsPoint in
            let firstTime = values[.firstTimeDownloads]
            let redownloads = values[.redownloads]
            return ASCAnalyticsPoint(
                date: date,
                firstTimeDownloads: firstTime,
                redownloads: redownloads,
                totalDownloads: firstTime.flatMap { first in redownloads.map { first + $0 } },
                productPageViews: values[.productPageViews],
                impressionEvents: values[.impressionEvents]
            )
        }.sorted { $0.date < $1.date }
        let period: String?
        if let first = points.first?.date, let last = points.last?.date {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "MMM d, yyyy"
            period = first == last ? formatter.string(from: first) : "\(formatter.string(from: first)) – \(formatter.string(from: last))"
        } else {
            period = periods.first
        }
        return ASCAnalyticsSnapshot(
            points: points,
            fetchedAt: fetchedAt,
            reportNames: Array(Set(recognizedReports)).sorted(),
            periodDescription: period
        )
    }

    private static func normalizeHeader(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .lowercased()
            .replacingOccurrences(of: "–", with: "-")
    }

    private static func parseNumber(_ text: String) -> Double? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "%", with: "")
        guard !value.isEmpty, value != "—", value != "-" else { return nil }
        return Double(value)
    }

    private static func parseDate(_ text: String) -> Date? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
            let parts = value.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { return nil }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            var components = DateComponents()
            components.year = parts[0]
            components.month = parts[1]
            components.day = parts[2]
            guard let date = calendar.date(from: components), calendar.component(.day, from: date) == parts[2] else { return nil }
            return date
        }
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: value) { return date }
        for format in ["yyyy/MM/dd", "MM/dd/yyyy", "yyyy-MM"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.isLenient = false
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return Calendar(identifier: .gregorian).startOfDay(for: date) }
        }
        return nil
    }

    private static func delimitedRows(_ text: String) -> [[String]] {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let delimiter: Character = firstLine.filter { $0 == "\t" }.count > firstLine.filter { $0 == "," }.count ? "\t" : ","
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\"" {
                if quoted, index + 1 < characters.count, characters[index + 1] == "\"" {
                    field.append("\"")
                    index += 1
                } else {
                    quoted.toggle()
                }
            } else if character == delimiter, !quoted {
                row.append(field); field = ""
            } else if (character == "\n" || character == "\r"), !quoted {
                row.append(field); field = ""
                if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
                row = []
                if character == "\r", index + 1 < characters.count, characters[index + 1] == "\n" { index += 1 }
            } else {
                field.append(character)
            }
            index += 1
        }
        row.append(field)
        if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
        return rows
    }
}

nonisolated enum ASCAnalyticsError: LocalizedError {
    case noExistingRequest
    case noCompatibleReports
    case malformedResponse
    case command(String)

    var errorDescription: String? {
        switch self {
        case .noExistingRequest: "No analytics report request exists for this app. App Store Connect report requests must be enabled in App Store Connect before Indie Dev Buddy can read them."
        case .noCompatibleReports: "No downloadable report with supported date and metric columns was found."
        case .malformedResponse: "The asc command returned analytics data in an unsupported format."
        case .command(let message): message
        }
    }
}

actor ASCAnalyticsRepository {
    private let executablePath: String
    private let appID: String
    private let cacheURL: URL
    private let cacheLifetime: TimeInterval
    private var cached: ASCAnalyticsSnapshot?
    private var lastLoadIssue: String?

    init(executablePath: String, appID: String, cacheLifetime: TimeInterval = 86_400) {
        self.executablePath = executablePath
        self.appID = appID
        self.cacheLifetime = cacheLifetime
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let cacheKey = SHA256.hash(data: Data(appID.utf8)).map { String(format: "%02x", $0) }.joined()
        cacheURL = root.appendingPathComponent("IndieDevBuddy/ASCAnalytics-\(cacheKey).json")
    }

    func load(forceRefresh: Bool = false) async throws -> ASCAnalyticsSnapshot {
        if cached == nil { cached = readCache() }
        if !forceRefresh, let cached, Date.now.timeIntervalSince(cached.fetchedAt) < cacheLifetime { return cached }
        lastLoadIssue = nil
        do {
            let snapshot = try await fetchSnapshot()
            guard !snapshot.points.isEmpty else { throw ASCAnalyticsError.noCompatibleReports }
            cached = snapshot
            writeCache(snapshot)
            return snapshot
        } catch {
            if let cached {
                lastLoadIssue = "Refresh failed. Showing saved data: \(error.localizedDescription)"
                return cached
            }
            throw error
        }
    }

    func refreshIssue() -> String? { lastLoadIssue }

    private func fetchSnapshot() async throws -> ASCAnalyticsSnapshot {
        let requestData = try await run(["analytics", "requests", "--app", appID, "--paginate", "--output", "json"])
        let requests = try ASCAnalyticsJSON.objects(from: requestData).filter { ASCAnalyticsJSON.type(of: $0).localizedCaseInsensitiveContains("request") }
        guard !requests.isEmpty else { throw ASCAnalyticsError.noExistingRequest }

        guard let request = requests.first(where: { ASCAnalyticsJSON.accessType(of: $0) == "ONGOING" }) ?? requests.first,
              let requestID = ASCAnalyticsJSON.id(of: request) else { throw ASCAnalyticsError.noExistingRequest }
        var reports: [ASCAnalyticsRawReport] = []
        var instances: [String: (name: String, reportDate: String?, processingDate: String?, version: String?, id: String, segments: [String])] = [:]
        for granularity in ["DAILY", "WEEKLY", "MONTHLY"] {
            let viewData = try await run(["analytics", "view", "--request-id", requestID, "--granularity", granularity, "--paginate", "--output", "json"])
            let page = try JSONDecoder().decode(ASCAnalyticsReportPage.self, from: viewData)
            for report in page.data where ASCAnalyticsReportParser.supportsReportName(report.name) {
                for instance in report.instances ?? [] {
                    let dateKey = instance.reportDate ?? instance.processingDate ?? instance.id
                    let key = "\(report.id)|\(dateKey)|\(instance.granularity ?? report.granularity ?? granularity)"
                    let candidate = (report.name, instance.reportDate, instance.processingDate, instance.version, instance.id, (instance.segments ?? []).map(\.id))
                    if let existing = instances[key] {
                        let candidateOrder = (candidate.2 ?? "", candidate.3 ?? "")
                        let existingOrder = (existing.processingDate ?? "", existing.version ?? "")
                        if candidateOrder.0 > existingOrder.0 || (candidateOrder.0 == existingOrder.0 && candidateOrder.1 > existingOrder.1) {
                            instances[key] = candidate
                        }
                    } else {
                        instances[key] = candidate
                    }
                }
            }
            if !instances.isEmpty { break }
        }
        var remainingDownloads = 60
        var omittedInstances = 0
        let byReport = Dictionary(grouping: Array(instances.values), by: { $0.name })
        let sortedInstances = byReport.keys.sorted().flatMap { name in
            Array((byReport[name] ?? []).sorted { ($0.processingDate ?? $0.reportDate ?? "") > ($1.processingDate ?? $1.reportDate ?? "") }.prefix(30))
        }
        for instance in sortedInstances.prefix(60) {
            let instanceDate = instance.reportDate ?? instance.processingDate
            var segmentIDs = instance.segments
            if segmentIDs.isEmpty {
                do {
                    let segmentData = try await run(["analytics", "instances", "links", "--instance-id", instance.id, "--paginate", "--output", "json"])
                    let segmentObjects = try ASCAnalyticsJSON.objects(from: segmentData).filter { ASCAnalyticsJSON.type(of: $0).localizedCaseInsensitiveContains("segment") }
                    segmentIDs = segmentObjects.compactMap(ASCAnalyticsJSON.id(of:))
                } catch {
                    omittedInstances += 1
                    continue
                }
            }
            if segmentIDs.isEmpty {
                guard remainingDownloads > 0 else { break }
                remainingDownloads -= 1
                do {
                    reports.append(try await download(requestID: requestID, instanceID: instance.id, reportName: instance.name, segmentID: nil, period: instanceDate))
                } catch { omittedInstances += 1 }
            } else {
                // Never use a partial segment set: segment files can represent distinct dimensions.
                guard segmentIDs.count <= remainingDownloads else { omittedInstances += 1; continue }
                remainingDownloads -= segmentIDs.count
                var instanceReports: [ASCAnalyticsRawReport] = []
                var instanceFailed = false
                for segmentID in segmentIDs {
                    do {
                        instanceReports.append(try await download(requestID: requestID, instanceID: instance.id, reportName: instance.name, segmentID: segmentID, period: instanceDate))
                    } catch {
                        instanceFailed = true
                        break
                    }
                }
                if instanceFailed { omittedInstances += 1 } else { reports.append(contentsOf: instanceReports) }
            }
            if remainingDownloads == 0 { break }
        }
        if omittedInstances > 0 {
            lastLoadIssue = "Skipped \(omittedInstances) incomplete report instance(s); displayed data includes only complete downloads."
        }
        let snapshot = ASCAnalyticsReportParser.parse(reports)
        guard !snapshot.points.isEmpty else {
            if reports.isEmpty { throw ASCAnalyticsError.noCompatibleReports }
            return snapshot
        }
        let cutoff = Calendar(identifier: .gregorian).date(byAdding: .day, value: -90, to: .now) ?? .distantPast
        return ASCAnalyticsSnapshot(
            points: snapshot.points.filter { $0.date >= cutoff },
            fetchedAt: snapshot.fetchedAt,
            reportNames: snapshot.reportNames,
            periodDescription: snapshot.periodDescription ?? "Most recent 90 days"
        )
    }

    private func download(requestID: String, instanceID: String, reportName: String, segmentID: String?, period: String?) async throws -> ASCAnalyticsRawReport {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ASCAnalytics-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("report.csv")
        var arguments = ["analytics", "download", "--request-id", requestID, "--instance-id", instanceID, "--decompress", "--output", output.path]
        if let segmentID { arguments += ["--segment-id", segmentID] }
        let metadata = try await run(arguments)
        let metadataObject = (try? JSONSerialization.jsonObject(with: metadata)) as? [String: Any] ?? [:]
        let savedPath = metadataObject["decompressedPath"] as? String
        let candidates = [savedPath, output.path, output.path + ".csv"].compactMap { $0 }
            .map { URL(fileURLWithPath: $0).standardizedFileURL }
        let savedURL = candidates.first(where: {
            $0.path.hasPrefix(directory.standardizedFileURL.path + "/") &&
            $0.pathExtension.lowercased() == "csv" && FileManager.default.fileExists(atPath: $0.path)
        })
        guard let savedURL, let contents = try? String(contentsOf: savedURL, encoding: .utf8) else {
            throw ASCAnalyticsError.malformedResponse
        }
        return ASCAnalyticsRawReport(name: reportName, contents: contents, periodDescription: period)
    }

    private func run(_ arguments: [String]) async throws -> Data {
        do { return try await ASCIntegration.run(executablePath: executablePath, arguments: arguments) }
        catch { throw ASCAnalyticsError.command(ASCIntegration.userMessage(for: error)) }
    }

    private func readCache() -> ASCAnalyticsSnapshot? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ASCAnalyticsSnapshot.self, from: data)
    }

    private func writeCache(_ snapshot: ASCAnalyticsSnapshot) {
        do {
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(snapshot).write(to: cacheURL, options: .atomic)
        } catch { /* Caching is optional; preserve the successful fetch. */ }
    }
}

private nonisolated enum ASCAnalyticsJSON {
    static func objects(from data: Data) throws -> [[String: Any]] {
        let root = try JSONSerialization.jsonObject(with: data)
        var result: [[String: Any]] = []
        func visit(_ value: Any, relation: String? = nil) {
            if let object = value as? [String: Any] {
                if object["id"] is String,
                   object["type"] is String || relation == "instance" || relation == "segment" {
                    var candidate = object
                    if candidate["type"] == nil {
                        candidate["type"] = relation == "instance" ? "analyticsReportInstances" : "analyticsReportSegments"
                    }
                    result.append(candidate)
                }
                for (key, child) in object {
                    let context: String?
                    if key.localizedCaseInsensitiveContains("instance") { context = "instance" }
                    else if key.localizedCaseInsensitiveContains("segment") { context = "segment" }
                    else { context = relation }
                    visit(child, relation: context)
                }
            } else if let values = value as? [Any] { values.forEach { visit($0, relation: relation) } }
        }
        visit(root)
        return result
    }

    static func type(of object: [String: Any]) -> String { object["type"] as? String ?? "" }
    static func id(of object: [String: Any]) -> String? { object["id"] as? String }
    static func accessType(of object: [String: Any]) -> String {
        let attributes = object["attributes"] as? [String: Any] ?? [:]
        return (attributes["accessType"] as? String)?.uppercased() ?? ""
    }
    static func date(of object: [String: Any]) -> String { dateLabel(of: object) ?? "" }
    static func dateLabel(of object: [String: Any]) -> String? {
        let attributes = object["attributes"] as? [String: Any] ?? [:]
        return (attributes["processingDate"] as? String) ?? (attributes["startDate"] as? String) ?? (attributes["date"] as? String)
    }
    static func label(from data: Data) -> String? {
        guard let objects = try? objects(from: data) else { return nil }
        for object in objects {
            let attributes = object["attributes"] as? [String: Any] ?? [:]
            for key in ["name", "reportName", "title"] {
                if let value = attributes[key] as? String { return value }
            }
        }
        return nil
    }
}

struct AppStoreAnalyticsView: View {
    let repository: ASCAnalyticsRepository
    let refreshID: Int
    @State private var snapshot: ASCAnalyticsSnapshot?
    @State private var selectedMetric: ASCAnalyticsMetric = .firstTimeDownloads
    @State private var isLoading = false
    @State private var errorMessage: String?

    init(executablePath: String, appID: String, refreshID: Int = 0) {
        repository = ASCAnalyticsRepository(executablePath: executablePath, appID: appID)
        self.refreshID = refreshID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Analytics", systemImage: "chart.xyaxis.line")
                    .font(.headline)
                Spacer()
                Button { Task { await refresh() } } label: {
                    if isLoading { ProgressView().controlSize(.small) }
                    else { Label("Refresh", systemImage: "arrow.clockwise") }
                }
                .controlSize(.small)
                .disabled(isLoading)
            }
            if let snapshot, !snapshot.availableMetrics.isEmpty {
                Picker("Metric", selection: $selectedMetric) {
                    ForEach(snapshot.availableMetrics) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                let chartPoints = snapshot.points.filter { $0.value(for: selectedMetric) != nil }
                Chart(chartPoints) { point in
                    if let value = point.value(for: selectedMetric) {
                        if chartPoints.count == 1 {
                            PointMark(x: .value("Date", point.date), y: .value(selectedMetric.title, value))
                                .foregroundStyle(.tint)
                        } else {
                            AreaMark(x: .value("Date", point.date), y: .value(selectedMetric.title, value))
                                .foregroundStyle(.tint.opacity(0.12))
                            LineMark(x: .value("Date", point.date), y: .value(selectedMetric.title, value))
                                .foregroundStyle(.tint)
                                .interpolationMethod(.linear)
                        }
                    }
                }
                .chartYAxis { AxisMarks(position: .leading) }
                .frame(height: 190)
                HStack {
                    Text("\(selectedMetric.title): \(formatted(snapshot.latestValue(for: selectedMetric), metric: selectedMetric))")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if let period = snapshot.periodDescription { Text(period) }
                    Text("Updated \(snapshot.fetchedAt.formatted(date: .abbreviated, time: .shortened))")
                }
                .font(.caption).foregroundStyle(.secondary)
                Text("Downloads combine first-time downloads and redownloads; updates are excluded. Impression Events count Discovery & Engagement impression events, which are narrower than the App Store Connect dashboard’s broader impressions measure. Downloads are not confirmed installations.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else if isLoading {
                ProgressView("Loading App Store reports…")
                    .frame(maxWidth: .infinity, minHeight: 100)
            } else if let errorMessage {
                ContentUnavailableView("Analytics Unavailable", systemImage: "chart.xyaxis.line", description: Text(errorMessage))
                    .frame(minHeight: 110)
            } else {
                ContentUnavailableView("No Analytics Reports", systemImage: "chart.xyaxis.line", description: Text("Refresh to check existing App Store Connect reports. Indie Dev Buddy reads reports already configured in App Store Connect."))
                    .frame(minHeight: 110)
            }
            if let errorMessage, snapshot != nil {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        .task(id: refreshID) { await refresh(forceRefresh: refreshID > 0) }
    }

    private func refresh(forceRefresh: Bool = true) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await repository.load(forceRefresh: forceRefresh)
            snapshot = result
            errorMessage = await repository.refreshIssue()
            if !result.availableMetrics.contains(selectedMetric), let first = result.availableMetrics.first { selectedMetric = first }
        } catch { errorMessage = error.localizedDescription }
    }

    private func formatted(_ value: Double?, metric: ASCAnalyticsMetric) -> String {
        guard let value else { return "—" }
        return value.formatted(.number.precision(.fractionLength(0)))
    }
}
