import SwiftUI
import WidgetKit
import AppIntents

struct WidgetGoalEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Goal")
    static let defaultQuery = WidgetGoalQuery()
    let id: String
    let name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}
struct WidgetGoalQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [WidgetGoalEntity] {
        GoalWidgetStorage().read().goals.filter { identifiers.contains($0.id) }.map { WidgetGoalEntity(id: $0.id, name: $0.title) }
    }
    func suggestedEntities() async throws -> [WidgetGoalEntity] {
        let snapshot = GoalWidgetStorage().read()
        return snapshot.orderedGoals(limit: snapshot.goals.count).map { WidgetGoalEntity(id: $0.id, name: $0.title) }
    }
    func defaultResult() async -> WidgetGoalEntity? {
        GoalWidgetStorage().read().selectedGoal(id: nil).map { WidgetGoalEntity(id: $0.id, name: $0.title) }
    }
}
struct SelectWidgetGoal: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Choose a goal"
    static let description = IntentDescription("Select the goal to show in this widget.")
    @Parameter(title: "Goal") var goal: WidgetGoalEntity?
}
struct GoalWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: GoalWidgetSnapshot
    var selectedID: String? = nil
}
private func goalTimeline(snapshot: GoalWidgetSnapshot, selectedID: String? = nil) -> Timeline<GoalWidgetEntry> {
    let now = Date.now
    // A midnight entry invalidates completed progress at week/month rollover even
    // when the app is closed. Never display last period's check mark as current.
    let midnight = Calendar.current.startOfDay(for: Calendar.current.date(byAdding: .day, value: 1, to: now)!)
    return Timeline(entries: [GoalWidgetEntry(date: now, snapshot: snapshot, selectedID: selectedID),
                             GoalWidgetEntry(date: midnight, snapshot: snapshot, selectedID: selectedID)],
                    policy: .after(now.addingTimeInterval(900)))
}
struct CircleGoalProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> GoalWidgetEntry { GoalWidgetEntry(date: .now, snapshot: .example()) }
    func snapshot(for configuration: SelectWidgetGoal, in context: Context) async -> GoalWidgetEntry {
        GoalWidgetEntry(date: .now, snapshot: context.isPreview ? .example() : GoalWidgetStorage().read(), selectedID: context.isPreview ? nil : configuration.goal?.id)
    }
    func timeline(for configuration: SelectWidgetGoal, in context: Context) async -> Timeline<GoalWidgetEntry> {
        goalTimeline(snapshot: GoalWidgetStorage().read(), selectedID: configuration.goal?.id)
    }
}
struct OverviewGoalProvider: TimelineProvider {
    func placeholder(in context: Context) -> GoalWidgetEntry { GoalWidgetEntry(date: .now, snapshot: .example()) }
    func getSnapshot(in context: Context, completion: @escaping (GoalWidgetEntry) -> Void) {
        completion(GoalWidgetEntry(date: .now, snapshot: context.isPreview ? .example() : GoalWidgetStorage().read()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<GoalWidgetEntry>) -> Void) {
        completion(goalTimeline(snapshot: GoalWidgetStorage().read()))
    }
}

struct GoalCompletionMark: View {
    var size: CGFloat = 32
    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: size * 0.48, weight: .heavy, design: .rounded))
            .foregroundStyle(DreeveTheme.background)
            .frame(width: size, height: size)
            .background(LinearGradient(colors: [DreeveTheme.accent, Color(red: 0.40, green: 0.85, blue: 0.35)], startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
            .shadow(color: DreeveTheme.accent.opacity(0.22), radius: 5, y: 2)
            .accessibilityLabel("Goal reached")
    }
}
struct GoalWidgetEmpty: View {
    var unavailable = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "target").font(.title2).foregroundStyle(DreeveTheme.accent)
            Text(unavailable ? "Goal unavailable" : "Your goals, at a glance").font(.headline).foregroundStyle(.white)
            Text(unavailable ? "Open Dreeve or edit this widget to choose another goal." : "Open Dreeve to create goals and refresh progress.")
                .font(.caption).foregroundStyle(DreeveTheme.muted)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}
struct CircleGoalView: View {
    let entry: GoalWidgetEntry
    var body: some View {
        Group {
            if let goal = entry.snapshot.selectedGoal(id: entry.selectedID) {
                VStack(spacing: 3) {
                    HStack {
                        Text("DREEVE").font(.system(size: 9, weight: .heavy, design: .rounded)).tracking(1)
                        Spacer(minLength: 2)
                        Text(goal.frequency).font(.system(size: 9)).foregroundStyle(DreeveTheme.muted)
                    }.foregroundStyle(.white)
                    ZStack {
                        Circle().stroke(DreeveTheme.elevated, lineWidth: 7)
                        Circle().trim(from: 0, to: goal.fraction(at: entry.date))
                            .stroke(DreeveTheme.accent.gradient, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        if goal.isComplete(at: entry.date) { GoalCompletionMark(size: 37) }
                        else if goal.value(at: entry.date) != nil {
                            Text("\(Int((goal.fraction(at: entry.date) * 100).rounded()))%")
                                .font(.system(size: 19, weight: .bold, design: .rounded)).foregroundStyle(.white)
                        } else { Image(systemName: "arrow.clockwise").foregroundStyle(DreeveTheme.muted) }
                    }.frame(width: 62, height: 62).padding(.vertical, 3)
                    Text(goal.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.8)
                    Text(goal.progressText(at: entry.date)).font(.system(size: 10)).monospacedDigit().foregroundStyle(DreeveTheme.muted).lineLimit(1)
                    if goal.value(at: entry.date) == nil {
                        Text("Open to refresh").font(.system(size: 9)).foregroundStyle(DreeveTheme.accent)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(goal.title), \(goal.progressText(at: entry.date)), \(goal.isComplete(at: entry.date) ? "goal reached" : goal.frequency)")
            } else { GoalWidgetEmpty(unavailable: entry.selectedID != nil) }
        }
        .widgetURL(URL(string: "dreeve://overview"))
        .containerBackground(DreeveTheme.background, for: .widget)
    }
}
struct OverviewGoalsView: View {
    @Environment(\.widgetFamily) private var family
    let entry: GoalWidgetEntry
    var body: some View {
        let goals = entry.snapshot.orderedGoals(limit: family == .systemLarge ? 4 : 2)
        Group {
            if goals.isEmpty { GoalWidgetEmpty() }
            else {
                VStack(alignment: .leading, spacing: family == .systemLarge ? 16 : 9) {
                    HStack {
                        Label("Your goals", systemImage: "target").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                        Spacer()
                        Text("DREEVE").font(.system(size: 9, weight: .heavy, design: .rounded)).tracking(1).foregroundStyle(DreeveTheme.accent)
                    }
                    ForEach(goals) { goal in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 6) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(goal.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                                    Text("\(goal.frequency) · \(goal.progressText(at: entry.date))")
                                        .font(.system(size: 10)).monospacedDigit().foregroundStyle(DreeveTheme.muted).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                if goal.isComplete(at: entry.date) { GoalCompletionMark(size: 24) }
                            }
                            GeometryReader { geometry in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(DreeveTheme.elevated)
                                    Capsule().fill(DreeveTheme.accent.gradient).frame(width: geometry.size.width * goal.fraction(at: entry.date))
                                }
                            }.frame(height: 5)
                        }.accessibilityElement(children: .combine)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .widgetURL(URL(string: "dreeve://overview"))
        .containerBackground(DreeveTheme.background, for: .widget)
    }
}

struct DreeveCircleGoalWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "DreeveGoalCircle", intent: SelectWidgetGoal.self, provider: CircleGoalProvider()) { CircleGoalView(entry: $0) }
            .configurationDisplayName("Goal ring")
            .description("Choose a goal and follow its progress. A lime check celebrates completion.")
            .supportedFamilies([.systemSmall])
    }
}
struct DreeveGoalsOverviewWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "DreeveGoalOverview", provider: OverviewGoalProvider()) { OverviewGoalsView(entry: $0) }
            .configurationDisplayName("Goals overview")
            .description("Your favorite goals with progress bars and completion checks.")
            .supportedFamilies([.systemMedium, .systemLarge])
    }
}
@main struct DreeveGoalWidgets: WidgetBundle {
    var body: some Widget { DreeveCircleGoalWidget(); DreeveGoalsOverviewWidget() }
}
