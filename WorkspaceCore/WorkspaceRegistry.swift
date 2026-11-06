import Foundation

/// Uses the existing path-keyed registry. Direct distribution needs only the paths.
nonisolated enum WorkspaceRegistry {
    private static let prefix = "workspace:"

    static func workspaces() throws -> [URL] {
        try entries().keys.compactMap { key in
            guard key.hasPrefix(prefix) else { return nil }
            return URL(fileURLWithPath: String(key.dropFirst(prefix.count)))
        }.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
    }

    static func addWorkspace(_ url: URL) throws {
        var values = try entries()
        let key = prefix + url.standardizedFileURL.path
        if values[key] == nil { values[key] = Data() }
        try save(values)
    }

    static func removeWorkspace(_ url: URL) throws {
        var values = try entries()
        values.removeValue(forKey: prefix + url.standardizedFileURL.path)
        try save(values)
    }

    static func bookmark(forKey key: String) throws -> Data? {
        if let bookmark = try entries()[key] { return bookmark }
        guard let legacy = UserDefaults.standard.data(forKey: key) else { return nil }
        try setBookmark(legacy, forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        return legacy
    }

    static func setBookmark(_ bookmark: Data, forKey key: String) throws {
        var values = try entries()
        values[key] = bookmark
        try save(values)
    }

    private static func entries() throws -> [String: Data] {
        let url = try registryURL()
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            let legacy = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Containers/com.bravenewdesign.Indie-Dev-Buddy/Data/Library/Application Support/Indie Dev Buddy/ExternalFileBookmarks.plist")
            do {
                data = try Data(contentsOf: legacy)
            } catch CocoaError.fileReadNoSuchFile {
                return [:]
            } catch CocoaError.fileReadNoPermission {
                // macOS can restrict access to the old sandbox container. Reopening
                // a workspace registers its path in the direct-distribution location.
                return [:]
            }
        }
        guard var entries = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Data] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        if let bookmark = entries.removeValue(forKey: "workspaceBookmark") {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &stale) {
                entries[prefix + url.standardizedFileURL.path] = Data()
            }
        }
        return entries
    }

    private static func save(_ values: [String: Data]) throws {
        let url = try registryURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
        try data.write(to: url, options: .atomic)
    }

    private static func registryURL() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            .appendingPathComponent("Indie Dev Buddy/ExternalFileBookmarks.plist")
    }
}
