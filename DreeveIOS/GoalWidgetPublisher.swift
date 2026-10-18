import SwiftUI
import SwiftData
import WidgetKit
import UIKit

/// The extension receives only active goal definitions and derived totals. The
/// SwiftData store, API credentials and underlying activity records stay in the app.
struct GoalWidgetPublisher: View {
    @EnvironmentObject private var progress: GoalProgressStore
    @Query private var goals: [TrainingGoal]
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    private struct Request: Equatable { let snapshot: GoalWidgetSnapshot; let active: Bool }
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            let value = snapshot(at: timeline.date, goals: goals)
            Color.clear.frame(width: 0, height: 0)
                .task(id: Request(snapshot: value, active: scenePhase == .active)) {
                    guard scenePhase == .active, UIApplication.shared.isProtectedDataAvailable, !progress.instanceID.isEmpty else { return }
                    do {
                        // Query observation invalidates this task, but only a successful
                        // explicit fetch authorizes publishing an empty inventory.
                        let fetched = try context.fetch(FetchDescriptor<TrainingGoal>())
                        let confirmed = snapshot(at: timeline.date, goals: fetched)
                        let storage = GoalWidgetStorage()
                        try storage.prepareForWidgetAccess()
                        let previous = storage.readResult().snapshot
                        let published = confirmed.retainingKnownProgress(from: previous)
                        guard previous != published else { return }
                        try storage.write(published)
                        for kind in GoalWidgetStorage.kinds { WidgetCenter.shared.reloadTimelines(ofKind: kind) }
                    } catch {
                        // A missing App Group must never block the app's local goals.
                    }
                }
        }
        .accessibilityHidden(true)
    }
    private func snapshot(at date: Date, goals: [TrainingGoal]) -> GoalWidgetSnapshot {
        guard !progress.instanceID.isEmpty else { return .empty }
        let visible = TrainingGoal.visible(goals, instance: progress.instanceID).filter { !$0.isArchived && $0.target.isFinite && $0.target > 0 }
        return GoalWidgetSnapshot(instanceID: progress.instanceID, updatedAt: progress.snapshot?.refreshedAt,
            refreshFailed: progress.error != nil, favorites: TrainingGoal.favorites(visible).map { $0.id.uuidString }, goals: visible.map { goal in
                let period = GoalCalendar.period(goal.frequency, now: date)
                let divisor = goal.metric == .distance ? 1000.0 : 1.0
                return WidgetGoal(id: goal.id.uuidString, title: goal.title, sport: goal.sportType, frequency: goal.frequency.label,
                    isDistance: goal.metric == .distance, target: goal.target / divisor,
                    current: progress.value(for: goal, now: date).map { $0 / divisor },
                    periodStart: period.start, periodEnd: period.endExclusive)
            })
    }
}
