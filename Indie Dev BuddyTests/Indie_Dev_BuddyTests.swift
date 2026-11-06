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

    func reset() {
        lock.lock()
        didChange = false
        lock.unlock()
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
        let externalVersion = try await store.read(relativePath: path)
        let retryData = Data("{\"schemaVersion\":1,\"keptLocal\":true}".utf8)
        _ = try await store.write(retryData, relativePath: path, expectedRevision: externalVersion.revision)
        #expect(try await store.read(relativePath: path).data == retryData)
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

    @Test func batchWriteReportsAndPreservesExternalChangesThatPreventRollback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = WorkspaceStore(rootURL: root)
        _ = try await store.createWorkspace(at: root)
        let firstPath = "Content/item/original.txt"
        let secondPath = "Content/item/record.json"
        let firstRevision = try await store.write(Data("draft".utf8), relativePath: firstPath)
        let secondRevision = try await store.write(Data("record".utf8), relativePath: secondPath)
        let externalData = Data("external writer's version".utf8)
        await store.setWriteInterferenceInjectionForTesting(at: firstPath, data: externalData)
        await store.setWriteFailureInjectionForTesting(at: secondPath)

        do {
            _ = try await store.writeBatch([
                WorkspaceWriteOperation(data: Data("replacement".utf8), relativePath: firstPath, expectedRevision: firstRevision),
                WorkspaceWriteOperation(data: Data("replacement record".utf8), relativePath: secondPath, expectedRevision: secondRevision)
            ])
            Issue.record("Expected the injected failure and external-write interference")
        } catch let WorkspaceStoreError.partialWriteRecovery(paths) {
            #expect(paths == [firstPath])
        } catch {
            Issue.record("Expected partial recovery to identify the externally changed file, got \(error)")
        }

        #expect(try Data(contentsOf: root.appendingPathComponent(firstPath)) == externalData)
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

    @Test func blogCanKeepMultipleUniqueAppAssociations() throws {
        var article = ContentRecord(kind: .blog, title: "Shared launch", appIds: ["app-a"])
        article.setAppAssociation("app-b", selected: true)
        article.setAppAssociation("app-b", selected: true)
        article.setAppAssociation("", selected: true)

        #expect(article.appIds == ["app-a", "app-b"])

        let data = try JSONEncoder().encode(article)
        let reopened = try JSONDecoder().decode(ContentRecord.self, from: data)
        #expect(reopened.appIds == ["app-a", "app-b"])

        article.setAppAssociation("app-a", selected: false)
        #expect(article.appIds == ["app-b"])
    }

    @Test func existingPostKeepsUnavailableDestinationsOutOfNewSelection() {
        let identity = IdentityRecord(id: "person", name: "Personal")
        let app = AppRecord(id: "app", name: "Example App")
        let available = SocialAccountRecord(
            id: "available", platform: "Threads", owner: RecordOwner(type: .identity, id: identity.id), handle: "@person"
        )
        let appOwned = SocialAccountRecord(
            id: "app-owned", platform: "Instagram", owner: RecordOwner(type: .app, id: app.id), handle: "@exampleapp"
        )
        let disabled = SocialAccountRecord(
            id: "disabled", platform: "Threads", owner: RecordOwner(type: .identity, id: identity.id), handle: "@brand", enabled: false
        )
        let unresolvedOwner = SocialAccountRecord(
            id: "unresolved-owner", platform: "LinkedIn", owner: RecordOwner(type: .identity, id: "missing-person"), handle: "@legacy"
        )
        let ownerless = SocialAccountRecord(id: "ownerless", platform: "X", handle: "@legacy")
        let destinations = ["available", "app-owned", "disabled", "unresolved-owner", "ownerless", "deleted-account"].map {
            ContentDestination(accountId: $0, status: .published)
        }
        let post = ContentRecord(id: "post", kind: .social, title: "Existing post", destinations: destinations)
        let snapshot = WorkspaceSnapshot(
            manifest: WorkspaceManifest(), identities: [identity], apps: [app], websites: [],
            socialAccounts: [available, appOwned, disabled, unresolvedOwner, ownerless], content: [post],
            errors: [], opaqueRecords: []
        )

        let selection = snapshot.socialDestinationSelection(for: post)

        #expect(selection.selectedAccountIDs == ["available", "app-owned"])
        #expect(selection.unavailableAccountIDs == ["disabled", "unresolved-owner", "ownerless", "deleted-account"])
        #expect(post.destinations == destinations)
    }

    @MainActor @Test func accountEligibilityRefreshPreservesDraftAndDoesNotCreateFalseDirtyState() {
        func draft() -> ComposerDraft {
            ComposerDraft(
                title: "Post", originalText: "Shared text", selectedAccountIDs: ["enabled", "disabled"],
                appIDs: [], releaseID: nil, customizedText: [:], destinationStatuses: [:], destinationURLs: [:],
                plannedDate: nil, destinationPublicationDates: [:], sharedMediaPaths: [],
                destinationMediaOverrides: [:], preservedDestinationIDs: [], includeArticleLink: false, status: "Draft"
            )
        }
        var current = draft()
        var baseline = current
        current.reconcileAccountAvailability(eligibleAccountIDs: ["enabled"], unavailableDestinationIDs: ["disabled"])
        baseline.reconcileAccountAvailability(eligibleAccountIDs: ["enabled"], unavailableDestinationIDs: ["disabled"])

        #expect(current.selectedAccountIDs == ["enabled"])
        #expect(current.preservedDestinationIDs == ["disabled"])
        #expect(current == baseline)

        current.originalText = "Local unsaved edit"
        current.reconcileAccountAvailability(eligibleAccountIDs: ["enabled"], unavailableDestinationIDs: ["disabled"])
        #expect(current.originalText == "Local unsaved edit")
        #expect(current != baseline)
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

    @Test func workspaceLoadRejectsSymlinkedRecordFoldersOutsideWorkspace() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let store = WorkspaceStore(rootURL: root)
        _ = try await store.createWorkspace(at: root)

        let externalRecord = try JSONEncoder().encode(AppRecord(id: "outside-app", name: "Outside App"))
        try externalRecord.write(to: outside.appendingPathComponent("record.json"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Apps/linked-outside", isDirectory: true),
            withDestinationURL: outside
        )

        let snapshot = try await store.load()

        #expect(snapshot.apps.isEmpty)
        #expect(snapshot.errors.contains { $0.path.hasSuffix("Apps/linked-outside/record.json") })
        #expect(!snapshot.opaqueRecords.contains { $0.relativePath.hasSuffix("Apps/linked-outside/record.json") })
    }

    @Test func filesBrowserRelativePathCanonicalizesTemporaryDirectoryAliases() {
        let root = URL(fileURLWithPath: "/tmp/indie-dev-buddy-\(UUID().uuidString)", isDirectory: true)
        let child = root.appendingPathComponent("Inbox", isDirectory: true)
        let sibling = URL(fileURLWithPath: "/tmp/other-\(UUID().uuidString)", isDirectory: true)

        #expect(workspaceRelativePath(for: child, root: root) == "Inbox")
        #expect(workspaceRelativePath(for: sibling, root: root) == nil)
    }

    @Test func filesBrowserOperationsCoverWorkspaceItemsButProtectStoreMarkers() {
        #expect(workspaceBrowserCanManageItem(relativePath: "Inbox/notes.txt"))
        #expect(workspaceBrowserCanManageItem(relativePath: "Apps/dictate-bar"))
        #expect(workspaceBrowserCanManageItem(relativePath: "Content/article/Assets/cover.png"))
        #expect(!workspaceBrowserCanManageItem(relativePath: "Apps/dictate-bar/record.json"))
        #expect(!workspaceBrowserCanManageItem(relativePath: "workspace.json"))
        #expect(!workspaceBrowserCanManageItem(relativePath: "AGENTS.md"))
        #expect(!workspaceBrowserCanManageItem(relativePath: "Apps"))
    }

    @Test func filesBrowserImportCopiesFilesWithoutReplacingExistingItems() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("workspace", isDirectory: true)
        let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)

        let newSource = parent.appendingPathComponent("new-file.txt")
        let existingSource = parent.appendingPathComponent("existing.txt")
        let existingTarget = inbox.appendingPathComponent("existing.txt")
        try Data("new content".utf8).write(to: newSource)
        try Data("replacement attempt".utf8).write(to: existingSource)
        try Data("keep this".utf8).write(to: existingTarget)

        let failures = importWorkspaceFiles([newSource, existingSource], into: inbox, workspaceRoot: root)

        #expect(failures.count == 1)
        #expect(try Data(contentsOf: inbox.appendingPathComponent("new-file.txt")) == Data("new content".utf8))
        #expect(try Data(contentsOf: existingTarget) == Data("keep this".utf8))
    }

    @Test func filesBrowserImportRejectsSymbolicLinksAndDestinationsOutsideWorkspace() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("workspace", isDirectory: true)
        let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
        let outside = parent.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)

        let source = parent.appendingPathComponent("source.txt")
        let symbolicLink = parent.appendingPathComponent("source-link.txt")
        try Data("source".utf8).write(to: source)
        try FileManager.default.createSymbolicLink(at: symbolicLink, withDestinationURL: source)

        let linkFailures = importWorkspaceFiles([symbolicLink], into: inbox, workspaceRoot: root)
        let outsideFailures = importWorkspaceFiles([source], into: outside, workspaceRoot: root)

        #expect(linkFailures.count == 1)
        #expect(linkFailures[0].contains("Symbolic links"))
        #expect(outsideFailures.count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: inbox.path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
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

        let guide = try String(contentsOf: root.appendingPathComponent("docs/DATA_FORMAT.md"), encoding: .utf8)
        #expect(guide.contains("relative to that content record's folder"))
        #expect(guide.contains("relative to the app folder"))
        #expect(guide.contains("relative to the release folder"))
        #expect(guide.contains("relative to the workspace root"))
        #expect(guide.contains("inherits the content's media"))
        #expect(guide.contains("not assume a multi-file update is atomic"))
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

    @Test func externalMarkdownAndImageReplacementsNotifyWorkspaceWatcher() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = WorkspaceStore(rootURL: root)
        _ = try await store.createWorkspace(at: root)

        let bodyURL = root.appendingPathComponent("Content/article/body.md")
        let imageURL = root.appendingPathComponent("Content/article/Assets/cover.png")
        try FileManager.default.createDirectory(at: imageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("First draft".utf8).write(to: bodyURL)
        try Data([0, 1, 2]).write(to: imageURL)

        let flag = TestChangeFlag()
        await store.startWatching { flag.signal() }
        try await Task.sleep(for: .milliseconds(200))

        try Data("Externally edited article".utf8).write(to: bodyURL, options: .atomic)
        for _ in 0..<60 where !flag.value() { try await Task.sleep(for: .milliseconds(50)) }
        #expect(flag.value())

        try await Task.sleep(for: .milliseconds(300))
        flag.reset()
        try Data([3, 4, 5]).write(to: imageURL, options: .atomic)
        for _ in 0..<60 where !flag.value() { try await Task.sleep(for: .milliseconds(50)) }
        await store.stopWatching()

        #expect(flag.value())
        #expect(try Data(contentsOf: bodyURL) == Data("Externally edited article".utf8))
        #expect(try Data(contentsOf: imageURL) == Data([3, 4, 5]))
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
