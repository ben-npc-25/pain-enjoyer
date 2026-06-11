import SwiftUI

/// Month grid: each day shows a dot + km when there's a run.
/// Tap a day with runs → detail sheet. M3 overlays planned workouts here.
struct CalendarView: View {
    let runsByDay: [String: [RunRecord]]
    var onSelectDay: ([RunRecord]) -> Void

    @State private var monthOffset = 0

    private var calendar: Calendar { Calendar.current }

    private var displayedMonth: Date {
        calendar.date(byAdding: .month, value: monthOffset,
                      to: calendar.startOfMonth(for: .now))!
    }

    var body: some View {
        VStack(spacing: 12) {
            header
            weekdayRow
            monthGrid
            monthSummary
        }
        .padding(.horizontal)
    }

    // MARK: pieces

    private var header: some View {
        HStack {
            Button { monthOffset -= 1 } label: { Image(systemName: "chevron.left") }
            Spacer()
            Text(displayedMonth.formatted(.dateTime.month(.wide).year()))
                .font(.headline)
            Spacer()
            Button { monthOffset += 1 } label: { Image(systemName: "chevron.right") }
                .disabled(monthOffset >= 0)
        }
        .padding(.horizontal, 4)
    }

    private var weekdaySymbols: [String] {
        // rotate so the row starts on the locale's first weekday
        let syms = calendar.veryShortWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(syms[first...] + syms[..<first])
    }

    private var weekdayRow: some View {
        HStack {
            ForEach(weekdaySymbols, id: \.self) { d in
                Text(d).font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    /// Day cells for the displayed month, padded with nils to align weekdays.
    private var cells: [Date?] {
        let firstOfMonth = displayedMonth
        let daysInMonth = calendar.range(of: .day, in: .month, for: firstOfMonth)!.count
        let firstWeekday = calendar.component(.weekday, from: firstOfMonth)
        let leading = (firstWeekday - calendar.firstWeekday + 7) % 7
        var result: [Date?] = Array(repeating: nil, count: leading)
        for d in 0..<daysInMonth {
            result.append(calendar.date(byAdding: .day, value: d, to: firstOfMonth))
        }
        return result
    }

    private var monthGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7),
                  spacing: 6) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, day in
                if let day {
                    DayCell(
                        day: day,
                        runs: runsByDay[day.localDayKey] ?? [],
                        isToday: calendar.isDateInToday(day)
                    )
                    .onTapGesture {
                        let dayRuns = runsByDay[day.localDayKey] ?? []
                        if !dayRuns.isEmpty { onSelectDay(dayRuns) }
                    }
                } else {
                    Color.clear.frame(height: 46)
                }
            }
        }
    }

    private var monthRuns: [RunRecord] {
        let key = displayedMonth.localDayKey.prefix(7) // "2026-06"
        return runsByDay.filter { $0.key.hasPrefix(key) }.flatMap(\.value)
    }

    private var monthSummary: some View {
        let km = monthRuns.reduce(0) { $0 + $1.distanceKm }
        let count = monthRuns.count
        return Text(count == 0
                    ? "No runs this month yet"
                    : String(format: "%d runs · %.1f km this month", count, km))
            .font(.footnote)
            .foregroundStyle(.secondary)
    }
}

private struct DayCell: View {
    let day: Date
    let runs: [RunRecord]
    let isToday: Bool

    private var km: Double { runs.reduce(0) { $0 + $1.distanceKm } }

    var body: some View {
        VStack(spacing: 2) {
            Text("\(Calendar.current.component(.day, from: day))")
                .font(.callout.weight(isToday ? .bold : .regular))
                .foregroundStyle(isToday ? Color.accentColor : .primary)
            if runs.isEmpty {
                Circle().fill(.clear).frame(width: 6, height: 6)
                Text(" ").font(.system(size: 8))
            } else {
                Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                Text(String(format: "%.0f", km))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 46)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(runs.isEmpty ? Color.clear : Color.accentColor.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isToday ? Color.accentColor : .clear, lineWidth: 1)
        )
    }
}

extension Calendar {
    func startOfMonth(for date: Date) -> Date {
        self.date(from: dateComponents([.year, .month], from: date))!
    }
}
