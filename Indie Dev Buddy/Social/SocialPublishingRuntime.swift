import AppKit
import Foundation
import Observation
import SocialKit

/// App-owned runtime shared by all windows. The schedule journal and sender live for the
/// process lifetime, while dispatch is enabled only during an active, awake interval.
@MainActor @Observable
final class SocialPublishingRuntime {
    let connections: SocialConnections
    private let coordinator: PublishingCoordinator?
    private(set) var metaCredentialStatus: [SocialAccount.ID: String] = [:]
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
        credentialTask = Task { [weak self, connections] in
            var force = true
            while !Task.isCancelled {
                let status = await connections.checkMetaCredentials(force: force)
                guard !Task.isCancelled else { return }
                self?.metaCredentialStatus = status
                force = false
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    private func stopCredentialChecks() {
        credentialTask?.cancel()
        credentialTask = nil
    }

    func updateCredentialStatus(for id: SocialAccount.ID) {
        metaCredentialStatus.removeValue(forKey: id)
        guard credentialTask != nil else { return }
        stopCredentialChecks()
        startCredentialChecks()
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
