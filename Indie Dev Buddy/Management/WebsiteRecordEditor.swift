import SwiftUI

struct WebsiteRecordEditor: View {
    let record: WebsiteRecord?
    let owners: [OwnerChoice]
    let onDirtyChange: (Bool) -> Void
    let onSave: (WebsiteRecord) async -> Bool
    @State private var name = ""
    @State private var ownerID = ""
    @State private var baseURL = "https://"
    @State private var blogEnabled = false
    @State private var blogIndexURL = ""
    @State private var saving = false
    var body: some View {
        Form {
            Section("Website") {
                TextField("Name", text: $name)
                ownerPicker
                TextField("Base URL", text: $baseURL)
                Toggle("Enable as a blog destination", isOn: $blogEnabled)
                if blogEnabled { TextField("Blog index URL (optional)", text: $blogIndexURL) }
            }
            Section { HStack { Spacer(); Button("Save Website") { Task { await save() } }.buttonStyle(.borderedProminent).disabled(!canSave) } }
        }
        .formStyle(.grouped)
        .navigationTitle(record == nil ? "New Website" : name)
        .focusedSceneValue(\.workspaceSaveAction, canSave ? WorkspaceSaveAction { completion in
            Task { completion(await save()) }
        } : nil)
        .onAppear { if let record { name = record.name; ownerID = "\(record.owner.type.rawValue):\(record.owner.id)"; baseURL = record.baseURL.absoluteString; blogEnabled = record.blogEnabled; blogIndexURL = record.blogIndexURL?.absoluteString ?? "" } else { ownerID = owners.first?.id ?? "" } }
        .onChange(of: dirtySignature) { _, _ in onDirtyChange(isDirty) }
    }
    private var ownerPicker: some View {
        Picker("Owner", selection: $ownerID) {
            Text("Choose owner").tag("")
            ForEach(owners) { choice in Text("\(choice.title) (\(choice.detail))").tag(choice.id) }
        }
    }
    private var canSave: Bool {
        !(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || URL(string: baseURL)?.scheme == nil || ownerID.isEmpty || saving)
    }

    @discardableResult
    private func save() async -> Bool {
        guard canSave else { return false }
        guard let choice = owners.first(where: { $0.id == ownerID }), let url = URL(string: baseURL) else { return false }
        saving = true; defer { saving = false }
        let value = WebsiteRecord(id: record?.id ?? UUID().uuidString.lowercased(), name: name.trimmingCharacters(in: .whitespacesAndNewlines), owner: choice.owner, baseURL: url, blogEnabled: blogEnabled, blogIndexURL: optionalWebURL(blogIndexURL))
        if await onSave(value) {
            onDirtyChange(false)
            return true
        }
        return false
    }
    private var dirtySignature: String { "\(name)|\(ownerID)|\(baseURL)|\(blogEnabled)|\(blogIndexURL)" }
    private var isDirty: Bool {
        if let record {
            return record.name != name.trimmingCharacters(in: .whitespacesAndNewlines) || ownerID != "\(record.owner.type.rawValue):\(record.owner.id)" || baseURL != record.baseURL.absoluteString || blogEnabled != record.blogEnabled || blogIndexURL != (record.blogIndexURL?.absoluteString ?? "")
        }
        return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || ownerID != (owners.first?.id ?? "") || baseURL != "https://" || blogEnabled || !blogIndexURL.isEmpty
    }
}
