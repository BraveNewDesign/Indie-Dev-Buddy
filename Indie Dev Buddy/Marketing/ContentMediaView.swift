import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A reusable asset manager for a single content record's folder.
/// `assetPaths` are paths relative to `contentFolderURL` (for example `Assets/cover.png`).
struct ContentMediaView: View {
    let contentFolderURL: URL
    @Binding var assetPaths: [String]

    @State private var showingFilePicker = false
    @State private var isDropTargeted = false
    @State private var errorMessage: String?

    private var assetsFolderURL: URL {
        contentFolderURL.appendingPathComponent("Assets", isDirectory: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Media").font(.headline)
                Spacer()
                Button { showingFilePicker = true } label: { Label("Add Files", systemImage: "plus") }
                Button { pasteImage() } label: { Label("Paste Image", systemImage: "doc.on.clipboard") }
                Button { revealAssetsFolder() } label: { Label("Reveal Folder", systemImage: "folder") }
            }

            if assetPaths.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled").font(.largeTitle).foregroundStyle(.secondary)
                    Text("Add or paste images and files").font(.headline)
                    Text("Drop files here to copy them into this content folder.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 150)
                .contentShape(Rectangle())
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    ForEach(assetPaths, id: \.self) { relativePath in
                        mediaTile(relativePath)
                    }
                }
            }
        }
        .padding(14)
        .background(isDropTargeted ? Color.accentColor.opacity(0.08) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: isDropTargeted ? [] : [5, 4])))
        .dropDestination(for: URL.self) { urls, _ in
            importFiles(urls)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .dropDestination(for: Data.self) { dataItems, _ in
            let images = dataItems.filter { NSImage(data: $0) != nil }
            guard !images.isEmpty else { return false }
            images.forEach { importImageData($0) }
            return true
        } isTargeted: { isDropTargeted = $0 }
        .fileImporter(isPresented: $showingFilePicker, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): importFiles(urls)
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
        .alert("Couldn’t add media", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Try again.")
        }
    }

    private func mediaTile(_ relativePath: String) -> some View {
        let fileURL = validatedAssetURL(relativePath)
        let image = fileURL.flatMap { isImage($0) ? NSImage(contentsOf: $0) : nil }
        let tile = VStack(alignment: .leading, spacing: 8) {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 108)
                        .background(Color.secondary.opacity(0.08))
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: fileURL.map { symbol(for: $0) } ?? "exclamationmark.triangle")
                            .font(.system(size: 32)).foregroundStyle(.secondary)
                        let extensionName = fileURL?.pathExtension.uppercased() ?? ""
                        Text(extensionName.isEmpty ? "FILE" : extensionName)
                            .font(.caption2.bold()).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 108)
                    .background(Color.secondary.opacity(0.08))
                }
            }
            Text(URL(fileURLWithPath: relativePath).lastPathComponent)
                .font(.caption)
                .lineLimit(1)
                .help(relativePath)
            if fileURL == nil {
                Label("Invalid or outside content folder", systemImage: "exclamationmark.triangle")
                    .font(.caption2).foregroundStyle(.red)
            }
            HStack(spacing: 10) {
                Button(fileURL.map(isImage) == true ? "Copy Image" : "Copy File") {
                    if let fileURL { copy(fileURL, asImage: isImage(fileURL)) }
                }
                    .buttonStyle(.link)
                    .disabled(fileURL == nil)
                Spacer()
                Button { remove(relativePath) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("Remove from this content record")
            }
        }
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.15)))
        if let fileURL { return AnyView(tile.draggable(fileURL)) }
        return AnyView(tile)
    }

    private func importFiles(_ urls: [URL]) {
        do {
            let safeFolder = try safeAssetsFolderURL(createIfNeeded: true)
            var addedPaths: [String] = []
            for sourceURL in urls {
                let accessed = sourceURL.startAccessingSecurityScopedResource()
                defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }
                guard sourceURL.isFileURL else { continue }
                let destinationURL = try uniqueDestination(for: sourceURL.lastPathComponent, in: safeFolder)
                try FileManager.default.copyItem(at: sourceURL.resolvingSymlinksInPath(), to: destinationURL)
                addedPaths.append(relativePath(for: destinationURL))
            }
            assetPaths = deduplicated(assetPaths + addedPaths)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func pasteImage() {
        let pasteboard = NSPasteboard.general
        guard let image = NSImage(pasteboard: pasteboard),
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            errorMessage = "The clipboard does not contain a supported image."
            return
        }
        importImageData(pngData, preferredName: "pasted-image.png")
    }

    private func importImageData(_ data: Data, preferredName: String = "dropped-image.png") {
        guard let image = NSImage(data: data),
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else { return }
        do {
            let safeFolder = try safeAssetsFolderURL(createIfNeeded: true)
            let destinationURL = try uniqueDestination(for: preferredName, in: safeFolder)
            try pngData.write(to: destinationURL, options: .atomic)
            assetPaths = deduplicated(assetPaths + [relativePath(for: destinationURL)])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func uniqueDestination(for proposedName: String, in folderURL: URL) throws -> URL {
        let base = URL(fileURLWithPath: proposedName).deletingPathExtension().lastPathComponent
        let ext = URL(fileURLWithPath: proposedName).pathExtension
        var candidate = folderURL.appendingPathComponent(proposedName)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let nextName = ext.isEmpty ? "\(base)-\(suffix)" : "\(base)-\(suffix).\(ext)"
            candidate = folderURL.appendingPathComponent(nextName)
            suffix += 1
        }
        return candidate
    }

    private func relativePath(for url: URL) -> String {
        let rootPath = contentFolderURL.standardizedFileURL.resolvingSymlinksInPath().path
        let root = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : url.lastPathComponent
    }

    private func validatedAssetURL(_ relativePath: String) -> URL? {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"),
              !relativePath.split(separator: "/").contains("..") else { return nil }
        let root = contentFolderURL.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = contentFolderURL.appendingPathComponent(relativePath).standardizedFileURL.resolvingSymlinksInPath()
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path.hasPrefix(rootPrefix),
              FileManager.default.fileExists(atPath: candidate.path) else { return nil }
        return candidate
    }

    private func safeAssetsFolderURL(createIfNeeded: Bool) throws -> URL {
        let root = contentFolderURL.standardizedFileURL.resolvingSymlinksInPath()
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let proposed = root.appendingPathComponent("Assets", isDirectory: true)
        if FileManager.default.fileExists(atPath: proposed.path) {
            let resolved = proposed.standardizedFileURL.resolvingSymlinksInPath()
            guard resolved.path.hasPrefix(rootPrefix),
                  (try resolved.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else {
                throw CocoaError(.fileReadInvalidFileName)
            }
            return resolved
        }
        guard createIfNeeded else { return proposed }
        try FileManager.default.createDirectory(at: proposed, withIntermediateDirectories: false)
        let resolved = proposed.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(rootPrefix) else { throw CocoaError(.fileReadInvalidFileName) }
        return resolved
    }

    private func isImage(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }

    private func symbol(for url: URL) -> String {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return "doc" }
        if type.conforms(to: .movie) { return "video" }
        if type.conforms(to: .pdf) { return "doc.richtext" }
        return "doc"
    }

    private func copy(_ url: URL, asImage: Bool) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if asImage, let image = NSImage(contentsOf: url) {
            pasteboard.writeObjects([image])
        } else {
            pasteboard.writeObjects([url as NSURL])
        }
    }

    private func revealAssetsFolder() {
        do {
            let safeFolder = try safeAssetsFolderURL(createIfNeeded: true)
            NSWorkspace.shared.activateFileViewerSelecting([safeFolder])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func remove(_ relativePath: String) {
        assetPaths.removeAll { $0 == relativePath }
    }

    private func deduplicated(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }
}
