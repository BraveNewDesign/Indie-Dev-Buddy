import AppKit
import SocialKit
import SwiftUI
import UniformTypeIdentifiers

/// A lightweight editor surface that can be backed by the file workspace without owning storage.
struct ComposerSocialAccount: Identifiable, Hashable {
    let id: String
    let platform: String
    let handle: String?
    let profileURL: URL?
    let avatarPath: String?
    let ownerGroupID: String
    let ownerName: String?
    let enabled: Bool
    let hasOwner: Bool
    let providerIdentity: ContentRecipientIdentity?
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
        ownerGroupID = record.owner.map { "\($0.type):\($0.id)" } ?? ""
        providerIdentity = record.providerIdentity
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

    var apiPlatform: SocialPlatform? {
        guard enabled, let providerIdentity,
              let matched = SocialPlatform.workspacePlatform(platform),
              matched.rawValue == providerIdentity.platform else { return nil }
        return matched
    }
    var isAPISchedulable: Bool { apiPlatform != nil }
}

struct ComposerArticleReference: Identifiable, Hashable {
    let id: String
    let title: String
    let publishedURL: URL?
}

struct ComposerRelatedItem: Identifiable, Hashable {
    let id: String
    let title: String
    let kind: String
    let status: String
}

struct MarketingComposerView: View {
    @Environment(SocialPublishingRuntime.self) private var socialPublishingRuntime
    let contentID: String
    let workspaceID: String
    let contentFolderURL: URL
    let apps: [AppRecord]
    let accounts: [ComposerSocialAccount]
    let article: ComposerArticleReference?
    let hasUnavailableSource: Bool
    let relatedItems: [ComposerRelatedItem]
    let unavailableDestinationIDs: Set<String>
    let characterGuidelines: [String: Int]
    let onSave: (ComposerDraft, @escaping (Bool) -> Void) -> Void
    let onPublishNow: (ComposerDraft, String, @escaping (String?) -> Void) -> Void
    let onOpenRelated: (String) -> Void
    @Binding var requestedNavigationID: String?
    let onNavigationConfirmed: (String) -> Void
    let onDirtyChange: (Bool) -> Void

    @State private var title = ""
    @State private var selectedAppIDs = Set<String>()
    @State private var originalText = ""
    @State private var selectedAccountIDs = Set<String>()
    @State private var customizedText: [String: String] = [:]
    @State private var destinationStatuses: [String: String] = [:]
    @State private var destinationURLs: [String: String] = [:]
    @State private var destinationScheduleDates: [String: Date] = [:]
    @State private var destinationMediaLinks: [String: ComposerMediaLink] = [:]
    @State private var mentionResolutions: [String: ComposerMentionResolution] = [:]
    @State private var rescheduleAccountIDs: Set<String> = []
    @State private var savedAPIScheduledAccountIDs: Set<String> = []
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
    @State private var deliveryHistory: [LocalDeliveryJournal.Entry] = []
    @State private var dismissedDeliveryIDs = Set<UUID>()
    @State private var deliveryError: String?
    @State private var mentionResolutionMessage: String?
    @State private var connectedAccounts: [SocialAccount] = []
    @State private var publishableAccountIDs = Set<String>()
    @State private var mediaPublishableAccountIDs = Set<String>()
    @State private var uncertainDeliveryAccountIDs = Set<String>()
    @State private var apiPublishedAccountIDs = Set<String>()
    @State private var publishingAccountIDs = Set<String>()
    private enum EditorSection: String, CaseIterable {
        case content = "Content"
        case publishing = "Accounts & Publishing"
        case details = "Details & Relationships"
    }

    @State private var section = EditorSection.content
    @State private var editingAccountVersion = false
    private struct AccountSelection: Identifiable {
        let id = UUID()
        let accountIDs: Set<String>
    }

    @State private var accountSelection: AccountSelection?
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
    private var selectedAccounts: [ComposerSocialAccount] {
        eligibleAccounts.filter { selectedAccountIDs.contains($0.id) }
    }

    private var destinationIDs: Set<String> { selectedAccountIDs.union(unavailableDestinationIDs) }
    private var postedCount: Int { destinationIDs.filter { destinationStatuses[$0] == "Published" }.count }
    private var progressText: String { "\(postedCount) of \(destinationIDs.count) posted" }
    private var effectiveGlobalStatus: String {
        guard !destinationIDs.isEmpty else { return draftStatus }
        if postedCount == destinationIDs.count { return "Posted" }
        return postedCount == 0 ? "Not Posted" : "Partially Posted"
    }
    private var currentDraft: ComposerDraft {
        ComposerDraft(title: title, originalText: originalText, selectedAccountIDs: selectedAccountIDs,
                      appIDs: Array(selectedAppIDs).sorted(),
                      customizedText: customizedText, destinationStatuses: destinationStatuses,
                      destinationURLs: destinationURLs,
                      destinationScheduleDates: destinationScheduleDates,
                      destinationMediaLinks: destinationMediaLinks,
                      mentionResolutions: mentionResolutions,
                      rescheduleAccountIDs: rescheduleAccountIDs,
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
            if geometry.size.width >= 890 {
                HStack(spacing: 0) {
                    editorPane
                    Divider()
                    ScrollView { previewPane }
                        .frame(minWidth: 310, idealWidth: 360, maxWidth: 430)
                        .background(Color(nsColor: .windowBackgroundColor))
                }
            } else {
                VStack(spacing: 0) {
                    Picker("Composer view", selection: $compactPreviewSelected) {
                        Text("Edit").tag(false)
                        Text("Publishing & Preview").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    if compactPreviewSelected {
                        ScrollView { previewPane }
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
        .task(id: contentID) {
            while !Task.isCancelled {
                await refreshDeliveryHistory()
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
        .task(id: accounts) {
            let verified = try? await socialPublishingRuntime.connections.accounts()
            guard !Task.isCancelled else { return }
            connectedAccounts = verified ?? []
            var publishable = Set<String>()
            var mediaPublishable = Set<String>()
            for account in accounts {
                guard let identity = account.providerIdentity,
                      (verified ?? []).contains(where: {
                          $0.platform.rawValue == identity.platform && $0.server == identity.server && $0.remoteID == identity.remoteID
                      }) else { continue }
                guard let capabilities = try? await socialPublishingRuntime.connections.capabilities(for: identity) else {
                    continue
                }
                if capabilities.contains(.publishMedia) { mediaPublishable.insert(account.id) }
                if capabilities.contains(.publishText) || capabilities.contains(.publishMedia) {
                    publishable.insert(account.id)
                }
            }
            guard !Task.isCancelled else { return }
            publishableAccountIDs = publishable
            mediaPublishableAccountIDs = mediaPublishable
        }
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
        .sheet(item: $accountSelection) { selection in
            ComposerAccountChooser(accounts: eligibleAccounts, selectedIDs: selection.accountIDs) { ids in
                selectedAccountIDs = ids.intersection(eligibleAccounts.map(\.id))
            }
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
                TextField("Post title", text: $title)
                    .font(.title2.bold())
                    .textFieldStyle(.roundedBorder)
                header
                Picker("Editor section", selection: $section) {
                    ForEach(EditorSection.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Divider()
                switch section {
                case .content:
                    contentSection
                    destinationsSection
                    sourceSection
                    relatedSection
                case .publishing:
                    destinationsSection
                    ForEach(selectedAccounts) { account in
                        Divider()
                        publicationEditor(for: account)
                    }
                case .details:
                    metadataSection
                    sourceSection
                    relatedSection
                }
            }
            .padding(24)
            .frame(maxWidth: 780, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var header: some View {
        HStack {
            Label("Social Post", systemImage: "megaphone")
                .foregroundStyle(.secondary)
            if destinationIDs.isEmpty {
                Picker("Post status", selection: $draftStatus) {
                    ForEach(["Idea", "Draft", "Ready", "Published"], id: \.self) { Text($0).tag($0) }
                }
                .fixedSize()
            } else {
                Text("\(effectiveGlobalStatus) (\(postedCount) of \(destinationIDs.count))")
                    .foregroundStyle(postedCount > 0 ? Color.accentColor : .secondary)
            }
        }
        .font(.callout)
    }

    private var contentSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Post Text")
            if !selectedAccounts.isEmpty {
                Picker("Version", selection: $editingAccountVersion) {
                    Text("Shared Original").tag(false)
                    Text("Custom for Account").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            if editingAccountVersion, let account = selectedAccount {
                accountPicker
                if customizedText[account.id] != nil {
                    TextEditor(text: accountTextBinding(account.id))
                        .accessibilityLabel("Custom post text for \(account.displayName)")
                        .frame(minHeight: 150)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                    HStack {
                        Button("View Original") { showOriginalText = true }
                        Button("Use Original Text") { showUseOriginalConfirmation = true }
                    }
                } else {
                    Text("This account uses the shared original text.").foregroundStyle(.secondary)
                    Button("Customize Text") { customizedText[account.id] = originalText }
                }
                accountMedia(for: account)
            } else {
                originalSection
                sharedMediaSection
            }
            if selectedAccounts.contains(where: { $0.apiPlatform == .bluesky }) {
                VStack(alignment: .leading, spacing: 6) {
                    Button("Resolve @mentions for Bluesky") { Task { await resolveBlueskyMentions() } }
                        .disabled(isSaving || selectedAccounts.filter { $0.apiPlatform == .bluesky }.isEmpty)
                    if let text = mentionResolutionMessage {
                        Text(text).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if selectedAccounts.contains(where: { $0.apiPlatform != .bluesky }) {
                Text("Other platforms receive @names as plain text unless their own mention support is added.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var accountPicker: some View {
        Picker("Account", selection: $selectedAccountID) {
            ForEach(selectedAccounts) { account in
                Text(account.displayName).tag(Optional(account.id))
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
            Toggle("Planned date", isOn: plannedDatePresenceBinding)
            if plannedDate != nil {
                DatePicker("Planned", selection: plannedDateBinding, displayedComponents: .date)
                    .datePickerStyle(.field)
            }
        }
    }

    private var originalSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Accounts without custom text use the shared original.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $originalText)
                .accessibilityLabel("Shared original post text")
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
                sectionTitle("Selected Accounts (\(selectedAccounts.count))")
                Spacer()
                Button("Choose Accounts…") {
                    accountSelection = AccountSelection(accountIDs: selectedAccountIDs)
                }
            }
            if selectedAccounts.isEmpty {
                Text("Choose accounts to prepare their posts.").foregroundStyle(.secondary)
            }
            ForEach(selectedAccounts) { account in
                HStack {
                    SocialPlatformIcon(platform: account.platform, size: 20)
                    Text(account.displayName)
                    Spacer()
                    if customizedText[account.id] != nil || customMediaAccountIDs.contains(account.id) {
                        Text("Custom").foregroundStyle(.secondary)
                    }
                    Button("Preview") {
                        selectedAccountID = account.id
                        compactPreviewSelected = true
                    }
                    .buttonStyle(.link)
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
            deliveryHistorySection
            publishingProgress
            Divider()
            Text("Preview").font(.title2.bold())
            if !selectedAccounts.isEmpty { accountPicker }
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
                    } else if let guideline, Double(resolvedText.count) >= Double(guideline) * 0.9 {
                        Label("Approaching this platform’s suggested limit.", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    } else {
                        Text("Counts are guidance and may differ from platform validation.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Divider()
                Button("Edit Version for This Account") {
                    section = .content
                    editingAccountVersion = true
                    compactPreviewSelected = false
                }
                HStack {
                    Button {
                        copyMessage = copyCurrentText()
                    } label: { Label("Copy Text", systemImage: "doc.on.doc") }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .help("Copy the selected account’s effective post text (⇧⌘C)")
                    Text(copyMessage ?? "").font(.caption).foregroundStyle(.secondary)
                }
                if let url = account.profileURL { Link("Open Social Account", destination: url) }
            } else {
                ContentUnavailableView("Select an account", systemImage: "rectangle.and.text.magnifyingglass",
                                       description: Text("Choose an eligible destination to review its effective post."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(20)
        .sheet(isPresented: $showingGuidanceSettings) {
            PlatformGuidanceSettingsView()
        }
    }

    @ViewBuilder private var deliveryHistorySection: some View {
        let entries = deliveryHistory.filter { $0.intent.contentID == contentID && !dismissedDeliveryIDs.contains($0.intent.id) }
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("API Delivery History")
                if let deliveryError {
                    Text(deliveryError).font(.caption).foregroundStyle(.orange)
                }
                ForEach(entries, id: \.intent.id) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(entry.state == .queued && entry.canResumeContainer ? "Preparing on Meta" : entry.state.displayTitle)
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(entry.intent.scheduledDate.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let attempt = entry.attempts.last {
                            Text(attempt.message ?? attempt.finishedAt?.formatted(date: .abbreviated, time: .shortened) ?? "Delivery in progress")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if entry.state == .outcomeUnknown {
                            Text("Check the account before taking another action. Indie Dev Buddy will not retry automatically.")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        if entry.state == .overdue {
                            Label("Missed while the app was closed or Mac was asleep. This post was not sent automatically.", systemImage: "exclamationmark.clock")
                                .font(.caption).foregroundStyle(.orange)
                            HStack {
                                Button("Submit Now") {
                                    Task {
                                        do {
                                            let result = try await socialPublishingRuntime.publishNow(entry.intent)
                                            if result.state == .delivered { deliveryError = nil }
                                            else { deliveryError = result.message ?? "The post was not confirmed as published." }
                                        } catch { deliveryError = error.localizedDescription }
                                        await refreshDeliveryHistory()
                                    }
                                }
                                Button("Reschedule…") {
                                    selectedAccountID = entry.intent.destinationID
                                    selectedAccountIDs.insert(entry.intent.destinationID)
                                    destinationStatuses[entry.intent.destinationID] = "Scheduled"
                                    destinationScheduleDates[entry.intent.destinationID] = Date().addingTimeInterval(3600)
                                    rescheduleAccountIDs.insert(entry.intent.destinationID)
                                    section = .publishing
                                    deliveryError = "Choose the new API post time, then save to confirm the reschedule."
                                }
                                Button("Dismiss") { dismissedDeliveryIDs.insert(entry.intent.id) }
                            }
                        }
                        if let url = entry.attempts.last?.publishedURL { Link("View Post", destination: url) }
                        if entry.state == .queued || entry.state == .overdue {
                            Button(entry.canResumeContainer ? "Cancel Delivery" : "Cancel API Schedule", role: .destructive) {
                                Task {
                                    do {
                                        try await socialPublishingRuntime.cancel([entry.intent.id])
                                        deliveryError = nil
                                    } catch {
                                        deliveryError = "This schedule could not be canceled. Review the latest delivery status."
                                    }
                                    await refreshDeliveryHistory()
                                }
                            }
                            .font(.caption)
                        }
                    }
                    .padding(9)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            Divider()
        }
    }

    private func refreshDeliveryHistory() async {
        let root = contentFolderURL.deletingLastPathComponent().deletingLastPathComponent()
        let history = await socialPublishingRuntime.history(workspaceID: workspaceID, workspaceRoot: root)
        deliveryHistory = history
        let current = history.filter { $0.intent.contentID == contentID }
        let unknown = Set(current.filter { $0.state == .outcomeUnknown }.map(\.intent.destinationID))
        let confirmed = Set(current.filter { $0.state == .delivered }.map(\.intent.destinationID))
        uncertainDeliveryAccountIDs.subtract(confirmed.subtracting(unknown))
        uncertainDeliveryAccountIDs.formUnion(unknown)
    }

    private var publishingProgress: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Publishing Progress")
            if destinationIDs.isEmpty {
                Text("No destinations selected").foregroundStyle(.secondary)
            } else {
                ProgressView(value: Double(postedCount), total: Double(destinationIDs.count)) {
                    Text(progressText)
                }
                .tint(postedCount == destinationIDs.count ? .green : .accentColor)
                ForEach(selectedAccounts) { account in
                    let posted = destinationStatuses[account.id] == "Published"
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            SocialPlatformIcon(platform: account.platform, size: 20)
                            Text(account.displayName).fontWeight(.medium)
                            Spacer(minLength: 8)
                            Text(posted
                                 ? (apiPublishedAccountIDs.contains(account.id) ? "Published via API" : "Recorded manually")
                                 : destinationStatuses[account.id] ?? "Draft")
                                .foregroundStyle(posted ? Color.green : .secondary)
                        }
                        if posted, let date = destinationPublicationDates[account.id] {
                            Text(date.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if posted, let rawURL = destinationURLs[account.id], let url = URL(string: rawURL),
                           let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil {
                            Link("View Post", destination: url)
                        }
                    }
                }
                if !unavailableDestinationIDs.isEmpty {
                    Text("\(unavailableDestinationIDs.count) unavailable destination(s) included")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !selectedAccounts.isEmpty {
                    Button("Manage Publishing") {
                        section = .publishing
                        compactPreviewSelected = false
                    }
                }
            }
        }
    }

    private func publicationEditor(for account: ComposerSocialAccount) -> some View {
        let id = account.id
        let recipient = account.providerIdentity.flatMap { identity in
            connectedAccounts.first {
                $0.platform.rawValue == identity.platform && $0.server == identity.server && $0.remoteID == identity.remoteID
            }
        }
        let canSchedule = account.isAPISchedulable && recipient != nil
        return VStack(alignment: .leading, spacing: 8) {
            sectionTitle(account.displayName)
            Picker("Status", selection: destinationStatusBinding(id)) {
                Text("Idea").tag("Idea")
                Text("Draft").tag("Draft")
                Text("Ready").tag("Ready")
                if canSchedule || destinationStatuses[id] == "Scheduled" { Text("Scheduled on This Mac").tag("Scheduled") }
                Text("Manually Scheduled").tag("Manually Scheduled")
                if destinationStatuses[id] == "Published" { Text("Published").tag("Published") }
            }
            if destinationStatuses[id] == "Scheduled" {
                let hasSavedAPISchedule = savedAPIScheduledAccountIDs.contains(id)
                if hasSavedAPISchedule && !rescheduleAccountIDs.contains(id) {
                    Text("This scheduled post keeps its approved text, mentions, media, and time. Draft edits won’t change what is sent.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Reschedule with Current Draft") { rescheduleAccountIDs.insert(id) }
                } else if rescheduleAccountIDs.contains(id) {
                    Text("Saving will replace the approved payload with the current draft and selected time.")
                        .font(.caption).foregroundStyle(.orange)
                    Button("Keep Existing Scheduled Post") { rescheduleAccountIDs.remove(id) }
                }
                if let recipient {
                    Label("API recipient: \(recipient.username) on \(recipient.platform.workspaceTitle)", systemImage: "person.crop.circle.badge.checkmark")
                        .font(.caption)
                    if let status = socialPublishingRuntime.metaCredentialStatus[recipient.id] {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                }
                DatePicker("Local delivery time", selection: destinationScheduleDateBinding(id),
                           displayedComponents: [.date, .hourAndMinute])
                    .disabled(hasSavedAPISchedule && !rescheduleAccountIDs.contains(id))
                Text("Indie Dev Buddy sends this post at the selected time. Keep the app open and the Mac awake.")
                    .font(.caption).foregroundStyle(.secondary)
                if account.apiPlatform == .threads || account.apiPlatform == .instagram {
                    TextField(account.apiPlatform == .instagram ? "Public media URL" : "Public media URL (optional)",
                              text: destinationMediaLinkBinding(id).url)
                        .disabled(hasSavedAPISchedule && !rescheduleAccountIDs.contains(id))
                    Picker("Media type", selection: destinationMediaLinkBinding(id).kind) {
                        Text("Image").tag(ContentScheduledMediaKind.image)
                        Text("Video").tag(ContentScheduledMediaKind.video)
                    }
                    .disabled(hasSavedAPISchedule && !rescheduleAccountIDs.contains(id))
                    Text("Enter a public HTTPS link to a file you want to publish. The app never uploads workspace files automatically.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if !canSchedule {
                Text("API scheduling is not configured for this account. You can still mark it Manually Scheduled.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if account.apiPlatform == .facebookPages,
               mediaPublishableAccountIDs.contains(id) || destinationMediaLinks[id]?.url.isEmpty == false,
               destinationStatuses[id] != "Published", destinationStatuses[id] != "Manually Scheduled" {
                let savedScheduleIsLocked = destinationStatuses[id] == "Scheduled" &&
                    savedAPIScheduledAccountIDs.contains(id) && !rescheduleAccountIDs.contains(id)
                TextField("Public photo URL (optional)", text: destinationMediaLinkBinding(id).url)
                    .disabled(savedScheduleIsLocked)
                Text("Enter a public HTTPS link to a single photo. Facebook downloads the photo from that link.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if destinationStatuses[id] == "Manually Scheduled" {
                DatePicker("Manual post time", selection: destinationScheduleDateBinding(id),
                           displayedComponents: [.date, .hourAndMinute])
                Text("This records your plan only. Indie Dev Buddy will not send this post.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if destinationStatuses[id] == "Published" {
                Label(apiPublishedAccountIDs.contains(id) ? "Published through the connected API" : "Recorded as already posted",
                      systemImage: apiPublishedAccountIDs.contains(id) ? "checkmark.seal.fill" : "checkmark.circle")
                    .font(.caption).foregroundStyle(apiPublishedAccountIDs.contains(id) ? .green : .secondary)
                TextField("Post URL (optional)", text: destinationURLBinding(id))
                    .textFieldStyle(.roundedBorder)
                Toggle("Record publication date", isOn: destinationPublicationDatePresenceBinding(id))
                if destinationPublicationDates[id] != nil {
                    DatePicker("Posted on", selection: destinationPublicationDateBinding(id),
                               displayedComponents: [.date, .hourAndMinute])
                        .datePickerStyle(.field)
                }
            } else {
                let isPreparing = deliveryHistory.contains {
                    $0.intent.contentID == contentID && $0.intent.destinationID == id &&
                        ($0.state == .sending || ($0.state == .queued && $0.canResumeContainer))
                }
                if publishableAccountIDs.contains(id) && !uncertainDeliveryAccountIDs.contains(id) && !isPreparing {
                    Button(publishingAccountIDs.contains(id) ? "Publishing…" : "Publish Now") {
                        var draft = currentDraft
                        // An explicit immediate send retires any still-queued schedule for this account.
                        draft.destinationStatuses[id] = "Ready"
                        publishingAccountIDs.insert(id)
                        onPublishNow(draft, id) { message in
                            publishingAccountIDs.remove(id)
                            deliveryError = message
                            Task { await refreshDeliveryHistory() }
                        }
                    }
                        .buttonStyle(.borderedProminent)
                    .disabled(publishingAccountIDs.contains(id))
                }
                if isPreparing {
                    Label("Delivery is in progress.", systemImage: "clock")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if uncertainDeliveryAccountIDs.contains(id) {
                    Label("Check the provider before retrying this uncertain delivery.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                Button("Record as Already Posted") { destinationStatusBinding(id).wrappedValue = "Published" }
                Text("Use this only if you posted outside the app. API publishing records a verified receipt and post link.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func accountMedia(for account: ComposerSocialAccount) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Media for This Account")
            if customMediaAccountIDs.contains(account.id) {
                ContentMediaView(contentFolderURL: contentFolderURL, assetPaths: mediaOverrideBinding(account.id))
                Button("Use Shared Media") {
                    customMediaAccountIDs.remove(account.id)
                    destinationMediaOverrides.removeValue(forKey: account.id)
                }
            } else {
                Text("Using shared media (\(sharedMediaPaths.count))").foregroundStyle(.secondary)
                Button("Customize Media") {
                    customMediaAccountIDs.insert(account.id)
                    destinationMediaOverrides[account.id] = sharedMediaPaths
                }
            }
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

    @MainActor
    private func resolveBlueskyMentions() async {
        mentionResolutionMessage = nil
        let targets = selectedAccounts.filter { $0.apiPlatform == .bluesky }
        guard !targets.isEmpty else { return }
        var completed = 0
        for account in targets {
            guard let identity = account.providerIdentity else { continue }
            var text = customizedText[account.id] ?? originalText
            if includeArticleLink, let url = article?.publishedURL {
                text = text.isEmpty ? url.absoluteString : "\(text)\n\n\(url.absoluteString)"
            }
            do {
                let mentions = try await socialPublishingRuntime.connections.resolveBlueskyMentions(in: text, for: identity)
                mentionResolutions[account.id] = ComposerMentionResolution(textSnapshot: text, mentions: mentions)
                completed += 1
            } catch {
                mentionResolutionMessage = "Could not resolve mentions for \(account.displayName). Check the Bluesky connection and handle spelling."
                return
            }
        }
        mentionResolutionMessage = completed == 0
            ? "Connect a Bluesky account to resolve tagged mentions."
            : "Resolved \(completed) Bluesky account version\(completed == 1 ? "" : "s"). Scheduled posts keep the resolved account IDs."
    }

    private func accountTextBinding(_ id: String) -> Binding<String> {
        Binding(get: { customizedText[id] ?? originalText }, set: { customizedText[id] = $0 })
    }

    private func destinationStatusBinding(_ id: String) -> Binding<String> {
        Binding(get: { destinationStatuses[id] ?? "Draft" }, set: { status in
            destinationStatuses[id] = status
            if status == "Manually Scheduled" || status == "Scheduled" {
                destinationScheduleDates[id] = destinationScheduleDates[id] ?? Date().addingTimeInterval(3600)
            } else {
                destinationScheduleDates.removeValue(forKey: id)
            }
            if status != "Scheduled" { destinationMediaLinks.removeValue(forKey: id) }
            if status == "Published" {
                destinationPublicationDates[id] = destinationPublicationDates[id] ?? Date()
            } else {
                destinationPublicationDates.removeValue(forKey: id)
                destinationURLs.removeValue(forKey: id)
            }
        })
    }

    private func destinationURLBinding(_ id: String) -> Binding<String> {
        Binding(get: { destinationURLs[id] ?? "" }, set: { destinationURLs[id] = $0 })
    }

    private func destinationScheduleDateBinding(_ id: String) -> Binding<Date> {
        Binding(get: { destinationScheduleDates[id] ?? Date().addingTimeInterval(3600) },
                set: { destinationScheduleDates[id] = $0 })
    }

    private func destinationMediaLinkBinding(_ id: String) -> Binding<ComposerMediaLink> {
        Binding(get: { destinationMediaLinks[id] ?? ComposerMediaLink() },
                set: { destinationMediaLinks[id] = $0 })
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
                rescheduleAccountIDs = []
                savedAPIScheduledAccountIDs = Set(draft.destinationStatuses.compactMap { accountID, status in
                    status == "Scheduled" ? accountID : nil
                })
                savedDraftSnapshot = currentDraft
                onDirtyChange(false)
                Task { await refreshDeliveryHistory() }
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

struct ComposerMediaLink: Equatable {
    var url = ""
    var kind: ContentScheduledMediaKind = .image
}

struct ComposerDraft: Equatable {
    var title: String
    var originalText: String
    var selectedAccountIDs: Set<String>
    var appIDs: [String]
    var customizedText: [String: String]
    var destinationStatuses: [String: String]
    var destinationURLs: [String: String]
    var destinationScheduleDates: [String: Date] = [:]
    var destinationMediaLinks: [String: ComposerMediaLink] = [:]
    var mentionResolutions: [String: ComposerMentionResolution] = [:]
    var rescheduleAccountIDs: Set<String> = []
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

struct ComposerMentionResolution: Equatable {
    var textSnapshot: String
    var mentions: [ContentScheduledMention]
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
        characterGuidelines: [String: Int] = [:],
        requestedNavigationID: Binding<String?>,
        onSave: @escaping (ComposerDraft, @escaping (Bool) -> Void) -> Void,
        onPublishNow: @escaping (ComposerDraft, String, @escaping (String?) -> Void) -> Void = { _, _, completion in completion(nil) },
        onOpenRelated: @escaping (String) -> Void,
        onNavigationConfirmed: @escaping (String) -> Void,
        onDirtyChange: @escaping (Bool) -> Void
    ) {
        let related = Self.relatedFamily(for: content, snapshot: snapshot)
        let destinationSelection = snapshot.socialDestinationSelection(for: content)
        let selectableIDs = destinationSelection.selectedAccountIDs
        let unavailableIDs = destinationSelection.unavailableAccountIDs
        self.init(
            contentID: content.id,
            workspaceID: snapshot.manifest.id,
            contentFolderURL: contentFolderURL,
            apps: snapshot.apps,
            accounts: snapshot.socialAccounts.map { ComposerSocialAccount(record: $0, snapshot: snapshot) },
            article: article ?? Self.sourceArticle(for: content, snapshot: snapshot),
            hasUnavailableSource: content.sourceContentId.map { snapshot.contentByID[$0] == nil } ?? false,
            relatedItems: related.filter { $0.id != content.sourceContentId }.map {
                ComposerRelatedItem(id: $0.id, title: $0.title, kind: $0.kind.rawValue.capitalized, status: $0.status.rawValue.capitalized)
            },
            unavailableDestinationIDs: unavailableIDs,
            characterGuidelines: characterGuidelines,
            onSave: onSave,
            onPublishNow: onPublishNow,
            onOpenRelated: onOpenRelated,
            requestedNavigationID: requestedNavigationID,
            onNavigationConfirmed: onNavigationConfirmed,
            onDirtyChange: onDirtyChange
        )
        _title = State(initialValue: content.title)
        _selectedAppIDs = State(initialValue: Set(content.appIds))
        _originalText = State(initialValue: originalText)
        _includeArticleLink = State(initialValue: content.includeSourceLink)
        _draftStatus = State(initialValue: content.status.displayTitle)
        _selectedAccountIDs = State(initialValue: selectableIDs)
        _selectedAccountID = State(initialValue: selectableIDs.sorted().first)
        _customizedText = State(initialValue: customizedText)
        _destinationStatuses = State(initialValue: Dictionary(content.destinations.map { ($0.accountId, $0.status.displayTitle) }, uniquingKeysWith: { _, latest in latest }))
        _destinationURLs = State(initialValue: Dictionary(content.destinations.compactMap { destination in
            destination.publishedURL.map { (destination.accountId, $0.absoluteString) }
        }, uniquingKeysWith: { _, latest in latest }))
        _destinationScheduleDates = State(initialValue: Dictionary(content.destinations.compactMap { destination in
            destination.schedule.map { (destination.accountId, $0.scheduledDate) }
        }, uniquingKeysWith: { _, latest in latest }))
        _savedAPIScheduledAccountIDs = State(initialValue: Set(content.destinations.compactMap { destination in
            destination.schedule?.mode == .api ? destination.accountId : nil
        }))
        _uncertainDeliveryAccountIDs = State(initialValue: Set(content.destinations.compactMap { destination in
            destination.schedule?.state == .outcomeUnknown || destination.deliveryHistory?.last?.state == .outcomeUnknown
                ? destination.accountId : nil
        }))
        _apiPublishedAccountIDs = State(initialValue: Set(content.destinations.compactMap { destination in
            destination.status == .published && destination.deliveryHistory?.contains(where: { $0.state == .delivered }) == true
                ? destination.accountId : nil
        }))
        let mediaLinks = Dictionary(content.destinations.compactMap { destination in
            destination.schedule?.media?.first.map {
                (destination.accountId, ComposerMediaLink(url: $0.publicURL.absoluteString, kind: $0.kind))
            }
        }, uniquingKeysWith: { _, latest in latest })
        _destinationMediaLinks = State(initialValue: mediaLinks)
        let savedMentions = Dictionary(content.destinations.compactMap { destination -> (String, ComposerMentionResolution)? in
            guard let schedule = destination.schedule, let textSnapshot = schedule.textSnapshot,
                  let mentions = schedule.mentions, !mentions.isEmpty else { return nil }
            return (destination.accountId, ComposerMentionResolution(textSnapshot: textSnapshot, mentions: mentions))
        }, uniquingKeysWith: { _, latest in latest })
        _mentionResolutions = State(initialValue: savedMentions)
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
            selectedAccountIDs: selectableIDs, appIDs: content.appIds.sorted(),
            customizedText: customizedText,
            destinationStatuses: Dictionary(content.destinations.map { ($0.accountId, $0.status.displayTitle) }, uniquingKeysWith: { _, latest in latest }),
            destinationURLs: Dictionary(content.destinations.compactMap { destination in destination.publishedURL.map { (destination.accountId, $0.absoluteString) } }, uniquingKeysWith: { _, latest in latest }),
            destinationScheduleDates: Dictionary(content.destinations.compactMap { destination in destination.schedule.map { (destination.accountId, $0.scheduledDate) } }, uniquingKeysWith: { _, latest in latest }),
            destinationMediaLinks: mediaLinks,
            mentionResolutions: savedMentions,
            plannedDate: content.plannedDate,
            destinationPublicationDates: Dictionary(content.destinations.compactMap { destination in destination.publishedDate.map { (destination.accountId, $0) } }, uniquingKeysWith: { _, latest in latest }),
            sharedMediaPaths: content.mediaPaths,
            destinationMediaOverrides: Dictionary(content.destinations.compactMap { destination in destination.mediaPaths.map { (destination.accountId, $0) } }, uniquingKeysWith: { _, latest in latest }),
            preservedDestinationIDs: unavailableIDs,
            includeArticleLink: content.includeSourceLink,
            status: content.status.displayTitle
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

private struct ComposerAccountChooser: View {
    @Environment(\.dismiss) private var dismiss
    let accounts: [ComposerSocialAccount]
    let onConfirm: (Set<String>) -> Void
    @State private var selectedIDs: Set<String>

    init(accounts: [ComposerSocialAccount], selectedIDs: Set<String>, onConfirm: @escaping (Set<String>) -> Void) {
        self.accounts = accounts
        self.onConfirm = onConfirm
        _selectedIDs = State(initialValue: selectedIDs)
    }

    var body: some View {
        let groups = Dictionary(grouping: accounts, by: \.ownerGroupID)
        let sortedGroups = groups.values.sorted {
            let left = $0.first?.ownerName ?? ""
            let right = $1.first?.ownerName ?? ""
            if left == right { return ($0.first?.ownerGroupID ?? "") < ($1.first?.ownerGroupID ?? "") }
            return left.localizedStandardCompare(right) == .orderedAscending
        }
        return VStack(alignment: .leading, spacing: 14) {
            Text("Choose Accounts").font(.title2.bold())
            if accounts.isEmpty {
                ContentUnavailableView("No eligible accounts", systemImage: "person.crop.circle.badge.exclamationmark",
                                       description: Text("Enable an account with an owner, platform, and handle or profile URL."))
            } else {
                List {
                    ForEach(sortedGroups.compactMap(\.first)) { owner in
                        Section(owner.ownerName ?? "Accounts") {
                            ForEach(groups[owner.ownerGroupID] ?? []) { account in
                                Toggle(account.displayName, isOn: Binding(
                                    get: { selectedIDs.contains(account.id) },
                                    set: { isSelected in
                                        if isSelected { selectedIDs.insert(account.id) }
                                        else { selectedIDs.remove(account.id) }
                                    }
                                ))
                                .toggleStyle(.checkbox)
                            }
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Done") {
                    onConfirm(selectedIDs)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460, height: 390)
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
