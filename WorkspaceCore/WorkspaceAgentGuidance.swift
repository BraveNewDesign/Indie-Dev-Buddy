import Foundation

nonisolated struct WorkspaceGuidanceEntry: Codable, Identifiable, Sendable {
    enum Status: String, Codable, Sendable {
        case current, updateAvailable, customized, installed, missing, archived, unavailable
    }

    var id: String { path }
    let path: String
    let skillFolder: String?
    let builtIn: Bool
    let status: Status
    var text: String? = nil
    var revision: String? = nil
    var replacement: String? = nil
    var additionalInstructions: String? = nil
    var issue: String? = nil
}

nonisolated struct WorkspaceInstructionsChange: Codable, Sendable {
    let before: String
    let after: String
    let revision: String?
}

nonisolated struct WorkspaceGuidanceInventory: Codable, Sendable {
    let files: [WorkspaceGuidanceEntry]
    let issues: [String]
}

extension WorkspaceStore {
    func agentGuidance() throws -> WorkspaceGuidanceInventory {
        try withWorkspaceLock(exclusive: false) {
            _ = try readManifest()
            var issues: [String] = []
            var active: Set<String> = []
            var archived: Set<String> = []
            do { active = try guidanceSkillFolders(in: WorkspaceGuidance.skillsFolder) }
            catch { issues.append("\(WorkspaceGuidance.skillsFolder): \(error.localizedDescription)") }
            do { archived = try guidanceSkillFolders(in: WorkspaceGuidance.archiveFolder) }
            catch { issues.append("\(WorkspaceGuidance.archiveFolder): \(error.localizedDescription)") }

            var files = WorkspaceGuidance.files.filter { $0.path != WorkspaceGuidance.builtInSkillPath }
                .map { guidanceEntry(path: $0.path, template: $0.contents) }
            let versionedReference = guidanceEntry(path: WorkspaceGuidance.versionedDataFormatPath,
                                                   template: WorkspaceGuidance.dataFormat)
            if versionedReference.status != .missing { files.append(versionedReference) }
            let skills = active.union(archived).union([WorkspaceGuidance.builtInSkill])
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            for skill in skills {
                let path = "\(WorkspaceGuidance.skillsFolder)/\(skill)/SKILL.md"
                let template = WorkspaceGuidance.files.first { $0.path == path }?.contents
                let isArchived = archived.contains(skill) && !active.contains(skill)
                var entry = guidanceEntry(path: path, template: template, skillFolder: skill, archived: isArchived)
                if active.contains(skill), archived.contains(skill) {
                    entry.issue = "A skill with this folder name exists in both the workspace and the archive."
                }
                files.append(entry)
            }
            return WorkspaceGuidanceInventory(files: files, issues: issues)
        }
    }

    func previewAdditionalInstructions(_ text: String, expectedRevision: String?) throws -> WorkspaceInstructionsChange {
        try withWorkspaceLock(exclusive: false) {
            _ = try readManifest()
            return try instructionsChange(text, expectedRevision: expectedRevision)
        }
    }

    func saveAdditionalInstructions(_ text: String, expectedRevision: String?) throws -> String? {
        try withWorkspaceLock {
            _ = try readManifest()
            let change = try instructionsChange(text, expectedRevision: expectedRevision)
            let newData = Data(change.after.utf8)
            guard newData != Data(change.before.utf8) else { return change.revision }
            return try applyWrites([.init(data: newData, relativePath: WorkspaceGuidance.instructionsPath,
                                          expectedRevision: change.revision)])[0]
        }
    }

    func updateAgentGuidance(path: String, expectedRevision: String?) throws -> String {
        try withWorkspaceLock {
            _ = try readManifest()
            guard let template = WorkspaceGuidance.files.first(where: { $0.path == path })?.contents else {
                throw WorkspaceCommandError("Choose a built-in guidance file shown by the guidance command.")
            }
            if path == WorkspaceGuidance.builtInSkillPath,
               try guidanceItemExists("\(WorkspaceGuidance.archiveFolder)/\(WorkspaceGuidance.builtInSkill)") {
                throw WorkspaceCommandError("Restore the archived skill before updating it.")
            }
            let entry = guidanceEntry(path: path, template: template)
            if let issue = entry.issue { throw WorkspaceCommandError(issue) }
            try requireGuidanceRevision(expectedRevision, current: entry.revision, path: path)
            guard let replacement = entry.replacement else {
                throw WorkspaceCommandError("This file is current or contains customized guidance. Review its contents before editing.")
            }
            return try applyWrites([.init(data: Data(replacement.utf8), relativePath: path,
                                          expectedRevision: expectedRevision)])[0]
        }
    }

    func setGuidanceSkillArchived(_ skill: String, archived: Bool, expectedRevision: String) throws {
        try withWorkspaceLock {
            _ = try readManifest()
            try validateGuidanceSkillFolder(skill)
            let active = "\(WorkspaceGuidance.skillsFolder)/\(skill)"
            let archive = "\(WorkspaceGuidance.archiveFolder)/\(skill)"
            let source = archived ? active : archive
            let destination = archived ? archive : active
            let sourceURL = try guidanceURL(source)
            let targetURL = try guidanceURL(destination)
            let file = try guidanceText(at: "\(source)/SKILL.md")
            try requireGuidanceRevision(expectedRevision, current: file?.revision, path: "\(source)/SKILL.md")
            let manager = FileManager.default
            guard !manager.fileExists(atPath: targetURL.path) else {
                throw WorkspaceCommandError("A skill named \(skill) already exists at \(destination).")
            }
            try manager.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.moveItem(at: sourceURL, to: targetURL)
        }
    }

    func importGuidanceSkill(from source: URL) throws -> String {
        try withWorkspaceLock {
            _ = try readManifest()
            let skill = source.lastPathComponent
            try validateGuidanceSkillFolder(skill)
            guard skill.caseInsensitiveCompare(WorkspaceGuidance.builtInSkill) != .orderedSame else {
                throw WorkspaceCommandError("Choose a folder name that differs from the built-in skill.")
            }
            let path = "\(WorkspaceGuidance.skillsFolder)/\(skill)"
            let target = try guidanceURL(path)
            guard try !guidanceItemExists(path), try !guidanceItemExists("\(WorkspaceGuidance.archiveFolder)/\(skill)") else {
                throw WorkspaceCommandError("A skill named \(skill) already exists in this workspace or its archive.")
            }
            let resolvedSource = source.standardizedFileURL.resolvingSymlinksInPath()
            let parent = target.deletingLastPathComponent()
            let staging = try guidanceURL("\(WorkspaceGuidance.archiveFolder)/.import-\(UUID().uuidString)")
            let sourcePrefix = resolvedSource.path.hasSuffix("/") ? resolvedSource.path : resolvedSource.path + "/"
            guard [target, staging].allSatisfy({
                $0.path.range(of: sourcePrefix, options: [.anchored, .caseInsensitive]) == nil
            }) else {
                throw WorkspaceCommandError("Choose a skill folder that does not contain the workspace’s guidance directories.")
            }
            let manager = FileManager.default
            try manager.createDirectory(at: staging.deletingLastPathComponent(), withIntermediateDirectories: true)
            defer { try? manager.removeItem(at: staging) }
            try copyGuidanceSkillFolder(from: source, to: staging)
            let file = staging.appendingPathComponent("SKILL.md")
            guard let text = try? String(contentsOf: file, encoding: .utf8), validSkillFrontMatter(text) else {
                throw WorkspaceCommandError("A skill folder needs a UTF-8 SKILL.md with name and description in its front matter.")
            }

            try manager.createDirectory(at: parent, withIntermediateDirectories: true)
            try manager.moveItem(at: staging, to: target)
            return "\(path)/SKILL.md"
        }
    }

    private func guidanceEntry(path: String, template: String?, skillFolder: String? = nil,
                               archived: Bool = false) -> WorkspaceGuidanceEntry {
        let actualPath = if archived, let skillFolder {
            "\(WorkspaceGuidance.archiveFolder)/\(skillFolder)/SKILL.md"
        } else {
            path
        }
        do {
            guard let file = try guidanceText(at: actualPath) else {
                if archived {
                    return .init(path: actualPath, skillFolder: skillFolder, builtIn: template != nil,
                                 status: .unavailable, issue: "The archived folder is missing SKILL.md.")
                }
                return .init(path: path, skillFolder: skillFolder, builtIn: template != nil,
                             status: .missing, replacement: template)
            }
            if archived {
                return .init(path: actualPath, skillFolder: skillFolder, builtIn: template != nil,
                             status: .archived, text: file.text, revision: file.revision)
            }
            let parts: (base: String, additional: String?)
            do {
                parts = path == WorkspaceGuidance.instructionsPath ? try splitInstructions(file.text) : (file.text, nil)
            } catch {
                return .init(path: path, skillFolder: skillFolder, builtIn: template != nil, status: .unavailable,
                             text: file.text, revision: file.revision, issue: error.localizedDescription)
            }
            let (base, additional) = parts
            let status: WorkspaceGuidanceEntry.Status
            var replacement: String?
            if let template {
                if base == template {
                    status = .current
                } else if WorkspaceGuidance.priorRevisions[path]?.contains(Self.revision(Data(base.utf8))) == true {
                    status = .updateAvailable
                    replacement = renderedInstructions(base: template, additional: additional ?? "")
                } else {
                    status = .customized
                }
            } else {
                status = .installed
            }
            return .init(path: path, skillFolder: skillFolder, builtIn: template != nil, status: status,
                         text: file.text, revision: file.revision, replacement: replacement,
                         additionalInstructions: additional)
        } catch {
            return .init(path: actualPath, skillFolder: skillFolder, builtIn: template != nil,
                         status: .unavailable, issue: error.localizedDescription)
        }
    }

    private func instructionsChange(_ additional: String, expectedRevision: String?) throws -> WorkspaceInstructionsChange {
        let path = WorkspaceGuidance.instructionsPath
        let file = try guidanceText(at: path)
        try requireGuidanceRevision(expectedRevision, current: file?.revision, path: path)
        let before = file?.text ?? ""
        let parts = try splitInstructions(file?.text ?? WorkspaceGuidance.agents)
        guard !additional.contains(WorkspaceGuidance.additionalStart), !additional.contains(WorkspaceGuidance.additionalEnd) else {
            throw WorkspaceCommandError("Additional instructions cannot contain Indie Dev Buddy’s section markers.")
        }
        let after = renderedInstructions(base: parts.base, additional: additional)
        return .init(before: before, after: after, revision: file?.revision)
    }

    private func splitInstructions(_ text: String) throws -> (base: String, additional: String?) {
        guard text.contains(WorkspaceGuidance.additionalStart) || text.contains(WorkspaceGuidance.additionalEnd) else {
            return (text, nil)
        }
        let bytes = Data(text.utf8)
        let start = Data("\n\n\(WorkspaceGuidance.additionalStart)\n".utf8)
        let end = "\n\(WorkspaceGuidance.additionalEnd)" + (bytes.last == 10 ? "\n" : "")
        let closing = Data(end.utf8)
        let endIndex = bytes.endIndex - closing.count
        guard let opening = bytes.range(of: start), opening.upperBound <= endIndex,
              bytes.suffix(closing.count) == closing else {
            throw WorkspaceCommandError("The additional instructions section has changed outside the app. Review its markers in AGENTS.md.")
        }
        let base = String(decoding: bytes[..<opening.lowerBound], as: UTF8.self)
        let additional = String(decoding: bytes[opening.upperBound..<endIndex], as: UTF8.self)
        guard !base.contains(WorkspaceGuidance.additionalStart), !base.contains(WorkspaceGuidance.additionalEnd),
              !additional.contains(WorkspaceGuidance.additionalStart), !additional.contains(WorkspaceGuidance.additionalEnd) else {
            throw WorkspaceCommandError("AGENTS.md contains duplicate additional instruction markers.")
        }
        return (base, additional)
    }

    private func renderedInstructions(base: String, additional: String) -> String {
        guard !additional.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return base }
        return "\(base)\n\n\(WorkspaceGuidance.additionalStart)\n\(additional)\n\(WorkspaceGuidance.additionalEnd)\n"
    }

    private func requireGuidanceRevision(_ expected: String?, current: String?, path: String) throws {
        guard expected == current else { throw WorkspaceStoreError.conflict(path: path, currentRevision: current) }
    }

    private func guidanceURL(_ path: String) throws -> URL {
        try rejectSymbolicLinks(path)
        let url = try safeURL(path)
        guard url.path == rootURL.appendingPathComponent(path).path else {
            throw WorkspaceStoreError.invalidRelativePath(path)
        }
        return url
    }

    private func guidanceItemExists(_ path: String) throws -> Bool {
        FileManager.default.fileExists(atPath: try guidanceURL(path).path)
    }

    private func guidanceText(at path: String) throws -> (text: String, revision: String)? {
        let url = try guidanceURL(path)
        let file: (data: Data, revision: String)
        do {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw WorkspaceStoreError.invalidRelativePath(path)
            }
            file = try read(relativePath: path)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        } catch CocoaError.fileNoSuchFile {
            return nil
        }
        guard let text = String(validating: file.data, as: UTF8.self) else {
            throw WorkspaceCommandError("\(path) is not UTF-8 text.")
        }
        return (text, file.revision)
    }

    private func guidanceSkillFolders(in path: String) throws -> Set<String> {
        let directory = try guidanceURL(path)
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
        } catch CocoaError.fileReadNoSuchFile {
            return []
        } catch CocoaError.fileNoSuchFile {
            return []
        }
        return try Set(entries.compactMap { entry in
            let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true || values.isSymbolicLink == true,
                  (try? validateGuidanceSkillFolder(entry.lastPathComponent)) != nil else { return nil }
            return entry.lastPathComponent
        })
    }

    private func validateGuidanceSkillFolder(_ name: String) throws {
        guard !name.isEmpty, !name.hasPrefix("."), name.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\:\0")) == nil else {
            throw WorkspaceStoreError.invalidRelativePath(name)
        }
    }

    private func copyGuidanceSkillFolder(from source: URL, to target: URL) throws {
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        let folder = try source.resourceValues(forKeys: keys)
        guard folder.isDirectory == true, folder.isSymbolicLink != true else {
            throw WorkspaceCommandError("Select a skill folder. Symbolic links cannot be imported.")
        }
        try manager.createDirectory(at: target, withIntermediateDirectories: false)
        for item in try manager.contentsOfDirectory(at: source, includingPropertiesForKeys: Array(keys)) {
            let values = try item.resourceValues(forKeys: keys)
            let destination = target.appendingPathComponent(item.lastPathComponent)
            if values.isSymbolicLink == true {
                throw WorkspaceCommandError("Symbolic links cannot be imported: \(item.lastPathComponent).")
            }
            if values.isDirectory == true {
                try copyGuidanceSkillFolder(from: item, to: destination)
            } else if values.isRegularFile == true {
                try manager.copyItem(at: item, to: destination)
            } else {
                throw WorkspaceCommandError("Unsupported file in skill folder: \(item.lastPathComponent).")
            }
        }
    }

    private func validSkillFrontMatter(_ text: String) -> Bool {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { return false }
        let frontMatter = lines[1..<end]
        return ["name:", "description:"].allSatisfy { key in
            frontMatter.contains { line in
                line.hasPrefix(key) && !line.dropFirst(key.count).trimmingCharacters(in: .whitespaces).isEmpty
            }
        }
    }
}
