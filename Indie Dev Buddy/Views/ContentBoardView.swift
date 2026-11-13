import SwiftUI

struct ContentBoardView: View {
    let records: [ContentRecord]
    let snapshot: WorkspaceSnapshot
    let open: (String) -> Void
    let move: (String, ContentStage) -> Void

    @State private var highlightedStage: ContentStage?

    private var dragPrefix: String { "indiedevbuddy:\(snapshot.manifest.id):" }

    var body: some View {
        let stages = Dictionary(grouping: records, by: ContentStage.init)
        GeometryReader { geometry in
            let width = max(204, (geometry.size.width - 76) / 4)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(ContentStage.allCases) { stage in
                        column(stage, items: stages[stage] ?? [])
                            .frame(width: width, height: max(0, geometry.size.height - 32))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
        }
    }

    private func column(_ stage: ContentStage, items: [ContentRecord]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(stage.rawValue).font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Text(items.count, format: .number)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(items) { item in
                        card(item)
                    }
                    if items.isEmpty {
                        Text("No items")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(10)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(highlightedStage == stage ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.045),
                    in: RoundedRectangle(cornerRadius: 10))
        .dropDestination(for: String.self) { cards, _ in
            guard cards.count == 1, let card = cards.first, card.hasPrefix(dragPrefix) else { return false }
            let id = String(card.dropFirst(dragPrefix.count))
            guard let item = records.first(where: { $0.id == id }),
                  stage.allowsMove(from: item) else { return false }
            move(item.id, stage)
            return true
        } isTargeted: { targeted in
            if targeted, stage != .posted { highlightedStage = stage }
            else if highlightedStage == stage { highlightedStage = nil }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(stage.rawValue), \(items.count) items")
    }

    @ViewBuilder
    private func card(_ item: ContentRecord) -> some View {
        let destinations = ContentStage.allCases.filter { $0.allowsMove(from: item) }
        let card = Button { open(item.id) } label: {
            ContentLibraryRow(item: item, snapshot: snapshot, compact: true)
                .padding(8)
                .background(.background, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Open") { open(item.id) }
            if !destinations.isEmpty {
                Menu("Move to") {
                    ForEach(destinations) { destination in
                        Button(destination.rawValue) { move(item.id, destination) }
                    }
                }
            }
        }
        if destinations.isEmpty {
            card
        } else {
            card.draggable(dragPrefix + item.id)
        }
    }
}
