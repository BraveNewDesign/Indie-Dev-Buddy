import Foundation
import Testing
@testable import Indie_Dev_Buddy

struct AppStoreAnalyticsTests {
    @Test func parsesExplicitMetricsFromCSVAndTSVReports() throws {
        let day = try #require(ISO8601DateFormatter().date(from: "2026-11-10T00:00:00Z"))
        let reports = [
            ASCAnalyticsRawReport(name: "App Store Downloads Standard", contents: "Date,Download Type,App Version,Device,Counts\n2026-11-10,First-time Download,1.0,iPhone,8\n2026-11-10,First-time Download,1.0,iPad,4\n2026-11-10,Redownload,1.0,iPhone,3\n2026-11-10,Redownload,1.0,iPad,2\n2026-11-10,Update,1.0,iPhone,99\n", periodDescription: "Daily · Nov 10"),
            ASCAnalyticsRawReport(name: "Discovery & Engagement Standard", contents: "Date,Event,Page Type,Source Type,Counts\n2026-11-10,Impression,Product page,Search,800\n2026-11-10,Impression,Search results,Browse,200\n2026-11-10,Page view,Product page,App Store,120\n2026-11-10,Page view,Search results,Search,50\n", periodDescription: "Daily · Nov 10")
        ]

        let snapshot = ASCAnalyticsReportParser.parse(reports, fetchedAt: day)
        #expect(snapshot.points.count == 1)
        let point = try #require(snapshot.points.first)
        #expect(point.date == day)
        #expect(point.firstTimeDownloads == 12)
        #expect(point.redownloads == 5)
        #expect(point.totalDownloads == 17)
        #expect(point.productPageViews == 120)
        #expect(point.impressionEvents == 1_000)
        #expect(snapshot.availableMetrics.count == 5)
        #expect(snapshot.reportNames.count == 2)
    }

    @Test func parsesQuotedCSVFieldsAndSkipsMalformedRows() {
        let report = ASCAnalyticsRawReport(name: "App Store Downloads Standard", contents: "Date,Download Type,Notes,Counts\n2026-11-09,First-time Download,\"Holiday, sale\",8\nnot-a-date,First-time Download,ignored,100\n2026-11-10,First-time Download,missing-count,\n", periodDescription: nil)
        let snapshot = ASCAnalyticsReportParser.parse([report])

        #expect(snapshot.points.count == 1)
        #expect(snapshot.points.first?.firstTimeDownloads == 8)
    }

    @Test func doesNotInventMetricsFromUnrecognizedColumns() {
        let report = ASCAnalyticsRawReport(name: "Unknown", contents: "Date,Units,Views\n2026-11-10,99,500\n", periodDescription: nil)
        let snapshot = ASCAnalyticsReportParser.parse([report])

        #expect(snapshot.points.isEmpty)
        #expect(snapshot.availableMetrics.isEmpty)
    }

    @Test func normalizesMetricAliasesAndMultipleDates() {
        let report = ASCAnalyticsRawReport(name: "App Store Downloads Standard", contents: "day,download type,device,counts\n2026/11/09,First-time Download,iPhone,3\n2026/11/09,Redownload,iPhone,1\n2026/11/10,First-time Download,iPhone,6\n2026/11/10,Redownload,iPhone,1\n", periodDescription: nil)
        let snapshot = ASCAnalyticsReportParser.parse([report])

        #expect(snapshot.points.count == 2)
        #expect(snapshot.points[0].firstTimeDownloads == 3)
        #expect(snapshot.points[0].totalDownloads == 4)
        #expect(snapshot.points[1].totalDownloads == 7)
    }

    @Test func sumsDistinctDimensionalRowsAndDeduplicatesExactSegmentRows() {
        let first = ASCAnalyticsRawReport(name: "App Store Downloads Standard", contents: "Date,Download Type,Device,Counts\n2026-11-10,First-time Download,iPhone,20\n", periodDescription: nil)
        let second = ASCAnalyticsRawReport(name: "App Store Downloads Standard", contents: "Date,Download Type,Device,Counts\n2026-11-10,First-time Download,iPhone,20\n2026-11-10,First-time Download,iPad,7\n", periodDescription: nil)
        let snapshot = ASCAnalyticsReportParser.parse([first, second])

        #expect(snapshot.points.count == 1)
        #expect(snapshot.points.first?.firstTimeDownloads == 27)
    }
}
