import SwiftUI

struct HealthSyncView: View {
    @EnvironmentObject private var session: DreeveSession
    @EnvironmentObject private var sync: HealthSyncStore
    @State private var from = Calendar.current.date(byAdding: .day, value: -30, to: .now) ?? .now
    @State private var includeRoutes = true
    @State private var includeHeartRate = true
    @State private var selected: Set<UUID> = []
    @State private var confirmSync = false
    @State private var retryWorkout: HealthWorkoutSummary?
    @State private var overrideWorkout: HealthWorkoutSummary?
    @State private var proposedLink: ProposedHealthLink?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    SurfaceCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("Apple Health → Dreeve", systemImage: "heart.fill").font(.title2.bold())
                            Text("Choose workouts to send as FIT files. Apple Health is read only; Dreeve edits and deletions stay in Dreeve.")
                                .font(.subheadline).foregroundStyle(DreeveTheme.muted)
                            DatePicker("Workouts since", selection: $from, in: ...Date.now, displayedComponents: .date)
                            Toggle("Include workout routes", isOn: $includeRoutes)
                            Toggle("Include heart rate", isOn: $includeHeartRate)
                            Button("Load Apple Health workouts", systemImage: "heart.text.clipboard") {
                                selected = []
                                Task { await sync.load(session: session, from: from, routes: includeRoutes, heartRate: includeHeartRate) }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(sync.isBusy || sync.storageError != nil)
                            if !session.canUpload {
                                Text("Your Dreeve instance must use file import mode to receive workouts.")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                            if let error = sync.storageError { Text(error).font(.caption).foregroundStyle(.red) }
                        }
                    }
                    if sync.isBusy { ProgressView(sync.progress).frame(maxWidth: .infinity) }
                    HStack {
                        Text("Workouts").font(.title3.bold())
                        Spacer()
                        Button("Refresh status", systemImage: "arrow.clockwise") {
                            Task { await sync.refresh(session: session) }
                        }.disabled(sync.isBusy)
                    }
                    if sync.isReady && sync.workouts.isEmpty {
                        Text("No readable workouts in this period. Check Health permissions and your selected date. Apple does not tell apps whether read access was denied.")
                            .foregroundStyle(DreeveTheme.muted)
                    }
                    ForEach(sync.visibleWorkouts(server: session.serverAddress)) { workout in
                        workoutCard(workout)
                    }
                    if !sync.visibleWorkouts(server: session.serverAddress).isEmpty {
                        Text("Uploads are queued for Dreeve’s next import run. Refresh status to finish linking imported activities.")
                            .font(.caption).foregroundStyle(DreeveTheme.muted)
                    }
                }
                .padding(18)
                .disabled(sync.isBusy)
            }
            .dreeveBackground()
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !sync.visibleWorkouts(server: session.serverAddress).isEmpty {
                    Button { confirmSync = true } label: {
                        Label("Sync selected (\(selected.count))", systemImage: "arrow.triangle.2.circlepath")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(sync.isBusy || !sync.isReady || !session.canUpload || selected.isEmpty || sync.storageError != nil)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(DreeveTheme.surface)
                    .overlay(alignment: .top) { Divider() }
                }
            }
            .navigationTitle("Health sync")
            .task { if sync.isReady { await sync.refresh(session: session) } }
            .onChange(of: session.serverAddress) { _, _ in selected = [] }
            .confirmationDialog("Sync \(selected.count) workouts?", isPresented: $confirmSync, titleVisibility: .visible) {
                Button("Send to Dreeve") {
                    let ids = selected
                    selected = []
                    Task { await sync.sync(ids: ids, session: session, routes: includeRoutes, heartRate: includeHeartRate) }
                }
            } message: {
                Text("Selected workout summaries\(includeRoutes ? ", routes" : "")\(includeHeartRate ? ", and heart rate" : "") will be sent to \(session.serverAddress).")
            }
            .alert("Health sync", isPresented: Binding(get: { sync.errorMessage != nil }, set: { if !$0 { sync.errorMessage = nil } })) {
                Button("OK") { sync.errorMessage = nil }
            } message: { Text(sync.errorMessage ?? "Unknown error") }
            .confirmationDialog("Retry an unconfirmed upload?", isPresented: Binding(get: { retryWorkout != nil }, set: { if !$0 { retryWorkout = nil } }), titleVisibility: .visible) {
                Button("Allow retry") {
                    if let workout = retryWorkout { sync.authorizeRetry(workout, server: session.serverAddress) }
                    retryWorkout = nil
                }
            } message: { Text("Refresh status first. If Dreeve still has no record, you may retry, but the earlier upload could arrive later and create a duplicate. Import history will be checked again before sending.") }
            .confirmationDialog("Import a separate workout?", isPresented: Binding(get: { overrideWorkout != nil }, set: { if !$0 { overrideWorkout = nil } }), titleVisibility: .visible) {
                Button("These are different workouts — allow upload") {
                    if let workout = overrideWorkout {
                        sync.allowNewUpload(workout.id)
                        selected.insert(workout.id)
                    }
                    overrideWorkout = nil
                }
            } message: { Text("Only continue if the suggested Dreeve activities are different. Uploading the same workout may create a duplicate.") }
            .sheet(item: $proposedLink) { link in
                NavigationStack {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Confirm this is the same workout").font(.title2.bold())
                        Text("Apple Health: \(link.workout.sportType), \(link.workout.start.formatted()), \(Int(link.workout.duration / 60)) min")
                        Text("Dreeve: \(link.activity.name), \(link.activity.startDateLocal), \(Int(link.activity.movingMinutes)) min, \(link.activity.distanceKilometers.oneDecimal) km")
                        Text("This creates a local association and avoids uploading a second copy.").foregroundStyle(DreeveTheme.muted)
                        Button("Link this activity") {
                            sync.link(link.workout, activity: link.activity, server: session.serverAddress)
                            proposedLink = nil
                            selected.remove(link.workout.id)
                        }.buttonStyle(.borderedProminent)
                        Spacer()
                    }
                    .padding(20)
                    .navigationTitle("Link existing activity")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { proposedLink = nil } } }
                }
            }
        }
        .tint(DreeveTheme.accent)
    }

    @ViewBuilder private func workoutCard(_ workout: HealthWorkoutSummary) -> some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: activitySymbol(workout.sportType)).foregroundStyle(DreeveTheme.accent)
                    Text(workout.sportType).font(.headline)
                    Spacer()
                    if sync.canSelect(workout, server: session.serverAddress) {
                        Button {
                            if selected.contains(workout.id) { selected.remove(workout.id) }
                            else { selected.insert(workout.id) }
                        } label: {
                            Image(systemName: selected.contains(workout.id) ? "checkmark.circle.fill" : "circle")
                                .font(.title2)
                        }
                        .accessibilityLabel(selected.contains(workout.id) ? "Deselect workout" : "Select workout")
                    }
                }
                Text(workout.start.formatted(date: .abbreviated, time: .shortened)).font(.subheadline)
                Text("\(Int(workout.duration / 60)) min\(workout.distance.map { " · \(($0 / 1000).oneDecimal) km" } ?? "") · \(workout.source)")
                    .font(.caption).foregroundStyle(DreeveTheme.muted)
                if let record = sync.record(workout.id, server: session.serverAddress) {
                    Text(record.state.label).font(.subheadline.weight(.semibold))
                    if let message = record.message { Text(message).font(.caption).foregroundStyle(DreeveTheme.muted) }
                    if record.state == .uncertain {
                        Button("Review retry") { retryWorkout = workout }
                    }
                    if let activityID = record.activityID {
                        NavigationLink("View Dreeve activity") { ActivityDetailView(activityID: activityID) }
                    }
                }
                if let matches = sync.candidates[workout.id], !matches.isEmpty,
                   sync.record(workout.id, server: session.serverAddress)?.activityID == nil,
                   sync.record(workout.id, server: session.serverAddress)?.state != .queued,
                   sync.record(workout.id, server: session.serverAddress)?.state != .uncertain {
                    Text("Possible existing activity — review before syncing").font(.caption).foregroundStyle(.orange)
                    ForEach(matches) { activity in
                        Button("Review \(activity.name)") { proposedLink = ProposedHealthLink(workout: workout, activity: activity) }
                    }
                    if sync.record(workout.id, server: session.serverAddress)?.state != .skipped {
                        Button("None of these match") { overrideWorkout = workout }
                    }
                    Text("New upload is paused until you review these possible matches.")
                        .font(.caption).foregroundStyle(DreeveTheme.muted)
                }
            }
        }
    }
}

private struct ProposedHealthLink: Identifiable {
    let workout: HealthWorkoutSummary
    let activity: DreeveActivity
    var id: UUID { workout.id }
}
