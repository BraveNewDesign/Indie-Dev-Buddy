import Foundation
import Testing
@testable import Indie_Dev_Buddy

struct AppStoreReleaseTests {
    @Test func releaseHistoryUsesCurrentStateAndSeparatesPlatforms() throws {
        let versions = try ASCVersion.decode(Data(Self.versionsFixture.utf8))
        #expect(versions.map(\.id) == ["ios-draft", "ios-live", "mac-live"])
        #expect(versions.filter(\.isLive).map(\.id) == ["ios-live", "mac-live"])
        #expect(ASCDisplay.state(versions.first?.state) == "Waiting for developer release")
        #expect(ASCDisplay.state("COMPLETE") == "Review complete")
        #expect(ASCDisplay.date("2026-11-07T10:51:52.316Z") != nil)
        #expect(versions[0].createdDate != nil)

        let submissions = try JSONDecoder().decode([ASCReviewHistoryEntry].self, from: Data(Self.historyFixture.utf8))
        #expect(submissions[0].matches(versions[0]))
        #expect(!submissions[0].matches(versions[1]))
        #expect(!submissions[0].matches(versions[2]))
        #expect(submissions[0].outcome == "approved")
    }

    @Test func malformedAndEmptyReleasePayloadsAreDistinct() throws {
        #expect(try ASCVersion.decode(Data(#"{"data":[]}"#.utf8)).isEmpty)
        #expect(throws: DecodingError.self) {
            try ASCVersion.decode(Data(#"{"data":[{"id":"invalid","attributes":{"platform":"IOS"}}]}"#.utf8))
        }
    }

    @Test func processFailuresGiveActionableMessagesWithoutStderr() {
        let cases = [
            ("response 403 FORBIDDEN secret", "permission"),
            ("response 401 Unauthorized secret", "authentication"),
            ("unknown flag --read-only secret", "update asc"),
            ("network timeout secret", "connection")
        ]
        for (detail, expected) in cases {
            let message = ASCIntegration.userMessage(for: ASCIntegrationError.processFailed(detail)).lowercased()
            #expect(message.contains(expected))
            #expect(!message.contains("secret"))
        }
    }

    @Test func validationFindingsSurviveTheCLIBlockingExit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("asc")
        let script = """
        #!/bin/sh
        test "$1" = "--read-only" || exit 2
        printf '%s' '{"summary":{"errors":1,"warnings":0,"infos":0},"checks":[{"id":"version.state.editable","severity":"error","message":"Version is live"}]}'
        printf '%s' 'Error: validate: found 1 blocking issue(s)' >&2
        exit 1
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let data = try await ASCIntegration.run(executablePath: executable.path, arguments: ["validate"])
        let report = try ASCReadinessReport.decode(data)
        #expect(report.errors == 1)
        #expect(report.findings.first?.severity == .error)
    }

    @MainActor @Test func releaseDraftUsesTheOrdinaryWorkspaceContentFlow() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceStore(rootURL: directory)
        try await store.createWorkspace(at: directory)
        let app = AppRecord(name: "Example", platforms: ["iOS"])
        let version = try #require(ASCVersion.decode(Data(Self.versionsFixture.utf8)).first)
        _ = try await store.save(app, relativePath: "Apps/\(app.id)/record.json")
        let draft = AppStoreConnectView.marketingDraft(app: app, version: version)
        _ = try await store.createContent(draft, body: "Improved accessibility.")
        let loaded = try #require(try await store.load().contentByID[draft.id])

        #expect(loaded.kind == .social)
        #expect(loaded.status == .draft)
        #expect(loaded.appIds == [app.id])
        #expect(loaded.releaseId == version.id)
        #expect(loaded.destinations.isEmpty)
        #expect(try await store.readRecord(.content, id: draft.id).body == "Improved accessibility.")
    }

    private static let versionsFixture = """
    {"data":[
      {"id":"mac-live","attributes":{"versionString":"1.0","platform":"MAC_OS","appStoreState":"READY_FOR_SALE","createdDate":"2026-10-06T14:25:10-08:00"}},
      {"id":"ios-draft","attributes":{"versionString":"1.1","platform":"IOS","appVersionState":"PENDING_DEVELOPER_RELEASE","appStoreState":"READY_FOR_SALE","createdDate":"2026-11-06T14:25:10-08:00"}},
      {"id":"ios-live","attributes":{"versionString":"1.0","platform":"IOS","appVersionState":"READY_FOR_DISTRIBUTION","createdDate":"2026-11-01T14:25:10-08:00"}}
    ]}
    """

    private static let historyFixture = """
    [{"submissionId":"submission-1","versionString":"1.1","platform":"IOS","state":"COMPLETE",
      "submittedDate":"2026-11-07T10:51:52.316Z","outcome":"approved",
      "items":[{"type":"appStoreVersion","resourceId":"ios-draft"}]}]
    """
}
