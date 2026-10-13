import SwiftUI

struct ActivitiesView: View {
    @EnvironmentObject private var session: DreeveSession
    @StateObject private var filtered = GearActivitiesStore()
    @State private var search = ""
    @State private var selectedGearID: String?
    @State private var gearChoices: [DreeveGear]
    @State private var gearError: String?
    private let embedded: Bool

    init(gear: DreeveGear? = nil, embedded: Bool = false) {
        self.embedded = embedded
        _selectedGearID = State(initialValue: gear?.id)
        _gearChoices = State(initialValue: gear.map { [$0] } ?? [])
    }
    private var selectedName: String? {
        guard let selectedGearID else { return nil }
        return gearChoices.first { $0.id == selectedGearID }?.name ?? selectedGearID
    }
    private var source: [DreeveActivity] { selectedGearID == nil ? session.activities : filtered.activities }
    private var isLoading: Bool { selectedGearID == nil ? session.isLoadingActivities : filtered.isLoading }
    private var visibleActivities: [DreeveActivity] {
        guard !search.isEmpty else { return source }
        return source.filter { activity in
            activity.name.localizedCaseInsensitiveContains(search) ||
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
            if let error = filtered.error, selectedGearID != nil {
                Section { Text(error).font(.caption).foregroundStyle(.orange) }
            }
            Section {
                if isLoading && selectedGearID != nil { ProgressView("Finding activities for this gear…") }
                if source.isEmpty && !isLoading {
                    EmptyMessage(title: "No activities", message: selectedGearID == nil ? "Imported workouts will appear here." : "No activities are assigned to this gear.", symbol: "figure.run")
                        .listRowBackground(Color.clear)
                }
                ForEach(visibleActivities) { activity in
                    NavigationLink { ActivityDetailView(activityID: activity.id) } label: { ActivityRow(activity: activity) }
                        .listRowBackground(DreeveTheme.surface)
                }
                if selectedGearID == nil && session.hasMore {
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
            } header: { Text(selectedGearID == nil ? "Recent activities" : "Gear activities") }
            footer: {
                Text(selectedGearID == nil ? "Search applies to loaded activities. Load more to see older workouts." : "\(source.count) activities assigned to this gear. Search by name, sport, location or gear.")
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
        .task(id: session.serverAddress + "|" + (selectedGearID ?? "all")) {
            if selectedGearID != nil { await reload() }
            else { filtered.reset(); if session.activities.isEmpty { await session.reloadActivities() } }
        }
        .refreshable { await reload() }
        .alert("Request failed", isPresented: Binding(get: { session.errorMessage != nil }, set: { if !$0 { session.errorMessage = nil } })) {
            Button("OK") { session.errorMessage = nil }
        } message: { Text(session.errorMessage ?? "Unknown error") }
    }
    private func reload() async {
        if let selectedGearID {
            do { await filtered.load(client: try session.configuredClient(), gearID: selectedGearID) }
            catch { session.errorMessage = error.localizedDescription }
        } else { await session.reloadActivities() }
    }
    private func loadGearChoices() async {
        let server = session.serverAddress
        do {
            let choices = try await session.gear()
            guard server == session.serverAddress, !Task.isCancelled else { return }
            let current = gearChoices.first { $0.id == selectedGearID }
            gearChoices = choices
            if let current, !choices.contains(where: { $0.id == current.id }) { gearChoices.append(current) }
            gearError = nil
        } catch {
            if server == session.serverAddress, !Task.isCancelled { gearError = "Gear filters unavailable. Try again." }
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
