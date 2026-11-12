import Darwin
import Foundation

@main
struct IndieDevBuddyCLI {
    private static let help = """
    Indie Dev Buddy workspace CLI

      indiedevbuddy workspaces
      indiedevbuddy list <identities|apps|websites|accounts|content> --workspace PATH
      indiedevbuddy read <category> ID --workspace PATH
      indiedevbuddy create <blog|social|idea> --workspace PATH --title TITLE --body-file FILE
          [--app ID ...] [--website ID] [--source ID] [--account ID ...]
      indiedevbuddy update ID --workspace PATH --revision HASH [--title TITLE]
          [--body-file FILE --body-revision HASH]
      indiedevbuddy save-record <category> ID --workspace PATH --record-file FILE [--revision HASH]
          [--file WORKSPACE_PATH=SOURCE_FILE --file-revision WORKSPACE_PATH=HASH|new ...]
      indiedevbuddy delete <category> ID --workspace PATH --revision HASH
      indiedevbuddy create-workspace PATH [--name NAME]
      indiedevbuddy register-workspace PATH
      indiedevbuddy forget-workspace PATH
      indiedevbuddy files --workspace PATH [--path RELATIVE_FOLDER]
      indiedevbuddy mkdir --workspace PATH --path RELATIVE_FOLDER
      indiedevbuddy import-file --workspace PATH --source FILE --path RELATIVE_PATH
      indiedevbuddy rename --workspace PATH --path RELATIVE_PATH --name NEW_NAME
      indiedevbuddy remove --workspace PATH --path RELATIVE_PATH --confirm yes
      indiedevbuddy trash --workspace PATH --path RELATIVE_PATH --confirm yes
      indiedevbuddy validate --workspace PATH

    Use workspaces to get a registered path or pass an existing workspace folder.
    Use read to obtain the record and body revisions before updating. save-record
    creates a model record when --revision is omitted, or replaces it when the
    current --revision is supplied. JSON must contain the stable record ID. Content
    relationship, body, and asset references are validated before persistence.
    For content, --file and --file-revision pairs atomically replace referenced
    destination-variant or media files; read returns their paths and revisions.
    delete permanently removes the record folder and requires its current revision.
    File commands use workspace-relative paths. remove recursively and permanently
    deletes a managed item and requires --confirm yes; marker files are protected.
    Use the app's Asset Library to change managed assets and screenshot sets.
    validate checks workspace records and Asset Library references.
    create-workspace creates the standard workspace structure and registers it.
    update edits the title and/or original body; related destination state can be
    changed with save-record using the full record JSON from read.
    FILE is a UTF-8 file or "-" to read standard input. Quote paths with spaces.
    Update backups mirror the original paths under the returned backupDirectory.
    Commands emit JSON to stdout. Errors emit JSON to stderr and exit 1.
    Validation issues emit JSON to stdout and exit 2. Use --help for this guide.
    """

    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments.isEmpty || arguments == ["--help"] || arguments == ["-h"]
                || (arguments.count == 2 && arguments[1] == "--help") {
                print(help)
                return
            }
            try await run(arguments)
        } catch {
            var result = ["error": error.localizedDescription]
            if case WorkspaceStoreError.conflict(let path, let revision) = error {
                result["code"] = "conflict"
                result["path"] = path
                result["currentRevision"] = revision
            }
            try? writeJSON(result, to: .standardError)
            exit(1)
        }
    }

    private static func run(_ arguments: [String]) async throws {
        let command = arguments[0]
        if command == "workspaces" {
            guard arguments.count == 1 else { throw WorkspaceCommandError("workspaces takes no arguments.") }
            var results: [[String: Any]] = []
            for url in try WorkspaceRegistry.workspaces() {
                var result: [String: Any] = ["path": url.path, "name": url.lastPathComponent]
                do {
                    let manifest = try await WorkspaceStore(rootURL: url).readManifest()
                    result["name"] = manifest.name
                    result["id"] = manifest.id
                    result["available"] = true
                } catch {
                    result["available"] = false
                    result["error"] = error.localizedDescription
                }
                results.append(result)
            }
            try writeJSON(results)
            return
        }
        let requiredPositionals: Int
        let allowed: Set<String>
        switch command {
        case "list": (requiredPositionals, allowed) = (1, ["workspace"])
        case "read": (requiredPositionals, allowed) = (2, ["workspace"])
        case "create": (requiredPositionals, allowed) = (1, ["workspace", "title", "body-file", "app", "website", "source", "account"])
        case "update": (requiredPositionals, allowed) = (1, ["workspace", "revision", "title", "body-file", "body-revision"])
        case "save-record": (requiredPositionals, allowed) = (2, ["workspace", "record-file", "revision", "file", "file-revision"])
        case "delete": (requiredPositionals, allowed) = (2, ["workspace", "revision"])
        case "create-workspace": (requiredPositionals, allowed) = (1, ["name"])
        case "register-workspace", "forget-workspace": (requiredPositionals, allowed) = (1, [])
        case "files": (requiredPositionals, allowed) = (0, ["workspace", "path"])
        case "mkdir": (requiredPositionals, allowed) = (0, ["workspace", "path"])
        case "import-file": (requiredPositionals, allowed) = (0, ["workspace", "source", "path"])
        case "rename": (requiredPositionals, allowed) = (0, ["workspace", "path", "name"])
        case "remove": (requiredPositionals, allowed) = (0, ["workspace", "path", "confirm"])
        case "trash": (requiredPositionals, allowed) = (0, ["workspace", "path", "confirm"])
        case "validate": (requiredPositionals, allowed) = (0, ["workspace"])
        default: throw WorkspaceCommandError("Unknown command \(command). Run indiedevbuddy --help.")
        }
        let positionals = Array(arguments.dropFirst().prefix(requiredPositionals))
        guard positionals.count == requiredPositionals, positionals.allSatisfy({ !$0.hasPrefix("--") }) else {
            throw WorkspaceCommandError("Missing positional arguments for \(command). Run indiedevbuddy --help.")
        }
        let options = try Options(Array(arguments.dropFirst(1 + requiredPositionals)), allowed: allowed)
        if command == "create-workspace" {
            let root = URL(fileURLWithPath: positionals[0], isDirectory: true)
            let workspaceStore = WorkspaceStore(rootURL: root)
            let manifest = try await workspaceStore.createWorkspace(at: root, name: options["name"] ?? "Indie Dev Buddy Workspace")
            try WorkspaceRegistry.addWorkspace(root)
            try writeJSON(["created": true, "path": root.standardizedFileURL.path, "manifest": ["id": manifest.id, "name": manifest.name, "schemaVersion": manifest.schemaVersion]])
            return
        }
        if command == "register-workspace" || command == "forget-workspace" {
            let root = URL(fileURLWithPath: positionals[0], isDirectory: true).standardizedFileURL
            if command == "register-workspace" {
                _ = try await WorkspaceStore(rootURL: root).readManifest()
                try WorkspaceRegistry.addWorkspace(root)
                try writeJSON(["registered": true, "path": root.path])
            } else {
                try WorkspaceRegistry.removeWorkspace(root)
                try writeJSON(["forgotten": true, "path": root.path, "filesDeleted": false])
            }
            return
        }
        let workspace = try options.require("workspace")
        guard !workspace.isEmpty else { throw WorkspaceCommandError("--workspace requires a folder path.") }
        let store = WorkspaceStore(rootURL: URL(fileURLWithPath: workspace, isDirectory: true))
        switch command {
        case "list":
            let kind = try recordKind(positionals[0])
            let snapshot = try await store.load(installAgentGuidance: false)
            let records: Data
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            switch kind {
            case .identities: records = try encoder.encode(snapshot.identities)
            case .apps: records = try encoder.encode(snapshot.apps)
            case .websites: records = try encoder.encode(snapshot.websites)
            case .accounts: records = try encoder.encode(snapshot.socialAccounts)
            case .content: records = try encoder.encode(snapshot.content)
            }
            try writeJSON(["records": try JSONSerialization.jsonObject(with: records), "issues": issuesJSON(snapshot.errors)])
        case "read":
            try writeRecord(await store.readRecord(recordKind(positionals[0]), id: positionals[1]))
        case "create":
            guard let kind = ContentKind(rawValue: positionals[0]) else {
                throw WorkspaceCommandError("Content kind must be blog, social, or idea.")
            }
            let record = ContentRecord.draft(kind: kind, title: try options.require("title"),
                appIDs: options.values["app"] ?? [], websiteID: options["website"], sourceID: options["source"],
                accountIDs: options.values["account"] ?? [])
            try writeRecord(await store.createContent(record, body: readBody(options.require("body-file"))))
        case "update":
            if options["body-revision"] != nil && options["body-file"] == nil {
                throw WorkspaceCommandError("--body-revision requires --body-file.")
            }
            let body = try options["body-file"].map(readBody)
            try writeRecord(await store.updateContent(id: positionals[0], title: options["title"], body: body,
                expectedRevision: options.require("revision"), expectedBodyRevision: options["body-revision"]))
        case "save-record":
            let kind = try recordKind(positionals[0])
            let id = positionals[1]
            let revision = options["revision"]
            if revision == "new" { throw WorkspaceCommandError("For a new record, omit --revision. For an existing record, pass the current hash, not 'new'.") }
            let json = try Data(contentsOf: URL(fileURLWithPath: options.require("record-file")))
            let writes = try fileWriteOperations(options)
            try writeRecord(try await store.saveRecord(kind, id: id, json: json, expectedRevision: revision, fileWrites: writes))
        case "delete":
            let kind = try recordKind(positionals[0])
            let folder = try await store.deleteRecord(kind, id: positionals[1], expectedRevision: options.require("revision"))
            try writeJSON(["deleted": true, "id": positionals[1], "category": kind.rawValue, "folder": folder])
        case "files":
            let items = try await store.listItems(relativePath: options["path"] ?? "")
            try writeJSON(["items": items.map { item -> [String: Any] in
                var value: [String: Any] = ["name": item.name, "path": item.path, "isDirectory": item.isDirectory]
                value["revision"] = item.revision
                return value
            }])
        case "mkdir":
            let path = try options.require("path")
            try await store.createFolder(relativePath: path)
            try writeJSON(["created": true, "path": path])
        case "import-file":
            let path = try options.require("path")
            let revision = try await store.importFile(from: URL(fileURLWithPath: options.require("source")), to: path)
            try writeJSON(["imported": true, "path": path, "revision": revision])
        case "rename":
            let path = try options.require("path")
            let newPath = try await store.renameItem(relativePath: path, newName: options.require("name"))
            try writeJSON(["renamed": true, "path": path, "newPath": newPath])
        case "remove":
            guard try options.require("confirm") == "yes" else { throw WorkspaceCommandError("Permanent removal requires --confirm yes.") }
            let path = try options.require("path")
            try await store.removeManagedItem(relativePath: path)
            try writeJSON(["removed": true, "path": path])
        case "trash":
            guard try options.require("confirm") == "yes" else { throw WorkspaceCommandError("Moving an item to the Trash requires --confirm yes.") }
            let path = try options.require("path")
            try await store.trashManagedItem(relativePath: path)
            try writeJSON(["trashed": true, "path": path])
        case "validate":
            let issues = try await store.validateWorkspace()
            try writeJSON(["valid": issues.isEmpty, "issues": issuesJSON(issues)])
            if !issues.isEmpty { exit(2) }
        default: break
        }
    }

    private static func recordKind(_ value: String) throws -> WorkspaceRecordKind {
        guard let kind = WorkspaceRecordKind(rawValue: value) else {
            throw WorkspaceCommandError("Unknown record category \(value). Choose identities, apps, websites, accounts, or content.")
        }
        return kind
    }

    private static func readBody(_ file: String) throws -> String {
        let data = file == "-" ? FileHandle.standardInput.readDataToEndOfFile() : try Data(contentsOf: URL(fileURLWithPath: file))
        guard let text = String(data: data, encoding: .utf8) else { throw WorkspaceCommandError("Body input must be UTF-8.") }
        return text
    }

    private static func fileWriteOperations(_ options: Options) throws -> [WorkspaceWriteOperation] {
        let files = try options.values["file", default: []].map { try parsePair($0, option: "--file") }
        let revisions = try options.values["file-revision", default: []].map { try parsePair($0, option: "--file-revision") }
        var expected: [String: String] = [:]
        for (path, revision) in revisions {
            guard expected[path] == nil else { throw WorkspaceCommandError("Duplicate --file-revision for \(path).") }
            expected[path] = revision == "new" ? "" : revision
        }
        var seen = Set<String>()
        return try files.map { path, source in
            guard seen.insert(path).inserted else { throw WorkspaceCommandError("Duplicate --file target \(path).") }
            guard let revision = expected.removeValue(forKey: path) else { throw WorkspaceCommandError("--file \(path) requires a matching --file-revision PATH=HASH or PATH=new.") }
            let data = try Data(contentsOf: URL(fileURLWithPath: source))
            return WorkspaceWriteOperation(data: data, relativePath: path, expectedRevision: revision.isEmpty ? nil : revision)
        }.alsoCheckNoUnusedRevisions(expected)
    }

    private static func parsePair(_ value: String, option: String) throws -> (String, String) {
        guard let separator = value.firstIndex(of: "="), separator != value.startIndex else {
            throw WorkspaceCommandError("\(option) requires PATH=VALUE.")
        }
        return (String(value[..<separator]), String(value[value.index(after: separator)...]))
    }

    private static func issuesJSON(_ issues: [WorkspaceFileError]) -> [[String: String]] {
        issues.map { ["path": $0.path, "message": $0.message] }
    }

    private static func writeRecord(_ result: WorkspaceRecordRead) throws {
        var object: [String: Any] = [
            "record": try JSONSerialization.jsonObject(with: result.data), "path": result.path, "revision": result.revision
        ]
        object["body"] = result.body
        object["bodyRevision"] = result.bodyRevision
        object["relatedFiles"] = result.relatedFiles.map { file -> [String: Any] in
            var value: [String: Any] = ["path": file.path, "revision": file.revision]
            value["text"] = file.text
            return value
        }
        object["backupDirectory"] = result.backupDirectory
        try writeJSON(object)
    }

    private static func writeJSON(_ object: Any, to handle: FileHandle = .standardOutput) throws {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(10)
        try handle.write(contentsOf: data)
    }

    private struct Options {
        var values: [String: [String]] = [:]

        init(_ arguments: [String], allowed: Set<String>) throws {
            var iterator = arguments.makeIterator()
            while let option = iterator.next() {
                let key = String(option.dropFirst(2))
                guard option.hasPrefix("--"), allowed.contains(key) else { throw WorkspaceCommandError("Unexpected option \(option). Run indiedevbuddy --help.") }
                guard let value = iterator.next() else { throw WorkspaceCommandError("\(option) requires a value.") }
                guard values[key] == nil || ["app", "account", "file", "file-revision"].contains(key) else {
                    throw WorkspaceCommandError("\(option) can only be specified once.")
                }
                values[key, default: []].append(value)
            }
        }

        subscript(key: String) -> String? { values[key]?.first }

        func require(_ key: String) throws -> String {
            guard let value = self[key] else { throw WorkspaceCommandError("Missing --\(key). Run indiedevbuddy --help.") }
            return value
        }
    }
}

private extension Array where Element == WorkspaceWriteOperation {
    func alsoCheckNoUnusedRevisions(_ revisions: [String: String]) throws -> [WorkspaceWriteOperation] {
        guard revisions.isEmpty else { throw WorkspaceCommandError("--file-revision supplied without a matching --file for \(revisions.keys.sorted().joined(separator: ", ")).") }
        return self
    }
}
