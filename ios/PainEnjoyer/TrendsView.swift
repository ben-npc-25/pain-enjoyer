import SwiftUI
import Charts

/// M4 Trends tab: weekly volume, HRV/RHR vs baseline, effort score per run.
/// All display-only — the coaching numbers come from the server engine.
struct TrendsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    card("Weekly volume", subtitle: "last 12 weeks") { volumeChart }
                    card("Heart-rate variability", subtitle: "30 days vs baseline") {
                        recoveryChart(\.hrv_sdnn_ms, unit: "ms", color: .teal)
                    }
                    card("Resting heart rate", subtitle: "30 days vs baseline") {
                        recoveryChart(\.resting_hr, unit: "bpm", color: .pink)
                    }
                    card("Effort score per run", subtitle: "single-run VDOT, 180 days") { vdotChart }
                    coachReviewCard
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Trends")
            .refreshable { await model.refresh() }
        }
    }

    // MARK: chart cards

    @ViewBuilder
    private func card(_ title: String, subtitle: String,
                      @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Spacer()
                Text(subtitle).font(.caption).foregroundStyle(.tertiary)
            }
            content()
        }
        .cardStyle()
    }

    // MARK: weekly volume

    private struct WeekVolume: Identifiable {
        let id: Date
        let weekStart: Date
        let km: Double
    }

    private var weeklyVolumes: [WeekVolume] {
        let cal = Calendar.current
        guard let thisWeek = cal.dateInterval(of: .weekOfYear, for: .now)?.start else { return [] }
        var byWeek: [Date: Double] = [:]
        for run in model.runs {
            guard let wk = cal.dateInterval(of: .weekOfYear, for: run.startDate)?.start else { continue }
            byWeek[wk, default: 0] += run.distanceKm
        }
        return (0..<12).reversed().compactMap { back in
            guard let wk = cal.date(byAdding: .weekOfYear, value: -back, to: thisWeek) else { return nil }
            return WeekVolume(id: wk, weekStart: wk, km: byWeek[wk] ?? 0)
        }
    }

    @ViewBuilder
    private var volumeChart: some View {
        let data = weeklyVolumes
        if data.allSatisfy({ $0.km == 0 }) {
            placeholder("No runs in the last 12 weeks")
        } else {
            Chart(data) { w in
                BarMark(
                    x: .value("Week", w.weekStart, unit: .weekOfYear),
                    y: .value("km", w.km)
                )
                .foregroundStyle(Color.accentColor.gradient)
                .cornerRadius(4)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .month)) {
                    AxisGridLine(); AxisValueLabel(format: .dateTime.month(.abbreviated))
                }
            }
            .frame(height: 160)
        }
    }

    // MARK: recovery series (HRV / RHR share a shape)

    @ViewBuilder
    private func recoveryChart(_ keyPath: KeyPath<RecoveryFull, Double?>,
                               unit: String, color: Color) -> some View {
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: .now)!
        let points = model.recovery
            .compactMap { row -> (Date, Double)? in
                guard let v = row[keyPath: keyPath], v > 0, row.day >= cutoff else { return nil }
                return (row.day, v)
            }
            .sorted { $0.0 < $1.0 }
        // baseline over the whole fetched window (~90 d) — same idea as the engine
        let all = model.recovery.compactMap { $0[keyPath: keyPath] }.filter { $0 > 0 }.sorted()
        let baseline: Double? = all.isEmpty ? nil
            : (all.count % 2 == 1 ? all[all.count / 2] : (all[all.count / 2 - 1] + all[all.count / 2]) / 2)

        if points.count < 2 {
            placeholder("Not enough data yet — keep wearing the watch")
        } else {
            Chart {
                ForEach(points, id: \.0) { p in
                    LineMark(x: .value("Day", p.0), y: .value(unit, p.1))
                        .foregroundStyle(color)
                        .interpolationMethod(.catmullRom)
                    PointMark(x: .value("Day", p.0), y: .value(unit, p.1))
                        .foregroundStyle(color)
                        .symbolSize(20)
                }
                if let baseline {
                    RuleMark(y: .value("baseline", baseline))
                        .foregroundStyle(.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .annotation(position: .top, alignment: .trailing) {
                            Text("baseline \(Int(baseline)) \(unit)")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                }
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .frame(height: 150)
        }
    }

    // MARK: effort score

    @ViewBuilder
    private var vdotChart: some View {
        let points = model.runs
            .compactMap { run -> (Date, Double)? in
                guard let v = run.effortVDOT else { return nil }
                return (run.startDate, v)
            }
            .sorted { $0.0 < $1.0 }

        if points.count < 2 {
            placeholder("Runs of 3 km+ will chart here")
        } else {
            Chart {
                ForEach(points, id: \.0) { p in
                    PointMark(x: .value("Date", p.0), y: .value("VDOT", p.1))
                        .foregroundStyle(Color.accentColor.opacity(0.75))
                        .symbolSize(36)
                }
                if let current = model.engine?.vdot.value {
                    RuleMark(y: .value("current", current))
                        .foregroundStyle(.green)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .annotation(position: .top, alignment: .trailing) {
                            Text(String(format: "current %.1f", current))
                                .font(.caption2).foregroundStyle(.green)
                        }
                }
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .frame(height: 170)
        }
    }

    // MARK: coach's read on the charts (M6)

    private var latestReview: CoachMessage? {
        model.messages.last { $0.kind == "weekly_review" && !$0.isAthlete }
    }

    private var coachReviewCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Coach's read", systemImage: "figure.run.circle.fill").font(.headline)
                Spacer()
                Button {
                    Task { await model.trendsReview() }
                } label: {
                    if model.busy { ProgressView() }
                    else { Label("Refresh", systemImage: "sparkles").font(.footnote) }
                }
                .disabled(model.busy)
            }
            if let review = latestReview {
                CoachProse(text: review.content, font: .subheadline)
            } else {
                Text("Tap refresh and the coach will comment on what these charts say.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .cardStyle()
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.subheadline).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 110)
    }
}
