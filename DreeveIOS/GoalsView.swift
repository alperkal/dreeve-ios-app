import SwiftUI
import SwiftData

struct GoalsView: View {
    @EnvironmentObject private var persistence: GoalPersistence
    var body: some View {
        if persistence.container != nil { GoalsListView() }
        else {
            NavigationStack {
                ContentUnavailableView("Goals unavailable", systemImage: "externaldrive.badge.exclamationmark",
                                       description: Text(persistence.status))
            }
        }
    }
}

struct GoalsListView: View {
    @EnvironmentObject private var session: DreeveSession
    @EnvironmentObject private var progress: GoalProgressStore
    @EnvironmentObject private var persistence: GoalPersistence
    @Environment(\.modelContext) private var context
    @Query private var storedGoals: [TrainingGoal]
    @State private var creating = false
    @State private var editing: TrainingGoal?
    @State private var showArchived = false
    @State private var error: String?
    private var goals: [TrainingGoal] {
        TrainingGoal.visible(storedGoals, instance: progress.instanceID)
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    GoalRefreshStatus()
                    Text(persistence.status).font(.caption).foregroundStyle(.secondary)
                }
                Section("Overview favorites") {
                    ForEach(1...2, id: \.self) { rank in
                        Picker("Favorite \(rank)", selection: Binding<UUID?>(
                            get: { TrainingGoal.favorites(goals).first { $0.favoriteRank == rank }?.id },
                            set: { selectFavorite($0, rank: rank) })) {
                            Text("None").tag(UUID?.none)
                            ForEach(goals.filter { !$0.isArchived }) { goal in
                                Text(goal.title).tag(Optional(goal.id))
                            }
                        }
                    }
                }
                Section("Active goals") {
                    if goals.filter({ !$0.isArchived }).isEmpty {
                        Text("Create a goal to include all matching activities from the start of this week or month.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(goals.filter { !$0.isArchived }) { goal in
                        Button { editing = goal } label: { GoalProgressRow(goal: goal) }
                            .buttonStyle(.plain)
                            .swipeActions {
                                Button("Archive") { archive(goal, true) }.tint(.orange)
                            }
                    }
                }
                Section {
                    Toggle("Show archived goals", isOn: $showArchived)
                    if showArchived {
                        ForEach(goals.filter { $0.isArchived }) { goal in
                            HStack {
                                Button(goal.title) { editing = goal }
                                Spacer()
                                Button("Restore") { archive(goal, false) }
                            }
                        }
                    }
                }
                Section {
                    Text("Tap a goal to edit, or swipe left to archive. Weeks start Monday. The current week and month follow this device’s timezone; activities keep their recorded local date. Distance targets are entered in kilometres. Creating or editing a goal includes the entire current period.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Goals")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New goal", systemImage: "plus") { creating = true }
                }
            }
            .refreshable { await session.refreshGoals(); await persistence.checkAccount() }
            .sheet(isPresented: $creating) { GoalEditorView(goal: nil, instanceID: progress.instanceID) }
            .sheet(item: $editing) { GoalEditorView(goal: $0, instanceID: progress.instanceID) }
            .alert("Could not save goal", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
        }
        .tint(DreeveTheme.accent)
    }
    private func save() {
        do { try context.save() }
        catch { context.rollback(); self.error = error.localizedDescription }
    }
    private func archive(_ goal: TrainingGoal, _ value: Bool) {
        goal.isArchived = value
        goal.favoriteRank = 0
        goal.updatedAt = .now
        save()
    }
    private func selectFavorite(_ id: UUID?, rank: Int) {
        // Clear collisions imported by another device, then assign the chosen slot.
        for goal in goals where goal.favoriteRank == rank || goal.id == id {
            goal.favoriteRank = 0
            goal.updatedAt = .now
        }
        if let chosen = goals.first(where: { $0.id == id && !$0.isArchived }) {
            chosen.favoriteRank = rank
            chosen.updatedAt = .now
        }
        save()
    }
}

struct GoalEditorView: View {
    @EnvironmentObject private var session: DreeveSession
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let goal: TrainingGoal?
    let instanceID: String
    @State private var name: String
    @State private var sport: String
    @State private var metric: GoalMetric
    @State private var frequency: GoalFrequency
    @State private var targetText: String
    @State private var error: String?
    @State private var confirmDelete = false

    init(goal: TrainingGoal?, instanceID: String) {
        self.goal = goal
        self.instanceID = instanceID
        _name = State(initialValue: goal?.name ?? "")
        _sport = State(initialValue: goal?.sportType ?? "Run")
        _metric = State(initialValue: goal?.metric ?? .count)
        _frequency = State(initialValue: goal?.frequency ?? .weekly)
        let target = (goal?.target ?? 3) / (goal?.metric == .distance ? 1000 : 1)
        _targetText = State(initialValue: target.formatted(.number.grouping(.never).precision(.fractionLength(0...6))))
    }
    private var target: Double? {
        let formatter = NumberFormatter()
        formatter.locale = .current
        formatter.numberStyle = .decimal
        formatter.isLenient = false
        // Reject grouping / malformed entries; permit the locale decimal separator.
        let separator = formatter.decimalSeparator ?? "."
        let normalized = targetText.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: separator, with: ".")
        guard let value = Double(normalized), value.isFinite, value > 0,
              metric == .distance || value.rounded() == value,
              (value * (metric == .distance ? 1000 : 1)).isFinite else { return nil }
        return value * (metric == .distance ? 1000 : 1)
    }
    private var sports: [String] {
        Array(Set(["Run", "Walk", "Ride", "Hike", "Swim", "VirtualRide", "VirtualRun", "TrailRun"] +
                  session.activities.map(\.sportType) + session.insightsActivities.map(\.sportType))).sorted()
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Goal") {
                    TextField("Name (optional)", text: $name)
                    TextField("Dreeve sport type", text: $sport)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Menu("Choose a sport") {
                        ForEach(sports, id: \.self) { item in Button(item) { sport = item } }
                    }
                    Picker("Measure", selection: $metric) {
                        ForEach(GoalMetric.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Repeat", selection: $frequency) {
                        ForEach(GoalFrequency.allCases) { Text($0.label).tag($0) }
                    }
                    HStack {
                        Text(metric == .count ? "Target (activities)" : "Target (km)")
                        TextField("Target", text: $targetText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    if target == nil { Text("Enter a positive target; activity counts must be whole numbers.").font(.caption).foregroundStyle(.orange) }
                }
                Section {
                    Text("Sport type must exactly match Dreeve, for example Run or Walk. All matching activities in the current calendar period count, including activities before this goal was created.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if goal != nil {
                    Section {
                        Button("Delete goal", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .navigationTitle(goal == nil ? "New goal" : "Edit goal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(target == nil || sport.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .confirmationDialog("Delete this goal?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete goal", role: .destructive) {
                    guard let goal else { return }
                    context.delete(goal)
                    do { try context.save(); dismiss() }
                    catch { context.rollback(); self.error = error.localizedDescription }
                }
            }
            .alert("Could not save goal", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
        }
        .tint(DreeveTheme.accent)
    }
    private func save() {
        guard let target, !instanceID.isEmpty, session.goalProgress.instanceID == instanceID else { return }
        let value = goal ?? TrainingGoal(instanceID: instanceID, name: name, sport: sport, metric: metric, frequency: frequency, target: target)
        if goal == nil { context.insert(value) }
        value.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        value.sportType = sport.trimmingCharacters(in: .whitespacesAndNewlines)
        value.metricRaw = metric.rawValue
        value.frequencyRaw = frequency.rawValue
        value.target = target
        value.updatedAt = .now
        do {
            try context.save()
            dismiss()
            Task { await session.refreshGoals() }
        } catch { context.rollback(); self.error = error.localizedDescription }
    }
}

struct GoalProgressRow: View {
    @EnvironmentObject private var progress: GoalProgressStore
    let goal: TrainingGoal
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            let value = progress.value(for: goal, now: timeline.date)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(goal.title, systemImage: activitySymbol(goal.sportType)).font(.headline)
                    Spacer()
                    if goal.favoriteRank > 0 { Image(systemName: "star.fill").foregroundStyle(.yellow) }
                }
                Text("\(goal.sportType) · \(goal.frequency.label)").font(.caption).foregroundStyle(.secondary)
                if let value {
                    let divisor: Double = goal.metric == .distance ? 1000 : 1
                    let suffix = goal.metric == .distance ? "km" : "activities"
                    Text("\((value / divisor).formatted(.number.precision(.fractionLength(0...2)))) / \((goal.target / divisor).formatted(.number.precision(.fractionLength(0...2)))) \(suffix)")
                        .monospacedDigit()
                    ProgressView(value: min(1, max(0, value / max(goal.target, 1))))
                        .tint(DreeveTheme.accent)
                    if value >= goal.target { Text("Goal reached").font(.caption).foregroundStyle(DreeveTheme.accent) }
                } else { Text("Current period progress unavailable · refresh to calculate").font(.caption).foregroundStyle(.secondary) }
                if progress.isStale(now: timeline.date) { Text("Saved progress may be out of date").font(.caption).foregroundStyle(.orange) }
            }
            .padding(.vertical, 6)
        }
    }
}

struct GoalRefreshStatus: View {
    @EnvironmentObject private var progress: GoalProgressStore
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            VStack(alignment: .leading, spacing: 4) {
                if progress.isRefreshing { ProgressView("Updating goal progress…") }
                if let refreshed = progress.snapshot?.refreshedAt {
                    Text("Progress updated \(refreshed.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                } else { Text("Progress has not been fetched yet").font(.caption) }
                if let error = progress.error { Text(error).font(.caption).foregroundStyle(.orange) }
                else if progress.isStale(now: timeline.date) { Text("Progress is stale · refresh when connected").font(.caption).foregroundStyle(.orange) }
            }
        }
    }
}

struct FavoriteGoalsView: View {
    @EnvironmentObject private var progress: GoalProgressStore
    @Query private var storedGoals: [TrainingGoal]
    private var favorites: [TrainingGoal] {
        TrainingGoal.favorites(TrainingGoal.visible(storedGoals, instance: progress.instanceID))
    }
    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("YOUR GOALS").font(.caption.bold())
                    Spacer()
                    NavigationLink("View all") { GoalsView() }
                }
                if favorites.isEmpty { Text("Choose up to two favorites in Goals.").font(.subheadline).foregroundStyle(.secondary) }
                ForEach(favorites) { GoalProgressRow(goal: $0) }
                GoalRefreshStatus()
            }
        }
    }
}
