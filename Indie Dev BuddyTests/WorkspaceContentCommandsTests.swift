import Foundation
import Testing
@testable import Indie_Dev_Buddy

struct WorkspaceContentCommandsTests {
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
