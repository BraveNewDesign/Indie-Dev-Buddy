import Foundation
import Testing
@testable import Indie_Dev_Buddy

struct AppStoreListingDecodingTests {
    @Test func decodesAppStoreReviewAttributesAndResponseRelationship() throws {
        let data = Data(#"{"data":[{"id":"review-1","type":"customerReviews","attributes":{"rating":4,"title":"Useful","body":"A helpful app","reviewerNickname":"Sam","territory":"USA","createdDate":"2026-11-10T12:30:00Z"},"relationships":{"response":{"data":{"id":"response-1","type":"customerReviewResponses"}}}}]}"#.utf8)
        let reviews = try ASCStoreReview.decode(data)
        #expect(reviews.count == 1)
        #expect(reviews[0].rating == 4)
        #expect(reviews[0].title == "Useful")
        #expect(reviews[0].reviewer == "Sam")
        #expect(reviews[0].territory == "USA")
        #expect(reviews[0].createdAt != nil)
        #expect(reviews[0].hasResponse)
    }

    @Test func decodesTestFlightFeedbackAndOptionalScreenshot() throws {
        let data = Data(#"{"data":[{"id":"feedback-1","attributes":{"comment":"The settings screen froze","email":"tester@example.com","deviceModel":"iPhone 16","osVersion":"27.0","createdDate":"2026-11-11T09:00:00Z","screenshots":[{"url":"https://example.com/capture.png"}]}}]}"#.utf8)
        let feedback = try ASCTestFlightFeedback.decode(data)
        #expect(feedback.count == 1)
        #expect(feedback[0].comment == "The settings screen froze")
        #expect(feedback[0].device == "iPhone 16")
        #expect(feedback[0].operatingSystem == "27.0")
        #expect(feedback[0].screenshotURL?.host == "example.com")
    }

    @Test func decodesReadinessSummaryAndFindings() throws {
        let data = Data(#"{"versionString":"3.2","summary":{"errors":1,"warnings":1,"infos":0},"checks":[{"id":"metadata.description.missing","severity":"error","message":"Description is missing","remediation":"Add a localized description"},{"id":"keywords.duplicate","severity":"warning","message":"Keywords contain a duplicate"}]}"#.utf8)
        let report = try ASCReadinessReport.decode(data)
        #expect(report.version == "3.2")
        #expect(report.errors == 1)
        #expect(report.warnings == 1)
        #expect(report.findings.count == 2)
        #expect(report.findings[0].severity == .error)
        #expect(report.findings[0].remediation == "Add a localized description")
    }

    @Test func malformedJSONIsRejectedAndEmptyDataIsSupported() throws {
        #expect(throws: (any Error).self) { try ASCStoreReview.decode(Data("not-json".utf8)) }
        #expect(try ASCStoreReview.decode(Data(#"{"data":[]}"#.utf8)).isEmpty)
    }
}
