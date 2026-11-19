import AppKit
import Foundation
import Observation
import Network
import SocialKit

/// App-owned runtime shared by all windows. The schedule journal and sender live for the
/// process lifetime, while dispatch is enabled only during an active, awake interval.
@MainActor @Observable
final class SocialPublishingRuntime {
    let connections: SocialConnections
    let engagement = SocialEngagementStore()
    private let coordinator: PublishingCoordinator?
    private(set) var metaCredentialStatus: [SocialAccount.ID: String] = [:]
    private(set) var connectionStatus: [SocialAccount.ID: SocialConnections.Recovery] = [:]
    private(set) var lastManualCheck: [SocialAccount.ID: Date] = [:]
    private(set) var lastAvailable: [SocialAccount.ID: Date] = [:]
    private var networkMonitor: NWPathMonitor?
    private var networkWasAvailable: Bool?
    private var credentialTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var workspaceTokens: [NSObjectProtocol] = []
    private(set) var initializationError: String?

    init() {
        let x = SocialOAuthRegistration.load(.x)
        connections = SocialConnections(configuration: .init(xClientID: x.clientID, xRedirectURI: x.callback(for: .x)))
        do {
            let journal = try LocalDeliveryJournal()
            coordinator = PublishingCoordinator(journal: journal, validator: { intent, immediate in
                guard Self.isRegisteredWorkspace(intent.workspaceRootPath) else { return false }
                let store = WorkspaceStore(rootURL: URL(fileURLWithPath: intent.workspaceRootPath, isDirectory: true))
                if immediate { return (try? await store.canPublishNow(intent)) == true }
                return (try? await store.canDeliver(intent)) == true
            }, projector: { entry in
                guard Self.isRegisteredWorkspace(entry.intent.workspaceRootPath) else {
                    throw CocoaError(.fileReadNoPermission)
                }
                let store = WorkspaceStore(rootURL: URL(fileURLWithPath: entry.intent.workspaceRootPath, isDirectory: true))
                try await store.projectDelivery(entry)
            }, reconciler: { [connections] checkpoint, intent in
                guard Self.isRegisteredWorkspace(intent.workspaceRootPath) else { return false }
                return try await connections.wasMetaContainerPublished(checkpoint, for: intent)
            }) { [connections] intent, checkpoint, saveCheckpoint in
                try await connections.deliver(intent, checkpoint: checkpoint, saveCheckpoint: saveCheckpoint)
            }
        } catch {
            coordinator = nil
            initializationError = "Scheduled delivery history could not be opened. API delivery is paused."
        }
    }

    func start() {
        guard timerTask == nil else { return }
        installLifecycleObservers()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor in
                guard let self, self.networkMonitor != nil else { return }
                let recovered = available && self.networkWasAvailable == false
                self.networkWasAvailable = available
                if recovered, self.credentialTask != nil {
                    self.stopCredentialChecks()
                    self.startCredentialChecks()
                }
            }
        }
        networkMonitor = monitor
        monitor.start(queue: DispatchQueue(label: "indiedevbuddy.social.network"))
        setEligible(true)
        startCredentialChecks()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard let self, !Task.isCancelled else { return }
                if let coordinator = self.coordinator { await coordinator.tick() }
            }
        }
    }

    func stop() {
        timerTask?.cancel()
        timerTask = nil
        stopCredentialChecks()
        networkMonitor?.cancel()
        networkMonitor = nil
        networkWasAvailable = nil
        setEligible(false)
        for token in workspaceTokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        workspaceTokens.removeAll()
    }

    func history(workspaceID: String, workspaceRoot: URL) async -> [LocalDeliveryJournal.Entry] {
        guard let coordinator else { return [] }
        let path = workspaceRoot.standardizedFileURL.resolvingSymlinksInPath().path
        return await coordinator.history(workspaceID: workspaceID).filter { $0.intent.workspaceRootPath == path }
    }

    func authorize(_ intents: [ContentDeliveryIntent]) async throws {
        guard !intents.isEmpty else { return }
        guard let coordinator else { throw LocalDeliveryJournal.JournalError.storageFailure }
        try await coordinator.authorize(intents)
    }

    func cancel(_ ids: Set<UUID>) async throws {
        guard !ids.isEmpty else { return }
        guard let coordinator else { throw LocalDeliveryJournal.JournalError.storageFailure }
        try await coordinator.cancel(ids)
    }

    func publishNow(_ intent: ContentDeliveryIntent) async throws -> ContentDeliveryResult {
        guard Self.isRegisteredWorkspace(intent.workspaceRootPath) else {
            throw SocialError.invalidConfiguration
        }
        let store = WorkspaceStore(rootURL: URL(fileURLWithPath: intent.workspaceRootPath, isDirectory: true))
        guard try await store.canPublishNow(intent) else { throw SocialError.invalidConfiguration }
        guard let coordinator else { throw LocalDeliveryJournal.JournalError.storageFailure }
        var immediateIntent = intent
        if let existing = await coordinator.history(workspaceID: intent.workspaceID).first(where: { $0.intent.id == intent.id }) {
            guard !existing.canResumeContainer, existing.state == .queued || existing.state == .overdue else {
                throw LocalDeliveryJournal.JournalError.invalidTransition
            }
            try await coordinator.cancel([intent.id])
            immediateIntent.id = UUID()
            immediateIntent.draftID = immediateIntent.id
        }
        return try await coordinator.deliverNow(immediateIntent)
    }

    private func setEligible(_ eligible: Bool) {
        guard let coordinator else { return }
        let time = Date()
        Task {
            if eligible { await coordinator.beginEligibleSession(at: time) }
            else { await coordinator.endEligibleSession() }
        }
    }

    private nonisolated static func isRegisteredWorkspace(_ path: String) -> Bool {
        (try? WorkspaceRegistry.workspaces().contains {
            $0.standardizedFileURL.resolvingSymlinksInPath().path == path
        }) == true
    }

    private func startCredentialChecks() {
        guard credentialTask == nil else { return }
        credentialTask = Task { [weak self] in
            var force = true
            while !Task.isCancelled {
                await self?.checkSavedConnections(force: force)
                guard !Task.isCancelled else { return }
                force = false
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    private func checkSavedConnections(force: Bool) async {
        let accounts = (try? await connections.accounts()) ?? []
        var identities = Set(accounts.map(SocialOAuthRegistration.identity(for:)))
        if let coordinator {
            let entries = await coordinator.history()
            for entry in entries where entry.state == .queued || entry.state == .overdue {
                identities.insert(entry.intent.recipient)
            }
        }
        for identity in identities {
            guard !Task.isCancelled, let id = connectionID(for: identity) else { continue }
            let stale = lastAvailable[id].map { Date().timeIntervalSince($0) >= 6 * 60 * 60 } ?? true
            let status = connectionStatus[id]
            if !force, !id.platform.isMeta, status?.needsAuthorization == true { continue }
            let retrying = status.map { !$0.isAvailable && !$0.needsAuthorization } ?? false
            _ = await checkConnection(identity, force: force || (!id.platform.isMeta && (stale || retrying)))
        }
        for account in accounts where account.platform.isMeta {
            guard !Task.isCancelled else { return }
            metaCredentialStatus[account.id] = await connections.savedMetaStatus(for: account)
        }
    }

    private func stopCredentialChecks() {
        credentialTask?.cancel()
        credentialTask = nil
    }

    func checkConnection(_ identity: ContentRecipientIdentity, force: Bool = true, manual: Bool = false) async -> SocialConnections.Recovery {
        let result = await connections.recover(identity, force: force, manual: manual)
        guard !Task.isCancelled, let id = connectionID(for: identity) else { return result }
        if manual {
            lastManualCheck[id] = .now
        }
        if result != .ready || manual || connectionStatus[id] != .renewed {
            connectionStatus[id] = result
        }
        if result.isAvailable, force || lastAvailable[id] == nil {
            let now = Date()
            lastAvailable[id] = now
            UserDefaults.standard.set(now, forKey: availabilityKey(identity))
        }
        return result
    }

    func lastAvailable(for identity: ContentRecipientIdentity) -> Date? {
        guard let id = connectionID(for: identity) else { return nil }
        return lastAvailable[id] ?? UserDefaults.standard.object(forKey: availabilityKey(identity)) as? Date
    }

    private func connectionID(for identity: ContentRecipientIdentity) -> SocialAccount.ID? {
        guard let platform = SocialPlatform(rawValue: identity.platform) else { return nil }
        return .init(platform: platform, server: identity.server, remoteID: identity.remoteID)
    }

    private func availabilityKey(_ identity: ContentRecipientIdentity) -> String {
        SocialOAuthRegistration.accountKey(identity) + ".lastAvailable"
    }

    func updateCredentialStatus(for id: SocialAccount.ID) {
        metaCredentialStatus.removeValue(forKey: id)
        connectionStatus.removeValue(forKey: id)
        Task {
            await connections.didAuthorize(id)
            let identity = ContentRecipientIdentity(platform: id.platform.rawValue, server: id.server, remoteID: id.remoteID)
            _ = await checkConnection(identity)
        }
    }

    private func installLifecycleObservers() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceTokens.append(workspaceCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.stopCredentialChecks()
                self?.setEligible(false)
            }
        })
        workspaceTokens.append(workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.setEligible(true)
                self?.startCredentialChecks()
            }
        })
    }
}
