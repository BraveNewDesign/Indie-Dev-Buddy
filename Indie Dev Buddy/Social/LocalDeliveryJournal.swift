import CryptoKit
import Darwin
import Foundation
import SocialKit

/// Device-local authority for schedules that have been explicitly approved in the app.
/// Workspace JSON is a projection and cannot independently authorize a network write.
actor LocalDeliveryJournal {
    struct Entry: Codable, Sendable, Equatable {
        var intent: ContentDeliveryIntent
        var payloadFingerprint: String
        var state: ContentDeliveryState
        var approvedAt: Date
        var attempts: [ContentDeliveryAttempt]
        var checkpoint: MetaPublishingCheckpoint?
        var containerStagedAt: Date?
        var retryAfter: Date?
        var immediate: Bool?

        var canResumeContainer: Bool { checkpoint?.publishStarted == false }
    }

    static let recoveryWindow: TimeInterval = 86_400

    private struct File: Codable, Equatable {
        var schemaVersion = 1
        var entries: [UUID: Entry] = [:]
    }

    enum JournalError: Error {
        case invalidIntent
        case duplicateIntent
        case invalidTransition
        case storageFailure
    }

    private let fileURL: URL
    private let lease: JournalLease
    private var file: File
    private let encoder: JSONEncoder

    init(fileURL: URL? = nil) throws {
        let base: URL
        if let fileURL {
            base = fileURL
        } else {
            base = try FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("Indie Dev Buddy", isDirectory: true)
                .appendingPathComponent("DeliveryJournal.json")
        }
        self.fileURL = base
        lease = try JournalLease(directory: base.deletingLastPathComponent(), name: base.lastPathComponent + ".lock")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        if FileManager.default.fileExists(atPath: base.path) {
            let data = try Data(contentsOf: base)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let loaded = try decoder.decode(File.self, from: data)
            guard loaded.schemaVersion == 1 else { throw JournalError.storageFailure }
            var recovered = loaded
            for id in Array(recovered.entries.keys) {
                guard var entry = recovered.entries[id], entry.state == .sending else { continue }
                if entry.canResumeContainer {
                    entry.state = .queued
                    recovered.entries[id] = entry
                    continue
                }
                entry.state = .outcomeUnknown
                if let index = entry.attempts.indices.last {
                    entry.attempts[index].state = .outcomeUnknown
                    entry.attempts[index].finishedAt = Date()
                    entry.attempts[index].message = "The app stopped during delivery. Check the provider before retrying."
                }
                recovered.entries[id] = entry
            }
            file = recovered
            if recovered != loaded { try Self.write(recovered, to: base, encoder: encoder) }
        } else {
            file = File()
        }
    }

    func authorize(_ intents: [ContentDeliveryIntent], at now: Date = Date()) throws {
        var updated = file
        for intent in intents {
            guard intent.scheduledDate > now,
              !intent.workspaceID.isEmpty, !intent.contentID.isEmpty, !intent.destinationID.isEmpty,
              !intent.workspaceRootPath.isEmpty, !intent.recipient.platform.isEmpty,
              !intent.recipient.remoteID.isEmpty, intent.recipient.server.scheme?.lowercased() == "https",
              intent.media.allSatisfy({ $0.publicURL.scheme?.lowercased() == "https" && $0.publicURL.host != nil }) else {
                throw JournalError.invalidIntent
            }
            guard !Self.hasUnresolvedDelivery(for: intent, in: updated) else { throw JournalError.duplicateIntent }
            let fingerprint = try Self.fingerprint(intent, encoder: encoder)
            if let existing = updated.entries[intent.id] {
                guard existing.payloadFingerprint == fingerprint, existing.state == .queued else {
                    throw JournalError.duplicateIntent
                }
            } else {
                updated.entries[intent.id] = Entry(intent: intent, payloadFingerprint: fingerprint,
                                                   state: .queued, approvedAt: now, attempts: [])
            }
        }
        try commit(updated)
    }

    /// Records an explicit Publish Now request before any provider write begins.
    func beginImmediate(_ intent: ContentDeliveryIntent, at now: Date = Date()) throws -> Entry {
        guard !intent.workspaceID.isEmpty, !intent.contentID.isEmpty, !intent.destinationID.isEmpty,
              !intent.workspaceRootPath.isEmpty, !intent.recipient.platform.isEmpty,
              !intent.recipient.remoteID.isEmpty, intent.recipient.server.scheme?.lowercased() == "https",
              intent.media.allSatisfy({ $0.publicURL.scheme?.lowercased() == "https" && $0.publicURL.host != nil }),
              file.entries[intent.id] == nil else { throw JournalError.invalidIntent }
        guard !Self.hasUnresolvedDelivery(for: intent, in: file) else { throw JournalError.duplicateIntent }
        let fingerprint = try Self.fingerprint(intent, encoder: encoder)
        var updated = file
        let entry = Entry(
            intent: intent, payloadFingerprint: fingerprint, state: .sending,
            approvedAt: now,
            attempts: [ContentDeliveryAttempt(intentID: intent.id, state: .sending, startedAt: now)],
            immediate: true
        )
        updated.entries[intent.id] = entry
        try commit(updated)
        return entry
    }

    /// Marks jobs that were already due before this awake app session as overdue.
    func markOverdue(before sessionStartedAt: Date, now: Date) throws -> [ContentDeliveryIntent] {
        var changed: [ContentDeliveryIntent] = []
        var updated = file
        for id in file.entries.keys {
            guard var entry = file.entries[id], entry.state == .queued,
                  !entry.canResumeContainer, entry.intent.scheduledDate < sessionStartedAt,
                  entry.intent.scheduledDate <= now else { continue }
            entry.state = .overdue
            updated.entries[id] = entry
            changed.append(entry.intent)
        }
        try commit(updated)
        return changed
    }

    /// Atomically records `sending` before returning a single intent for a provider write.
    func claimNextDue(sessionStartedAt: Date, now: Date) throws -> Entry? {
        guard let pair = file.entries.filter({ _, entry in
            guard entry.state == .queued, !Self.hasUnresolvedDelivery(for: entry.intent, in: file) else { return false }
            if entry.canResumeContainer { return (entry.retryAfter ?? .distantPast) <= now }
            return entry.intent.scheduledDate >= sessionStartedAt && entry.intent.scheduledDate <= now
        }).min(by: { $0.value.intent.scheduledDate < $1.value.intent.scheduledDate }) else { return nil }
        var entry = pair.value
        entry.state = .sending
        if !entry.canResumeContainer {
            entry.attempts.append(ContentDeliveryAttempt(intentID: pair.key, state: .sending, startedAt: now))
        }
        var updated = file
        updated.entries[pair.key] = entry
        try commit(updated)
        return entry
    }

    func saveCheckpoint(_ checkpoint: MetaPublishingCheckpoint, for id: UUID, at now: Date = Date()) throws {
        guard var entry = file.entries[id], entry.state == .sending,
              entry.intent.recipient.platform == SocialPlatform.instagram.rawValue ||
                entry.intent.recipient.platform == SocialPlatform.threads.rawValue else {
            throw JournalError.invalidTransition
        }
        if let previous = entry.checkpoint {
            guard !previous.publishStarted, checkpoint.publishStarted, previous.containerID == checkpoint.containerID else {
                throw JournalError.invalidTransition
            }
        } else {
            guard !checkpoint.publishStarted else { throw JournalError.invalidTransition }
            entry.containerStagedAt = now
        }
        entry.checkpoint = checkpoint
        var updated = file
        updated.entries[id] = entry
        try commit(updated)
    }

    /// Only a staged container can return to the queue. Once publish starts, the result is uncertain.
    func pausePolling(_ id: UUID, at now: Date = Date()) throws -> ContentDeliveryResult {
        guard var entry = file.entries[id], entry.state == .sending, entry.canResumeContainer else {
            throw JournalError.invalidTransition
        }
        if let stagedAt = entry.containerStagedAt, now.timeIntervalSince(stagedAt) < Self.recoveryWindow {
            entry.state = .queued
            entry.retryAfter = now.addingTimeInterval(60)
            var updated = file
            updated.entries[id] = entry
            try commit(updated)
            return ContentDeliveryResult(state: .queued, message: "Meta is still preparing this post. Polling will resume while the app is open and the Mac is awake.")
        }
        let result = ContentDeliveryResult(state: .failed, message: "Meta did not finish preparing the post before the local recovery window ended.")
        try finish(id, result: result, at: now)
        return result
    }

    func confirmPublishedContainer(_ id: UUID, at now: Date = Date()) throws {
        guard var entry = file.entries[id], entry.state == .outcomeUnknown,
              entry.checkpoint != nil, let index = entry.attempts.indices.last else {
            throw JournalError.invalidTransition
        }
        entry.state = .delivered
        entry.checkpoint = nil
        entry.containerStagedAt = nil
        entry.attempts[index].state = .delivered
        entry.attempts[index].finishedAt = now
        entry.attempts[index].message = "Meta confirmed publication. The published post ID was unavailable."
        var updated = file
        updated.entries[id] = entry
        try commit(updated)
    }

    func finish(_ id: UUID, result: ContentDeliveryResult, at now: Date = Date()) throws {
        guard var entry = file.entries[id], entry.state == .sending,
              [.delivered, .failed, .outcomeUnknown, .overdue].contains(result.state),
              let index = entry.attempts.indices.last else { throw JournalError.invalidTransition }
        entry.state = result.state
        if result.state != .outcomeUnknown {
            entry.checkpoint = nil
            entry.containerStagedAt = nil
        }
        entry.retryAfter = nil
        entry.attempts[index].state = result.state
        entry.attempts[index].finishedAt = now
        entry.attempts[index].providerPostID = result.providerPostID
        entry.attempts[index].publishedURL = result.publishedURL
        entry.attempts[index].message = result.message
        var updated = file
        updated.entries[id] = entry
        try commit(updated)
    }

    func cancel(_ ids: Set<UUID>) throws {
        var updated = file
        for id in ids {
            guard var entry = updated.entries[id] else { continue }
            guard entry.state != .sending, entry.state != .delivered else { throw JournalError.invalidTransition }
            guard [.queued, .overdue].contains(entry.state) else { continue }
            entry.state = .canceled
            if let index = entry.attempts.indices.last, entry.attempts[index].state == .sending {
                entry.attempts[index].state = .canceled
                entry.attempts[index].finishedAt = Date()
            }
            entry.checkpoint = nil
            entry.containerStagedAt = nil
            entry.retryAfter = nil
            updated.entries[id] = entry
        }
        try commit(updated)
    }

    func entries(workspaceID: String? = nil) -> [Entry] {
        file.entries.values
            .filter { workspaceID == nil || $0.intent.workspaceID == workspaceID }
            .sorted { $0.intent.scheduledDate < $1.intent.scheduledDate }
    }

    private static func hasUnresolvedDelivery(for intent: ContentDeliveryIntent, in file: File) -> Bool {
        file.entries.values.contains { entry in
            let other = entry.intent
            return other.id != intent.id && other.workspaceID == intent.workspaceID &&
                other.workspaceRootPath == intent.workspaceRootPath && other.contentID == intent.contentID &&
                other.recipient == intent.recipient &&
                (entry.state == .sending || (entry.state == .outcomeUnknown && entry.checkpoint != nil) ||
                 (entry.state == .queued && entry.canResumeContainer))
        }
    }

    private func commit(_ updated: File) throws {
        guard updated != file else { return }
        try Self.write(updated, to: fileURL, encoder: encoder)
        file = updated
    }

    private static func write(_ file: File, to url: URL, encoder: JSONEncoder) throws {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try encoder.encode(file).write(to: url, options: .atomic)
        } catch {
            throw JournalError.storageFailure
        }
    }

    private static func fingerprint(_ intent: ContentDeliveryIntent, encoder: JSONEncoder) throws -> String {
        let digest = SHA256.hash(data: try encoder.encode(intent))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// A stable sidecar inode keeps a second instance from loading stale claims.
private nonisolated final class JournalLease: Sendable {
    private let descriptor: Int32

    init(directory: URL, name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent(name).path
        let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(S_IRUSR | S_IWUSR))
        guard fd >= 0 else { throw LocalDeliveryJournal.JournalError.storageFailure }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw LocalDeliveryJournal.JournalError.storageFailure
        }
        descriptor = fd
    }

    deinit { close(descriptor) }
}
