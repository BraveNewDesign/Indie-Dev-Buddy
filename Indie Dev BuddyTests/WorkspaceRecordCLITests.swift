import Foundation
import Testing
@testable import Indie_Dev_Buddy

struct WorkspaceRecordCLITests {
    @Test func sharedPostOverridesAndPartialPublicationMetadataRoundTrip() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(rootURL: root)
        try await store.createWorkspace(at: root)

        let owner = IdentityRecord(name: "Owner")
        _ = try await store.saveRecord(.identities, id: owner.id, json: JSONEncoder().encode(owner), expectedRevision: nil)
        let accounts = ["threads", "linkedin", "instagram"].map { platform in
            SocialAccountRecord(platform: platform, owner: RecordOwner(type: .identity, id: owner.id), handle: "@\(platform)")
        }
        for account in accounts {
            _ = try await store.saveRecord(.accounts, id: account.id, json: JSONEncoder().encode(account), expectedRevision: nil)
        }

        // Keep the current CLI-style account selection contract intact: selected accounts
        // start as destinations that inherit the shared original.
        let cliStyleDraft = ContentRecord.draft(kind: .social, title: "CLI post", accountIDs: accounts.prefix(2).map(\.id))
        #expect(cliStyleDraft.destinations.map(\.accountId) == accounts.prefix(2).map(\.id))
        #expect(cliStyleDraft.destinations.allSatisfy { $0.bodyPath == nil && $0.status == .draft })

        let publishedDate = Date(timeIntervalSince1970: 1_800_000_000)
        let publishedURL = try #require(URL(string: "https://example.com/threads-post"))
        let post = ContentRecord(
            kind: .social, title: "Shared announcement",
            originalBodyPath: "original.txt",
            destinations: [
                ContentDestination(accountId: accounts[0].id, bodyPath: "Variants/threads.txt", status: .published,
                                   publishedURL: publishedURL, publishedDate: publishedDate,
                                   mediaPaths: ["Media/threads.png"]),
                ContentDestination(accountId: accounts[1].id, bodyPath: "Variants/linkedin.txt", status: .ready,
                                   mediaPaths: ["Media/linkedin.png"]),
                ContentDestination(accountId: accounts[2].id, status: .draft)
            ],
            mediaPaths: ["Media/shared.png"]
        )
        try await store.write(Data("Threads wording".utf8), relativePath: "Content/\(post.id)/Variants/threads.txt")
        try await store.write(Data("LinkedIn wording".utf8), relativePath: "Content/\(post.id)/Variants/linkedin.txt")
        for path in ["Media/shared.png", "Media/threads.png", "Media/linkedin.png"] {
            try await store.write(Data([0x01]), relativePath: "Content/\(post.id)/\(path)")
        }
        _ = try await store.createContent(post, body: "Shared wording")

        let loaded = try await store.load().contentByID[post.id]
        let persisted = try #require(loaded)
        #expect(persisted.originalBodyPath == "original.txt")
        #expect(persisted.destinations.map(\.accountId) == accounts.map(\.id))
        #expect(persisted.destinations[0].bodyPath == "Variants/threads.txt")
        #expect(persisted.destinations[1].bodyPath == "Variants/linkedin.txt")
        #expect(persisted.destinations[2].bodyPath == nil)
        #expect(persisted.destinations.map(\.status) == [.published, .ready, .draft])
        #expect(persisted.destinations[0].publishedURL == publishedURL)
        #expect(persisted.destinations[0].publishedDate == publishedDate)
        #expect(persisted.destinations[1].publishedURL == nil && persisted.destinations[1].publishedDate == nil)
        #expect(persisted.mediaPaths == ["Media/shared.png"])
        #expect(persisted.destinations[0].mediaPaths == ["Media/threads.png"])
        #expect(persisted.destinations[1].mediaPaths == ["Media/linkedin.png"])
    }

    @Test func accountCreateUpdateConflictAndDeleteAreRevisionGuarded() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(rootURL: root)
        try await store.createWorkspace(at: root)
        let owner = IdentityRecord(name: "Owner")
        _ = try await store.saveRecord(.identities, id: owner.id, json: JSONEncoder().encode(owner), expectedRevision: nil)
        let account = SocialAccountRecord(platform: "Threads", owner: RecordOwner(type: .identity, id: owner.id), handle: "@fixture")
        let created = try await store.saveRecord(.accounts, id: account.id, json: JSONEncoder().encode(account), expectedRevision: nil)
        var changed = account
        changed.enabled = false
        let updated = try await store.saveRecord(.accounts, id: account.id, json: JSONEncoder().encode(changed), expectedRevision: created.revision)
        #expect(try await store.readRecord(.accounts, id: account.id).revision == updated.revision)
        #expect(try await store.load().socialAccountsByID[account.id]?.enabled == false)
        #expect(updated.backupDirectory != nil)
        do {
            _ = try await store.saveRecord(.accounts, id: account.id, json: JSONEncoder().encode(account), expectedRevision: created.revision)
            Issue.record("A stale revision must fail.")
        } catch WorkspaceStoreError.conflict { }
        _ = try await store.deleteRecord(.accounts, id: account.id, expectedRevision: updated.revision)
        #expect(try await store.load().socialAccountsByID[account.id] == nil)
    }

    @Test func invalidOwnerAndContentDestinationStatesLeaveExistingBytesUntouched() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(rootURL: root)
        try await store.createWorkspace(at: root)
        let account = SocialAccountRecord(platform: "Threads", owner: RecordOwner(type: .identity, id: UUID().uuidString), handle: "@fixture")
        do {
            _ = try await store.saveRecord(.accounts, id: account.id, json: JSONEncoder().encode(account), expectedRevision: nil)
            Issue.record("Unknown owners must be rejected.")
        } catch { #expect(error.localizedDescription.contains("Unknown identity owner")) }
        let post = ContentRecord(kind: .social, title: "Scheduled", originalBodyPath: "original.txt", status: .draft)
        let created = try await store.createContent(post, body: "Post")
        let invalid = Data("{\"schemaVersion\":1,\"id\":\"\(post.id)\",\"kind\":\"social\",\"title\":\"Scheduled\",\"appIds\":[],\"includeSourceLink\":false,\"status\":\"scheduled\",\"destinations\":[],\"mediaPaths\":[]}".utf8)
        do {
            _ = try await store.saveRecord(.content, id: post.id, json: invalid, expectedRevision: created.revision)
            Issue.record("Unsupported statuses must be rejected.")
        } catch { #expect(!error.localizedDescription.isEmpty) }
        let invalidAccount = Data("{\"schemaVersion\":1,\"id\":\"\(post.id)\",\"kind\":\"social\",\"title\":\"Scheduled\",\"appIds\":[],\"includeSourceLink\":false,\"status\":\"draft\",\"destinations\":[{\"accountId\":\"\(UUID().uuidString)\",\"status\":\"published\"}],\"mediaPaths\":[]}".utf8)
        do {
            _ = try await store.saveRecord(.content, id: post.id, json: invalidAccount, expectedRevision: created.revision)
            Issue.record("Unknown destination account IDs must be rejected.")
        } catch { #expect(!error.localizedDescription.isEmpty) }
        #expect(try await store.readRecord(.content, id: post.id).revision == created.revision)
        #expect(try await store.readRecord(.content, id: post.id).body == "Post")
    }

    @Test func invalidAssetPathAndInjectedWriteFailureDoNotEscapeOrPartiallyReplace() async throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let root = fixture.appendingPathComponent("Workspace")
        let store = WorkspaceStore(rootURL: root)
        try await store.createWorkspace(at: root)
        let app = AppRecord(name: "Fixture")
        let created = try await store.saveRecord(.apps, id: app.id, json: JSONEncoder().encode(app), expectedRevision: nil)
        var escaping = app
        escaping.iconPath = "../../outside.png"
        do {
            _ = try await store.saveRecord(.apps, id: app.id, json: JSONEncoder().encode(escaping), expectedRevision: created.revision)
            Issue.record("An escaping asset path must be rejected.")
        } catch { }
        var changed = app
        changed.name = "Changed"
        await store.setWriteFailureInjectionForTesting(at: created.path)
        do {
            _ = try await store.saveRecord(.apps, id: app.id, json: JSONEncoder().encode(changed), expectedRevision: created.revision)
            Issue.record("Injected write failure must be reported.")
        } catch { }
        #expect(try await store.readRecord(.apps, id: app.id).revision == created.revision)
        #expect(try await store.load().apps.first?.name == "Fixture")
    }

    @Test func destinationVariantAndStatusUpdateUseFileAndRecordRevisionsAtomically() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(rootURL: root)
        try await store.createWorkspace(at: root)
        let owner = IdentityRecord(name: "Owner")
        _ = try await store.saveRecord(.identities, id: owner.id, json: JSONEncoder().encode(owner), expectedRevision: nil)
        let account = SocialAccountRecord(platform: "Threads", owner: RecordOwner(type: .identity, id: owner.id), handle: "@fixture")
        _ = try await store.saveRecord(.accounts, id: account.id, json: JSONEncoder().encode(account), expectedRevision: nil)
        let post = ContentRecord(kind: .social, title: "Scheduled", originalBodyPath: "original.txt",
                                 destinations: [ContentDestination(accountId: account.id, bodyPath: "Variants/threads.txt")])
        let folder = "Content/\(post.id)"
        let variantPath = "\(folder)/Variants/threads.txt"
        let initialVariantRevision = try await store.write(Data("First wording".utf8), relativePath: variantPath)
        let created = try await store.createContent(post, body: "Original")
        let contentEncoder = JSONEncoder()
        contentEncoder.dateEncodingStrategy = .iso8601
        var update = post
        update.destinations[0].status = .published
        update.destinations[0].publishedURL = URL(string: "https://example.com/post")
        update.destinations[0].publishedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let variantBytes = Data("Updated wording".utf8)
        let success = try await store.saveRecord(.content, id: post.id, json: contentEncoder.encode(update), expectedRevision: created.revision,
            fileWrites: [.init(data: variantBytes, relativePath: variantPath, expectedRevision: initialVariantRevision)])
        #expect(try await store.read(relativePath: variantPath).data == variantBytes)
        #expect(try await store.load().contentByID[post.id]?.destinations[0].status == .published)
        let newVariantRevision = try await store.read(relativePath: variantPath).revision
        let readBack = try await store.readRecord(.content, id: post.id)
        #expect(readBack.relatedFiles.first?.text == "Updated wording")
        #expect(readBack.relatedFiles.first?.revision == newVariantRevision)
        var next = update
        next.title = "Should Roll Back"
        await store.setWriteFailureInjectionForTesting(at: success.path)
        do {
            _ = try await store.saveRecord(.content, id: post.id, json: contentEncoder.encode(next), expectedRevision: success.revision,
                fileWrites: [.init(data: Data("Partial".utf8), relativePath: variantPath, expectedRevision: newVariantRevision)])
            Issue.record("Record write failure should roll back the variant write.")
        } catch { }
        #expect(try await store.read(relativePath: variantPath).data == variantBytes)
        #expect(try await store.readRecord(.content, id: post.id).revision == success.revision)
        do {
            _ = try await store.saveRecord(.content, id: post.id, json: contentEncoder.encode(next), expectedRevision: success.revision,
                fileWrites: [.init(data: Data("Stale".utf8), relativePath: variantPath, expectedRevision: initialVariantRevision)])
            Issue.record("A stale variant revision must reject the entire edit.")
        } catch WorkspaceStoreError.conflict(let path, _) { #expect(path == variantPath) }
        #expect(try await store.read(relativePath: variantPath).data == variantBytes)
    }

    @Test func workspaceFileCommandsStayInsideWorkspaceAndProtectMarkers() async throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let root = fixture.appendingPathComponent("Workspace")
        let source = fixture.appendingPathComponent("source.txt")
        let store = WorkspaceStore(rootURL: root)
        try await store.createWorkspace(at: root)
        try Data("file body".utf8).write(to: source)
        try await store.createFolder(relativePath: "Inbox/Fixture")
        _ = try await store.importFile(from: source, to: "Inbox/Fixture/source.txt")
        let renamed = try await store.renameItem(relativePath: "Inbox/Fixture/source.txt", newName: "renamed.txt")
        #expect(renamed == "Inbox/Fixture/renamed.txt")
        try await store.removeManagedItem(relativePath: renamed)
        #expect(try await store.listItems(relativePath: "Inbox/Fixture").isEmpty)
        do {
            try await store.removeManagedItem(relativePath: "workspace.json")
            Issue.record("Workspace markers must not be removable through file commands.")
        } catch { }
        let outside = fixture.appendingPathComponent("Outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)
        do {
            try await store.createFolder(relativePath: "escape/new-folder")
            Issue.record("File commands must reject symbolic-link ancestors.")
        } catch { }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test func managedPathsRejectDotAliasesAndProtectedMarkers() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(rootURL: root)
        try await store.createWorkspace(at: root)
        for path in ["./.", "./Inbox", "./Content", "Inbox/../Content", "Inbox/Fixture/../..", "Inbox/AGENTS.MD"] {
            do {
                try await store.trashManagedItem(relativePath: path)
                Issue.record("Managed path alias or protected marker must be rejected: \(path)")
            } catch { }
        }
        #expect(try FileManager.default.fileExists(atPath: root.appendingPathComponent("Inbox").path))
        #expect(try FileManager.default.fileExists(atPath: root.appendingPathComponent("Content").path))
    }

    @Test func contentReadSurvivesMissingRelatedFilesAndRecordDeleteRejectsSymlink() async throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let root = fixture.appendingPathComponent("Workspace")
        let store = WorkspaceStore(rootURL: root)
        try await store.createWorkspace(at: root)
        var post = ContentRecord(kind: .social, title: "Readable", originalBodyPath: "original.txt")
        let created = try await store.createContent(post, body: "Body")
        post.mediaPaths = ["missing.png"]
        let missingMediaRevision = try await store.write(JSONEncoder().encode(post), relativePath: created.path,
                                                         expectedRevision: created.revision)
        let read = try await store.readRecord(.content, id: post.id)
        #expect(read.revision == missingMediaRevision)
        #expect(read.body == "Body")
        #expect(read.relatedFiles.isEmpty)

        let account = SocialAccountRecord(platform: "Threads", owner: nil, handle: "@fixture")
        // Install a readable record fixture directly so deletion exercises the indexed symlink path.
        let recordPath = "SocialAccounts/\(account.id)/record.json"
        try await store.createFolder(relativePath: "SocialAccounts/\(account.id)")
        _ = try await store.write(JSONEncoder().encode(account), relativePath: recordPath)
        let targetDirectory = root.appendingPathComponent("Inbox/target")
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        let target = targetDirectory.appendingPathComponent("record.json")
        try JSONEncoder().encode(account).write(to: target)
        try FileManager.default.removeItem(at: root.appendingPathComponent(recordPath))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(recordPath), withDestinationURL: target)
        #expect(try await store.load().recordPaths[WorkspaceRecordKind.accounts.directory]?[account.id] == recordPath)
        do {
            _ = try await store.deleteRecord(.accounts, id: account.id,
                                             expectedRevision: WorkspaceStore.revision(try Data(contentsOf: target)))
            Issue.record("Deleting a record through a symlink must fail.")
        } catch { }
        #expect(try FileManager.default.fileExists(atPath: target.path))
    }
}
