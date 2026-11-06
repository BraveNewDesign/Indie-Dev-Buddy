import Foundation
import Testing
@testable import Indie_Dev_Buddy

struct WorkspaceGuidanceTests {
    private let paths = [
        "AGENTS.md",
        "docs/DATA_FORMAT.md",
        "docs/EXAMPLES.md",
        ".agents/skills/indie-dev-buddy-content/SKILL.md"
    ]

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    @Test func newWorkspaceContainsGuidance() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(rootURL: root)
        _ = try await store.createWorkspace(at: root)
        for path in paths {
            let data = try Data(contentsOf: root.appendingPathComponent(path))
            #expect(!data.isEmpty, "Empty guidance: \(path)")
        }
    }

    @Test func openingOlderWorkspaceInstallsMissingGuidance() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(rootURL: root)
        _ = try await store.createWorkspace(at: root)
        try FileManager.default.removeItem(at: root.appendingPathComponent("AGENTS.md"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("docs"))
        try FileManager.default.removeItem(at: root.appendingPathComponent(".agents"))
        let manifestBefore = try Data(contentsOf: root.appendingPathComponent("workspace.json"))

        _ = try await store.load()

        for path in paths { #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path)) }
        #expect(try Data(contentsOf: root.appendingPathComponent("workspace.json")) == manifestBefore)
    }

    @Test func partialSetupPreservesCustomizedFilesAndIsIdempotent() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(rootURL: root)
        _ = try await store.createWorkspace(at: root)
        let customizedURL = root.appendingPathComponent("AGENTS.md")
        let customized = Data("# My workspace rules\nKeep my instructions.\n".utf8)
        try customized.write(to: customizedURL)
        let existingURL = root.appendingPathComponent("docs/DATA_FORMAT.md")
        let existing = try Data(contentsOf: existingURL)
        let sentinel = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.modificationDate: sentinel], ofItemAtPath: customizedURL.path)
        try FileManager.default.setAttributes([.modificationDate: sentinel], ofItemAtPath: existingURL.path)
        let expectedCustomTime = try #require(FileManager.default.attributesOfItem(atPath: customizedURL.path)[.modificationDate] as? Date)
        let expectedExistingTime = try #require(FileManager.default.attributesOfItem(atPath: existingURL.path)[.modificationDate] as? Date)
        try FileManager.default.removeItem(at: root.appendingPathComponent("docs/EXAMPLES.md"))
        try FileManager.default.removeItem(at: root.appendingPathComponent(".agents/skills/indie-dev-buddy-content/SKILL.md"))

        _ = try await store.load()
        let installed = try paths.map { try Data(contentsOf: root.appendingPathComponent($0)) }
        let dates = try paths.map { path in
            try #require(FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(path).path)[.modificationDate] as? Date)
        }
        _ = try await store.load()

        #expect(try Data(contentsOf: customizedURL) == customized)
        #expect(try Data(contentsOf: existingURL) == existing)
        #expect(try FileManager.default.attributesOfItem(atPath: customizedURL.path)[.modificationDate] as? Date == expectedCustomTime)
        #expect(try FileManager.default.attributesOfItem(atPath: existingURL.path)[.modificationDate] as? Date == expectedExistingTime)
        for (index, path) in paths.enumerated() {
            let url = root.appendingPathComponent(path)
            #expect(try Data(contentsOf: url) == installed[index])
            #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date == dates[index])
        }
    }

    @Test func inaccessibleGuidanceDirectoryDoesNotPreventLoadingWorkspace() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(rootURL: root)
        _ = try await store.createWorkspace(at: root)
        let docs = root.appendingPathComponent("docs")
        try FileManager.default.removeItem(at: docs)
        let obstruction = Data("User file, not a directory".utf8)
        try obstruction.write(to: docs)
        let manifestBefore = try Data(contentsOf: root.appendingPathComponent("workspace.json"))

        let snapshot = try await store.load()

        #expect(snapshot.manifest.schemaVersion == 1)
        #expect(try Data(contentsOf: docs) == obstruction)
        #expect(try Data(contentsOf: root.appendingPathComponent("workspace.json")) == manifestBefore)
    }

    @Test func guidanceSetupDoesNotFollowDirectorySymlinkOutsideWorkspace() async throws {
        let root = temporaryRoot()
        let outside = temporaryRoot()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let store = WorkspaceStore(rootURL: root)
        _ = try await store.createWorkspace(at: root)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: root.appendingPathComponent("docs"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("docs"), withDestinationURL: outside)

        _ = try await store.load()

        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }
    @Test func documentedExamplesLoadAsConnectedDrafts() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(rootURL: root)
        _ = try await store.createWorkspace(at: root)
        let examples = try String(contentsOf: root.appendingPathComponent("docs/EXAMPLES.md"), encoding: .utf8)
        let pattern = #"`([^`]+)`\n```(?:json|markdown)\n([\s\S]*?)\n```"#
        let regex = try NSRegularExpression(pattern: pattern)
        let ns = examples as NSString
        let matches = regex.matches(in: examples, range: NSRange(location: 0, length: ns.length))
        #expect(matches.count == 10)
        for match in matches {
            let path = ns.substring(with: match.range(at: 1))
            let contents = ns.substring(with: match.range(at: 2))
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }
        let snapshot = try await store.load()
        #expect(snapshot.errors.isEmpty)
        #expect(snapshot.identities.count == 1 && snapshot.apps.count == 1 && snapshot.websites.count == 1)
        #expect(snapshot.socialAccounts.count == 2 && snapshot.content.count == 2)
        let post = try #require(snapshot.content.first { $0.id == "content-beacon-social" })
        #expect(post.status == .draft && post.sourceContentId == "content-beacon-article")
        #expect(snapshot.socialDestinationSelection(for: post).selectedAccountIDs.count == 2)
        #expect(post.destinations.allSatisfy { $0.status == .draft })
        for path in [post.originalBodyPath] + post.destinations.map(\.bodyPath) {
            if let path { #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Content/beacon-social/" + path).path)) }
        }
    }

    @Test func olderMarkedReferenceGetsSeparateUpdateWithoutChangingOriginal() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(rootURL: root)
        _ = try await store.createWorkspace(at: root)
        let original = Data("<!-- Indie Dev Buddy guidance version: 0 -->\nCustom notes\n".utf8)
        let path = root.appendingPathComponent("docs/DATA_FORMAT.md")
        try original.write(to: path)
        _ = try await store.load()
        let update = root.appendingPathComponent("docs/DATA_FORMAT.v1.md")
        let updated = try Data(contentsOf: update)
        #expect(try Data(contentsOf: path) == original)
        _ = try await store.load()
        #expect(try Data(contentsOf: update) == updated)
    }

}
