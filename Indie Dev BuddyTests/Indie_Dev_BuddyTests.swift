//
//  Indie_Dev_BuddyTests.swift
//  Indie Dev BuddyTests
//
//  Created by Shawn Crawford on 11/5/26.
//

import Testing
import Foundation
@testable import Indie_Dev_Buddy

private final class TestChangeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var didChange = false

    func signal() {
        lock.lock()
        didChange = true
        lock.unlock()
    }

    func value() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return didChange
    }
}

struct Indie_Dev_BuddyTests {

    @Test func workspaceCreationDoesNotOverwriteExistingWorkspace() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let store = WorkspaceStore(rootURL: parent)
        _ = try await store.createWorkspace(at: parent)
        let original = try Data(contentsOf: parent.appendingPathComponent("workspace.json"))
        do {
            _ = try await store.createWorkspace(at: parent, name: "Replacement")
            Issue.record("Expected existing workspace creation to fail")
        } catch WorkspaceStoreError.workspaceAlreadyExists { }
        #expect(try Data(contentsOf: parent.appendingPathComponent("workspace.json")) == original)
    }

    @Test func optimisticRevisionRejectsExternalEdit() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let store = WorkspaceStore(rootURL: parent)
        _ = try await store.createWorkspace(at: parent)
        let path = "Content/example/record.json"
        let initial = Data("{\"schemaVersion\":1}".utf8)
        let revision = try await store.write(initial, relativePath: path)
        try Data("{\"schemaVersion\":1,\"external\":true}".utf8).write(to: parent.appendingPathComponent(path), options: .atomic)
        do {
            _ = try await store.write(Data("{}".utf8), relativePath: path, expectedRevision: revision)
            Issue.record("Expected external edit to cause a conflict")
        } catch WorkspaceStoreError.conflict { }
    }

    @Test func batchWritePreflightPreventsEarlierFilesChangingOnLaterConflict() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = WorkspaceStore(rootURL: root)
        _ = try await store.createWorkspace(at: root)
        let firstPath = "Content/item/original.txt"
        let secondPath = "Content/item/record.json"
        let firstRevision = try await store.write(Data("draft".utf8), relativePath: firstPath)
        _ = try await store.write(Data("before".utf8), relativePath: secondPath)
        try Data("external edit".utf8).write(to: root.appendingPathComponent(secondPath), options: .atomic)

        do {
            _ = try await store.writeBatch([
                WorkspaceWriteOperation(data: Data("replacement".utf8), relativePath: firstPath, expectedRevision: firstRevision),
                WorkspaceWriteOperation(data: Data("record".utf8), relativePath: secondPath, expectedRevision: "stale-revision")
            ])
            Issue.record("Expected a later conflict to reject the whole batch before writes")
        } catch WorkspaceStoreError.conflict { }

        #expect(try Data(contentsOf: root.appendingPathComponent(firstPath)) == Data("draft".utf8))
        #expect(try Data(contentsOf: root.appendingPathComponent(secondPath)) == Data("external edit".utf8))
    }

    @Test func batchWriteRollsBackEarlierWritesAfterLaterWriteFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = WorkspaceStore(rootURL: root)
        _ = try await store.createWorkspace(at: root)
        let firstPath = "Content/item/original.txt"
        let secondPath = "Content/item/record.json"
        let firstRevision = try await store.write(Data("draft".utf8), relativePath: firstPath)
        let secondRevision = try await store.write(Data("record".utf8), relativePath: secondPath)
        await store.setWriteFailureInjectionForTesting(at: secondPath)

        do {
            _ = try await store.writeBatch([
                WorkspaceWriteOperation(data: Data("replacement".utf8), relativePath: firstPath, expectedRevision: firstRevision),
                WorkspaceWriteOperation(data: Data("replacement record".utf8), relativePath: secondPath, expectedRevision: secondRevision)
            ])
            Issue.record("Expected the injected later write failure")
        } catch { }

        #expect(try Data(contentsOf: root.appendingPathComponent(firstPath)) == Data("draft".utf8))
        #expect(try Data(contentsOf: root.appendingPathComponent(secondPath)) == Data("record".utf8))
    }

    @Test func socialDestinationEligibilityRejectsWhitespaceOnlyHandle() {
        let account = SocialAccountRecord(
            id: "account", platform: "threads", owner: RecordOwner(type: .identity, id: "owner"),
            handle: " \n\t ", enabled: true
        )
        #expect(!account.isEligibleDestination)
    }

    @Test func socialDestinationEligibilityRequiresEnabledAccountResolvedOwnerAndIdentity() {
        let ready = SocialAccountRecord(
            id: "ready", platform: "threads", owner: RecordOwner(type: .identity, id: "owner"),
            profileURL: URL(string: "https://threads.net/@sample"), enabled: true
        )
        let disabled = SocialAccountRecord(id: "disabled", platform: "threads", owner: ready.owner, handle: "@sample", enabled: false)
        let noOwner = SocialAccountRecord(id: "ownerless", platform: "threads", handle: "@sample")
        let noPlatform = SocialAccountRecord(id: "platformless", platform: "  ", owner: ready.owner, handle: "@sample")

        #expect(ready.isEligibleDestination)
        #expect(!disabled.isEligibleDestination)
        #expect(!noOwner.isEligibleDestination)
        #expect(!noPlatform.isEligibleDestination)
    }

    @Test func workspacePathsCannotEscapeThroughSymlink() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent); try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: outside.appendingPathComponent("secret.txt"))
        try FileManager.default.createSymbolicLink(at: parent.appendingPathComponent("escape"), withDestinationURL: outside)
        let store = WorkspaceStore(rootURL: parent)
        do {
            _ = try await store.read(relativePath: "escape/secret.txt")
            Issue.record("Expected symlink escape to be rejected")
        } catch WorkspaceStoreError.invalidRelativePath { }
    }

    @Test func malformedAndFutureRecordsArePreservedAsOpaqueData() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let store = WorkspaceStore(rootURL: parent)
        _ = try await store.createWorkspace(at: parent)
        let malformedPath = parent.appendingPathComponent("Apps/bad/record.json")
        let futurePath = parent.appendingPathComponent("Apps/future/record.json")
        try FileManager.default.createDirectory(at: malformedPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: futurePath.deletingLastPathComponent(), withIntermediateDirectories: true)
        let malformed = Data("{not-json".utf8)
        let future = Data("{\"schemaVersion\":42,\"id\":\"future\"}".utf8)
        try malformed.write(to: malformedPath)
        try future.write(to: futurePath)
        let snapshot = try await store.load()
        #expect(snapshot.opaqueRecords.count == 2)
        #expect(snapshot.opaqueRecords.contains { $0.data == malformed })
        #expect(snapshot.opaqueRecords.contains { $0.data == future })
        #expect(snapshot.errors.count == 2)
    }

    @Test func relatedContentIsDerivedFromOneWaySourceIDs() {
        let article = ContentRecord(id: "article", kind: .blog, title: "Article")
        let social = ContentRecord(id: "social", kind: .social, title: "Announcement", sourceContentId: "article")
        let followup = ContentRecord(id: "followup", kind: .social, title: "Follow-up", sourceContentId: "social")
        let snapshot = WorkspaceSnapshot(
            manifest: WorkspaceManifest(), identities: [], apps: [], websites: [], socialAccounts: [],
            content: [article, social, followup], errors: [], opaqueRecords: []
        )

        #expect(snapshot.relatedContent(to: "article").map(\.id) == ["social"])
        #expect(snapshot.relatedContent(to: "social").map(\.id) == ["followup"])
        #expect(snapshot.relatedContent(to: "missing").isEmpty)
    }

    @Test func relatedFamilyIncludesParentSiblingsChildrenAndGroupMembers() {
        let article = ContentRecord(id: "article", kind: .blog, title: "Article")
        let postA = ContentRecord(id: "post-a", kind: .social, title: "A post", sourceContentId: "article")
        let postB = ContentRecord(id: "post-b", kind: .social, title: "B post", sourceContentId: "article")
        let grouped = ContentRecord(id: "grouped", kind: .idea, title: "Related idea", relatedGroupId: "family")
        let groupedSibling = ContentRecord(id: "grouped-sibling", kind: .social, title: "Another related item", relatedGroupId: "family")
        let snapshot = WorkspaceSnapshot(
            manifest: WorkspaceManifest(), identities: [], apps: [], websites: [], socialAccounts: [],
            content: [article, postA, postB, grouped, groupedSibling], errors: [], opaqueRecords: []
        )

        #expect(snapshot.relatedFamily(to: "article").map(\.id) == ["post-a", "post-b"])
        #expect(snapshot.relatedFamily(to: "post-a").map(\.id) == ["article", "post-b"])
        #expect(snapshot.relatedFamily(to: "grouped").map(\.id) == ["grouped-sibling"])
    }

    @Test func generatedWorkspaceGuideDescribesCurrentPathBasesAndSchema() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(rootURL: root)
        _ = try await store.createWorkspace(at: root)

        let guide = try String(contentsOf: root.appendingPathComponent("AGENTS.md"), encoding: .utf8)
        #expect(guide.contains("Content body/media paths are relative to the content folder"))
        #expect(guide.contains("iconPath` is relative to the app folder"))
        #expect(guide.contains("release notes/assets are relative to that release folder"))
        #expect(guide.contains("avatarPath` is relative to the workspace root"))
        #expect(guide.contains("destination's `mediaPaths: null`"))
        #expect(guide.contains("not crash recovery or a transaction"))
    }

    @Test func missingWorkspaceCategoryProducesActionableLoadError() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(rootURL: root)
        _ = try await store.createWorkspace(at: root)
        try FileManager.default.removeItem(at: root.appendingPathComponent("Websites"))

        let snapshot = try await store.load()
        #expect(snapshot.errors.contains { $0.path.hasSuffix("/Websites") && $0.message.contains("Could not read workspace records") })
    }

    @Test func destinationsDistinguishLiveOriginalFromCustomizedBranch() {
        let sharedDestination = ContentDestination(accountId: "business", bodyPath: nil)
        let customDestination = ContentDestination(accountId: "personal", bodyPath: "Variants/personal.txt")
        let post = ContentRecord(
            id: "post", kind: .social, title: "Shared announcement",
            originalBodyPath: "original.txt", destinations: [sharedDestination, customDestination]
        )

        #expect(post.originalBodyPath == "original.txt")
        #expect(post.destinations.first(where: { $0.accountId == "business" })?.bodyPath == nil)
        #expect(post.destinations.first(where: { $0.accountId == "personal" })?.bodyPath == "Variants/personal.txt")
    }

    @Test func externalRecordChangeNotifiesAndReloadsUpdatedContent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = WorkspaceStore(rootURL: root)
        _ = try await store.createWorkspace(at: root)

        let path = "Content/announcement/record.json"
        let record = ContentRecord(id: "content-announcement", kind: .social, title: "Before")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try await store.write(encoder.encode(record), relativePath: path)

        let flag = TestChangeFlag()
        await store.startWatching { flag.signal() }
        try await Task.sleep(for: .milliseconds(200))

        var externallyEdited = record
        externallyEdited.title = "After external edit"
        try encoder.encode(externallyEdited).write(to: root.appendingPathComponent(path), options: .atomic)

        for _ in 0..<60 where !flag.value() {
            try await Task.sleep(for: .milliseconds(50))
        }
        await store.stopWatching()

        #expect(flag.value())
        let snapshot = try await store.load()
        #expect(snapshot.contentByID[record.id]?.title == "After external edit")
    }

    @Test func nestedReleaseRecordCanBeReadAndDecodedFromWorkspace() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = WorkspaceStore(rootURL: root)
        _ = try await store.createWorkspace(at: root)

        let release = ReleaseRecord(
            id: "release-1-2", appId: "app-demo", version: "1.2", status: .released,
            releaseDate: Date(timeIntervalSince1970: 1_800_000_000), notesPath: "notes.md",
            assetPaths: ["Assets/build-banner.png"],
            externalChangelogPath: "/tmp/CHANGELOG.md"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let path = "Apps/demo/Releases/1.2/record.json"
        try await store.write(encoder.encode(release), relativePath: path)

        let stored = try await store.read(relativePath: path)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let loaded = try decoder.decode(ReleaseRecord.self, from: stored.data)
        #expect(loaded == release)

        let notes = Data("# Version 1.2\n\nA release note.\n".utf8)
        try await store.write(notes, relativePath: "Apps/demo/Releases/1.2/notes.md")
        let loadedNotes = try await store.read(relativePath: "Apps/demo/Releases/1.2/notes.md")
        #expect(loadedNotes.data == notes)
    }

    @Test func contentPlannedAndPublicationDatesRoundTripAndRemainOptionalForOlderRecords() throws {
        let planned = Date(timeIntervalSince1970: 1_800_000_000)
        let published = Date(timeIntervalSince1970: 1_800_086_400)
        let record = ContentRecord(
            id: "content-dated", kind: .social, title: "Dated post",
            plannedDate: planned,
            destinations: [ContentDestination(accountId: "account", status: .published, publishedDate: published)]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(ContentRecord.self, from: encoder.encode(record))
        #expect(decoded.plannedDate == planned)
        #expect(decoded.destinations.first?.publishedDate == published)

        let olderRecord = Data(#"{"schemaVersion":1,"id":"legacy","kind":"social","title":"Older post","appIds":[],"includeSourceLink":false,"status":"draft","destinations":[{"accountId":"legacy-account","status":"draft"}],"mediaPaths":[]}"#.utf8)
        let legacy = try decoder.decode(ContentRecord.self, from: olderRecord)
        #expect(legacy.plannedDate == nil)
        #expect(legacy.destinations.first?.publishedDate == nil)
    }

    @Test func legacyReleaseRecordsDecodeWithoutAssetPaths() throws {
        let data = Data("""
        {"schemaVersion":1,"id":"old-release","appId":"app-demo","version":"1.0","status":"planned","notesPath":"notes.md"}
        """.utf8)
        let release = try JSONDecoder().decode(ReleaseRecord.self, from: data)
        #expect(release.assetPaths == nil)
    }

}
