import SwiftUI
import WidgetKit
import AppIntents

struct WatchGoalEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Goal")
    static let defaultQuery = WatchGoalQuery()
    let id: String
    let title: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }
}
struct WatchGoalQuery: EntityQuery {
    func suggestedEntities() async throws -> [WatchGoalEntity] {
        let snapshot = GoalWatchStorage().readResult().snapshot ?? .empty
        return snapshot.orderedGoals(limit: snapshot.goals.count).map {
            WatchGoalEntity(id: WatchGoalSelection(instanceID: snapshot.instanceID, goalID: $0.id).entityID, title: $0.title)
        }
    }
    func entities(for identifiers: [String]) async throws -> [WatchGoalEntity] {
        let snapshot = GoalWatchStorage().readResult().snapshot ?? .empty
        // Keep a configured missing entity intact. Returning [] can make WidgetKit
        // reset an optional parameter to nil and silently pick a different favorite.
        return identifiers.compactMap { identifier in
            guard let selection = WatchGoalSelection(entityID: identifier) else { return nil }
            return WatchGoalEntity(id: identifier, title: selection.goal(in: snapshot)?.title ?? "Goal unavailable")
        }
    }
    func defaultResult() async -> WatchGoalEntity? { try? await suggestedEntities().first }
}
struct ChooseWatchGoal: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Choose a goal"
    static let description = IntentDescription("Select a Dreeve goal for this complication.")
    @Parameter(title: "Goal") var goal: WatchGoalEntity?
}
struct WatchComplicationEntry: TimelineEntry {
    let date: Date
    let snapshot: GoalWidgetSnapshot
    let selectedID: String?
    var storageUnavailable = false
    var goal: WidgetGoal? {
        guard let selectedID else { return snapshot.selectedGoal(id: nil) }
        return WatchGoalSelection(entityID: selectedID)?.goal(in: snapshot)
    }
    var url: URL {
        goal.map { WatchGoalSelection(instanceID: snapshot.instanceID, goalID: $0.id).url } ??
            selectedID.flatMap { WatchGoalSelection(entityID: $0)?.url } ?? URL(string: "dreevewatch://goals")!
    }
}
struct WatchComplicationProvider: AppIntentTimelineProvider {
    func recommendations() -> [AppIntentRecommendation<ChooseWatchGoal>] {
        let snapshot = GoalWatchStorage().readResult().snapshot ?? .empty
        let goals = snapshot.orderedGoals(limit: snapshot.goals.count)
        if goals.isEmpty { return [AppIntentRecommendation(intent: ChooseWatchGoal(), description: "Goal progress")] }
        return goals.map { goal in
            let intent = ChooseWatchGoal()
            intent.goal = WatchGoalEntity(id: WatchGoalSelection(instanceID: snapshot.instanceID, goalID: goal.id).entityID, title: goal.title)
            return AppIntentRecommendation(intent: intent, description: goal.title)
        }
    }

    func placeholder(in context: Context) -> WatchComplicationEntry {
        WatchComplicationEntry(date: .now, snapshot: .example(), selectedID: nil)
    }
    func snapshot(for configuration: ChooseWatchGoal, in context: Context) async -> WatchComplicationEntry {
        let result = context.isPreview ? GoalWidgetReadResult.available(.example()) : GoalWatchStorage().readResult()
        return WatchComplicationEntry(date: .now, snapshot: result.snapshot ?? .empty,
            selectedID: context.isPreview ? nil : configuration.goal?.id, storageUnavailable: result.snapshot == nil)
    }
    func timeline(for configuration: ChooseWatchGoal, in context: Context) async -> Timeline<WatchComplicationEntry> {
        let now = Date.now
        let result = GoalWatchStorage().readResult()
        let midnight = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now))!
        return Timeline(entries: [now, midnight].map {
            WatchComplicationEntry(date: $0, snapshot: result.snapshot ?? .empty, selectedID: configuration.goal?.id,
                storageUnavailable: result.snapshot == nil)
        }, policy: .after(now.addingTimeInterval(result.snapshot == nil ? 60 : 900)))
    }
}
struct WatchGoalComplicationView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WatchComplicationEntry
    private let accent = Color(red: 177/255, green: 244/255, blue: 82/255)
    var body: some View {
        Group {
            if let goal = entry.goal {
                let value = goal.value(at: entry.date)
                if family == .accessoryCorner {
                    Group {
                        if goal.isComplete(at: entry.date) { Image(systemName: "checkmark.circle.fill").foregroundStyle(accent) }
                        else { Text(value == nil ? "—" : "\(Int((goal.fraction(at: entry.date) * 100).rounded()))%") }
                    }
                    .font(.system(.title3, design: .rounded).bold())
                    .widgetLabel {
                        Gauge(value: goal.fraction(at: entry.date)) { Text(goal.title) }
                        currentValueLabel: { Text(value == nil ? "Refresh" : goal.progressText(at: entry.date)) }
                        .tint(accent)
                    }
                } else {
                    Gauge(value: goal.fraction(at: entry.date)) { Image(systemName: watchGoalSymbol(goal.sport)) }
                    currentValueLabel: {
                        if goal.isComplete(at: entry.date) { Image(systemName: "checkmark").foregroundStyle(accent) }
                        else if value == nil { Image(systemName: "arrow.clockwise") }
                        else { Text("\(Int((goal.fraction(at: entry.date) * 100).rounded()))%") }
                    }
                    .gaugeStyle(.accessoryCircular).tint(accent)
                    .widgetLabel { Text(goal.title) }
                }
            } else {
                Image(systemName: entry.storageUnavailable ? "iphone" : "target")
                    .widgetLabel { Text(entry.storageUnavailable ? "Open iPhone app" : entry.selectedID != nil ? "Choose goal" : "No goals") }
            }
        }
        .containerBackground(.clear, for: .widget)
        .widgetURL(entry.url)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.goal.map {
            "\($0.title), \($0.progressText(at: entry.date)), \($0.isComplete(at: entry.date) ? "goal reached" : $0.value(at: entry.date) == nil ? "refresh on iPhone" : "saved goal progress")"
        } ?? "Dreeve goals unavailable. Open Dreeve on iPhone.")
    }
}
@main struct DreeveWatchComplications: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "DreeveWatchGoal", intent: ChooseWatchGoal.self, provider: WatchComplicationProvider()) {
            WatchGoalComplicationView(entry: $0)
        }
        .configurationDisplayName("Goal progress")
        .description("Choose a goal for a corner gauge or circular progress ring.")
        .supportedFamilies([.accessoryCorner, .accessoryCircular])
    }
}
