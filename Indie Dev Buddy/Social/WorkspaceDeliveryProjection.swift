import Foundation
import SocialKit

extension WorkspaceStore {
    func canDeliver(_ intent: ContentDeliveryIntent) throws -> Bool {
        try withWorkspaceLock(exclusive: false) {
            let snapshot = try load(installAgentGuidance: false)
            guard snapshot.manifest.id == intent.workspaceID, rootURL.path == intent.workspaceRootPath,
                  snapshot.content.filter({ $0.id == intent.contentID }).count == 1,
                  snapshot.socialAccounts.filter({ $0.id == intent.destinationID }).count == 1,
                  let record = snapshot.contentByID[intent.contentID],
                  let destination = record.destinations.first(where: { $0.accountId == intent.destinationID }),
                  record.destinations.filter({ $0.accountId == intent.destinationID }).count == 1,
                  destination.status == .scheduled,
                  snapshot.socialDestinationSelection(for: record).selectedAccountIDs.contains(intent.destinationID),
                  let account = snapshot.socialAccountsByID[intent.destinationID],
                  account.providerIdentity == intent.recipient,
                  SocialPlatform.workspacePlatform(account.platform)?.rawValue == intent.recipient.platform,
                  let schedule = destination.schedule, schedule.state == .queued else { return false }
            return schedule.matches(intent)
        }
    }

    func projectDelivery(_ entry: LocalDeliveryJournal.Entry) throws {
        let intent = entry.intent
        let snapshot = try load(installAgentGuidance: false)
        guard snapshot.manifest.id == intent.workspaceID, rootURL.path == intent.workspaceRootPath,
              snapshot.content.filter({ $0.id == intent.contentID }).count == 1,
              let path = snapshot.recordPaths["Content"]?[intent.contentID] else { return }
        let current = try read(relativePath: path)
        var record = try decoder.decode(ContentRecord.self, from: current.data)
        guard record.id == intent.contentID,
              record.destinations.filter({ $0.accountId == intent.destinationID }).count == 1,
              let index = record.destinations.firstIndex(where: { $0.accountId == intent.destinationID }) else { return }
        var destination = record.destinations[index]
        let known = Set((destination.deliveryHistory ?? []).map(\.id))
        let newAttempts = entry.attempts.filter { !known.contains($0.id) }
        if !newAttempts.isEmpty {
            destination.deliveryHistory = (destination.deliveryHistory ?? []) + newAttempts
        }
        if var schedule = destination.schedule, schedule.matches(intent), destination.status == .scheduled {
            schedule.state = entry.state
            schedule.lastError = entry.attempts.last?.message
            destination.schedule = schedule
            if entry.state == .delivered, let receipt = entry.attempts.last {
                destination.status = .published
                destination.publishedDate = receipt.finishedAt
                destination.publishedURL = receipt.publishedURL
            }
        }
        guard destination != record.destinations[index] else { return }
        record.destinations[index] = destination
        if record.destinations.allSatisfy({ $0.status == .published }) {
            record.status = .published
        } else if entry.state == .delivered && record.status == .scheduled {
            record.status = .draft
        }
        try save(record, relativePath: path, expectedRevision: current.revision)
    }
}

private extension ContentSchedule {
    nonisolated func matches(_ intent: ContentDeliveryIntent) -> Bool {
        mode == .api && idempotencyKey == intent.id && recipient == intent.recipient &&
            scheduledDate == intent.scheduledDate && draftID == intent.draftID &&
            draftCreatedAt == intent.draftCreatedAt && textSnapshot == intent.text &&
            (media ?? []) == intent.media && mediaURLs == intent.media.map(\.publicURL) &&
            (mentions ?? []) == (intent.mentions ?? [])
    }
}
