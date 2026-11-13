import Foundation
import Testing
@testable import Indie_Dev_Buddy

struct WorkspaceContentCommandsTests {
    @Test func boardMovesPreservePublishingAndPlannedDates() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(rootURL: root)
        try await store.createWorkspace(at: root)

        let owner = IdentityRecord(name: "Test Brand")
        _ = try await store.save(owner, relativePath: "Identities/\(owner.id)/record.json")
        let accounts = ["one", "two", "three"].map {
            SocialAccountRecord(platform: "Bluesky", owner: .init(type: .identity, id: owner.id), handle: $0)
        }
        for account in accounts {
            _ = try await store.save(account, relativePath: "SocialAccounts/\(account.id)/record.json")
        }

        var draft = ContentRecord.draft(kind: .social, title: "Board Test", accountIDs: accounts.map(\.id))
        draft.plannedDate = Date(timeIntervalSince1970: 1_900_000_000)
        let created = try await store.createContent(draft, body: "Shared original")
        #expect(ContentStage(draft) == .drafts)
        try await store.moveContent(id: draft.id, to: .ideas)
        #expect(try await store.load().contentByID[draft.id].map(ContentStage.init) == .ideas)
        try await store.moveContent(id: draft.id, to: .toPost)
        let savedSnapshot = try await store.load()
        let saved = try #require(savedSnapshot.contentByID[draft.id])
        #expect(ContentStage(saved) == .toPost)
        #expect(saved.destinations == draft.destinations)
        #expect(saved.plannedDate == draft.plannedDate)

        await #expect(throws: WorkspaceCommandError.self) {
            try await store.moveContent(id: draft.id, to: .posted)
        }
        #expect(try await store.load().contentByID[draft.id] == saved)
        #expect(try await store.readRecord(.content, id: draft.id).body == "Shared original")

        var partiallyPublished = saved
        partiallyPublished.destinations[0].status = .published
        partiallyPublished.destinations[0].publishedDate = draft.plannedDate
        let current = try await store.read(relativePath: created.path)
        _ = try await store.save(partiallyPublished, relativePath: created.path, expectedRevision: current.revision)
        #expect(ContentStage(partiallyPublished) == .toPost)
        await #expect(throws: WorkspaceCommandError.self) {
            try await store.moveContent(id: partiallyPublished.id, to: .drafts)
        }
        #expect(try await store.load().contentByID[draft.id] == partiallyPublished)

        var completed = partiallyPublished
        for index in completed.destinations.indices { completed.destinations[index].status = .published }
        #expect(ContentStage(completed) == .posted)
    }

    @Test func bodyConflictsAndUpdatesKeepRecoverableOriginals() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(rootURL: root)
        try await store.createWorkspace(at: root)
        let draft = ContentRecord.draft(kind: .blog, title: "Before")
        let created = try await store.createContent(draft, body: "Original")
        let bodyRevision = try #require(created.bodyRevision)
        let bodyPath = "Content/\(draft.id)/body.md"
        let latestBodyRevision = try await store.write(Data("External".utf8), relativePath: bodyPath, expectedRevision: bodyRevision)

        do {
            _ = try await store.updateContent(id: draft.id, title: "After", body: "Revised",
                                              expectedRevision: created.revision, expectedBodyRevision: bodyRevision)
            Issue.record("A stale body revision should prevent the entire update.")
        } catch WorkspaceStoreError.conflict(let path, _) {
            #expect(path == bodyPath)
        }
        #expect(try await store.read(relativePath: created.path).data == created.data)

        let updated = try await store.updateContent(id: draft.id, title: "After", body: "Revised",
                                                     expectedRevision: created.revision, expectedBodyRevision: latestBodyRevision)
        let backup = try #require(updated.backupDirectory)
        #expect(try await store.read(relativePath: "\(backup)/\(created.path)").data == created.data)
        #expect(try await store.read(relativePath: "\(backup)/\(bodyPath)").data == Data("External".utf8))
        #expect(try await store.readRecord(.content, id: draft.id).body == "Revised")
        #expect(try await store.load().contentByID[draft.id]?.title == "After")
        #expect(try await store.validateWorkspace().isEmpty)
    }

    @Test func escapingBackupAncestorBlocksTheUpdate() async throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let root = fixture.appendingPathComponent("Workspace")
        let outside = fixture.appendingPathComponent("Outside")
        let store = WorkspaceStore(rootURL: root)
        try await store.createWorkspace(at: root)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(".indiedevbuddy"), withDestinationURL: outside)
        let draft = ContentRecord.draft(kind: .blog, title: "Before")
        let created = try await store.createContent(draft, body: "Original")

        do {
            _ = try await store.updateContent(id: draft.id, title: "After", body: "Revised",
                                              expectedRevision: created.revision, expectedBodyRevision: created.bodyRevision)
            Issue.record("An escaping backup path should prevent the update.")
        } catch WorkspaceStoreError.invalidRelativePath(let path) {
            #expect(path.hasPrefix(".indiedevbuddy/backups/"))
        }
        let current = try await store.readRecord(.content, id: draft.id)
        #expect(current.revision == created.revision)
        #expect(current.body == "Original")
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }
}
