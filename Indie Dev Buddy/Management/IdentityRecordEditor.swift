import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct IdentityRecordEditor: View {
    let record: IdentityRecord?
    let workspaceStore: WorkspaceStore
    let snapshotGeneration: Int
    let onDirtyChange: (Bool) -> Void
    let onSave: (IdentityRecord) async -> Bool
    @State private var name = ""
    @State private var kind = "Personal"
    @State private var draftID = UUID().uuidString.lowercased()
    @State private var photoPath: String?
    @State private var photoPreview: NSImage?
    @State private var photoError: String?
    @State private var photoUnavailable = false
    @State private var showingPhotoPicker = false
    @State private var saving = false
    var body: some View {
        Form {
            Section("Identity") {
                TextField("Name", text: $name)
                Picker("Type", selection: $kind) {
                    Text("Personal").tag("Personal")
                    Text("Business").tag("Business")
                    Text("Brand").tag("Brand")
                }
            }
            Section("Photo") {
                HStack(spacing: 14) {
                    Group {
                        if let photoPreview {
                            Image(nsImage: photoPreview).resizable().scaledToFill()
                        } else {
                            Image(systemName: "person.crop.circle.fill").resizable().scaledToFit().foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 64, height: 64)
                    .clipShape(Circle())
                    .accessibilityLabel(photoPreview == nil ? "No identity photo selected" : "Identity photo preview")
                    VStack(alignment: .leading, spacing: 8) {
                        Button(photoPath == nil ? "Choose Photo…" : "Replace Photo…") { showingPhotoPicker = true }
                        if photoPath != nil {
                            Button("Remove Photo", role: .destructive) {
                                photoPath = nil
                                photoPreview = nil
                                photoError = nil
                                photoUnavailable = false
                            }
                        }
                        if let photoError { Text(photoError).font(.caption).foregroundStyle(.red) }
                        else if photoUnavailable || (photoPath != nil && photoRequest == nil) {
                            Text("The linked photo is unavailable or unreadable. Replace or remove it.")
                                .font(.caption)
                                .foregroundStyle(.red)
                        } else if photoPath == nil { Text("Used as the default avatar for this identity’s social accounts.").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            Section { HStack { Spacer(); Button("Save Identity") { Task { await save() } }.buttonStyle(.borderedProminent).disabled(!canSave) } }
        }
        .formStyle(.grouped)
        .navigationTitle(record == nil ? "New Identity" : name)
        .focusedSceneValue(\.workspaceSaveAction, canSave ? WorkspaceSaveAction { completion in
            Task { completion(await save()) }
        } : nil)
        .onAppear {
            if let record {
                draftID = record.id
                name = record.name
                kind = record.kind ?? "Personal"
                photoPath = record.photoPath
            }
        }
        .task(id: photoRequest) {
            guard let photoRequest else { return }
            let image = await WorkspaceThumbnailCache.shared.load(photoRequest)
            guard !Task.isCancelled, self.photoRequest == photoRequest else { return }
            photoPreview = image.map { NSImage(cgImage: $0, size: .zero) }
            photoUnavailable = image == nil
        }
        .onChange(of: name) { _, _ in onDirtyChange(isDirty) }
        .onChange(of: kind) { _, _ in onDirtyChange(isDirty) }
        .onChange(of: photoPath) { _, _ in onDirtyChange(isDirty) }
        .fileImporter(isPresented: $showingPhotoPicker, allowedContentTypes: [.image], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task { await importPhoto(from: url) }
            case .failure(let error): photoError = error.localizedDescription
            }
        }
    }
    private var photoRequest: WorkspaceThumbnailRequest? {
        .identityPhoto(root: workspaceStore.rootURL, path: photoPath, generation: snapshotGeneration)
    }

    private var canSave: Bool {
        !(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
    }

    @discardableResult
    private func save() async -> Bool {
        guard canSave else { return false }
        saving = true; defer { saving = false }
        if await onSave(IdentityRecord(id: draftID, name: name.trimmingCharacters(in: .whitespacesAndNewlines), kind: kind, photoPath: photoPath)) {
            onDirtyChange(false)
            return true
        }
        return false
    }
    private func importPhoto(from sourceURL: URL) async {
        do {
            let data = try await WorkspaceThumbnailCache.identityPhotoImport(from: sourceURL)
            guard let type = UTType(filenameExtension: sourceURL.pathExtension), type.conforms(to: .image) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let ext = type.preferredFilenameExtension ?? sourceURL.pathExtension.lowercased()
            guard !ext.isEmpty, ext.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) else {
                throw CocoaError(.fileReadInvalidFileName)
            }
            let identityFolder = record.flatMap { ManagementWorkspaceView.findRecordPath(root: workspaceStore.rootURL, category: "Identities", id: $0.id) }
                .map { String($0.dropLast("/record.json".count)) }
                ?? "Identities/\(ManagementWorkspaceView.slug(name))-\(draftID.prefix(8))"
            let path = "\(identityFolder)/Assets/identity-photo-\(UUID().uuidString.lowercased()).\(ext)"
            _ = try await workspaceStore.write(data, relativePath: path, expectedRevision: nil)
            photoPath = path
            photoPreview = nil
            photoError = nil
            photoUnavailable = false
        } catch {
            photoError = "Could not import this photo: \(error.localizedDescription)"
        }
    }
    private var isDirty: Bool {
        record.map {
            $0.name != name.trimmingCharacters(in: .whitespacesAndNewlines) || ($0.kind ?? "Personal") != kind || $0.photoPath != photoPath
        } ?? (!name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || kind != "Personal" || photoPath != nil)
    }
}
