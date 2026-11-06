import Foundation
import Testing
@testable import Indie_Dev_Buddy

struct AppMetadataTests {
    @Test func legacyAppRecordsDecodeWithoutNewMetadata() throws {
        let data = Data(#"{"schemaVersion":1,"id":"legacy-app","name":"Legacy App","platforms":["macOS"],"websiteLinks":[]}"#.utf8)
        let record = try JSONDecoder().decode(AppRecord.self, from: data)

        #expect(record.id == "legacy-app")
        #expect(record.description == nil)
        #expect(record.bundleIDs == nil)
        #expect(record.developmentStatus == nil)
        #expect(record.testFlightURL == nil)
    }

    @Test func appMetadataRoundTripsAsOrdinaryRecordFields() throws {
        let record = AppRecord(
            id: "app-metadata",
            name: "Example App",
            description: "A short product summary.",
            bundleIDs: ["com.example.app", "com.example.app.beta"],
            developmentStatus: .beta,
            platforms: ["macOS", "iOS"],
            testFlightURL: URL(string: "https://testflight.apple.com/join/example")
        )
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(AppRecord.self, from: data)

        #expect(decoded == record)
    }

    @Test func appWebsiteLinksHaveStableUniqueIDsAndDecodeLegacyRecords() throws {
        let first = AppWebsiteLink(websiteId: "shared-site", purpose: "product", isPrimary: true)
        let second = AppWebsiteLink(websiteId: "shared-site", purpose: "product")
        #expect(first.id != second.id)

        let decoded = try JSONDecoder().decode(AppWebsiteLink.self, from: JSONEncoder().encode(first))
        #expect(decoded.id == first.id)
        #expect(decoded.websiteId == first.websiteId)

        let app = AppRecord(id: "linked-app", name: "Linked App", websiteLinks: [first, second])
        let decodedApp = try JSONDecoder().decode(AppRecord.self, from: JSONEncoder().encode(app))
        #expect(decodedApp.websiteLinks.map(\.id) == [first.id, second.id])

        let legacy = Data(#"{"websiteId":"shared-site","purpose":"support","url":null,"isPrimary":false}"#.utf8)
        let legacyLink = try JSONDecoder().decode(AppWebsiteLink.self, from: legacy)
        #expect(!legacyLink.id.isEmpty)
        #expect(legacyLink.purpose == "support")
    }

    @Test func legacyContentRecordsDecodeWithoutPlannedDate() throws {
        let data = Data(#"{"schemaVersion":1,"id":"legacy-content","kind":"social","title":"Legacy","appIds":[],"includeSourceLink":false,"status":"draft","destinations":[],"mediaPaths":[]}"#.utf8)
        let record = try JSONDecoder().decode(ContentRecord.self, from: data)

        #expect(record.plannedDate == nil)
        #expect(record.releaseId == nil)
    }

    @Test func plannedContentDateRoundTripsInIso8601Form() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let record = ContentRecord(id: "planned-content", kind: .blog, title: "Planned", plannedDate: date)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(ContentRecord.self, from: encoder.encode(record))
        #expect(decoded.plannedDate == date)
    }
}
