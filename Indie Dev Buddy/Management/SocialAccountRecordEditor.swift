import SwiftUI
import AppKit
import UniformTypeIdentifiers
import SocialKit

struct SocialAccountRecordEditor: View {
    @Environment(SocialPublishingRuntime.self) private var socialPublishingRuntime
    let record: SocialAccountRecord?
    let owners: [OwnerChoice]
    let identities: [IdentityRecord]
    let workspaceStore: WorkspaceStore
    let onDirtyChange: (Bool) -> Void
    let onSave: (SocialAccountRecord) async -> Bool
    @Binding var connectionRequest: String?
    @State private var platform = "Threads"
    @State private var customPlatform = ""
    @State private var ownerID = ""
    @State private var handle = ""
    @State private var displayName = ""
    @State private var profileURL = ""
    @State private var enabled = true
    @State private var draftID = UUID().uuidString.lowercased()
    @State private var baselineRecord: SocialAccountRecord?
    @State private var avatarPath: String?
    @State private var avatarPreview: NSImage?
    @State private var identityAvatarPreview: NSImage?
    @State private var avatarError: String?
    @State private var showingAvatarPicker = false
    private enum ConnectionFollowUp { case authorize, switchAccount, activity }
    @State private var connectionFollowUp: ConnectionFollowUp?
    @State private var savedConnections: [SocialAccount] = []
    @State private var loadedSavedConnections = false
    @State private var expectedConnection: ContentRecipientIdentity?
    @State private var checkingConnection = false
    @State private var showingBlueskyConnect = false
    @State private var showingOAuthConnect = false
    @State private var showingAccountActivity = false
    @State private var providerIdentity: ContentRecipientIdentity?
    @State private var connectedAccount: SocialAccount?
    @State private var connectionCapabilities: Set<SocialCapability> = []
    @State private var connectionMessage: String?
    @State private var showingConnectionManager = false
    @State private var saving = false
    private let platforms = ["Bluesky", "Threads", "Instagram", "X", "Facebook", "LinkedIn", "Mastodon", "GitHub", "Other"]
    private var platformValue: String { platform == "Other" ? customPlatform : platform }
    private var apiPlatform: SocialPlatform? { SocialPlatform.workspacePlatform(platformValue) }

    init(record: SocialAccountRecord?, owners: [OwnerChoice], identities: [IdentityRecord], workspaceStore: WorkspaceStore, onDirtyChange: @escaping (Bool) -> Void, onSave: @escaping (SocialAccountRecord) async -> Bool, connectionRequest: Binding<String?>) {
        self._connectionRequest = connectionRequest
        self.record = record
        self.owners = owners
        self.identities = identities
        self.workspaceStore = workspaceStore
        self.onDirtyChange = onDirtyChange
        self.onSave = onSave
        _baselineRecord = State(initialValue: record)

        let ownerID = record?.owner.map { "\($0.type.rawValue):\($0.id)" } ?? ""
        let ownerIdentity = ownerID.hasPrefix("identity:")
            ? identities.first { $0.id == String(ownerID.dropFirst("identity:".count)) }
            : nil
        _ownerID = State(initialValue: ownerID)
        _avatarPath = State(initialValue: record?.avatarPath)
        _avatarPreview = State(initialValue: Self.loadImage(path: record?.avatarPath, root: workspaceStore.rootURL))
        _identityAvatarPreview = State(initialValue: Self.loadImage(path: ownerIdentity?.photoPath, root: workspaceStore.rootURL))
    }

    var body: some View {
        Form {
            accountHeader
            connectionSection
            Section("Profile") {
                Picker("Platform", selection: $platform) { ForEach(platforms, id: \.self) { Text($0).tag($0) } }
                if platform == "Other" { TextField("Platform name", text: $customPlatform) }
                Picker("Owner", selection: $ownerID) {
                    Text("Choose owner").tag("")
                    ForEach(owners) { Text("\($0.title) (\($0.detail))").tag($0.id) }
                }
                TextField("Handle", text: $handle, prompt: Text("@name"))
                TextField("Display name", text: $displayName)
                TextField("Profile URL", text: $profileURL)
                Toggle("Enabled for new posts", isOn: $enabled)
                HStack(spacing: 12) {
                    Group {
                        if let displayedAvatarPreview {
                            Image(nsImage: displayedAvatarPreview).resizable().scaledToFill()
                        } else {
                            Image(systemName: "person.crop.circle.fill").resizable().scaledToFit().foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 42, height: 42).clipShape(Circle())
                    .accessibilityLabel(displayedAvatarPreview == nil ? "No account avatar selected" : "Account avatar preview")
                    VStack(alignment: .leading, spacing: 4) {
                        Button(avatarPath == nil ? "Choose Avatar…" : "Replace Avatar…") { showingAvatarPicker = true }
                        if avatarPath != nil {
                            Button("Use Identity Photo") { avatarPath = nil; avatarPreview = nil; avatarError = nil }.font(.caption)
                        } else {
                            Text(selectedIdentity?.photoPath == nil ? "Uses the platform icon when no owner photo is available." : "Uses the owner’s identity photo.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let avatarError { Text(avatarError).font(.caption).foregroundStyle(.red) }
                    }
                }
            }
            Section {
                HStack {
                    if isDirty { Text("Unsaved changes").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button(saving ? "Saving…" : "Save Changes") { Task { await save() } }
                        .buttonStyle(.borderedProminent).disabled(!canSave || !isDirty)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(record == nil ? "New Social Account" : platformValue)
        .focusedSceneValue(\.workspaceSaveAction, canSave ? WorkspaceSaveAction { completion in
            Task { completion(await save()) }
        } : nil)
        .sheet(isPresented: $showingBlueskyConnect) {
            let savedHandle = savedConnections.first { SocialOAuthRegistration.identity(for: $0) == expectedConnection }?.username
            BlueskyConnectionSheet(initialHandle: savedHandle ?? handle, expected: expectedConnection, onConnected: applyConnection)
        }
        .sheet(isPresented: $showingOAuthConnect) {
            if let apiPlatform {
                SocialOAuthConnectionSheet(platform: apiPlatform, expected: expectedConnection, recovery: expectedConnection == nil ? nil : connectionRecovery, onConnected: applyConnection)
            }
        }
        .sheet(isPresented: $showingAccountActivity) {
            if let providerIdentity, let connectedAccount {
                SocialAccountActivityView(identity: providerIdentity, account: connectedAccount)
            }
        }
        .sheet(isPresented: $showingConnectionManager, onDismiss: openConnectionFollowUp) {
            if let apiPlatform {
                SocialConnectionManagementSheet(
                    platform: apiPlatform, identity: providerIdentity, account: connectedAccount,
                    capabilities: connectionCapabilities, statusMessage: connectionMessage,
                    recovery: connectionRecovery, lastAvailable: connectionLastAvailable,
                    checking: checkingConnection,
                    lastAttempt: connectionID.flatMap { socialPublishingRuntime.lastManualCheck[$0] },
                    onCheck: { Task { await repairConnection() } },
                    onAuthorize: { dismissConnectionManager(then: .authorize) },
                    onSwitch: { dismissConnectionManager(then: .switchAccount) },
                    onActivity: { dismissConnectionManager(then: .activity) },
                    onUnlink: unlinkConnection
                )
            }
        }
        .onAppear {
            load()
            openRequestedConnection()
        }
        .onChange(of: connectionRequest) { _, _ in
            openRequestedConnection()
        }
        .task(id: providerIdentity) {
            connectedAccount = nil
            connectionCapabilities = []
            connectionMessage = nil
            guard let identity = providerIdentity else { return }
            await loadSavedConnection(identity)
        }
        .task(id: apiPlatform) {
            await refreshSavedConnections()
        }
        .onChange(of: platformValue) { _, newValue in
            if SocialPlatform.workspacePlatform(newValue)?.rawValue != providerIdentity?.platform { providerIdentity = nil }
        }
        .onChange(of: dirtySignature) { _, _ in onDirtyChange(isDirty) }
        .onChange(of: ownerID) { _, _ in loadIdentityAvatarPreview() }
        .onChange(of: selectedIdentity?.photoPath) { _, _ in loadIdentityAvatarPreview() }
        .fileImporter(isPresented: $showingAvatarPicker, allowedContentTypes: [.image], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task { await importAvatar(from: url) }
            case .failure(let error): avatarError = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private var connectionSection: some View {
        Section(providerIdentity == nil ? "Optional API connection" : "API connection") {
            if let apiPlatform {
                HStack(alignment: .top, spacing: 12) {
                    if providerIdentity != nil || connectionNeedsAttention {
                        Image(systemName: connectionSymbol).font(.title3).foregroundStyle(connectionTint).frame(width: 28)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(connectionTitle).font(.headline)
                        Text(connectionSummary).font(.subheadline).foregroundStyle(.secondary)
                        if let connectedAccount, let name = connectedAccount.authenticatedUserName,
                           name != connectedAccount.displayName {
                            Text("Authorized by \(name)").font(.caption).foregroundStyle(.secondary)
                        }
                        if let profile = connectedAccount?.profileURL, profile.scheme == "https" { Link("Open profile", destination: profile).font(.caption) }
                    }
                    Spacer(minLength: 8)
                    if providerIdentity == nil {
                        let saved = savedConnections.filter { $0.platform == apiPlatform }
                        if saved.isEmpty {
                            Button("Connect API…") { presentConnection(for: apiPlatform) }
                                .buttonStyle(.bordered)
                        } else {
                            Menu("Connect API") {
                                ForEach(saved) { account in
                                    Button("Use @\(account.username)") {
                                        Task { await reuseSavedConnection(account) }
                                    }
                                }
                                Divider()
                                Button("Connect Another Account…") { presentConnection(for: apiPlatform) }
                            }
                            .disabled(checkingConnection)
                        }
                    } else {
                        VStack(alignment: .trailing, spacing: 6) {
                            if connectionRecovery?.needsAuthorization == true {
                                Button("Authorize Again…") { presentConnection(for: apiPlatform) }
                                    .buttonStyle(.borderedProminent)
                            }
                            Button("Manage Connection…") { showingConnectionManager = true }
                                .buttonStyle(.bordered)
                                .accessibilityHint("View capabilities and manage authorization")
                        }
                    }
                }
                if let status = connectedAccount.flatMap({ socialPublishingRuntime.metaCredentialStatus[$0.id] }) {
                    Text(status).font(.caption).foregroundStyle(status.localizedCaseInsensitiveContains("reconnect") ? .orange : .secondary)
                }
                if let connectionMessage { Label(connectionMessage, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                if providerIdentity == nil, [.facebookPages, .instagram, .threads].contains(apiPlatform) {
                    Text("Connect with a Meta access token or browser sign-in where configured.").font(.caption).foregroundStyle(.secondary)
                } else if providerIdentity == nil, apiPlatform.requiresBroker {
                    Text("Browser authorization uses a provider registration and trusted HTTPS exchange service.").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Label("Manual posting", systemImage: "hand.tap")
                Text("This platform does not have a publishing API connection in Indie Dev Buddy.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var accountHeader: some View {
        Section {
            HStack(spacing: 14) {
                Group {
                    if let displayedAvatarPreview { Image(nsImage: displayedAvatarPreview).resizable().scaledToFill() }
                    else { SocialPlatformIcon(platform: platformValue, size: 40) }
                }
                .frame(width: 48, height: 48).clipShape(Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (handle.isEmpty ? "New Social Account" : handle) : displayName)
                        .font(.title3.weight(.semibold))
                    Text([handle.isEmpty ? nil : (handle.hasPrefix("@") ? handle : "@\(handle)"), platformValue, selectedOwnerName].compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                if let providerIdentity {
                    connectionBadge(for: providerIdentity)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func connectionBadge(for identity: ContentRecipientIdentity) -> some View {
        let status: (title: String, symbol: String)
        if connectionNeedsAttention {
            status = ("Needs attention", "exclamationmark.circle")
        } else if connectedAccount == nil {
            status = ("API linked", "link")
        } else if SocialEngagementStore.manualOnly(identity) {
            status = ("Saved connection", "link")
        } else {
            status = ("Connected", "checkmark.circle")
        }
        return Label(status.title, systemImage: status.symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
    }

    private var selectedOwnerName: String? { owners.first(where: { $0.id == ownerID })?.title }
    private var connectionTitle: String {
        if checkingConnection { return "Checking saved connection…" }
        if connectionNeedsAttention { return "Connection needs attention" }
        if providerIdentity != nil && connectedAccount == nil { return "Connection unavailable on this Mac" }
        if let connectedAccount {
            let saved = providerIdentity.map(SocialEngagementStore.manualOnly) == true
            return saved ? "Saved connection for @\(connectedAccount.username)" : "Connected as @\(connectedAccount.username)"
        }
        return "API connection is optional"
    }
    private var connectionSummary: String {
        if let connectionRecovery, !connectionRecovery.isAvailable { return connectionRecovery.message }
        if let connectionMessage { return connectionMessage }
        if providerIdentity != nil && connectedAccount == nil { return "Credentials may be missing or need renewal." }
        if connectedAccount != nil {
            let names = Set(connectionCapabilities.compactMap(capabilityLabel)).sorted()
            return names.isEmpty ? "Connection verified." : "Can \(names.joined(separator: ", "))."
        }
        return "Manual posting remains available without an API connection."
    }
    private var connectionSymbol: String { connectionNeedsAttention ? "exclamationmark.triangle.fill" : (connectedAccount == nil ? (providerIdentity == nil ? "link" : "exclamationmark.triangle") : "checkmark.circle.fill") }
    private var connectionTint: Color { connectionNeedsAttention ? .orange : (connectedAccount == nil ? (providerIdentity == nil ? .secondary : .orange) : .green) }
    private var connectionNeedsAttention: Bool {
        if connectionMessage != nil { return true }
        if let connectionRecovery, !connectionRecovery.isAvailable { return true }
        guard let id = connectedAccount?.id else { return false }
        return socialPublishingRuntime.metaCredentialStatus[id]?.localizedCaseInsensitiveContains("reconnect") == true
    }
    private func capabilityLabel(_ capability: SocialCapability) -> String? {
        switch capability {
        case .publishText: "publish text"
        case .publishMedia: "publish media"
        case .publishMultipleMedia: "publish multiple items"
        case .listPosts: "view posts"
        case .reply: "reply"
        case .readReplies: "view replies"
        case .deleteReply: "delete replies"
        case .moderateReplies: "moderate replies"
        case .like, .unlike: "manage likes"
        case .repost, .unrepost: "repost"
        case .analytics: "view analytics"
        case .resolveMentions: "resolve mentions"
        case .readPost, .refreshSession: nil
        }
    }

    private var connectionID: SocialAccount.ID? {
        guard let identity = providerIdentity, let platform = SocialPlatform(rawValue: identity.platform) else { return nil }
        return .init(platform: platform, server: identity.server, remoteID: identity.remoteID)
    }

    private var connectionRecovery: SocialConnections.Recovery? {
        guard let connectionID else { return nil }
        if let recovery = socialPublishingRuntime.connectionStatus[connectionID] { return recovery }
        return loadedSavedConnections && !savedConnections.contains(where: { $0.id == connectionID })
            ? .missingCredential : nil
    }

    private var connectionLastAvailable: Date? {
        providerIdentity.flatMap { socialPublishingRuntime.lastAvailable(for: $0) }
    }

    private func dismissConnectionManager(then followUp: ConnectionFollowUp) {
        connectionFollowUp = followUp
        showingConnectionManager = false
    }

    private func openConnectionFollowUp() {
        guard let followUp = connectionFollowUp, let platform = apiPlatform else { return }
        connectionFollowUp = nil
        switch followUp {
        case .authorize: presentConnection(for: platform)
        case .switchAccount: presentConnection(for: platform, switching: true)
        case .activity: showingAccountActivity = true
        }
    }

    private func refreshSavedConnections() async {
        guard let accounts = try? await socialPublishingRuntime.connections.accounts(), !Task.isCancelled else { return }
        savedConnections = accounts
        loadedSavedConnections = true
    }

    private func reuseSavedConnection(_ account: SocialAccount) async {
        guard !checkingConnection else { return }
        checkingConnection = true
        defer { checkingConnection = false }
        let identity = SocialOAuthRegistration.identity(for: account)
        let result = await socialPublishingRuntime.checkConnection(identity, manual: true)
        guard !Task.isCancelled, providerIdentity == nil, apiPlatform == account.platform else { return }
        if result.isAvailable {
            connectionMessage = nil
            applyConnection(account)
        } else if result.needsAuthorization {
            expectedConnection = identity
            if account.platform == .bluesky { showingBlueskyConnect = true }
            else { showingOAuthConnect = true }
        } else {
            connectionMessage = result.message
        }
    }

    private func loadSavedConnection(_ identity: ContentRecipientIdentity) async {
        let accounts = try? await socialPublishingRuntime.connections.accounts()
        guard !Task.isCancelled, providerIdentity == identity else { return }
        connectedAccount = accounts?.first {
            $0.platform.rawValue == identity.platform && $0.server == identity.server && $0.remoteID == identity.remoteID
        }
        guard connectedAccount != nil else { connectionCapabilities = []; return }
        do {
            connectionCapabilities = try await socialPublishingRuntime.connections.capabilities(for: identity)
            connectionMessage = nil
        } catch {
            connectionCapabilities = []
            connectionMessage = "Connection check failed. Reconnect if publishing is unavailable."
        }
    }

    private func repairConnection() async {
        guard !checkingConnection, let identity = providerIdentity else { return }
        checkingConnection = true
        defer { checkingConnection = false }
        let result = await socialPublishingRuntime.checkConnection(identity, manual: true)
        guard providerIdentity == identity else { return }
        connectionMessage = nil
        if result.isAvailable {
            await loadSavedConnection(identity)
        }
    }

    private func openRequestedConnection() {
        guard let record, connectionRequest == record.id, let apiPlatform else { return }
        connectionRequest = nil
        if providerIdentity == nil { presentConnection(for: apiPlatform) }
        else { showingConnectionManager = true }
    }

    private func presentConnection(for platform: SocialPlatform, switching: Bool = false) {
        expectedConnection = switching ? nil : providerIdentity
        if platform == .bluesky { showingBlueskyConnect = true }
        else { showingOAuthConnect = true }
    }

    private func applyConnection(_ account: SocialAccount) {
        socialPublishingRuntime.updateCredentialStatus(for: account.id)
        connectedAccount = account
        providerIdentity = ContentRecipientIdentity(platform: account.platform.rawValue,
                                                     server: account.server,
                                                     remoteID: account.remoteID)
        // Connecting an existing record saves its link independently of any edits to profile metadata.
        if baselineRecord == nil && record == nil {
            if handle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { handle = account.username }
            if displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let name = account.displayName, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                displayName = name
            }
            if profileURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let url = account.profileURL, url.scheme?.lowercased() == "https", url.host != nil {
                profileURL = url.absoluteString
            }
        }
        Task { await persistConnectionLink() }
    }

    private func persistConnectionLink() async {
        let identity = providerIdentity
        guard let identity else { return }
        let linkedRecord: SocialAccountRecord
        if let record = baselineRecord ?? record {
            linkedRecord = SocialAccountRecord(id: record.id, platform: platformValue.trimmingCharacters(in: .whitespacesAndNewlines), owner: record.owner,
                                               handle: record.handle, displayName: record.displayName,
                                               profileURL: record.profileURL, avatarPath: record.avatarPath,
                                               providerIdentity: identity, enabled: record.enabled)
        } else {
            guard canSave else {
                connectionMessage = "Connection authorized. Add an owner and profile handle, then save the account to link it in this workspace."
                return
            }
            let choice = owners.first(where: { $0.id == ownerID })
            linkedRecord = SocialAccountRecord(id: draftID, platform: platformValue, owner: choice?.owner,
                                               handle: handle, displayName: displayName,
                                               profileURL: optionalWebURL(profileURL), avatarPath: avatarPath,
                                               providerIdentity: identity, enabled: enabled)
        }
        if await onSave(linkedRecord) {
            baselineRecord = linkedRecord
            connectionMessage = nil
            onDirtyChange(isDirty)
        } else {
            connectionMessage = "Authorization succeeded, but the account link could not be saved. Save the account to finish linking it."
        }
    }

    private func unlinkConnection() {
        guard providerIdentity != nil else { return }
        let unlinkedRecord: SocialAccountRecord
        if let record = baselineRecord ?? record {
            unlinkedRecord = SocialAccountRecord(id: record.id, platform: record.platform, owner: record.owner,
                                                  handle: record.handle, displayName: record.displayName,
                                                  profileURL: record.profileURL, avatarPath: record.avatarPath,
                                                  providerIdentity: nil, enabled: record.enabled)
        } else {
            guard let owner = owners.first(where: { $0.id == ownerID })?.owner else { return }
            unlinkedRecord = SocialAccountRecord(id: draftID, platform: platformValue, owner: owner,
                                                  handle: handle, displayName: displayName,
                                                  profileURL: optionalWebURL(profileURL), avatarPath: avatarPath,
                                                  providerIdentity: nil, enabled: enabled)
        }
        Task {
            if await onSave(unlinkedRecord) {
                providerIdentity = nil
                connectedAccount = nil
                connectionCapabilities = []
                baselineRecord = unlinkedRecord
                connectionMessage = nil
                await refreshSavedConnections()
                onDirtyChange(isDirty)
            } else {
                connectionMessage = "The workspace link could not be removed. Try again after saving the account."
            }
        }
    }
    private func load() {
        guard let record else {
            ownerID = owners.first?.id ?? ""
            return
        }
        draftID = record.id
        baselineRecord = record
        platform = platforms.contains(record.platform) ? record.platform : "Other"
        customPlatform = platforms.contains(record.platform) ? "" : record.platform
        ownerID = record.owner.map { "\($0.type.rawValue):\($0.id)" } ?? ""
        handle = record.handle ?? ""; displayName = record.displayName ?? ""; profileURL = record.profileURL?.absoluteString ?? ""; enabled = record.enabled
        providerIdentity = record.providerIdentity
        avatarPath = record.avatarPath
        avatarPreview = Self.loadImage(path: record.avatarPath, root: workspaceStore.rootURL)
        loadIdentityAvatarPreview()
    }
    private var selectedIdentity: IdentityRecord? {
        guard ownerID.hasPrefix("identity:") else { return nil }
        let identityID = String(ownerID.dropFirst("identity:".count))
        return identities.first { $0.id == identityID }
    }
    private var displayedAvatarPreview: NSImage? { avatarPath == nil ? identityAvatarPreview : (avatarPreview ?? identityAvatarPreview) }
    private func loadIdentityAvatarPreview() {
        identityAvatarPreview = Self.loadImage(path: selectedIdentity?.photoPath, root: workspaceStore.rootURL)
    }

    private static func loadImage(path: String?, root: URL) -> NSImage? {
        guard let url = ManagementWorkspaceView.safeWorkspacePhotoURL(root: root, photoPath: path) else { return nil }
        return NSImage(contentsOf: url)
    }
    private func importAvatar(from sourceURL: URL) async {
        let access = sourceURL.startAccessingSecurityScopedResource()
        defer { if access { sourceURL.stopAccessingSecurityScopedResource() } }
        do {
            let sourceData = try Data(contentsOf: sourceURL)
            guard !sourceData.isEmpty, sourceData.count <= 20 * 1_024 * 1_024,
                  let image = NSImage(data: sourceData),
                  let contentType = UTType(filenameExtension: sourceURL.pathExtension), contentType.conforms(to: .image) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let accountID = record?.id ?? draftID
            let accountFolder = try await avatarFolderRelativePath(for: accountID)
            let ext = contentType.preferredFilenameExtension ?? sourceURL.pathExtension.lowercased()
            guard !ext.isEmpty, ext.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) else {
                throw CocoaError(.fileReadInvalidFileName)
            }
            let relativePath = "\(accountFolder)/Assets/avatar-\(UUID().uuidString.lowercased()).\(ext)"
            _ = try await workspaceStore.write(sourceData, relativePath: relativePath, expectedRevision: nil)
            avatarPath = relativePath
            avatarPreview = image
            avatarError = nil
        } catch {
            avatarError = "Could not import this avatar: \(error.localizedDescription)"
        }
    }
    private func avatarFolderRelativePath(for accountID: String) async throws -> String {
        if record != nil {
            let category = workspaceStore.rootURL.appendingPathComponent("SocialAccounts", isDirectory: true)
            let folders = try FileManager.default.contentsOfDirectory(at: category, includingPropertiesForKeys: [.isDirectoryKey])
            let decoder = JSONDecoder()
            for folder in folders where (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                let relativeRecord = "SocialAccounts/\(folder.lastPathComponent)/record.json"
                guard let bytes = try? await workspaceStore.read(relativePath: relativeRecord),
                      let stored = try? decoder.decode(SocialAccountRecord.self, from: bytes.data), stored.id == accountID else { continue }
                return "SocialAccounts/\(folder.lastPathComponent)"
            }
            throw CocoaError(.fileNoSuchFile)
        }
        return "SocialAccounts/\(folderName(platformValue))-\(accountID.prefix(8))"
    }
    private func folderName(_ value: String) -> String {
        let pieces = value.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let slug = pieces.prefix(8).joined(separator: "-")
        return slug.isEmpty ? "record" : slug
    }
    private var canSave: Bool {
        !(platformValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || ownerID.isEmpty || (handle.isEmpty && profileURL.isEmpty) || saving)
    }

    @discardableResult
    private func save() async -> Bool {
        guard canSave else { return false }
        guard let choice = owners.first(where: { $0.id == ownerID }) else { return false }
        saving = true; defer { saving = false }
        let updatedRecord = SocialAccountRecord(id: baselineRecord?.id ?? draftID, platform: platformValue.trimmingCharacters(in: .whitespacesAndNewlines), owner: choice.owner, handle: handle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : handle.trimmingCharacters(in: .whitespacesAndNewlines), displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : displayName.trimmingCharacters(in: .whitespacesAndNewlines), profileURL: optionalWebURL(profileURL), avatarPath: avatarPath, providerIdentity: providerIdentity, enabled: enabled)
        if await onSave(updatedRecord) {
            baselineRecord = updatedRecord
            onDirtyChange(false)
            return true
        }
        return false
    }
    private var dirtySignature: String { "\(platform)|\(customPlatform)|\(ownerID)|\(handle)|\(displayName)|\(profileURL)|\(enabled)|\(avatarPath ?? "")|\(providerIdentity?.platform ?? "")|\(providerIdentity?.server.absoluteString ?? "")|\(providerIdentity?.remoteID ?? "")" }
    private var isDirty: Bool {
        if let baselineRecord {
            let savedPlatform = platforms.contains(baselineRecord.platform) ? baselineRecord.platform : "Other"
            let savedCustomPlatform = platforms.contains(baselineRecord.platform) ? "" : baselineRecord.platform
            return platform != savedPlatform || customPlatform != savedCustomPlatform || ownerID != (baselineRecord.owner.map { "\($0.type.rawValue):\($0.id)" } ?? "") || handle != (baselineRecord.handle ?? "") || displayName != (baselineRecord.displayName ?? "") || profileURL != (baselineRecord.profileURL?.absoluteString ?? "") || enabled != baselineRecord.enabled || avatarPath != baselineRecord.avatarPath || providerIdentity != baselineRecord.providerIdentity
        }
        return platform != "Threads" || !customPlatform.isEmpty || ownerID != (owners.first?.id ?? "") || !handle.isEmpty || !displayName.isEmpty || !profileURL.isEmpty || !enabled || avatarPath != nil
    }
}

private struct SocialConnectionManagementSheet: View {
    @Environment(\.dismiss) private var dismiss
    let platform: SocialPlatform
    let identity: ContentRecipientIdentity?
    let account: SocialAccount?
    let capabilities: Set<SocialCapability>
    let statusMessage: String?
    let recovery: SocialConnections.Recovery?
    let lastAvailable: Date?
    let checking: Bool
    let lastAttempt: Date?
    let onCheck: () -> Void
    let onAuthorize: () -> Void
    let onSwitch: () -> Void
    let onActivity: () -> Void
    let onUnlink: () -> Void
    @State private var confirmingUnlink = false
    @State private var confirmingSwitch = false

    private var capabilityItems: [(SocialCapability, String)] {
        [(.publishText, "Publish text"), (.publishMedia, "Publish media"),
         (.publishMultipleMedia, "Publish multiple media items"), (.listPosts, "View posts"),
         (.reply, "Reply"), (.readReplies, "View replies"), (.deleteReply, "Delete replies"),
         (.moderateReplies, "Moderate replies"), (.like, "Like posts"), (.repost, "Repost"),
         (.analytics, "View analytics"), (.resolveMentions, "Resolve mentions")]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                SocialPlatformIcon(platform: platform.workspaceTitle, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Manage Connection").font(.title2.weight(.semibold))
                    Text(platform.workspaceTitle).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Divider()
            if let account {
                Label("@\(account.username)", systemImage: "person.crop.circle")
                if let name = account.authenticatedUserName, name != account.displayName {
                    LabeledContent("Authorized by", value: name)
                }
                if let profileURL = account.profileURL, profileURL.scheme == "https" {
                    Link(destination: profileURL) { Label("Open profile", systemImage: "arrow.up.right.square") }
                }
            } else if identity != nil {
                Label("Connection unavailable on this Mac", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            if checking {
                HStack { ProgressView().controlSize(.small); Text("Checking Keychain and provider authorization…") }
            } else if let recovery {
                Label(recovery.message, systemImage: recovery.isAvailable ? "checkmark.circle" : "exclamationmark.circle")
                    .foregroundStyle(recovery.isAvailable ? Color.secondary : .orange)
            } else if let statusMessage {
                Label(statusMessage, systemImage: "exclamationmark.circle").foregroundStyle(.orange)
            }
            if let lastAttempt {
                LabeledContent("Last check", value: lastAttempt.formatted(date: .abbreviated, time: .standard))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let lastAvailable {
                LabeledContent("Last available", value: lastAvailable.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
            }
            GroupBox("Available capabilities") {
                if account == nil {
                    Text("Reconnect to verify this provider’s current capabilities.").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if capabilities.isEmpty {
                    Text("No publishing or activity capabilities were confirmed.").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        ForEach(capabilityItems.filter { capabilities.contains($0.0) }, id: \.0) { _, title in
                            Label(title, systemImage: "checkmark.circle.fill")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Spacer(minLength: 0)
            HStack {
                if account != nil {
                    Button("View Account Activity…", systemImage: "text.bubble") { onActivity() }
                }
                Spacer()
                Menu("Account Actions") {
                    Button("Switch Account…") { confirmingSwitch = true }
                    Button("Unlink", role: .destructive) { confirmingUnlink = true }
                }
                .disabled(identity == nil || checking)
                Button(recovery?.needsAuthorization == true ? "Retry Saved Connection" : "Check Connection",
                       systemImage: "arrow.clockwise", action: onCheck)
                    .disabled(checking)
                    .buttonStyle(.bordered)
                if recovery?.needsAuthorization == true {
                    Button("Authorize Again…", action: onAuthorize)
                        .buttonStyle(.borderedProminent).disabled(checking)
                }
            }
        }
        .padding(22)
        .frame(minWidth: 630, idealWidth: 680, minHeight: 360, idealHeight: 420)
        .confirmationDialog("Switch the account linked to this workspace?", isPresented: $confirmingSwitch, titleVisibility: .visible) {
            Button("Switch Account…", action: onSwitch)
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Unlink this provider identity from the workspace account?", isPresented: $confirmingUnlink, titleVisibility: .visible) {
            Button("Unlink Account", role: .destructive) { onUnlink(); dismiss() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the workspace link only. It does not delete the account record, related content, or credentials stored by the provider connection.")
        }
    }
}

private struct BlueskyConnectionSheet: View {
    @Environment(SocialPublishingRuntime.self) private var socialPublishingRuntime
    @Environment(\.dismiss) private var dismiss
    let initialHandle: String
    let expected: ContentRecipientIdentity?
    let onConnected: (SocialAccount) -> Void
    @State private var handle = ""
    @State private var appPassword = ""
    @State private var server = "https://bsky.social"
    @State private var isConnecting = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            TextField("Handle", text: $handle, prompt: Text("name.bsky.social"))
            if expected != nil {
                Text("Bluesky’s saved session could not be restored. Enter an existing Bluesky app password, or create one in Bluesky settings.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            SecureField("App password", text: $appPassword)
            TextField("PDS server", text: $server)
            Text("Create an app password in Bluesky settings. The resulting connection credential is stored in Keychain.")
                .font(.caption).foregroundStyle(.secondary)
            if let errorMessage { Text(errorMessage).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button("Cancel") { appPassword = ""; dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(isConnecting ? "Connecting…" : "Connect") { Task { await connect() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(isConnecting || handle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || appPassword.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 430)
        .onAppear {
            handle = initialHandle
            if let expected { server = expected.server.absoluteString }
        }
    }

    private func connect() async {
        guard let serverURL = URL(string: server.trimmingCharacters(in: .whitespacesAndNewlines)),
              serverURL.scheme?.lowercased() == "https", serverURL.host != nil else {
            errorMessage = "Enter a trusted HTTPS PDS server URL."
            return
        }
        isConnecting = true
        defer { isConnecting = false }
        do {
            let account = try await socialPublishingRuntime.connections.connectBluesky(
                identifier: handle.trimmingCharacters(in: .whitespacesAndNewlines),
                appPassword: appPassword,
                server: serverURL, expected: expected
            )
            appPassword = ""
            onConnected(account)
            dismiss()
        } catch {
            appPassword = ""
            errorMessage = "Bluesky connection failed: \(error.localizedDescription)"
        }
    }
}
