import Foundation

/// Runs local deliveries only inside an explicitly opened, awake runtime interval.
/// A host app should call `endEligibleSession()` for sleep or workspace deactivation.
actor PublishingCoordinator {
    typealias Sender = @Sendable (ContentDeliveryIntent) async throws -> ContentDeliveryResult
    typealias Validator = @Sendable (ContentDeliveryIntent) async -> Bool
    typealias Projector = @Sendable (LocalDeliveryJournal.Entry) async throws -> Void

    private let journal: LocalDeliveryJournal
    private let sender: Sender
    private let validator: Validator
    private let projector: Projector
    private var eligibleSessionStartedAt: Date?
    private var isDraining = false
    private var projectedStates: [UUID: ContentDeliveryState] = [:]

    init(journal: LocalDeliveryJournal, validator: @escaping Validator, projector: @escaping Projector, sender: @escaping Sender) {
        self.journal = journal
        self.validator = validator
        self.projector = projector
        self.sender = sender
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
                  let intent = try await journal.claimNextDue(sessionStartedAt: sessionStartedAt, now: now) {
                let result: ContentDeliveryResult
                let isValid = await validator(intent)
                if eligibleSessionStartedAt != sessionStartedAt || Task.isCancelled {
                    result = ContentDeliveryResult(state: .overdue, message: "The Mac stopped being available before delivery began.")
                } else if !isValid {
                    result = ContentDeliveryResult(state: .failed, message: "The saved schedule or its connected account could not be verified. Review it before scheduling again.")
                } else {
                    do {
                        result = try await sender(intent)
                    } catch {
                        // A thrown transport/provider error may have followed an accepted write.
                        result = ContentDeliveryResult(
                            state: .outcomeUnknown,
                            message: "Delivery result is unclear. Check the provider before retrying."
                        )
                    }
                }
                try await journal.finish(intent.id, result: result)
            }
        } catch {
            // Persistence/claim errors stop the drain. No provider call occurs without a claim.
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
        try await journal.beginImmediate(intent)
        let result: ContentDeliveryResult
        do {
            result = try await sender(intent)
        } catch {
            result = ContentDeliveryResult(
                state: .outcomeUnknown,
                message: "Delivery result is unclear. Check the provider before retrying."
            )
        }
        try await journal.finish(intent.id, result: result)
        if let entry = await journal.entries().first(where: { $0.intent.id == intent.id }) {
            try await projector(entry)
            projectedStates[intent.id] = entry.state
        }
        return result
    }

    func cancel(_ intentIDs: Set<UUID>) async throws {
        try await journal.cancel(intentIDs)
    }

    func history(workspaceID: String? = nil) async -> [LocalDeliveryJournal.Entry] {
        await journal.entries(workspaceID: workspaceID)
    }
}
