import SwiftUI

struct ActivitiesView: View {
    @EnvironmentObject private var session: DreeveSession
    @State private var search = ""

    private var visibleActivities: [DreeveActivity] {
        guard !search.isEmpty else { return session.activities }
        return session.activities.filter {
            $0.name.localizedCaseInsensitiveContains(search) ||
            $0.sportType.localizedCaseInsensitiveContains(search) ||
            $0.locationLabel.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if session.activities.isEmpty && !session.isLoadingActivities {
                        EmptyMessage(title: "No activities", message: "Imported workouts will appear here.", symbol: "figure.run")
                            .listRowBackground(Color.clear)
                    }
                    ForEach(visibleActivities) { activity in
                        NavigationLink(value: activity.id) {
                            ActivityRow(activity: activity)
                        }
                        .listRowBackground(DreeveTheme.surface)
                    }
                    if session.hasMore {
                        Button {
                            Task { await session.loadMoreActivities() }
                        } label: {
                            HStack {
                                Spacer()
                                if session.isLoadingActivities { ProgressView() }
                                else { Text("Load more activities") }
                                Spacer()
                            }
                        }
                        .listRowBackground(DreeveTheme.surface)
                        .disabled(session.isLoadingActivities)
                    }
                } header: {
                    Text("Recent activities")
                } footer: {
                    Text("Search applies to loaded activities. Load more to see older workouts.")
                }
            }
            .scrollContentBackground(.hidden)
            .dreeveBackground()
            .searchable(text: $search, prompt: "Name, sport or location")
            .navigationTitle("Activities")
            .navigationDestination(for: String.self) { id in
                ActivityDetailView(activityID: id)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await session.reloadActivities() } } label: { Image(systemName: "arrow.clockwise") }
                }
            }
            .task { if session.activities.isEmpty { await session.reloadActivities() } }
            .refreshable { await session.reloadActivities() }
            .alert("Request failed", isPresented: Binding(get: { session.errorMessage != nil }, set: { if !$0 { session.errorMessage = nil } })) {
                Button("OK") { session.errorMessage = nil }
            } message: { Text(session.errorMessage ?? "Unknown error") }
        }
    }
}

struct ActivityRow: View {
    let activity: DreeveActivity

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: activitySymbol(activity.sportType))
                .font(.title3)
                .foregroundStyle(DreeveTheme.accent)
                .frame(width: 44, height: 44)
                .background(DreeveTheme.elevated, in: RoundedRectangle(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 5) {
                Text(activity.name).font(.headline).lineLimit(1)
                Text("\(activity.sportType) · \(activity.startDate?.formatted(date: .abbreviated, time: .omitted) ?? activity.startDateLocal)")
                    .font(.caption)
                    .foregroundStyle(DreeveTheme.muted)
                HStack(spacing: 12) {
                    Label("\(activity.distanceKilometers.oneDecimal) km", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                    Label("\(Int(activity.movingMinutes)) min", systemImage: "clock")
                }
                .font(.caption.weight(.medium))
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
    }
}
