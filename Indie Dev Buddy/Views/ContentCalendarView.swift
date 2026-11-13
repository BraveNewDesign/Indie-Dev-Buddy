import SwiftUI

struct ContentCalendarView: View {
    let records: [ContentRecord]
    let snapshot: WorkspaceSnapshot
    let showsControls: Bool
    let open: (String) -> Void
    let create: (ContentKind, Date) -> Void

    @Environment(\.calendar) private var calendar
    @State private var selectedDay = Date()
    @State private var mode: Mode = .month

    private enum Mode: String, CaseIterable {
        case month = "Month"
        case week = "Week Agenda"

        var component: Calendar.Component { self == .month ? .month : .weekOfYear }
    }

    private var period: DateInterval? { calendar.dateInterval(of: mode.component, for: selectedDay) }

    private var itemsByDay: [Date: [ContentRecord]] {
        var items: [Date: [ContentRecord]] = [:]
        for item in records {
            guard let date = item.plannedDate else { continue }
            items[calendar.startOfDay(for: date), default: []].append(item)
        }
        return items.mapValues { records in
            records.sorted {
                if $0.plannedDate != $1.plannedDate {
                    return ($0.plannedDate ?? .distantFuture) < ($1.plannedDate ?? .distantFuture)
                }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        }
    }

    var body: some View {
        let items = itemsByDay
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let period {
                    Text(periodTitle(period)).font(.title2.weight(.semibold))
                    if mode == .month {
                        monthGrid(period, items: items)
                        agendaDay(calendar.startOfDay(for: selectedDay), items: items)
                    } else {
                        ForEach(0..<7) { offset in
                            if let day = calendar.date(byAdding: .day, value: offset, to: period.start) {
                                agendaDay(day, items: items)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .toolbar {
            if showsControls {
                ToolbarItem {
                    Picker("Calendar View", selection: $mode) {
                        ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .help("Calendar View")
                }
                ToolbarItemGroup {
                    Button("Today") { selectedDay = Date() }
                    Button(mode == .month ? "Previous Month" : "Previous Week", systemImage: "chevron.left") {
                        shift(-1)
                    }
                    .labelStyle(.iconOnly)
                    Button(mode == .month ? "Next Month" : "Next Week", systemImage: "chevron.right") {
                        shift(1)
                    }
                    .labelStyle(.iconOnly)
                }
            }
        }
    }

    private func periodTitle(_ period: DateInterval) -> String {
        if mode == .month { return period.start.formatted(.dateTime.month(.wide).year()) }
        let lastDay = calendar.date(byAdding: .day, value: -1, to: period.end) ?? period.start
        return (period.start..<lastDay).formatted(.interval.month(.abbreviated).day().year())
    }

    private func shift(_ amount: Int) {
        selectedDay = calendar.date(byAdding: mode.component, value: amount, to: selectedDay) ?? selectedDay
    }

    private func monthGrid(_ period: DateInterval, items: [Date: [ContentRecord]]) -> some View {
        let leading = (calendar.component(.weekday, from: period.start) - calendar.firstWeekday + 7) % 7
        let length = calendar.range(of: .day, in: .month, for: period.start)?.count ?? 0
        let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
        return LazyVGrid(columns: columns, spacing: 4) {
            ForEach(0..<7) { offset in
                let weekday = (calendar.firstWeekday - 1 + offset) % 7
                Text(calendar.shortStandaloneWeekdaySymbols[weekday])
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            ForEach(0..<((leading + length + 6) / 7 * 7), id: \.self) { cell in
                let offset = cell - leading
                if let day = calendar.date(byAdding: .day, value: offset, to: period.start) {
                    let count = Set(items[day, default: []].map(\.id)).count
                    monthDay(day, inMonth: (0..<length).contains(offset), count: count)
                }
            }
        }
    }

    private func monthDay(_ day: Date, inMonth: Bool, count: Int) -> some View {
        let selected = calendar.isDate(day, inSameDayAs: selectedDay)
        let today = calendar.isDateInToday(day)
        let cellShape = RoundedRectangle(cornerRadius: 6)
        let postCount: LocalizedStringKey = count == 1 ? "1 post" : "\(count) posts"
        return Button {
            selectedDay = day
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(day.formatted(.dateTime.day()))
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(inMonth || selected || today ? .primary : .secondary)
                    // Center the visible digits inside the ring rather than the font's line box.
                    .offset(x: today ? -0.5 : 0, y: today ? -0.5 : 0)
                    .frame(width: 24, height: 24)
                    .background {
                        if today {
                            Circle().strokeBorder(Color.accentColor, lineWidth: 1.5)
                        }
                    }
                Spacer(minLength: 0)
                if count > 0 {
                    Text(postCount)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(inMonth ? .primary : .secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
            }
            .padding(5)
            .frame(maxWidth: .infinity, minHeight: 58, maxHeight: 58, alignment: .topLeading)
            .background(selected ? Color.accentColor.opacity(0.14) : .clear, in: cellShape)
            .overlay {
                cellShape.strokeBorder(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(today ? "Today, \(day.formatted(date: .complete, time: .omitted))"
                                  : day.formatted(date: .complete, time: .omitted))
        .accessibilityValue(Text(postCount))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func agendaDay(_ day: Date, items: [Date: [ContentRecord]]) -> some View {
        let dayRecords = items[day] ?? []
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Menu("New Content", systemImage: "plus") {
                    Button("Social Post") { create(.social, day) }
                    Button("Blog Article") { create(.blog, day) }
                    Button("Idea") { create(.idea, day) }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("Create content for \(day.formatted(date: .complete, time: .omitted))")
            }
            if dayRecords.isEmpty {
                Text("Nothing planned").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(dayRecords) { item in
                Button { open(item.id) } label: {
                    ContentLibraryRow(item: item, snapshot: snapshot, showsPlannedTime: true)
                }
                .buttonStyle(.plain)
            }
            Divider()
        }
    }
}
