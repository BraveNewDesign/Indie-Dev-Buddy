import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceAgentGuidanceView: View {
    let store: WorkspaceStore
    let workspaceName: String

    @Environment(\.dismiss) private var dismiss
    @State private var inventory: WorkspaceGuidanceInventory?
    @State private var draft = ""
    @State private var draftBase: WorkspaceGuidanceEntry?
    @State private var isBusy = true
    @State private var showingImport = false
    @State private var showingDiscard = false
    @State private var closeAfterDiscard = false
    @State private var preview: Preview?
    @State private var pendingSkill: WorkspaceGuidanceEntry?
    @State private var errorMessage: String?

    private var instructions: WorkspaceGuidanceEntry? {
        inventory?.files.first { $0.path == WorkspaceGuidance.instructionsPath }
    }

    private var hasDraft: Bool { draft != (draftBase?.additionalInstructions ?? "") }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Agent Guidance").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Text(workspaceName).foregroundStyle(.secondary).help(store.rootURL.path)
            }
            .padding(.horizontal)

            if let inventory {
                TabView {
                    Tab("Instructions", systemImage: "text.document") { instructionsTab }
                    Tab("Skills", systemImage: "folder") {
                        Form {
                            Section {
                                Button("Import Skill Folder…", systemImage: "plus") { showingImport = true }
                                ForEach(inventory.files.filter { $0.skillFolder != nil }) { entry in
                                    guidanceRow(entry)
                                }
                            }
                            if !inventory.issues.isEmpty {
                                Section("Folder Issues") {
                                    ForEach(inventory.issues, id: \.self) { issue in
                                        Label(issue, systemImage: "exclamationmark.triangle")
                                    }
                                }
                            }
                        }
                        .formStyle(.grouped)
                    }
                    Tab("Reference Files", systemImage: "book") {
                        Form {
                            ForEach(inventory.files.filter {
                                $0.skillFolder == nil && $0.path != WorkspaceGuidance.instructionsPath
                            }) { entry in
                                guidanceRow(entry)
                            }
                        }
                        .formStyle(.grouped)
                    }
                }
                .disabled(isBusy)
            } else if isBusy {
                ProgressView("Reading workspace guidance…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("Couldn’t Read Guidance", systemImage: "text.document")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            HStack {
                Button("Reload") {
                    if hasDraft {
                        closeAfterDiscard = false
                        showingDiscard = true
                    } else {
                        run { try await reload(resetDraft: true) }
                    }
                }
                Spacer()
                Button("Done", action: finish).keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal)
            .disabled(isBusy)
        }
        .padding(.vertical)
        .frame(minWidth: 680, idealWidth: 760, minHeight: 460, idealHeight: 560)
        .interactiveDismissDisabled(hasDraft || isBusy)
        .onExitCommand { if !isBusy { finish() } }
        .task {
            do { try await reload(resetDraft: true) }
            catch { errorMessage = error.localizedDescription }
            isBusy = false
        }
        .fileImporter(isPresented: $showingImport, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                run {
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    _ = try await store.importGuidanceSkill(from: url)
                    try await reload()
                }
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
        .sheet(item: $preview) { change in
            GuidancePreviewView(title: change.title, before: change.before, after: change.after,
                                applyTitle: change.applyTitle) {
                preview = nil
                if let apply = change.apply { run(apply) }
            }
        }
        .alert(skillActionTitle, isPresented: Binding(
            get: { pendingSkill != nil },
            set: { if !$0 { pendingSkill = nil } }
        ), presenting: pendingSkill) { entry in
            Button(entry.status == .archived ? "Restore Skill" : "Archive Skill") {
                changeArchiveState(entry)
            }
            Button("Cancel", role: .cancel) { }
        } message: { entry in
            if entry.status == .archived {
                Text("Move \(entry.skillFolder ?? "") back into the workspace’s skills folder.")
            } else {
                let reminder = instructions?.text?.contains(entry.path) == true
                    ? " AGENTS.md references this skill. Review those instructions after archiving."
                    : ""
                Text("Move \(entry.skillFolder ?? "") and its supporting files to the workspace archive. You can restore it later.\(reminder)")
            }
        }
        .alert("Discard Additional Instructions Edits?", isPresented: $showingDiscard) {
            Button("Discard Edits", role: .destructive) {
                if closeAfterDiscard { dismiss() }
                else { run { try await reload(resetDraft: true) } }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Your unsaved instructions will be discarded.")
        }
        .alert("Agent Guidance", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var instructionsTab: some View {
        Form {
            Section("Workspace Instructions") {
                if let instructions { guidanceRow(instructions) }
                Button("View Built-In Instructions") {
                    showText("Built-In Instructions", WorkspaceGuidance.agents)
                }
            }
            Section("Additional Instructions") {
                Text("Add workspace-specific directions to AGENTS.md.")
                    .foregroundStyle(.secondary)
                TextEditor(text: $draft)
                    .font(.body.monospaced())
                    .frame(minHeight: 120)
                    .accessibilityLabel("Additional Instructions")
                    .disabled(instructions?.status == .unavailable)
                Button("Review Changes…", action: reviewInstructions)
                    .disabled(!hasDraft || instructions?.status == .unavailable)
            }
        }
        .formStyle(.grouped)
    }

    private func guidanceRow(_ entry: WorkspaceGuidanceEntry) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.skillFolder ?? (entry.path as NSString).lastPathComponent).fontWeight(.medium)
                    Text("\(entry.builtIn ? "Built-in" : "Workspace") · \(statusLabel(entry.status))")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text(entry.path).font(.caption.monospaced()).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                if let text = entry.text {
                    Button("View") { showText(entry.path, text) }
                        .accessibilityLabel("View \(entry.skillFolder ?? entry.path)")
                }
                if let replacement = entry.replacement, entry.issue == nil {
                    Button(entry.status == .missing ? "Review Install…" : "Review Update…") {
                        preview = Preview(title: entry.path, before: entry.text ?? "", after: replacement,
                                          applyTitle: entry.status == .missing ? "Install" : "Update") {
                            _ = try await store.updateAgentGuidance(path: entry.path, expectedRevision: entry.revision)
                            try await reload()
                        }
                    }
                    .disabled(entry.path == WorkspaceGuidance.instructionsPath && hasDraft)
                }
                if let folder = entry.skillFolder, entry.revision != nil {
                    Button("Show in Finder", systemImage: "folder") {
                        let file = store.rootURL.appendingPathComponent(entry.path)
                        NSWorkspace.shared.activateFileViewerSelecting([file.deletingLastPathComponent()])
                    }
                    .labelStyle(.iconOnly)
                    .help("Show \(folder) in Finder")
                    .accessibilityLabel("Show \(folder) in Finder")
                }
                if entry.skillFolder != nil, entry.revision != nil, entry.issue == nil {
                    Button(entry.status == .archived ? "Restore…" : "Archive…") { pendingSkill = entry }
                }
            }
            if let issue = entry.issue {
                Label(issue, systemImage: "exclamationmark.triangle")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var skillActionTitle: String {
        pendingSkill?.status == .archived ? "Restore Skill?" : "Archive Skill?"
    }

    private func statusLabel(_ status: WorkspaceGuidanceEntry.Status) -> String {
        switch status {
        case .current: "Up to date"
        case .updateAvailable: "Update available"
        case .customized: "Customized"
        case .installed: "Installed"
        case .missing: "Missing"
        case .archived: "Archived"
        case .unavailable: "Unavailable"
        }
    }

    private func reviewInstructions() {
        let text = draft
        let revision = draftBase?.revision
        run {
            let change = try await store.previewAdditionalInstructions(text, expectedRevision: revision)
            preview = Preview(title: "Review AGENTS.md", before: change.before, after: change.after,
                              applyTitle: "Save Instructions") {
                _ = try await store.saveAdditionalInstructions(text, expectedRevision: change.revision)
                try await reload(resetDraft: true)
            }
        }
    }

    private func changeArchiveState(_ entry: WorkspaceGuidanceEntry) {
        guard let skill = entry.skillFolder, let revision = entry.revision else { return }
        run {
            try await store.setGuidanceSkillArchived(skill, archived: entry.status != .archived, expectedRevision: revision)
            try await reload()
        }
    }

    private func showText(_ title: String, _ text: String) {
        preview = Preview(title: title, before: text)
    }

    private func finish() {
        if hasDraft {
            closeAfterDiscard = true
            showingDiscard = true
        } else {
            dismiss()
        }
    }

    private func reload(resetDraft: Bool = false) async throws {
        let keepDraft = hasDraft && !resetDraft
        inventory = try await store.agentGuidance()
        if !keepDraft {
            draftBase = instructions
            draft = instructions?.additionalInstructions ?? ""
        }
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !isBusy else { return }
        isBusy = true
        Task {
            defer { isBusy = false }
            do { try await action() }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private struct Preview: Identifiable {
        let id = UUID()
        let title: String
        let before: String
        var after: String? = nil
        var applyTitle: String? = nil
        var apply: (@MainActor () async throws -> Void)? = nil
    }
}

private struct GuidancePreviewView: View {
    let title: String
    let before: String
    let after: String?
    let applyTitle: String?
    let apply: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showFullText = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline).textSelection(.enabled)
            if let after {
                Picker("Preview", selection: $showFullText) {
                    Text("Changed Lines").tag(false)
                    Text("Full Text").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if showFullText {
                    HStack(alignment: .top, spacing: 12) {
                        textPane(before, label: "Current")
                        textPane(after, label: "Proposed")
                    }
                } else {
                    let changes = lineChanges(before: before, after: after)
                    HStack(alignment: .top, spacing: 12) {
                        textPane(changes.removed, label: "Removed Lines")
                        textPane(changes.added, label: "Added Lines")
                    }
                }
            } else {
                textPane(before)
            }
            HStack {
                Spacer()
                Button(applyTitle == nil ? "Done" : "Cancel") { dismiss() }
                    .keyboardShortcut(applyTitle == nil ? .defaultAction : .cancelAction)
                if let applyTitle {
                    Button(applyTitle, action: apply).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(18)
        .frame(minWidth: 660, idealWidth: 820, minHeight: 380, idealHeight: 480)
    }

    private func lineChanges(before: String, after: String) -> (removed: String, added: String) {
        let oldLines = before.isEmpty ? [] : before.components(separatedBy: "\n")
        let newLines = after.isEmpty ? [] : after.components(separatedBy: "\n")
        let changes = newLines.difference(from: oldLines)
        let removed = changes.removals.reversed().compactMap { change -> String? in
            guard case .remove(let offset, let line, _) = change else { return nil }
            return "\(offset + 1)  − \(line)"
        }
        let added = changes.insertions.compactMap { change -> String? in
            guard case .insert(let offset, let line, _) = change else { return nil }
            return "\(offset + 1)  + \(line)"
        }
        return (removed.isEmpty ? "No lines removed" : removed.joined(separator: "\n"),
                added.isEmpty ? "No lines added" : added.joined(separator: "\n"))
    }

    private func textPane(_ text: String, label: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let label { Text(label).font(.subheadline.weight(.semibold)).accessibilityAddTraits(.isHeader) }
            ScrollView {
                Text(verbatim: text.isEmpty ? "Empty file" : text)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(.background, in: RoundedRectangle(cornerRadius: 8))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
