import SwiftUI
import SwiftData

struct CoachCardView: View {
    let brief: CoachingBrief?
    let isLoading: Bool
    let status: String?
    let onRegenerate: () -> Void

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    Label("TRAINING BRIEF", systemImage: "sparkles")
                        .font(.caption.bold()).foregroundStyle(DreeveTheme.accent)
                    Spacer()
                    if let brief {
                        Text(badge(brief)).font(.caption2.bold()).foregroundStyle(DreeveTheme.accent)
                            .padding(6).background(DreeveTheme.accent.opacity(0.12), in: Capsule())
                    }
                    Button(action: onRegenerate) { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("Regenerate training brief").disabled(isLoading || brief == nil)
                }
                if isLoading { ProgressView("Preparing your brief…").font(.footnote) }
                if let brief {
                    Text(brief.headline).font(.subheadline.weight(.semibold))
                    ForEach(Array(brief.bulletInsights.enumerated()), id: \.offset) { _, bullet in
                        HStack(alignment: .top, spacing: 8) {
                            Circle().fill(DreeveTheme.accent).frame(width: 5, height: 5).padding(.top, 6)
                            Text(bullet).font(.footnote).foregroundStyle(DreeveTheme.muted)
                        }
                    }
                    Divider()
                    Label { Text(brief.goalActionPlan) } icon: {
                        Image(systemName: "flag.checkered").foregroundStyle(DreeveTheme.accent)
                    }.font(.footnote)
                    Text("\(brief.sourceEngine) · Verified figures")
                        .font(.caption2).foregroundStyle(DreeveTheme.muted)
                    Text("Recorded moving time describes volume, not intensity or injury risk. Goal pacing is an arithmetic average.")
                        .font(.caption2).foregroundStyle(DreeveTheme.muted)
                }
                if let status { Text(status).font(.footnote).foregroundStyle(DreeveTheme.muted) }
            }
        }
    }
    private func badge(_ brief: CoachingBrief) -> String {
        guard brief.workloadZone != .baselineBuilding, let ratio = brief.workloadRatio else { return "BASELINE" }
        return String(format: "DURATION %.2f×", ratio)
    }
}

// Only instantiate this query when the optional Goals container is available.
struct CoachGoalsSection: View {
    @Query private var storedGoals: [TrainingGoal]
    @EnvironmentObject private var progress: GoalProgressStore
    var body: some View {
        CoachDashboardHost(goals: TrainingGoal.favorites(TrainingGoal.visible(storedGoals, instance: progress.instanceID)))
    }
}

struct CoachDashboardHost: View {
    let goals: [TrainingGoal]
    @EnvironmentObject private var session: DreeveSession
    @EnvironmentObject private var progress: GoalProgressStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var engine = CoachEngine()
    @State private var brief: CoachingBrief?
    @State private var isLoading = false
    @State private var manualRequest = 0
    @State private var handledRequest = 0
    @State private var activation = 0

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            let context = makeContext(now: timeline.date)
            let current = brief.flatMap { $0.stateFingerprint == context?.stateFingerprint ? $0 : nil }
            CoachCardView(brief: current, isLoading: isLoading && context != nil,
                          status: status(context: context, now: timeline.date)) { manualRequest += 1 }
                .task(id: "\(context?.stateFingerprint ?? "pending")|\(manualRequest)|\(activation)") {
                    guard let context else { brief = nil; isLoading = false; return }
                    isLoading = true
                    let request = manualRequest
                    let result = await engine.generateBrief(for: context, forceRefresh: request != handledRequest)
                    guard !Task.isCancelled else { return }
                    brief = result; handledRequest = request; isLoading = false
                }
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { activation += 1 } }
    }

    private func makeContext(now: Date) -> CoachContextPayload? {
        guard session.isConfigured, session.activityIndexComplete, session.didLoadInsights,
              !progress.instanceID.isEmpty else { return nil }
        let today = GoalCalendar.today(now: now)
        let summaries = goals.compactMap { goal -> GoalRunRateSummary? in
            guard let current = progress.value(for: goal, now: now) else { return nil }
            return GoalRunRateSummary.make(id: goal.id.uuidString, title: goal.title, sport: goal.sportType,
                metric: goal.metric, target: goal.target, current: current,
                period: GoalCalendar.period(goal.frequency, now: now), today: today, frequency: goal.frequency)
        }
        // Overview's array is a complete local-index snapshot of the last 30 days,
        // refreshed after sync, imports, edits and deletions. No extra API request.
        return CoachContextBuilder.build(instanceHash: progress.instanceID, todayDayKey: today,
            activitiesLast30Days: session.insightsActivities.compactMap { try? ActivitySummaryRecord($0) },
            favoriteGoals: summaries, unavailableFavoriteGoals: goals.count - summaries.count)
    }

    private func status(context: CoachContextPayload?, now: Date) -> String? {
        if context == nil { return "Your brief will appear after the first complete activity sync." }
        if session.isSyncingActivityIndex { return "Updating activities… Showing the last complete snapshot." }
        if session.activitySyncError != nil || session.lastActivitySync.map({ now.timeIntervalSince($0) > 300 }) != false {
            return "Based on saved activities. Refresh Overview when connected for the latest figures."
        }
        return nil
    }
}
