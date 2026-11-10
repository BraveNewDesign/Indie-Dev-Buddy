import Foundation
import SocialKit

/// Runs local deliveries only inside an explicitly opened, awake runtime interval.
/// A host app should call `endEligibleSession()` for sleep or workspace deactivation.
actor PublishingCoordinator {
    typealias Sender = @Sendable (ContentDeliveryIntent, MetaPublishingCheckpoint?, @escaping MetaPublishingCheckpointWriter) async throws -> ContentDeliveryResult
    typealias Validator = @Sendable (ContentDeliveryIntent, Bool) async -> Bool
    typealias Reconciler = @Sendable (MetaPublishingCheckpoint, ContentDeliveryIntent) async throws -> Bool
    enum PollingPaused: Error { case unavailable }
    typealias Projector = @Sendable (LocalDeliveryJournal.Entry) async throws -> Void

    private let journal: LocalDeliveryJournal
    private let sender: Sender
    private let validator: Validator
    private let projector: Projector
    private let reconciler: Reconciler
    private var nextReconciliation: Date = .distantPast
    private var eligibleSessionStartedAt: Date?
    private var isDraining = false
    private var projectedStates: [UUID: ContentDeliveryState] = [:]

    init(journal: LocalDeliveryJournal, validator: @escaping Validator, projector: @escaping Projector,
         reconciler: @escaping Reconciler, sender: @escaping Sender) {
        self.journal = journal
        self.validator = validator
        self.projector = projector
        self.sender = sender
        self.reconciler = reconciler
    }

    func beginEligibleSession(at date: Date = Date()) {
        guard eligibleSessionStartedAt == nil else { return }
        eligibleSessionStartedAt = date
    }

    func endEligibleSession() {
        eligibleSessionStartedAt = nil
    }

    /// Call from a modest app-owned timer while the app is open and the Mac is awake.
    /// Jobs due before this active interval become overdue and are never sent automatically.
    func tick(at now: Date = Date()) async {
        guard let sessionStartedAt = eligibleSessionStartedAt, !isDraining else { return }
        isDraining = true
        defer { isDraining = false }

        do {
            _ = try await journal.markOverdue(before: sessionStartedAt, now: now)
            while eligibleSessionStartedAt == sessionStartedAt,
                  let entry = try await journal.claimNextDue(sessionStartedAt: sessionStartedAt, now: now) {
                if let stagedAt = entry.containerStagedAt, now.timeIntervalSince(stagedAt) >= LocalDeliveryJournal.recoveryWindow {
                    _ = try await journal.pausePolling(entry.intent.id, at: now)
                    continue
                }
                let isValid = await validator(entry.intent, entry.immediate == true)
                if eligibleSessionStartedAt != sessionStartedAt || Task.isCancelled {
                    if entry.canResumeContainer { _ = try await journal.pausePolling(entry.intent.id, at: now) }
                    else {
                        try await journal.finish(entry.intent.id, result: ContentDeliveryResult(
                            state: .overdue, message: "The Mac stopped being available before delivery began."
                        ))
                    }
                } else if !isValid {
                    try await journal.finish(entry.intent.id, result: ContentDeliveryResult(
                        state: .failed, message: "The saved schedule or its connected account could not be verified. Review it before scheduling again."
                    ))
                } else {
                    _ = try await send(entry, session: sessionStartedAt)
                }
            }
        } catch {
            // Persistence/claim errors stop the drain. No provider call occurs without a claim.
        }
        if eligibleSessionStartedAt == sessionStartedAt, now >= nextReconciliation {
            nextReconciliation = now.addingTimeInterval(60)
            for entry in await journal.entries() where entry.state == .outcomeUnknown {
                guard eligibleSessionStartedAt == sessionStartedAt, !Task.isCancelled else { break }
                guard let checkpoint = entry.checkpoint, let stagedAt = entry.containerStagedAt,
                      now.timeIntervalSince(stagedAt) < LocalDeliveryJournal.recoveryWindow else { continue }
                if (try? await reconciler(checkpoint, entry.intent)) == true {
                    try? await journal.confirmPublishedContainer(entry.intent.id)
                }
            }
        }
        for entry in await journal.entries() where entry.state != .queued && entry.state != .sending {
            guard projectedStates[entry.intent.id] != entry.state else { continue }
            do {
                try await projector(entry)
                projectedStates[entry.intent.id] = entry.state
            } catch {
                // Keep the receipt in the local journal and retry the workspace write on a later tick.
            }
        }
    }

    func authorize(_ intents: [ContentDeliveryIntent], at now: Date = Date()) async throws {
        try await journal.authorize(intents, at: now)
    }

    func deliverNow(_ intent: ContentDeliveryIntent) async throws -> ContentDeliveryResult {
        let entry = try await journal.beginImmediate(intent)
        let result = try await send(entry, session: eligibleSessionStartedAt)
        guard result.state != .queued else { return result }
        if let entry = await journal.entries().first(where: { $0.intent.id == intent.id }) {
            try await projector(entry)
            projectedStates[intent.id] = entry.state
        }
        return result
    }

    private func send(_ entry: LocalDeliveryJournal.Entry, session: Date?) async throws -> ContentDeliveryResult {
        let intent = entry.intent
        let result: ContentDeliveryResult
        do {
            result = try await sender(intent, entry.checkpoint) { checkpoint in
                if checkpoint.publishStarted {
                    guard await self.eligibleSessionStartedAt == session else { throw PollingPaused.unavailable }
                    guard await self.validator(intent, entry.immediate == true) else { throw SocialError.invalidInput }
                    guard await self.eligibleSessionStartedAt == session else { throw PollingPaused.unavailable }
                }
                try await self.journal.saveCheckpoint(checkpoint, for: intent.id)
            }
        } catch {
            switch error {
            case PollingPaused.unavailable, is CancellationError:
                if let paused = try? await journal.pausePolling(intent.id) { return paused }
            default: break
            }
            result = ContentDeliveryResult(
                state: .outcomeUnknown,
                message: "Delivery result is unclear. Check the provider before retrying."
            )
        }
        try await journal.finish(intent.id, result: result)
        return result
    }

    func cancel(_ intentIDs: Set<UUID>) async throws {
        try await journal.cancel(intentIDs)
    }

    func history(workspaceID: String? = nil) async -> [LocalDeliveryJournal.Entry] {
        await journal.entries(workspaceID: workspaceID)
    }
}
