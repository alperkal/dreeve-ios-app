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
    var storageUnavailable = false
    var appearance: ThemePreference = .dark
}
private func goalTimeline(result: GoalWidgetReadResult, selectedID: String? = nil) -> Timeline<GoalWidgetEntry> {
    let now = Date.now
    let appearance = ThemePreferenceStorage().read()
    guard let snapshot = result.snapshot else {
        // First-unlock restrictions or I/O failure aren't an empty goal inventory.
        return Timeline(entries: [GoalWidgetEntry(date: now, snapshot: .empty, selectedID: selectedID, storageUnavailable: true, appearance: appearance)],
                        policy: .after(now.addingTimeInterval(60)))
    }
    // A midnight entry invalidates completed progress at week/month rollover even
    // when the app is closed. Never display last period's check mark as current.
    let midnight = Calendar.current.startOfDay(for: Calendar.current.date(byAdding: .day, value: 1, to: now)!)
    return Timeline(entries: [GoalWidgetEntry(date: now, snapshot: snapshot, selectedID: selectedID, appearance: appearance),
                             GoalWidgetEntry(date: midnight, snapshot: snapshot, selectedID: selectedID, appearance: appearance)],
                    policy: .after(now.addingTimeInterval(900)))
}
struct CircleGoalProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> GoalWidgetEntry { GoalWidgetEntry(date: .now, snapshot: .example()) }
    func snapshot(for configuration: SelectWidgetGoal, in context: Context) async -> GoalWidgetEntry {
        let result: GoalWidgetReadResult = context.isPreview ? .available(.example()) : GoalWidgetStorage().readResult()
        return GoalWidgetEntry(date: .now, snapshot: result.snapshot ?? .empty, selectedID: context.isPreview ? nil : configuration.goal?.id,
                               storageUnavailable: result.snapshot == nil, appearance: context.isPreview ? .dark : ThemePreferenceStorage().read())
    }
    func timeline(for configuration: SelectWidgetGoal, in context: Context) async -> Timeline<GoalWidgetEntry> {
        goalTimeline(result: GoalWidgetStorage().readResult(), selectedID: configuration.goal?.id)
    }
}
struct OverviewGoalProvider: TimelineProvider {
    func placeholder(in context: Context) -> GoalWidgetEntry { GoalWidgetEntry(date: .now, snapshot: .example()) }
    func getSnapshot(in context: Context, completion: @escaping (GoalWidgetEntry) -> Void) {
        let result: GoalWidgetReadResult = context.isPreview ? .available(.example()) : GoalWidgetStorage().readResult()
        completion(GoalWidgetEntry(date: .now, snapshot: result.snapshot ?? .empty, storageUnavailable: result.snapshot == nil, appearance: context.isPreview ? .dark : ThemePreferenceStorage().read()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<GoalWidgetEntry>) -> Void) {
        completion(goalTimeline(result: GoalWidgetStorage().readResult()))
    }
}

struct GoalCompletionMark: View {
    var size: CGFloat = 32
    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: size * 0.48, weight: .heavy, design: .rounded))
            .foregroundStyle(DreeveTheme.background)
            .frame(width: size, height: size)
            .background(DreeveTheme.accent.gradient, in: Circle())
            .shadow(color: DreeveTheme.accent.opacity(0.22), radius: 5, y: 2)
            .accessibilityLabel("Goal reached")
    }
}
struct GoalWidgetEmpty: View {
    var unavailable = false
    var storageUnavailable = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "target").font(.title2).foregroundStyle(DreeveTheme.accent)
            Text(storageUnavailable ? "Saved goals unavailable" : unavailable ? "Goal unavailable" : "Your goals, at a glance").font(.headline).foregroundStyle(.primary)
            Text(storageUnavailable ? "Unlock or open Dreeve to reload saved goals." : unavailable ? "Open Dreeve or edit this widget to choose another goal." : "Open Dreeve to create goals and refresh progress.")
                .font(.caption).foregroundStyle(DreeveTheme.muted)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}
struct CircleGoalView: View {
    @Environment(\.colorScheme) private var systemScheme
    let entry: GoalWidgetEntry
    var body: some View {
        Group {
            if entry.storageUnavailable { GoalWidgetEmpty(storageUnavailable: true) }
            else if let goal = entry.snapshot.selectedGoal(id: entry.selectedID) {
                VStack(spacing: 3) {
                    HStack {
                        Text("DREEVE").font(.system(size: 9, weight: .heavy, design: .rounded)).tracking(1)
                        Spacer(minLength: 2)
                        Text(goal.frequency).font(.system(size: 9)).foregroundStyle(DreeveTheme.muted)
                    }.foregroundStyle(.primary)
                    ZStack {
                        Circle().stroke(DreeveTheme.elevated, lineWidth: 7)
                        Circle().trim(from: 0, to: goal.fraction(at: entry.date))
                            .stroke(DreeveTheme.accent.gradient, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        if goal.isComplete(at: entry.date) { GoalCompletionMark(size: 37) }
                        else if goal.value(at: entry.date) != nil {
                            Text("\(Int((goal.fraction(at: entry.date) * 100).rounded()))%")
                                .font(.system(size: 19, weight: .bold, design: .rounded)).foregroundStyle(.primary)
                        } else { Image(systemName: "arrow.clockwise").foregroundStyle(DreeveTheme.muted) }
                    }.frame(width: 62, height: 62).padding(.vertical, 3)
                    Text(goal.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.primary).lineLimit(1).minimumScaleFactor(0.8)
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
        .environment(\.colorScheme, entry.appearance.colorScheme ?? systemScheme)
    }
}
struct OverviewGoalsView: View {
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.widgetFamily) private var family
    let entry: GoalWidgetEntry
    var body: some View {
        let goals = entry.snapshot.orderedGoals(limit: family == .systemLarge ? 4 : 2)
        Group {
            if entry.storageUnavailable { GoalWidgetEmpty(storageUnavailable: true) }
            else if goals.isEmpty { GoalWidgetEmpty() }
            else {
                VStack(alignment: .leading, spacing: family == .systemLarge ? 16 : 9) {
                    HStack {
                        Label("Your goals", systemImage: "target").font(.system(size: 14, weight: .bold)).foregroundStyle(.primary)
                        Spacer()
                        Text("DREEVE").font(.system(size: 9, weight: .heavy, design: .rounded)).tracking(1).foregroundStyle(DreeveTheme.accent)
                    }
                    ForEach(goals) { goal in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 6) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(goal.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.primary).lineLimit(1)
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
        .environment(\.colorScheme, entry.appearance.colorScheme ?? systemScheme)
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
