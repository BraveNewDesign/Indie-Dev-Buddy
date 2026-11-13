import Foundation

nonisolated enum ContentStage: String, CaseIterable, Identifiable, Sendable {
    case ideas = "Ideas"
    case drafts = "Drafts"
    case toPost = "To Post"
    case posted = "Posted"

    var id: Self { self }

    init(_ item: ContentRecord) {
        if item.kind == .social, !item.destinations.isEmpty {
            if item.destinations.allSatisfy({ $0.status == .published }) {
                self = .posted
                return
            }
            if item.status == .published || item.destinations.contains(where: {
                [.published, .scheduled, .manuallyScheduled].contains($0.status)
            }) {
                self = .toPost
                return
            }
        }
        switch item.status {
        case .idea: self = .ideas
        case .draft: self = .drafts
        case .ready, .scheduled, .manuallyScheduled: self = .toPost
        case .published: self = .posted
        }
    }

    func allowsMove(from item: ContentRecord) -> Bool {
        guard self != .posted, ContentStage(item) != .posted, self != ContentStage(item) else { return false }
        var candidate = item
        candidate.status = editorialStatus ?? item.status
        return ContentStage(candidate) == self
    }

    var editorialStatus: ContentStatus? {
        switch self {
        case .ideas: .idea
        case .drafts: .draft
        case .toPost: .ready
        case .posted: nil
        }
    }
}
