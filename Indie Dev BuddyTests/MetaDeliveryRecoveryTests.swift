import Foundation
import SocialKit
import Testing
@testable import Indie_Dev_Buddy

struct MetaDeliveryRecoveryTests {
    @Test func stagedContainerSurvivesRelaunchAndKeepsOriginalAttempt() async throws {
        let (file, intent) = fixture()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let attempt = try await saveInterruptedDelivery(file, intent: intent, publishStarted: false)

        let journal = try LocalDeliveryJournal(fileURL: file)
        let recovered = try #require(await journal.entries().first)
        #expect(recovered.state == .queued)
        #expect(recovered.canResumeContainer)
        let now = Date().addingTimeInterval(30)
        _ = try await journal.markOverdue(before: now, now: now)
        let resumed = try #require(await journal.claimNextDue(sessionStartedAt: now, now: now))
        #expect(resumed.intent == recovered.intent)
        #expect(resumed.attempts.map(\.id) == [attempt])

        let paused = try await journal.pausePolling(intent.id, at: now)
        #expect(paused.state == .queued)
        #expect(try await journal.claimNextDue(sessionStartedAt: now, now: now) == nil)
        try await journal.cancel([intent.id])
        let canceled = try #require(await journal.entries().first)
        #expect(canceled.state == .canceled)
        #expect(canceled.attempts.last?.state == .canceled)
        #expect(canceled.checkpoint == nil)
    }

    @Test func interruptedPublishIsNeverReclaimedAndCanBeReconciled() async throws {
        let (file, intent) = fixture()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let attempt = try await saveInterruptedDelivery(file, intent: intent, publishStarted: true)

        let journal = try LocalDeliveryJournal(fileURL: file)
        let recovered = try #require(await journal.entries().first)
        #expect(recovered.state == .outcomeUnknown)
        #expect(recovered.checkpoint?.publishStarted == true)
        let now = Date()
        #expect(try await journal.claimNextDue(sessionStartedAt: .distantPast, now: now) == nil)
        var retry = intent
        retry.id = UUID()
        let retryIntent = retry
        await #expect(throws: LocalDeliveryJournal.JournalError.duplicateIntent) {
            try await journal.beginImmediate(retryIntent)
        }
        try await journal.confirmPublishedContainer(intent.id)
        let confirmed = try #require(await journal.entries().first)
        #expect(confirmed.state == .delivered)
        #expect(confirmed.attempts.map(\.id) == [attempt])
        #expect(confirmed.attempts.last?.providerPostID == nil)
        #expect(confirmed.checkpoint == nil)
    }

    private func saveInterruptedDelivery(_ file: URL, intent: ContentDeliveryIntent, publishStarted: Bool) async throws -> UUID {
        let journal = try LocalDeliveryJournal(fileURL: file)
        let entry = try await journal.beginImmediate(intent)
        try await journal.saveCheckpoint(checkpoint(publishStarted: false), for: intent.id)
        if publishStarted { try await journal.saveCheckpoint(checkpoint(publishStarted: true), for: intent.id) }
        return try #require(entry.attempts.last?.id)
    }

    private func checkpoint(publishStarted: Bool) throws -> MetaPublishingCheckpoint {
        let fixture = #"{"containerID":"container","publishStarted":"# + String(publishStarted) + "}"
        return try JSONDecoder().decode(MetaPublishingCheckpoint.self, from: Data(fixture.utf8))
    }

    private func fixture() -> (URL, ContentDeliveryIntent) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let now = Date()
        let intent = ContentDeliveryIntent(
            workspaceID: "workspace", workspaceRootPath: directory.path, contentID: "content", destinationID: "threads",
            recipient: ContentRecipientIdentity(platform: "threads", server: URL(string: "https://graph.threads.net")!, remoteID: "account"),
            scheduledDate: now, draftID: UUID(), draftCreatedAt: now, text: "Fixture"
        )
        return (directory.appendingPathComponent("journal.json"), intent)
    }
}
