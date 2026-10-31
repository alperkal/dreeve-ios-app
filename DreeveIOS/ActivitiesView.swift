import SwiftUI

struct ActivitiesView: View {
    @EnvironmentObject private var session: DreeveSession
    @EnvironmentObject private var healthSync: HealthSyncStore
    @State private var gearActivities: [DreeveActivity] = []
    @State private var gearActivityError: String?
    @State private var cachedGearKey = ""
    @State private var search = ""
    @State private var selectedGearID: String?
    @State private var gearChoices: [DreeveGear]
    @State private var gearError: String?
    @State private var gearChoicesServer = ""
    private let embedded: Bool
    private let sportFilter: ActivitySportFilter?
    @State private var sportActivities: [DreeveActivity] = []
    @State private var sportCacheKey = ""
    @State private var sportError: String?
    @State private var loadingSport = false
    @State private var sportRequestID = UUID()

    init(gear: DreeveGear? = nil, embedded: Bool = false, sportFilter: ActivitySportFilter? = nil) {
        self.sportFilter = sportFilter
        self.embedded = embedded
        _selectedGearID = State(initialValue: gear?.id)
        _gearChoices = State(initialValue: gear.map { [$0] } ?? [])
    }
    private var selectedName: String? {
        guard let selectedGearID else { return nil }
        return gearChoices.first { $0.id == selectedGearID }?.name ?? selectedGearID
    }
    private var source: [DreeveActivity] {
        if let sportFilter {
            let values = sportCacheKey == session.serverAddress + "|" + sportFilter.key ? sportActivities :
                session.insightsActivities.filter { sportFilter.matches($0) }
            return values.filter { selectedGearID == nil || $0.gearId == selectedGearID }
        }
        return selectedGearID == nil ? session.activities :
            (cachedGearKey == session.serverAddress + "|" + (selectedGearID ?? "") ? gearActivities : [])
    }
    private var isLoading: Bool {
        sportFilter != nil ? loadingSport : (selectedGearID == nil ? session.isLoadingActivities : session.isSyncingActivityIndex)
    }
    private var visibleFeed: [HealthActivityFeedEntry] {
        let entries = HealthActivityFeed.entries(activities: source,
            records: selectedGearID == nil ? healthSync.records : [], server: session.serverAddress,
            knownActivities: session.activities + session.insightsActivities)
        return entries.filter { entry in
            let activity = entry.summary
            if let sportFilter, !sportFilter.matches(activity) { return false }
            return search.isEmpty || activity.name.localizedCaseInsensitiveContains(search) ||
                activity.sportType.localizedCaseInsensitiveContains(search) ||
                activity.locationLabel.localizedCaseInsensitiveContains(search) ||
                (gearChoices.first { $0.id == activity.gearId }?.name.localizedCaseInsensitiveContains(search) ?? false)
        }
    }
    var body: some View {
        if embedded { content }
        else { NavigationStack { content } }
    }
    private var content: some View {
        List {
            if let sportFilter {
                Section {
                    Label("\(sportFilter.sport) · Last 30 days", systemImage: activitySymbol(sportFilter.sport))
                    Text("\(sportFilter.from) – \(sportFilter.to)")
                        .font(.caption).foregroundStyle(DreeveTheme.muted)
                    if loadingSport { ProgressView("Updating activities…") }
                    if let sportError {
                        Text("Could not refresh activities. \(sportError)")
                            .font(.caption).foregroundStyle(.orange)
                        if !source.isEmpty { Text("Showing saved activities.").font(.caption).foregroundStyle(DreeveTheme.muted) }
                        Button("Retry") { Task { await reload() } }.disabled(loadingSport)
                    }
                }
            }
            if let selectedName {
                Section {
                    HStack {
                        Label(selectedName, systemImage: "shoeprints.fill")
                        Spacer()
                        Button("Clear gear filter", systemImage: "xmark.circle") { selectedGearID = nil }
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                    }
                }
            }
            if let error = gearActivityError, selectedGearID != nil {
                Section { Text(error).font(.caption).foregroundStyle(.orange) }
            }
            Section {
                if sportFilter == nil && selectedGearID == nil, let error = session.activityListError {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.activities.isEmpty ? "Could not load activities." : "Showing saved activities.")
                        Text(error).font(.caption)
                        if session.showingCachedActivities && !session.activityIndexComplete {
                            Text("Saved activity history may be incomplete.").font(.caption)
                        }
                    }.foregroundStyle(.orange)
                } else if sportFilter == nil && selectedGearID == nil && session.showingCachedActivities && !session.activityIndexComplete {
                    Text("Saved activity history may be incomplete.").font(.caption).foregroundStyle(DreeveTheme.muted)
                }
                if sportFilter == nil && selectedGearID != nil && session.showsActivityIndexStatus { ActivityIndexStatusView() }
                if visibleFeed.isEmpty && !isLoading {
                    EmptyMessage(title: session.activityListError != nil && selectedGearID == nil && sportFilter == nil ? "Activities unavailable" : "No activities", message: session.activityListError != nil && selectedGearID == nil && sportFilter == nil ? "No saved activities are available. Pull to retry." : (sportFilter != nil ? "No matching activities in this period." : (selectedGearID == nil ? "Imported workouts will appear here." : "No activities are assigned to this gear.")), symbol: "figure.run")
                        .listRowBackground(Color.clear)
                }
                ForEach(visibleFeed) { entry in
                    switch entry {
                    case .activity(let activity):
                        NavigationLink { ActivityDetailView(activityID: activity.id, cachedActivity: activity) } label: { ActivityRow(activity: activity) }
                            .listRowBackground(DreeveTheme.surface)
                    case .importing(let record):
                        NavigationLink { ImportQueueDetailView(recordID: record.id) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                ActivityRow(activity: record.feedActivity)
                                HStack {
                                    Label(record.feedStatus, systemImage: record.state == .failed ? "exclamationmark.circle" : "clock.arrow.circlepath")
                                        .foregroundStyle(record.state == .failed ? Color.orange : DreeveTheme.accent)
                                    Spacer()
                                    if let calories = record.workout.calories {
                                        Label("\(Int(calories.rounded())) kcal", systemImage: "flame")
                                            .foregroundStyle(DreeveTheme.muted)
                                    }
                                }.font(.caption.weight(.medium))
                            }.padding(.bottom, 7)
                        }.listRowBackground(DreeveTheme.surface)
                    }
                }
                if sportFilter == nil && selectedGearID == nil && session.hasMore {
                    Button { Task { await session.loadMoreActivities() } } label: {
                        HStack {
                            Spacer()
                            if session.isLoadingActivities { ProgressView() }
                            else { Text("Load more activities") }
                            Spacer()
                        }
                    }
                    .listRowBackground(DreeveTheme.surface).disabled(session.isLoadingActivities)
                }
            } header: { Text(sportFilter != nil ? "Matching activities" : (selectedGearID == nil ? "Recent activities" : "Gear activities")) }
            footer: {
                if sportFilter != nil {
                    Text("\(source.count) matching activities. Search and gear filters apply within this period. Pull to refresh.")
                } else {
                    Text(selectedGearID == nil ? "Search applies to loaded activities. Load more to see older workouts." : "\(source.count) activities assigned to this gear. Search by name, sport, location or gear.")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .dreeveBackground()
        .searchable(text: $search, prompt: "Name, sport, location or gear")
        .navigationTitle("Activities")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Gear", selection: $selectedGearID) {
                        Text("All gear").tag(String?.none)
                        ForEach(gearChoices) { gear in
                            Text(gear.name + (gear.isRetired == true ? " (Retired)" : "")).tag(Optional(gear.id))
                        }
                    }
                    if let gearError {
                        Text(gearError)
                        Button("Retry gear filters") { Task { await loadGearChoices() } }
                    }
                } label: { Image(systemName: selectedGearID == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill") }
                    .accessibilityLabel("Filter activities by gear")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(isLoading)
            }
        }
        .task(id: session.serverAddress) { await loadGearChoices() }
        .task(id: session.serverAddress + "|" + (sportFilter?.key ?? selectedGearID ?? "all") + "|" + (sportFilter != nil ? String(session.activityIndexRevision) : "")) {
            if sportFilter != nil { await reload() }
            else if selectedGearID != nil { await reload(forceFullReconcile: false) }
            else { gearActivities = []; gearActivityError = nil; if session.activities.isEmpty { await session.reloadActivities() } }
        }
        .task(id: "\(session.serverAddress)|\(selectedGearID ?? "all")|\(session.activityIndexRevision)") {
            if sportFilter == nil { await loadCachedGear() }
        }
        .refreshable { await reload() }
        .alert("Request failed", isPresented: Binding(get: { session.errorMessage != nil }, set: { if !$0 { session.errorMessage = nil } })) {
            Button("OK") { session.errorMessage = nil }
        } message: { Text(session.errorMessage ?? "Unknown error") }
    }
    private func loadCachedGear() async {
        guard let gearID = selectedGearID else { return }
        let server = session.serverAddress
        do {
            let values = try await session.indexedActivities(gearID: gearID)
            guard server == session.serverAddress, selectedGearID == gearID, !Task.isCancelled else { return }
            gearActivities = values
            cachedGearKey = server + "|" + gearID
            gearActivityError = nil
        } catch {
            if !(error is CancellationError), server == session.serverAddress { gearActivityError = error.localizedDescription }
        }
    }
    private func reload(forceFullReconcile: Bool = true) async {
        await healthSync.refreshQueuedImports(session: session)
        if let sportFilter {
            let server = session.serverAddress
            let requestID = UUID()
            sportRequestID = requestID
            loadingSport = true
            defer { if sportRequestID == requestID { loadingSport = false } }
            do {
                let values = try await session.configuredClient().activities(matching: sportFilter)
                guard server == session.serverAddress, sportRequestID == requestID, !Task.isCancelled else { return }
                sportActivities = values
                sportCacheKey = server + "|" + sportFilter.key
                sportError = nil
            } catch {
                guard server == session.serverAddress, sportRequestID == requestID,
                      !Task.isCancelled, !(error is CancellationError), (error as? URLError)?.code != .cancelled else { return }
                sportError = error.localizedDescription
            }
        } else if selectedGearID != nil {
            await loadCachedGear()
            await session.syncActivityIndex(forceFullReconcile: forceFullReconcile)
            await loadCachedGear()
        } else { await session.reloadActivities() }
    }
    private func loadGearChoices() async {
        let server = session.serverAddress
        if !gearChoicesServer.isEmpty && gearChoicesServer != server { gearChoices = [] }
        gearChoicesServer = server
        if let saved = session.cachedGear() {
            let current = gearChoices.first { $0.id == selectedGearID }
            gearChoices = saved
            if let current, !saved.contains(where: { $0.id == current.id }) { gearChoices.append(current) }
        }
        do {
            let choices = try await session.gear()
            guard server == session.serverAddress, !Task.isCancelled else { return }
            let current = gearChoices.first { $0.id == selectedGearID }
            gearChoices = choices
            if let current, !choices.contains(where: { $0.id == current.id }) { gearChoices.append(current) }
            gearError = nil
        } catch {
            if server == session.serverAddress, !Task.isCancelled { gearError = gearChoices.isEmpty ? "Gear filters unavailable. Try again." : "Showing saved gear filters. Pull to refresh when connected." }
        }
    }
}

struct ActivityRow: View {
    let activity: DreeveActivity
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: activitySymbol(activity.sportType))
                .font(.title3).foregroundStyle(DreeveTheme.accent)
                .frame(width: 44, height: 44)
                .background(DreeveTheme.elevated, in: RoundedRectangle(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 5) {
                Text(activity.name).font(.headline).lineLimit(1)
                Text("\(activity.sportType) · \(activity.startDate?.formatted(date: .abbreviated, time: .omitted) ?? activity.startDateLocal)")
                    .font(.caption).foregroundStyle(DreeveTheme.muted)
                HStack(spacing: 12) {
                    Label("\(activity.distanceKilometers.oneDecimal) km", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                    Label("\(Int(activity.movingMinutes)) min", systemImage: "clock")
                }.font(.caption.weight(.medium))
            }
            Spacer(minLength: 0)
        }.padding(.vertical, 7)
    }
}


struct ActivityIndexStatusView: View {
    @EnvironmentObject private var session: DreeveSession
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if session.isSyncingActivityIndex { ProgressView("Updating activities…") }
            if !session.activityIndexComplete {
                Text("Activity history is still downloading. Saved results may be incomplete.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = session.activitySyncError {
                Text("Could not update activities. Showing saved data. \(error)")
                    .font(.caption).foregroundStyle(.orange)
            } else if let last = session.lastActivitySync, Date.now.timeIntervalSince(last) > 300 {
                Text("Showing saved activities. Pull to refresh.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Local-only, read-only details until a confirmed server activity exists.
struct ImportQueueDetailView: View {
    @EnvironmentObject private var session: DreeveSession
    @EnvironmentObject private var healthSync: HealthSyncStore
    let recordID: String
    private var record: HealthSyncRecord? {
        healthSync.records.first { $0.id == recordID && $0.server == session.serverAddress }
    }
    var body: some View {
        Group {
            if let record, let id = record.activityID, [.imported, .skipped].contains(record.state),
               !record.awaitingFeedHandoff || (session.activities + session.insightsActivities).contains(where: { $0.id == id }) {
                ActivityDetailView(activityID: id)
            } else if let record {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text(record.workout.sportType + " · Apple Health").font(.largeTitle.bold())
                        Text(record.workout.start.formatted(date: .complete, time: .shortened))
                            .font(.subheadline).foregroundStyle(DreeveTheme.muted)
                        SurfaceCard {
                            VStack(alignment: .leading, spacing: 8) {
                                Label(record.feedStatus, systemImage: record.state == .failed ? "exclamationmark.circle" : "clock.arrow.circlepath")
                                    .font(.headline).foregroundStyle(DreeveTheme.accent)
                                Text(statusMessage(record)).font(.subheadline)
                                if [.uncertain, .failed].contains(record.state), let message = record.message {
                                    Text(message).font(.caption).foregroundStyle(DreeveTheme.muted)
                                }
                            }
                        }
                        RouteMapView(activity: record.feedActivity, localRoute: record.preview?.route ?? [])
                        if record.preview?.route.isEmpty != false {
                            Text("No saved route preview. Indoor workouts and workouts imported without route access may have no map.")
                                .font(.caption).foregroundStyle(DreeveTheme.muted)
                        }
                        LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 12) {
                            if let distance = record.workout.distance {
                                MetricView(title: "Distance", value: "\((distance / 1000).oneDecimal) km", symbol: "point.topleft.down.curvedto.point.bottomright.up")
                            }
                            MetricView(title: "Moving", value: "\(Int(record.workout.duration / 60)) min", symbol: "clock")
                            if let calories = record.workout.calories {
                                MetricView(title: "Calories", value: "\(Int(calories.rounded())) kcal", symbol: "flame")
                            }
                        }
                        Text("Recorded by " + record.workout.source).font(.caption).foregroundStyle(DreeveTheme.muted)
                        HStack {
                            Button("Edit activity", systemImage: "pencil") {}.disabled(true)
                            Button("Add photo", systemImage: "photo.badge.plus") {}.disabled(true)
                        }.buttonStyle(.bordered)
                        Text("Editing, gear and photos become available when Dreeve finishes importing. Queued workouts do not count toward goals yet.")
                            .font(.caption).foregroundStyle(DreeveTheme.muted)
                    }.padding(20)
                }
                .dreeveBackground()
                .navigationTitle("Import queue")
                .navigationBarTitleDisplayMode(.inline)
                .refreshable { await healthSync.refreshQueuedImports(session: session) }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Check import status", systemImage: "arrow.clockwise") {
                            Task { await healthSync.refreshQueuedImports(session: session) }
                        }.disabled(healthSync.isBusy)
                    }
                }
            } else {
                EmptyMessage(title: "Import unavailable", message: "Open Health Sync to check this workout.", symbol: "clock.arrow.circlepath")
            }
        }
    }
    private func statusMessage(_ record: HealthSyncRecord) -> String {
        switch record.state {
        case .queued: return "Dreeve accepted this workout and is processing it. These are the saved Apple Health details."
        case .uncertain: return "The upload has not been confirmed. Its status will be checked without sending another copy."
        case .failed: return "Dreeve could not import this workout. Review it in Health Sync before retrying."
        case .imported, .skipped: return "Dreeve confirmed the import. Showing saved details until the completed activity is available in your feed."
        default: return "Dreeve is finishing this import. These are the saved Apple Health details."
        }
    }
}
