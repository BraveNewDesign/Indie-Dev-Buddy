import Foundation

nonisolated struct ASCAppSummary: Sendable, Equatable, Identifiable {
    let id: String
    let name: String
    let bundleID: String
    let primaryLocale: String?

    var listingURL: URL? { URL(string: "https://apps.apple.com/app/id\(id)") }
    var pickerTitle: String {
        bundleID.isEmpty ? name : "\(name) · \(bundleID)"
    }
}

nonisolated struct ASCImportSelection: Sendable {
    var name = true
    var bundleID = true
    var listingURL = true
}

nonisolated enum ASCIntegrationError: LocalizedError {
    case invalidResponse
    case appNotFound
    case projectUnavailable
    case processFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "The asc command returned data Indie Dev Buddy couldn’t read."
        case .appNotFound:
            "No matching App Store Connect app was found. Check the bundle ID and the asc account."
        case .projectUnavailable:
            "The linked project location is unavailable. Relink it before generating notes."
        case .processFailed:
            "The asc command failed."
        }
    }
}

nonisolated enum ASCIntegration {
    static func installedExecutable() -> URL? {
        let manager = FileManager.default
        let home = manager.homeDirectoryForCurrentUser
        let commonPaths = [
            home.appendingPathComponent(".local/bin/asc").path,
            "/opt/homebrew/bin/asc",
            "/usr/local/bin/asc",
            "/usr/bin/asc"
        ]
        let environmentPaths = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0), isDirectory: true).appendingPathComponent("asc").path }
        return (commonPaths + environmentPaths)
            .first(where: { manager.isExecutableFile(atPath: $0) })
            .map { URL(fileURLWithPath: $0) }
    }

    static func findApps(executablePath: String, bundleIDs: [String], name: String) async throws -> [ASCAppSummary] {
        var arguments = ["apps", "list"]
        let ids = bundleIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !ids.isEmpty {
            arguments += ["--bundle-id", ids.joined(separator: ",")]
        } else if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments += ["--name", name]
        }
        arguments += ["--paginate", "--output", "json"]
        let data = try await run(executablePath: executablePath, arguments: arguments)
        let summaries = try decodeApps(data)
        if !summaries.isEmpty { return summaries }

        if !ids.isEmpty, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let fallback = try await run(executablePath: executablePath, arguments: [
                "apps", "list", "--name", name, "--paginate", "--output", "json"
            ])
            return try decodeApps(fallback)
        }
        return []
    }

    static func generateReleaseNotes(executablePath: String, projectPath: String, sinceReference: String) async throws -> String {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: projectPath, isDirectory: &isDirectory) else {
            throw ASCIntegrationError.projectUnavailable
        }
        let workingDirectory = isDirectory.boolValue ? projectPath : URL(fileURLWithPath: projectPath).deletingLastPathComponent().path
        let data = try await run(
            executablePath: executablePath,
            arguments: ["release-notes", "generate", "--since-ref", sinceReference, "--until-ref", "HEAD", "--max-chars", "4000", "--output", "markdown"],
            workingDirectory: workingDirectory
        )
        let draft = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.isEmpty else { throw ASCIntegrationError.invalidResponse }
        return draft
    }

    static func run(executablePath: String, arguments: [String], workingDirectory: String? = nil) async throws -> Data {
        let command = ASCCommand()
        return try await withTaskCancellationHandler {
            let task = Task.detached(priority: .userInitiated) {
                try execute(command: command, executablePath: executablePath, arguments: arguments, workingDirectory: workingDirectory)
            }
            let data = try await task.value
            try Task.checkCancellation()
            return data
        } onCancel: {
            command.cancel()
        }
    }

    static func userMessage(for error: Error) -> String {
        guard case ASCIntegrationError.processFailed(let detail) = error else {
            if error is DecodingError { return ASCIntegrationError.invalidResponse.localizedDescription }
            return error.localizedDescription
        }
        let message = detail.lowercased()
        if message.contains("403") || message.contains("forbidden") || message.contains("insufficient permissions") {
            return "The current asc credentials don’t have permission to read this information."
        }
        if message.contains("401") || message.contains("unauthorized") || message.contains("credentials") || message.contains("auth login") {
            return "App Store Connect authentication is required. Check your asc profile in Terminal."
        }
        if message.contains("unknown command") || message.contains("flag provided but not defined") || message.contains("unknown flag") {
            return "This asc version doesn’t support the command. Update asc or choose a newer executable."
        }
        if message.contains("timeout") || message.contains("deadline exceeded") || message.contains("network") || message.contains("no such host") {
            return "Couldn’t reach App Store Connect. Check your connection and try again."
        }
        if message.contains("404") || message.contains("not found") {
            return "App Store Connect couldn’t find this resource with the current asc profile."
        }
        return "The asc command failed. Check the executable and active asc profile, then try again."
    }

    private static func execute(command: ASCCommand, executablePath: String, arguments: [String], workingDirectory: String?) throws -> Data {
        let process = Process()
        let output = Pipe()
        let errorURL = FileManager.default.temporaryDirectory.appendingPathComponent("IndieDevBuddy-ASC-error-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: errorURL.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let errorFile = try? FileHandle(forWritingTo: errorURL) else {
            throw ASCIntegrationError.processFailed("Could not prepare a temporary error log for asc.")
        }
        defer {
            try? errorFile.close()
            try? FileManager.default.removeItem(at: errorURL)
        }
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["--read-only"] + arguments
        process.environment = ProcessInfo.processInfo.environment.merging(["ASC_READ_ONLY": "1"]) { _, new in new }
        if let workingDirectory { process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true) }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errorFile
        do {
            try command.start(process)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ASCIntegrationError.processFailed("Could not start asc: \(error.localizedDescription)")
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try command.checkCancellation()
        guard process.terminationStatus == 0 else {
            try? errorFile.synchronize()
            let errorData = try? Data(contentsOf: errorURL)
            let detail = String(decoding: errorData ?? Data(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            // validate writes its structured findings even when a blocking finding produces exit 1.
            if arguments.first == "validate", process.terminationStatus == 1,
               detail.contains("validate: found"), detail.contains("blocking issue"), !data.isEmpty {
                return data
            }
            throw ASCIntegrationError.processFailed(detail.isEmpty ? "asc exited with code \(process.terminationStatus)." : detail)
        }
        return data
    }

    private static func decodeApps(_ data: Data) throws -> [ASCAppSummary] {
        struct Attributes: Decodable, Sendable {
            let name: String
            let bundleId: String?
            let primaryLocale: String?
        }

        let result = try JSONDecoder().decode(ASCResourceList<Attributes>.self, from: data)
        return result.data.map {
            ASCAppSummary(id: $0.id, name: $0.attributes.name,
                          bundleID: $0.attributes.bundleId ?? "", primaryLocale: $0.attributes.primaryLocale)
        }
    }
}


/// Serializes launch and cancellation so navigation can stop an in-flight CLI process.
private nonisolated final class ASCCommand: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func start(_ process: Process) throws {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        try process.run()
        self.process = process
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        if let process, process.isRunning { process.terminate() }
    }

    func checkCancellation() throws {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { throw CancellationError() }
    }
}
