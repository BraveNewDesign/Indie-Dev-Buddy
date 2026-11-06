import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A lightweight editor surface that can be backed by the file workspace without owning storage.
struct ComposerSocialAccount: Identifiable, Hashable {
    let id: String
    let platform: String
    let handle: String?
    let profileURL: URL?
    let avatarPath: String?
    let ownerName: String?
    let enabled: Bool
    let hasOwner: Bool
    let avatarSymbol: String

    init(record: SocialAccountRecord, snapshot: WorkspaceSnapshot) {
        id = record.id
        platform = record.platform
        handle = record.handle
        profileURL = record.profileURL
        let identityPhotoPath = record.owner.flatMap { owner in
            owner.type == .identity ? snapshot.identities.first { $0.id == owner.id }?.photoPath : nil
        }
        avatarPath = record.avatarPath ?? identityPhotoPath
        enabled = record.enabled
        var resolvedOwnerName: String?
        if let owner = record.owner {
            switch owner.type {
            case .identity: resolvedOwnerName = snapshot.identities.first { $0.id == owner.id }?.name
            case .app: resolvedOwnerName = snapshot.apps.first { $0.id == owner.id }?.name
            }
        } else { resolvedOwnerName = nil }
        ownerName = resolvedOwnerName
        hasOwner = resolvedOwnerName != nil
        avatarSymbol = "person.crop.circle.fill"
    }

    var displayName: String {
        let accountName = handle ?? profileURL?.host ?? "Unconfigured account"
        return [platform, accountName, ownerName].compactMap { $0 }.joined(separator: " · ")
    }

    var isEligible: Bool {
        enabled && hasOwner && (!platform.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) &&
        (handle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false || profileURL != nil)
    }
}

struct ComposerArticleReference: Identifiable, Hashable {
    let id: String
    let title: String
    let publishedURL: URL?
}

struct ComposerReleaseReference: Identifiable, Hashable {
    let id: String
    let appID: String
    let appName: String
    let version: String
    let status: String
    let releaseDate: Date?

    var displayName: String { "\(appName) · \(version) · \(status)" }
}

struct ComposerRelatedItem: Identifiable, Hashable {
    let id: String
    let title: String
    let kind: String
    let status: String
}

struct MarketingComposerView: View {
    let contentFolderURL: URL
    let apps: [AppRecord]
    let accounts: [ComposerSocialAccount]
    let article: ComposerArticleReference?
    let hasUnavailableSource: Bool
    let releases: [ComposerReleaseReference]
    let relatedItems: [ComposerRelatedItem]
    let unavailableDestinationIDs: Set<String>
    let characterGuidelines: [String: Int]
    let onSave: (ComposerDraft, @escaping (Bool) -> Void) -> Void
    let onOpenRelated: (String) -> Void
    @Binding var requestedNavigationID: String?
    let onNavigationConfirmed: (String) -> Void
    let onDirtyChange: (Bool) -> Void

    @State private var title = ""
    @State private var selectedAppIDs = Set<String>()
    @State private var selectedReleaseID: String?
    @State private var originalText = ""
    @State private var selectedAccountIDs = Set<String>()
    @State private var customizedText: [String: String] = [:]
    @State private var destinationStatuses: [String: String] = [:]
    @State private var destinationURLs: [String: String] = [:]
    @State private var plannedDate: Date?
    @State private var destinationPublicationDates: [String: Date] = [:]
    @State private var sharedMediaPaths: [String] = []
    @State private var destinationMediaOverrides: [String: [String]] = [:]
    @State private var customMediaAccountIDs = Set<String>()
    @State private var selectedAccountID: String?
    @State private var includeArticleLink = false
    @State private var draftStatus = "Draft"
    @State private var copyMessage: String?
    @State private var showUseOriginalConfirmation = false
    @State private var showOriginalText = false
    @State private var showUnsavedChanges = false
    @State private var savedDraftSnapshot: ComposerDraft?
    @State private var isSaving = false
    @State private var showingGuidanceSettings = false
    @State private var compactPreviewSelected = false
    @AppStorage("guidance.threads") private var threadsGuideline = 500
    @AppStorage("guidance.instagram") private var instagramGuideline = 2200
    @AppStorage("guidance.x") private var xGuideline = 280
    @AppStorage("guidance.facebook") private var facebookGuideline = 63206
    @AppStorage("guidance.linkedin") private var linkedInGuideline = 3000

    private var eligibleAccounts: [ComposerSocialAccount] { accounts.filter(\.isEligible) }
    private var selectedAccount: ComposerSocialAccount? {
        eligibleAccounts.first { $0.id == selectedAccountID && selectedAccountIDs.contains($0.id) }
    }
    private var effectiveText: String {
        guard let id = selectedAccountID else { return originalText }
        return customizedText[id] ?? originalText
    }
    private var resolvedText: String {
        let base = effectiveText
        guard includeArticleLink, let url = article?.publishedURL else { return base }
        return base.isEmpty ? url.absoluteString : "\(base)\n\n\(url.absoluteString)"
    }
    private var guideline: Int? {
        guard let account = selectedAccount else { return nil }
        let key = account.platform.lowercased()
        let stored: Int?
        switch key {
        case "threads": stored = threadsGuideline
        case "instagram": stored = instagramGuideline
        case "x", "twitter": stored = xGuideline
        case "facebook": stored = facebookGuideline
        case "linkedin": stored = linkedInGuideline
        default: stored = nil
        }
        if let stored, stored > 0 { return stored }
        return characterGuidelines[key]
    }
    private var effectiveGlobalStatus: String {
        guard !selectedAccountIDs.isEmpty else { return draftStatus }
        let statuses = selectedAccountIDs.map { destinationStatuses[$0] ?? "Draft" }
        if statuses.allSatisfy({ $0 == "Published" }) { return "Published" }
        if statuses.contains("Published") { return "Partially Published" }
        let uniqueStatuses = Set(statuses)
        return uniqueStatuses.count == 1 ? (uniqueStatuses.first ?? draftStatus) : "Mixed"
    }
    private var currentDraft: ComposerDraft {
        ComposerDraft(title: title, originalText: originalText, selectedAccountIDs: selectedAccountIDs,
                      appIDs: Array(selectedAppIDs).sorted(), releaseID: selectedReleaseID,
                      customizedText: customizedText, destinationStatuses: destinationStatuses,
                      destinationURLs: destinationURLs,
                      plannedDate: plannedDate,
                      destinationPublicationDates: destinationPublicationDates,
                      sharedMediaPaths: sharedMediaPaths,
                      destinationMediaOverrides: destinationMediaOverrides,
                      preservedDestinationIDs: unavailableDestinationIDs,
                      includeArticleLink: includeArticleLink, status: draftStatus)
    }
    private var hasUnsavedChanges: Bool { currentDraft != savedDraftSnapshot }

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width >= 1040 {
                HStack(spacing: 0) {
                    editorPane
                    Divider()
                    previewPane
                        .frame(minWidth: 310, idealWidth: 360, maxWidth: 430)
                        .background(Color(nsColor: .windowBackgroundColor))
                }
            } else {
                VStack(spacing: 0) {
                    Picker("Composer view", selection: $compactPreviewSelected) {
                        Text("Edit").tag(false)
                        Text("Preview").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    if compactPreviewSelected {
                        ScrollView { previewPane.padding(16) }
                    } else {
                        editorPane
                    }
                }
            }
        }
        .frame(minWidth: 0, minHeight: 360)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                Button(isSaving ? "Saving…" : "Save Changes") { saveDraft() }
                    .disabled(isSaving)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: .command)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(10)
            }
            .background(.bar)
        }
        .confirmationDialog("Use the shared original?", isPresented: $showUseOriginalConfirmation, titleVisibility: .visible) {
            Button("Discard customization and use original", role: .destructive) {
                if let id = selectedAccountID { customizedText.removeValue(forKey: id) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes the customized text for this account. The shared original stays unchanged.")
        }
        .onChange(of: selectedAccountIDs) { _, ids in
            if let current = selectedAccountID, !ids.contains(current) {
                selectedAccountID = ids.sorted().first
            }
            if selectedAccountID == nil { selectedAccountID = ids.sorted().first }
        }
        .onChange(of: currentDraft) { _, draft in onDirtyChange(draft != savedDraftSnapshot) }
        .onAppear { onDirtyChange(hasUnsavedChanges) }
        .onChange(of: accounts) { _, _ in
            let eligibleIDs = Set(eligibleAccounts.map(\.id))
            var current = currentDraft
            current.reconcileAccountAvailability(
                eligibleAccountIDs: eligibleIDs,
                unavailableDestinationIDs: unavailableDestinationIDs
            )
            selectedAccountIDs = current.selectedAccountIDs
            if let selectedAccountID, !current.selectedAccountIDs.contains(selectedAccountID) {
                self.selectedAccountID = current.selectedAccountIDs.sorted().first
            }
            if var baseline = savedDraftSnapshot {
                baseline.reconcileAccountAvailability(
                    eligibleAccountIDs: eligibleIDs,
                    unavailableDestinationIDs: unavailableDestinationIDs
                )
                savedDraftSnapshot = baseline
            }
        }
        .onChange(of: requestedNavigationID) { _, destinationID in
            guard let destinationID else { return }
            if hasUnsavedChanges { showUnsavedChanges = true }
            else { confirmNavigation(to: destinationID) }
        }
        .confirmationDialog("Unsaved marketing changes", isPresented: $showUnsavedChanges, titleVisibility: .visible) {
            Button("Save and Continue") {
                saveDraft { success in
                    if success, let destinationID = requestedNavigationID { confirmNavigation(to: destinationID) }
                }
            }
            Button("Discard and Continue", role: .destructive) {
                if let destinationID = requestedNavigationID { confirmNavigation(to: destinationID) }
            }
            Button("Cancel", role: .cancel) { requestedNavigationID = nil }
        } message: {
            Text("Save your changes before leaving, or discard them and continue.")
        }
        .sheet(isPresented: $showOriginalText) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Shared Original").font(.title2.bold())
                ScrollView { Text(originalText.isEmpty ? "No original text yet." : originalText).frame(maxWidth: .infinity, alignment: .leading) }
                HStack { Spacer(); Button("Done") { showOriginalText = false }.keyboardShortcut(.defaultAction) }
            }
            .padding(24)
            .frame(minWidth: 420, minHeight: 280)
        }
    }

    private var editorPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                TextField("Title", text: $title)
                    .font(.title2.bold())
                    .textFieldStyle(.roundedBorder)
                originalSection
                sharedMediaSection
                metadataSection
                destinationsSection
                sourceSection
                relatedSection
            }
            .padding(24)
            .frame(maxWidth: 780, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Social Post").font(.largeTitle.bold())
                Text("Prepare account-specific versions, then copy and publish manually.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text("Overall status").font(.caption).foregroundStyle(.secondary)
                Menu {
                    ForEach(["Idea", "Draft", "Ready"], id: \.self) { status in
                        Button(status) { draftStatus = status }
                    }
                } label: {
                    Text(effectiveGlobalStatus)
                }
            }
        }
    }

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Details")
            Menu {
                Button("None") { selectedAppIDs.removeAll() }
                ForEach(apps) { app in
                    Button {
                        if selectedAppIDs.contains(app.id) { selectedAppIDs.remove(app.id) }
                        else { selectedAppIDs.insert(app.id) }
                    } label: {
                        Label(app.name, systemImage: selectedAppIDs.contains(app.id) ? "checkmark.circle.fill" : "circle")
                    }
                }
            } label: {
                HStack {
                    Text("Apps mentioned")
                    let names = apps.filter { selectedAppIDs.contains($0.id) }.map(\.name).joined(separator: ", ")
                    Text(names.isEmpty ? "None" : names).foregroundStyle(.secondary).lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            Picker("Related release", selection: $selectedReleaseID) {
                Text("None").tag(String?.none)
                ForEach(releases.filter { $0.id == selectedReleaseID || selectedAppIDs.isEmpty || selectedAppIDs.contains($0.appID) }) { release in
                    Text(release.displayName).tag(Optional(release.id))
                }
            }
            .help("Associate this content with a release. The link uses the release's stable ID.")
            if let selectedReleaseID, !releases.contains(where: { $0.id == selectedReleaseID }) {
                Label("The linked release is unavailable. Choose another release or clear this association.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            } else if let selectedReleaseID,
                      let selectedRelease = releases.first(where: { $0.id == selectedReleaseID }),
                      !selectedAppIDs.isEmpty, !selectedAppIDs.contains(selectedRelease.appID) {
                Label("This release belongs to an app not selected above. Keep the association or select its app.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            Toggle("Planned date", isOn: plannedDatePresenceBinding)
            if plannedDate != nil {
                DatePicker("Planned", selection: plannedDateBinding, displayedComponents: .date)
                    .datePickerStyle(.field)
            }
        }
    }

    private var originalSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle("Shared original")
                Spacer()
                Text("Used by accounts without a custom version")
                    .font(.caption).foregroundStyle(.secondary)
            }
            TextEditor(text: $originalText)
                .font(.body)
                .frame(minHeight: 150)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
        }
    }

    private var sharedMediaSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Shared media")
            Text("Accounts inherit these files unless you set an account-specific media override.")
                .font(.caption).foregroundStyle(.secondary)
            ContentMediaView(contentFolderURL: contentFolderURL, assetPaths: $sharedMediaPaths)
        }
    }

    private var destinationsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle("Destination accounts")
                Spacer()
                Text("\(selectedAccountIDs.count) selected").font(.caption).foregroundStyle(.secondary)
            }
            if eligibleAccounts.isEmpty {
                ContentUnavailableView("No eligible accounts", systemImage: "person.crop.circle.badge.exclamationmark",
                                       description: Text("Enable an account and add an owner, platform, and handle or profile URL."))
                    .frame(height: 120)
            } else {
                ForEach(eligibleAccounts) { account in
                    HStack(spacing: 10) {
                        Toggle(account.displayName, isOn: selectionBinding(for: account))
                            .toggleStyle(.checkbox)
                        Spacer(minLength: 8)
                        if customizedText[account.id] != nil {
                            Label("Custom", systemImage: "arrow.branch")
                                .font(.caption).foregroundStyle(.tint)
                        } else {
                            Text("Original").font(.caption).foregroundStyle(.secondary)
                        }
                        Button("Preview") {
                            selectedAccountID = account.id
                            compactPreviewSelected = true
                        }
                            .disabled(!selectedAccountIDs.contains(account.id))
                            .buttonStyle(.link)
                    }
                    .padding(.vertical, 4)
                }
            }
            let unavailableReferenced = accounts.filter { !$0.isEligible && unavailableDestinationIDs.contains($0.id) }
            ForEach(unavailableReferenced) { account in
                Label("\(account.displayName) is unavailable. Existing post content is retained.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            ForEach(unavailableDestinationIDs.filter { id in !accounts.contains(where: { $0.id == id }) }.sorted(), id: \.self) { id in
                Label("Account reference \(id) is unavailable. Existing post content is retained.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Created from")
            if let article {
                HStack {
                    Image(systemName: "doc.text")
                    VStack(alignment: .leading) {
                        Text(article.title)
                        Text(article.publishedURL?.absoluteString ?? "Article link unavailable until a published URL is added")
                            .font(.caption).foregroundStyle(article.publishedURL == nil ? .orange : .secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button("Open") { requestNavigation(to: article.id) }
                }
                Toggle("Include link to original article", isOn: $includeArticleLink)
            } else if hasUnavailableSource {
                Label("The linked source content is unavailable. Its reference is retained.", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
            } else {
                Text("No source article or post is linked.").foregroundStyle(.secondary)
            }
        }
    }

    private var relatedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Other related content")
            if relatedItems.isEmpty {
                Text("Related articles and posts will appear here.").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(relatedItems) { item in
                    Button { requestNavigation(to: item.id) } label: {
                        HStack {
                            Image(systemName: item.kind.lowercased().contains("blog") ? "doc.text" : "bubble.left")
                            Text(item.title)
                            Spacer()
                            Text(item.status).foregroundStyle(.secondary)
                            Image(systemName: "arrow.up.right")
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Preview").font(.title2.bold())
                Spacer()
                if let account = selectedAccount {
                    Menu {
                        ForEach(eligibleAccounts.filter { selectedAccountIDs.contains($0.id) }) { candidate in
                            Button(candidate.displayName) { selectedAccountID = candidate.id }
                        }
                    } label: {
                        Label(account.platform, systemImage: "chevron.down")
                    }
                    .menuStyle(.borderlessButton)
                }
            }
            if let account = selectedAccount {
                previewCard(for: account)
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("Character guidance")
                        Spacer()
                        if let guideline { Text("\(resolvedText.count) / \(guideline)").monospacedDigit() }
                        else { Text("\(resolvedText.count) characters").monospacedDigit() }
                        Button("Edit Limits") { showingGuidanceSettings = true }
                            .buttonStyle(.link)
                    }
                    if let guideline, resolvedText.count > guideline {
                        Label("Over this platform's suggested limit — review before posting.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    } else {
                        Text("Counts are guidance and may differ from platform validation.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Divider()
                if customizedText[account.id] == nil {
                    Button("Customize for this account") {
                        customizedText[account.id] = originalText
                    }
                    .buttonStyle(.bordered)
                } else {
                    HStack {
                        Text("Custom version").font(.headline)
                        Spacer()
                        Button("View Original") { showOriginalText = true }
                        Button("Use Original") { showUseOriginalConfirmation = true }
                    }
                    TextEditor(text: accountTextBinding(account.id))
                        .frame(minHeight: 125)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
                    Button("Copy from Original") { customizedText[account.id] = originalText }
                        .buttonStyle(.link)
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Media for this account").font(.headline)
                        Spacer()
                        if customMediaAccountIDs.contains(account.id) {
                            Button("Use Shared Media") {
                                customMediaAccountIDs.remove(account.id)
                                destinationMediaOverrides.removeValue(forKey: account.id)
                            }
                        } else {
                            Button("Customize Media") {
                                customMediaAccountIDs.insert(account.id)
                                destinationMediaOverrides[account.id] = sharedMediaPaths
                            }
                        }
                    }
                    if customMediaAccountIDs.contains(account.id) {
                        ContentMediaView(contentFolderURL: contentFolderURL,
                                         assetPaths: mediaOverrideBinding(account.id))
                    } else if effectiveMediaPaths(for: account.id).isEmpty {
                        Text("No shared media selected.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Using \(sharedMediaPaths.count) shared file(s).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button {
                        copyMessage = copyCurrentText()
                    } label: { Label("Copy Text", systemImage: "doc.on.doc") }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .help("Copy the selected account’s effective post text (⇧⌘C)")
                    Text(copyMessage ?? "").font(.caption).foregroundStyle(.secondary)
                    if let url = account.profileURL { Button("Open Social Account") { NSWorkspace.shared.open(url) } }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Publication for this account").font(.headline)
                    Picker("Status", selection: destinationStatusBinding(account.id)) {
                        ForEach(["Idea", "Draft", "Ready", "Published"], id: \.self) { Text($0) }
                    }
                    if destinationStatuses[account.id] == "Published" {
                        TextField("Published URL (optional)", text: destinationURLBinding(account.id))
                            .textFieldStyle(.roundedBorder)
                        Toggle("Record publication date", isOn: destinationPublicationDatePresenceBinding(account.id))
                        if destinationPublicationDates[account.id] != nil {
                            DatePicker("Published on", selection: destinationPublicationDateBinding(account.id), displayedComponents: .date)
                                .datePickerStyle(.field)
                        }
                        Text("Marking Published records your work; it does not post to the account.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            } else {
                ContentUnavailableView("Select an account", systemImage: "rectangle.and.text.magnifyingglass",
                                       description: Text("Choose an eligible destination to review its effective post."))
            }
        }
        .padding(20)
        .sheet(isPresented: $showingGuidanceSettings) {
            PlatformGuidanceSettingsView()
        }
    }

    @ViewBuilder private func previewCard(for account: ComposerSocialAccount) -> some View {
        let platform = account.platform.lowercased()
        switch platform {
        case "threads": threadsPreview(account)
        case "instagram": instagramPreview(account)
        case "x", "twitter": xPreview(account)
        case "facebook": facebookPreview(account)
        case "linkedin": linkedInPreview(account)
        default: genericPreview(account)
        }
    }

    private func threadsPreview(_ account: ComposerSocialAccount) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                avatar(for: account, size: 38)
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(account.handle ?? account.ownerName ?? "Account").font(.headline)
                        Text("· Threads").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(account.ownerName ?? "").font(.caption).foregroundStyle(.secondary)
                    postText
                    previewMedia(for: account, featured: false)
                }
            }
        }
        .padding(16)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.secondary.opacity(0.16)))
    }

    private func instagramPreview(_ account: ComposerSocialAccount) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                avatar(for: account, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(account.handle ?? "Account").font(.subheadline.bold())
                    Text(account.ownerName ?? "").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "ellipsis").foregroundStyle(.secondary)
            }
            previewMedia(for: account, featured: true)
            Text(resolvedText.isEmpty ? "Your caption preview will appear here." : resolvedText)
                .font(.callout).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            Text("Instagram preview · media shown from this account’s effective attachments")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.16)))
    }

    private func xPreview(_ account: ComposerSocialAccount) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                avatar(for: account, size: 42)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Text(account.ownerName ?? account.handle ?? "Account").font(.headline)
                        if let handle = account.handle { Text(handle).foregroundStyle(.secondary) }
                        Spacer(minLength: 0)
                        Text("X").font(.headline)
                    }
                    postText
                    previewMedia(for: account, featured: false)
                }
            }
            Text("X post preview").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(16)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.secondary.opacity(0.2)))
    }

    private func facebookPreview(_ account: ComposerSocialAccount) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                avatar(for: account, size: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.ownerName ?? account.handle ?? "Account").font(.subheadline.bold())
                    Text("\(account.handle ?? account.platform) · Facebook").font(.caption).foregroundStyle(.secondary)
                }
            }
            postText
            previewMedia(for: account, featured: false)
            Text("Facebook post preview").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.16)))
    }

    private func linkedInPreview(_ account: ComposerSocialAccount) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                avatar(for: account, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.ownerName ?? account.handle ?? "Account").font(.subheadline.bold())
                    Text("\(account.handle ?? account.platform) · LinkedIn").font(.caption).foregroundStyle(.secondary)
                    Text("Post").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            postText
            previewMedia(for: account, featured: false)
            Rectangle().fill(Color.accentColor.opacity(0.6)).frame(height: 3)
        }
        .padding(16)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.16)))
    }

    private func genericPreview(_ account: ComposerSocialAccount) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            accountHeader(account, size: 40)
            postText
            previewMedia(for: account, featured: false)
            Text("\(account.platform) preview").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(16)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.18)))
    }

    private var postText: some View {
        Text(resolvedText.isEmpty ? "Your post preview will appear here." : resolvedText)
            .font(.body).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
    }

    private func accountHeader(_ account: ComposerSocialAccount, size: CGFloat) -> some View {
        HStack(spacing: 10) {
            avatar(for: account, size: size)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.ownerName ?? "Account owner").font(.headline)
                Text(account.handle ?? account.profileURL?.host ?? account.platform)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(account.platform).font(.caption.bold()).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func avatar(for account: ComposerSocialAccount, size: CGFloat) -> some View {
        if let path = account.avatarPath, let url = safeWorkspaceAssetURL(path), let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().scaledToFill()
                .frame(width: size, height: size).clipShape(Circle())
                .accessibilityLabel("\(account.displayName) avatar")
        } else {
            Image(systemName: account.avatarSymbol)
                .font(.title3).foregroundStyle(.tint)
                .frame(width: size, height: size)
                .background(Color.accentColor.opacity(0.12), in: Circle())
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder private func previewMedia(for account: ComposerSocialAccount, featured: Bool) -> some View {
        let urls = effectiveMediaPaths(for: account.id).compactMap(safeContentAssetURL)
            .filter { url in
                guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
                return type.conforms(to: .image)
            }
        if featured {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(urls, id: \.path) { url in
                        if let image = NSImage(contentsOf: url) {
                            Image(nsImage: image).resizable().scaledToFill()
                                .frame(width: 240, height: 220).clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
        } else if !urls.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(urls, id: \.path) { url in
                        if let image = NSImage(contentsOf: url) {
                            Image(nsImage: image).resizable().scaledToFill()
                                .frame(width: 100, height: 82).clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 7))
                        }
                    }
                }
            }
        }
    }

    private func safeContentAssetURL(_ relativePath: String) -> URL? {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"),
              !relativePath.split(separator: "/").contains("..") else { return nil }
        let root = contentFolderURL.standardizedFileURL.resolvingSymlinksInPath()
        let resolved = contentFolderURL.appendingPathComponent(relativePath).standardizedFileURL.resolvingSymlinksInPath()
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard resolved.path.hasPrefix(prefix), FileManager.default.fileExists(atPath: resolved.path) else { return nil }
        return resolved
    }

    private func safeWorkspaceAssetURL(_ relativePath: String) -> URL? {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"),
              !relativePath.split(separator: "/").contains("..") else { return nil }
        let root = contentFolderURL.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        let resolved = root.appendingPathComponent(relativePath).standardizedFileURL.resolvingSymlinksInPath()
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard resolved.path.hasPrefix(prefix), FileManager.default.fileExists(atPath: resolved.path) else { return nil }
        return resolved
    }

    private func sectionTitle(_ title: String) -> some View { Text(title).font(.headline) }

    private func selectionBinding(for account: ComposerSocialAccount) -> Binding<Bool> {
        Binding(get: { selectedAccountIDs.contains(account.id) }, set: { selected in
            if selected {
                selectedAccountIDs.insert(account.id)
                selectedAccountID = account.id
            } else {
                selectedAccountIDs.remove(account.id)
            }
        })
    }

    private func accountTextBinding(_ id: String) -> Binding<String> {
        Binding(get: { customizedText[id] ?? originalText }, set: { customizedText[id] = $0 })
    }

    private func destinationStatusBinding(_ id: String) -> Binding<String> {
        Binding(get: { destinationStatuses[id] ?? "Draft" }, set: { destinationStatuses[id] = $0 })
    }

    private func destinationURLBinding(_ id: String) -> Binding<String> {
        Binding(get: { destinationURLs[id] ?? "" }, set: { destinationURLs[id] = $0 })
    }

    private var plannedDatePresenceBinding: Binding<Bool> {
        Binding(get: { plannedDate != nil }, set: { isEnabled in
            plannedDate = isEnabled ? (plannedDate ?? Date()) : nil
        })
    }

    private var plannedDateBinding: Binding<Date> {
        Binding(get: { plannedDate ?? Date() }, set: { plannedDate = $0 })
    }

    private func destinationPublicationDatePresenceBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { destinationPublicationDates[id] != nil }, set: { isEnabled in
            if isEnabled { destinationPublicationDates[id] = destinationPublicationDates[id] ?? Date() }
            else { destinationPublicationDates.removeValue(forKey: id) }
        })
    }

    private func destinationPublicationDateBinding(_ id: String) -> Binding<Date> {
        Binding(get: { destinationPublicationDates[id] ?? Date() }, set: { destinationPublicationDates[id] = $0 })
    }

    private func effectiveMediaPaths(for id: String) -> [String] {
        customMediaAccountIDs.contains(id) ? (destinationMediaOverrides[id] ?? []) : sharedMediaPaths
    }

    private func mediaOverrideBinding(_ id: String) -> Binding<[String]> {
        Binding(get: { destinationMediaOverrides[id] ?? [] }, set: { destinationMediaOverrides[id] = $0 })
    }

    private func copyCurrentText() -> String {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(resolvedText, forType: .string)
        return "Copied effective version"
    }

    private func persistDraft() {
        saveDraft()
    }

    private func saveDraft(completion: ((Bool) -> Void)? = nil) {
        guard !isSaving else { completion?(false); return }
        isSaving = true
        let draft = currentDraft
        onSave(draft) { success in
            isSaving = false
            if success {
                savedDraftSnapshot = draft
                onDirtyChange(false)
            }
            completion?(success)
        }
    }

    private func requestNavigation(to id: String) {
        if hasUnsavedChanges {
            requestedNavigationID = id
            showUnsavedChanges = true
        } else {
            onOpenRelated(id)
        }
    }

    private func confirmNavigation(to id: String) {
        requestedNavigationID = nil
        onNavigationConfirmed(id)
    }
}

struct ComposerDraft: Equatable {
    var title: String
    var originalText: String
    var selectedAccountIDs: Set<String>
    var appIDs: [String]
    var releaseID: String?
    var customizedText: [String: String]
    var destinationStatuses: [String: String]
    var destinationURLs: [String: String]
    var plannedDate: Date?
    var destinationPublicationDates: [String: Date]
    var sharedMediaPaths: [String]
    var destinationMediaOverrides: [String: [String]]
    var preservedDestinationIDs: Set<String>
    var includeArticleLink: Bool
    var status: String

    mutating func reconcileAccountAvailability(eligibleAccountIDs: Set<String>, unavailableDestinationIDs: Set<String>) {
        selectedAccountIDs.formIntersection(eligibleAccountIDs)
        preservedDestinationIDs = unavailableDestinationIDs
    }
}

extension MarketingComposerView {
    /// Builds a UI projection from canonical workspace records. The caller loads and saves body files.
    init(
        snapshot: WorkspaceSnapshot,
        content: ContentRecord,
        contentFolderURL: URL,
        originalText: String,
        customizedText: [String: String] = [:],
        article: ComposerArticleReference? = nil,
        releases: [ComposerReleaseReference] = [],
        characterGuidelines: [String: Int] = [:],
        requestedNavigationID: Binding<String?>,
        onSave: @escaping (ComposerDraft, @escaping (Bool) -> Void) -> Void,
        onOpenRelated: @escaping (String) -> Void,
        onNavigationConfirmed: @escaping (String) -> Void,
        onDirtyChange: @escaping (Bool) -> Void
    ) {
        let related = Self.relatedFamily(for: content, snapshot: snapshot)
        let destinationSelection = snapshot.socialDestinationSelection(for: content)
        let selectableIDs = destinationSelection.selectedAccountIDs
        let unavailableIDs = destinationSelection.unavailableAccountIDs
        self.init(
            contentFolderURL: contentFolderURL,
            apps: snapshot.apps,
            accounts: snapshot.socialAccounts.map { ComposerSocialAccount(record: $0, snapshot: snapshot) },
            article: article ?? Self.sourceArticle(for: content, snapshot: snapshot),
            hasUnavailableSource: content.sourceContentId.map { snapshot.contentByID[$0] == nil } ?? false,
            releases: releases,
            relatedItems: related.map {
                ComposerRelatedItem(id: $0.id, title: $0.title, kind: $0.kind.rawValue.capitalized, status: $0.status.rawValue.capitalized)
            },
            unavailableDestinationIDs: unavailableIDs,
            characterGuidelines: characterGuidelines,
            onSave: onSave,
            onOpenRelated: onOpenRelated,
            requestedNavigationID: requestedNavigationID,
            onNavigationConfirmed: onNavigationConfirmed,
            onDirtyChange: onDirtyChange
        )
        _title = State(initialValue: content.title)
        _selectedAppIDs = State(initialValue: Set(content.appIds))
        _selectedReleaseID = State(initialValue: content.releaseId)
        _originalText = State(initialValue: originalText)
        _includeArticleLink = State(initialValue: content.includeSourceLink)
        _draftStatus = State(initialValue: content.status.rawValue.capitalized)
        _selectedAccountIDs = State(initialValue: selectableIDs)
        _selectedAccountID = State(initialValue: selectableIDs.first)
        _customizedText = State(initialValue: customizedText)
        _destinationStatuses = State(initialValue: Dictionary(content.destinations.map { ($0.accountId, $0.status.rawValue.capitalized) }, uniquingKeysWith: { _, latest in latest }))
        _destinationURLs = State(initialValue: Dictionary(content.destinations.compactMap { destination in
            destination.publishedURL.map { (destination.accountId, $0.absoluteString) }
        }, uniquingKeysWith: { _, latest in latest }))
        _plannedDate = State(initialValue: content.plannedDate)
        _destinationPublicationDates = State(initialValue: Dictionary(content.destinations.compactMap { destination in
            destination.publishedDate.map { (destination.accountId, $0) }
        }, uniquingKeysWith: { _, latest in latest }))
        _sharedMediaPaths = State(initialValue: content.mediaPaths)
        _destinationMediaOverrides = State(initialValue: Dictionary(content.destinations.compactMap { destination in
            destination.mediaPaths.map { (destination.accountId, $0) }
        }, uniquingKeysWith: { _, latest in latest }))
        _customMediaAccountIDs = State(initialValue: Set(content.destinations.compactMap { $0.mediaPaths == nil ? nil : $0.accountId }))
        _savedDraftSnapshot = State(initialValue: ComposerDraft(
            title: content.title, originalText: originalText,
            selectedAccountIDs: selectableIDs, appIDs: content.appIds, releaseID: content.releaseId,
            customizedText: customizedText,
            destinationStatuses: Dictionary(content.destinations.map { ($0.accountId, $0.status.rawValue.capitalized) }, uniquingKeysWith: { _, latest in latest }),
            destinationURLs: Dictionary(content.destinations.compactMap { destination in destination.publishedURL.map { (destination.accountId, $0.absoluteString) } }, uniquingKeysWith: { _, latest in latest }),
            plannedDate: content.plannedDate,
            destinationPublicationDates: Dictionary(content.destinations.compactMap { destination in destination.publishedDate.map { (destination.accountId, $0) } }, uniquingKeysWith: { _, latest in latest }),
            sharedMediaPaths: content.mediaPaths,
            destinationMediaOverrides: Dictionary(content.destinations.compactMap { destination in destination.mediaPaths.map { (destination.accountId, $0) } }, uniquingKeysWith: { _, latest in latest }),
            preservedDestinationIDs: unavailableIDs,
            includeArticleLink: content.includeSourceLink,
            status: content.status.rawValue.capitalized
        ))
    }

    private static func sourceArticle(for content: ContentRecord, snapshot: WorkspaceSnapshot) -> ComposerArticleReference? {
        guard let sourceID = content.sourceContentId, let source = snapshot.contentByID[sourceID] else { return nil }
        return ComposerArticleReference(id: source.id, title: source.title, publishedURL: source.status == .published ? source.publishedURL : nil)
    }

    private static func relatedFamily(for content: ContentRecord, snapshot: WorkspaceSnapshot) -> [ContentRecord] {
        snapshot.relatedFamily(to: content.id)
    }
}

private struct PlatformGuidanceSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("guidance.threads") private var threads = 500
    @AppStorage("guidance.instagram") private var instagram = 2200
    @AppStorage("guidance.x") private var x = 280
    @AppStorage("guidance.facebook") private var facebook = 63206
    @AppStorage("guidance.linkedin") private var linkedIn = 3000

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Character Guidance").font(.title2.bold())
            Text("These local limits are approximate. Platform rules can vary by account and media.")
                .font(.callout).foregroundStyle(.secondary)
            Form {
                limitField("Threads", value: $threads)
                limitField("Instagram", value: $instagram)
                limitField("X", value: $x)
                limitField("Facebook", value: $facebook)
                limitField("LinkedIn", value: $linkedIn)
            }
            HStack {
                Button("Reset Defaults") {
                    threads = 500; instagram = 2200; x = 280; facebook = 63206; linkedIn = 3000
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420, height: 380)
    }

    private func limitField(_ title: String, value: Binding<Int>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("Characters", value: value, format: .number)
                .frame(width: 100)
                .multilineTextAlignment(.trailing)
        }
    }
}
