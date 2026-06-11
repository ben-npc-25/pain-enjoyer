import SwiftUI

/// Month grid: dot + km where there's a run, workout-type badge where there's
/// a plan (M3), 🏁 on race day. Tap any day with content → detail sheet.
struct CalendarView: View {
    let runsByDay: [String: [RunRecord]]
    var plannedByDay: [String: [PlannedWorkout]] = [:]
    var raceDayKey: String?
    var onSelectDay: (String) -> Void

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
            // M3: future months are where the plan (and the race) lives.
            Button { monthOffset += 1 } label: { Image(systemName: "chevron.right") }
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
                    let key = day.localDayKey
                    DayCell(
                        day: day,
                        runs: runsByDay[key] ?? [],
                        planned: plannedByDay[key] ?? [],
                        isToday: calendar.isDateInToday(day),
                        isRace: key == raceDayKey
                    )
                    .onTapGesture {
                        if !(runsByDay[key] ?? []).isEmpty
                            || !(plannedByDay[key] ?? []).isEmpty {
                            onSelectDay(key)
                        }
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

    private var monthPlannedKm: Double {
        let key = displayedMonth.localDayKey.prefix(7)
        return plannedByDay.filter { $0.key.hasPrefix(key) }
            .flatMap(\.value).reduce(0) { $0 + $1.distanceKm }
    }

    private var monthSummary: some View {
        let km = monthRuns.reduce(0) { $0 + $1.distanceKm }
        let count = monthRuns.count
        var text = count == 0
            ? "No runs this month yet"
            : String(format: "%d runs · %.1f km this month", count, km)
        if monthPlannedKm > 0 {
            text += String(format: " · %.0f km planned", monthPlannedKm)
        }
        return Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
    }
}

private struct DayCell: View {
    let day: Date
    let runs: [RunRecord]
    let planned: [PlannedWorkout]
    let isToday: Bool
    let isRace: Bool

    private var km: Double { runs.reduce(0) { $0 + $1.distanceKm } }
    private var plan: PlannedWorkout? { planned.first }

    private var planColor: Color { plan?.statusColor ?? .blue }

    var body: some View {
        VStack(spacing: 2) {
            Text("\(Calendar.current.component(.day, from: day))")
                .font(.callout.weight(isToday ? .bold : .regular))
                .foregroundStyle(isToday ? Color.accentColor : .primary)
            marker
        }
        .frame(maxWidth: .infinity, minHeight: 46)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isToday ? Color.accentColor : .clear, lineWidth: 1)
        )
    }

    private var background: Color {
        if isRace { return .purple.opacity(0.15) }
        if !runs.isEmpty { return Color.accentColor.opacity(0.10) }
        if let p = plan, !p.isRest { return planColor.opacity(0.08) }
        return .clear
    }

    @ViewBuilder
    private var marker: some View {
        if isRace {
            Text("🏁").font(.system(size: 11))
            Text(" ").font(.system(size: 8))
        } else if !runs.isEmpty {
            Circle().fill(Color.accentColor).frame(width: 6, height: 6)
            Text(String(format: "%.0f", km))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
        } else if let p = plan, !p.isRest {
            // future/planned: type letter in the status color
            Text(p.type)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(planColor)
            Text(p.distanceKm > 0 ? String(format: "%.0f", p.distanceKm) : " ")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        } else if plan != nil {
            // planned rest day — visible (an injured rehab week is ALL of
            // these) and tappable for the description
            Text("zZ")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
            Text(" ").font(.system(size: 8))
        } else {
            Circle().fill(.clear).frame(width: 6, height: 6)
            Text(" ").font(.system(size: 8))
        }
    }
}

extension Calendar {
    func startOfMonth(for date: Date) -> Date {
        self.date(from: dateComponents([.year, .month], from: date))!
    }
}
