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
      indiedevbuddy validate --workspace PATH

    Use workspaces to get a registered path or pass an existing workspace folder.
    Use read to obtain the record and body revisions before updating. Updates edit
    the title and/or original body. Account variants and media are preserved.
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
        case "validate": (requiredPositionals, allowed) = (0, ["workspace"])
        default: throw WorkspaceCommandError("Unknown command \(command). Run indiedevbuddy --help.")
        }
        let positionals = Array(arguments.dropFirst().prefix(requiredPositionals))
        guard positionals.count == requiredPositionals, positionals.allSatisfy({ !$0.hasPrefix("--") }) else {
            throw WorkspaceCommandError("Missing positional arguments for \(command). Run indiedevbuddy --help.")
        }
        let options = try Options(Array(arguments.dropFirst(1 + requiredPositionals)), allowed: allowed)
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

    private static func issuesJSON(_ issues: [WorkspaceFileError]) -> [[String: String]] {
        issues.map { ["path": $0.path, "message": $0.message] }
    }

    private static func writeRecord(_ result: WorkspaceRecordRead) throws {
        var object: [String: Any] = [
            "record": try JSONSerialization.jsonObject(with: result.data), "path": result.path, "revision": result.revision
        ]
        object["body"] = result.body
        object["bodyRevision"] = result.bodyRevision
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
                guard values[key] == nil || key == "app" || key == "account" else {
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
