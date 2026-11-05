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

    @Test func example() async throws {
        // Write your test here and use APIs like `#expect(...)` to check expected conditions.
        // Swift Testing Documentation
        // https://developer.apple.com/documentation/testing
    }

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

}
