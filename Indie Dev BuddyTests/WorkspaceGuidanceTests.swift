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
        let inventory = try await store.agentGuidance()
        #expect(inventory.files.contains { $0.path == WorkspaceGuidance.versionedDataFormatPath && $0.status == .current })
    }

    @Test func updatesReviewedOlderDefaultsAndPreservesAdditionalInstructions() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(rootURL: root)
        _ = try await store.createWorkspace(at: root)
        let legacy = #"""
        # Indie Dev Buddy workspace

        Guidance version 3. Workspace schema 1.

        ## AI agent workflow

        - Use `indiedevbuddy` for all supported workspace reads and changes. Run `indiedevbuddy --help`, then `indiedevbuddy workspaces`. Confirm the intended workspace and pass its exact path with `--workspace` on every workspace command.
        - Use `list` and `read` to resolve stable record IDs. Use `create` for blog, social, and idea drafts and `update` for titles and original bodies. Supply body text through stdin with `--body-file -` or through a temporary file outside the workspace.
        - Read the current record before updating. Pass the returned `revision` with `--revision` and, for body edits, `bodyRevision` with `--body-revision`. If a conflict occurs, reread and reconcile before retrying. Run `validate` after changes and report any issues and returned backup location.
        - Never write, patch, move, or delete managed workspace files directly, including record JSON, bodies, variants, media, and manifests. Shell commands, scripts, and editor tools must follow the same rule. If the CLI is unavailable or lacks the requested operation, stop and explain what needs to be done in the app. A validation error does not authorize a direct repair.
        - Use the marketing skill at `.agents/skills/indie-dev-buddy-content/SKILL.md` for drafts. Treat schema examples as reference. Keep credentials and secrets out of the workspace.
        """#
        let path = WorkspaceGuidance.instructionsPath
        let url = root.appendingPathComponent(path)
        try Data(legacy.utf8).write(to: url)
        _ = try await store.load()
        #expect(try String(contentsOf: url, encoding: .utf8) == legacy)

        let original = try await store.read(relativePath: path)
        _ = try await store.saveAdditionalInstructions("Use Canadian English.", expectedRevision: original.revision)
        let before = try await store.agentGuidance()
        let entry = try #require(before.files.first { $0.path == path })
        #expect(entry.status == .updateAvailable)
        #expect(entry.replacement?.contains("save-record") == true)
        #expect(entry.replacement?.contains("Use Canadian English.") == true)

        _ = try await store.updateAgentGuidance(path: path, expectedRevision: entry.revision)
        let after = try await store.agentGuidance()
        let upgraded = try #require(after.files.first { $0.path == path })
        #expect(upgraded.status == .current)
        #expect(upgraded.additionalInstructions == "Use Canadian English.")
        #expect(upgraded.text == entry.replacement)
    }

    @Test func additionalInstructionsPreviewPreservesCustomFileAndRejectsStaleWrites() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(rootURL: root)
        _ = try await store.createWorkspace(at: root)
        let url = root.appendingPathComponent(WorkspaceGuidance.instructionsPath)
        let custom = "\u{FEFF}# Studio rules\r\nKeep these exact bytes.\r"
        try Data(custom.utf8).write(to: url)
        let original = try await store.read(relativePath: WorkspaceGuidance.instructionsPath)
        let preview = try await store.previewAdditionalInstructions("Use short sentences.", expectedRevision: original.revision)
        #expect(preview.before == custom)
        #expect(preview.after.utf8.starts(with: custom.utf8))
        #expect(try Data(contentsOf: url) == Data(custom.utf8))

        let external = custom + "\nAdded in an editor.\n"
        try Data(external.utf8).write(to: url)
        await #expect(throws: WorkspaceStoreError.self) {
            try await store.saveAdditionalInstructions("Use short sentences.", expectedRevision: preview.revision)
        }
        #expect(try Data(contentsOf: url) == Data(external.utf8))

        let latest = try await store.read(relativePath: WorkspaceGuidance.instructionsPath)
        let saved = try await store.saveAdditionalInstructions("Use short sentences.\r", expectedRevision: latest.revision)
        let inventory = try await store.agentGuidance()
        #expect(inventory.files.first { $0.path == WorkspaceGuidance.instructionsPath }?.additionalInstructions == "Use short sentences.\r")
        _ = try await store.saveAdditionalInstructions("", expectedRevision: saved)
        #expect(try Data(contentsOf: url) == Data(external.utf8))
    }

    @Test func archiveSurvivesRefreshAndReopenAndRestoresCompleteSkill() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(rootURL: root)
        _ = try await store.createWorkspace(at: root)
        let path = WorkspaceGuidance.builtInSkillPath
        let supporting = root.appendingPathComponent(path).deletingLastPathComponent().appendingPathComponent("notes.md")
        let note = Data("Keep my supporting file.".utf8)
        try note.write(to: supporting)
        let installed = try await store.read(relativePath: path)
        #expect(String(decoding: installed.data, as: UTF8.self).contains("save-record content"))

        try await store.setGuidanceSkillArchived(WorkspaceGuidance.builtInSkill, archived: true,
                                                 expectedRevision: installed.revision)
        _ = try await store.refresh()
        let reopened = WorkspaceStore(rootURL: root)
        _ = try await reopened.load()
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path))
        let inventory = try await reopened.agentGuidance()
        let archived = try #require(inventory.files.first { $0.skillFolder == WorkspaceGuidance.builtInSkill })
        #expect(archived.status == .archived)
        #expect(archived.revision == installed.revision)

        try await reopened.setGuidanceSkillArchived(WorkspaceGuidance.builtInSkill, archived: false,
                                                    expectedRevision: installed.revision)
        #expect(try Data(contentsOf: supporting) == note)
        #expect(try Data(contentsOf: root.appendingPathComponent(path)) == installed.data)
    }

    @Test func importsFullLocalSkillAndRejectsCollisionsAndSymbolicLinks() async throws {
        let root = temporaryRoot()
        let source = temporaryRoot()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: source)
        }
        let store = WorkspaceStore(rootURL: root)
        _ = try await store.createWorkspace(at: root)
        let manager = FileManager.default
        let local = source.appendingPathComponent("studio-style")
        let broken = source.appendingPathComponent("linked-style")
        try manager.createDirectory(at: local.appendingPathComponent("references"), withIntermediateDirectories: true)
        try manager.createDirectory(at: broken, withIntermediateDirectories: true)
        let skill = Data("---\nname: studio-style\ndescription: Apply the studio style.\n---\n# Studio Style".utf8)
        let reference = Data("Voice and tone.".utf8)
        try skill.write(to: local.appendingPathComponent("SKILL.md"))
        try reference.write(to: local.appendingPathComponent("references/style.md"))
        try skill.write(to: broken.appendingPathComponent("SKILL.md"))
        try manager.createSymbolicLink(at: broken.appendingPathComponent("linked.md"),
                                       withDestinationURL: local.appendingPathComponent("references/style.md"))

        let path = try await store.importGuidanceSkill(from: local)
        let imported = root.appendingPathComponent(path).deletingLastPathComponent()
        #expect(try Data(contentsOf: imported.appendingPathComponent("references/style.md")) == reference)
        await #expect(throws: WorkspaceCommandError.self) { try await store.importGuidanceSkill(from: local) }
        await #expect(throws: WorkspaceCommandError.self) { try await store.importGuidanceSkill(from: broken) }
        let inventory = try await store.agentGuidance()
        #expect(inventory.files.contains { $0.path == path && $0.status == .installed && !$0.builtIn })
        #expect(!inventory.files.contains { $0.skillFolder == "linked-style" })
    }

    @Test func refreshLeavesMissingGuidanceForExplicitRepair() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(rootURL: root)
        _ = try await store.createWorkspace(at: root)
        let path = "docs/EXAMPLES.md"
        let url = root.appendingPathComponent(path)
        let original = try Data(contentsOf: url)
        try FileManager.default.removeItem(at: url)

        _ = try await store.refresh()
        let inventory = try await store.agentGuidance()
        let entry = try #require(inventory.files.first { $0.path == path })
        #expect(entry.status == .missing)
        #expect(entry.replacement != nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        _ = try await store.updateAgentGuidance(path: path, expectedRevision: nil)
        #expect(try Data(contentsOf: url) == original)
    }

}
