import SwiftUI
import UIKit

@MainActor
final class HealthImportDiscovery: ObservableObject {
    @Published private(set) var entries: [HealthDiscoveryEntry] = []
    @Published private(set) var isChecking = false
    @Published private(set) var message: String?
    @Published var showingPrompt = false
    @Published private(set) var scope = ""
    private let reader = AppleHealthReader()
    private var journal: HealthDiscoveryJournal?
    private var shown = Set<UUID>()
    private var lastDiscoveredIDs = Set<UUID>()
    private var promptIDs = Set<UUID>()
    private var serverAddress = ""
    private var running = false
    private var rescanRequested = false
    private var generation = UUID()

    var visibleEntries: [HealthDiscoveryEntry] {
        entries.filter { journal?.decision(scope: scope, id: $0.id)?.action != .dismissed }
    }
    var promptEntries: [HealthDiscoveryEntry] { visibleEntries.filter { promptIDs.contains($0.id) } }
    var approvedCount: Int {
        visibleEntries.filter { journal?.decision(scope: scope, id: $0.id)?.action == .approved }.count
    }
    func isApproved(_ id: UUID) -> Bool { journal?.decision(scope: scope, id: id)?.action == .approved }

    init() {
        do {
            let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            journal = try HealthDiscoveryJournal(url: root.appendingPathComponent("HealthSync/discovery.json"))
        } catch { message = "Workout discovery storage is unavailable. \(error.localizedDescription)" }
    }

    func reset(server: String) {
        generation = UUID()
        reader.stopObserving()
        showingPrompt = false
        entries = []
        lastDiscoveredIDs = []
        shown = []
        promptIDs = []
        serverAddress = server
        scope = (try? DreeveAPIClient.validatedURL(server)).map(GoalEngine.instanceID) ?? ""
    }

    func start(session: DreeveSession, sync: HealthSyncStore, routes: Bool, heartRate: Bool) async {
        if serverAddress != session.serverAddress { reset(server: session.serverAddress) }
        shown = []
        let token = generation
        do {
            if !UserDefaults.standard.bool(forKey: "health.authorizationRequested") {
                try await reader.authorize(routes: routes, heartRate: heartRate)
            }
            try Task.checkCancellation()
            guard token == generation, UIApplication.shared.applicationState == .active else { return }
            reader.startObserving { [weak self, weak session, weak sync] in
                guard let self, let session, let sync else { return }
                Task { await self.check(session: session, sync: sync) }
            }
            await check(session: session, sync: sync)
        } catch { if token == generation, !Task.isCancelled { message = error.localizedDescription } }
    }

    func stop() {
        generation = UUID()
        reader.stopObserving()
        showingPrompt = false
    }

    func check(session: DreeveSession, sync: HealthSyncStore) async {
        guard !scope.isEmpty, session.isConfigured, UIApplication.shared.applicationState == .active,
              UserDefaults.standard.object(forKey: "health.discovery.enabled") as? Bool != false, let journal else { return }
        if running { rescanRequested = true; return }
        running = true
        isChecking = true
        let token = generation
        let server = session.serverAddress
        let instance = scope
        defer {
            running = false
            isChecking = false
            if rescanRequested {
                rescanRequested = false
                Task { await self.check(session: session, sync: sync) }
            }
        }
        do {
            let now = Date.now
            let workouts = try await reader.load(from: HealthDiscoveryPolicy.start(now: now), through: now)
            try Task.checkCancellation()
            guard token == generation, server == serverAddress else { return }
            // Never describe an unverified workout as definitely not imported.
            let unknown = workouts.filter { workout in
                HealthDiscoveryPolicy.recent(workout, now: now) &&
                !HealthDiscoveryPolicy.suppress(record: sync.record(workout.id, server: server))
            }
            let unknownIDs = Set(unknown.map(\.id))
            entries = entries.filter { unknownIDs.contains($0.id) } + unknown.filter {
                !lastDiscoveredIDs.contains($0.id)
            }.map { HealthDiscoveryEntry(workout: $0, status: .unverified) }
            lastDiscoveredIDs = Set(workouts.map(\.id))
            do {
                let client = try session.configuredClient()
                let verified = try await HealthDiscoveryVerifier.entries(workouts: workouts, records: sync.records,
                                                                         server: server, client: client, now: now)
                guard token == generation, server == session.serverAddress, !Task.isCancelled else { return }
                entries = verified.filter { !HealthDiscoveryPolicy.suppress(record: sync.record($0.id, server: server)) }
                message = nil
            } catch {
                guard token == generation, !Task.isCancelled else { return }
                entries = unknown.map { HealthDiscoveryEntry(workout: $0, status: .unverified) }
                message = "Dreeve status is unverified. Saved approvals will be checked before any upload. \(error.localizedDescription)"
                return
            }
            // An offline approval only authorizes this workout and these export options.
            let approved = entries.filter { $0.status == .ready && journal.decision(scope: instance, id: $0.id)?.action == .approved }
            if !approved.isEmpty, !sync.isBusy {
                let grouped = Dictionary(grouping: approved) { entry in
                    let decision = journal.decision(scope: instance, id: entry.id)!
                    return "\(decision.routes)|\(decision.heartRate)"
                }
                for group in grouped.values {
                    guard token == generation, server == session.serverAddress, !Task.isCancelled,
                          UIApplication.shared.applicationState == .active else { return }
                    let decision = journal.decision(scope: instance, id: group[0].id)!
                    await sync.load(session: session, from: HealthDiscoveryPolicy.start(), routes: decision.routes, heartRate: decision.heartRate)
                    guard token == generation, server == session.serverAddress, !Task.isCancelled,
                          UIApplication.shared.applicationState == .active,
                          UserDefaults.standard.object(forKey: "health.discovery.enabled") as? Bool != false else { return }
                    await sync.sync(ids: Set(group.map(\.id)), session: session, routes: decision.routes, heartRate: decision.heartRate) {
                        self.generation == token && UIApplication.shared.applicationState == .active &&
                        UserDefaults.standard.object(forKey: "health.discovery.enabled") as? Bool != false
                    }
                    guard token == generation, server == session.serverAddress else { return }
                    for entry in group where sync.record(entry.id, server: server) != nil {
                        try journal.remove(scope: instance, id: entry.id)
                    }
                }
                entries.removeAll { sync.record($0.id, server: server) != nil }
                if let error = sync.errorMessage { message = error }
            }
        } catch {
            if token == generation, !Task.isCancelled { message = error.localizedDescription }
        }
    }

    func considerPrompt() {
        guard !showingPrompt, !isChecking, UIApplication.shared.applicationState == .active,
              UserDefaults.standard.object(forKey: "health.discovery.enabled") as? Bool != false else { return }
        // A root presentation must wait for editors, share sheets and photo viewers.
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        guard let window = windows.first(where: \.isKeyWindow), window.rootViewController?.presentedViewController == nil else { return }
        let ready = visibleEntries.filter { $0.status == .ready && !shown.contains($0.id) &&
            HealthDiscoveryPolicy.mayPrompt(journal?.decision(scope: scope, id: $0.id)) }
        guard !ready.isEmpty else { return }
        promptIDs = Set(ready.map(\.id))
        shown.formUnion(promptIDs)
        showingPrompt = true
    }

    func noteRecords(_ records: [HealthSyncRecord], server: String) {
        guard server == serverAddress else { return }
        let known = Set(records.filter { $0.server == server }.map { $0.workout.id })
        entries.removeAll { known.contains($0.id) }
    }

    func review() {
        promptIDs = Set(visibleEntries.map(\.id))
        shown.formUnion(promptIDs)
        showingPrompt = !promptIDs.isEmpty
    }

    func dismissedPrompt() {
        guard let journal else { return }
        do {
            let values = promptEntries.filter { journal.decision(scope: scope, id: $0.id) == nil }.map {
                HealthDiscoveryDecision(scope: scope, workoutID: $0.id, action: .later, date: .now, routes: true, heartRate: true)
            }
            if !values.isEmpty { try journal.set(values) }
        } catch { message = "Could not save reminder preference. \(error.localizedDescription)" }
    }

    func cancelApprovals() {
        guard let journal, !isChecking else { return }
        do {
            for entry in promptEntries where isApproved(entry.id) {
                try journal.remove(scope: scope, id: entry.id)
            }
            objectWillChange.send()
        } catch { message = "Could not cancel approval. \(error.localizedDescription)" }
    }

    func decide(_ action: HealthDiscoveryAction, ids: Set<UUID>, routes: Bool, heartRate: Bool) {
        guard let journal else { return }
        do {
            let valid = ids.intersection(Set(promptEntries.filter { $0.status != .review }.map(\.id)))
            try journal.set(valid.map { HealthDiscoveryDecision(scope: scope, workoutID: $0, action: action,
                date: .now, routes: routes, heartRate: heartRate) })
            showingPrompt = false
            objectWillChange.send()
        } catch { message = "Could not save your decision. \(error.localizedDescription)" }
    }
}

struct HealthImportPrompt: View {
    @EnvironmentObject private var discovery: HealthImportDiscovery
    @EnvironmentObject private var session: DreeveSession
    @EnvironmentObject private var sync: HealthSyncStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("health.includeRoutes") private var routes = true
    @AppStorage("health.includeHeartRate") private var heartRate = true
    @State private var selected = Set<UUID>()
    let openHealthSync: () -> Void

    private var chosen: [HealthDiscoveryEntry] { discovery.promptEntries.filter { selected.contains($0.id) } }
    private var waiting: Bool { chosen.contains { $0.status == .unverified } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Image(systemName: "heart.text.clipboard.fill")
                        .font(.system(size: 38)).foregroundStyle(DreeveTheme.accent)
                        .padding(16).background(DreeveTheme.elevated, in: RoundedRectangle(cornerRadius: 23))
                    Text("Your effort.\nYour choice.")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("Recent Apple Health workouts from the last month. You decide what to import.")
                        .foregroundStyle(DreeveTheme.muted)
                    ForEach(discovery.promptEntries) { entry in
                        Button {
                            if selected.contains(entry.id) { selected.remove(entry.id) }
                            else { selected.insert(entry.id) }
                        } label: {
                            workoutCard(entry)
                        }
                        .buttonStyle(.plain).disabled(entry.status == .review)
                        .accessibilityLabel("\(entry.workout.sportType), \(status(entry)), \(selected.contains(entry.id) ? "selected" : "not selected")")
                    }
                    if discovery.promptEntries.contains(where: { $0.status == .review }) {
                        Button("Review possible matches in Health Sync", action: openHealthSync)
                            .tint(DreeveTheme.accent)
                    }
                    if discovery.promptEntries.contains(where: { discovery.isApproved($0.id) }) {
                        Button("Cancel pending approvals") { discovery.cancelApprovals() }
                            .disabled(discovery.isChecking || sync.isBusy)
                    }
                    SurfaceCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle("Include routes", isOn: $routes).tint(DreeveTheme.accent)
                            Toggle("Include heart rate", isOn: $heartRate).tint(DreeveTheme.accent)
                            Text("Available cadence and power are included. Only approved workouts are sent to your configured Dreeve server.")
                                .font(.caption).foregroundStyle(DreeveTheme.muted)
                        }
                    }
                    if let message = discovery.message {
                        Text(message).font(.caption).foregroundStyle(DreeveTheme.muted)
                    }
                    if waiting {
                        Text("Approval is saved on this device. When the app is open and Dreeve is reachable, we’ll check for duplicates before uploading.")
                            .font(.subheadline).foregroundStyle(DreeveTheme.muted)
                    }
                }.padding(22)
            }
            .dreeveBackground()
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 12) {
                    Button {
                        discovery.decide(.approved, ids: selected, routes: routes, heartRate: heartRate)
                        Task { await discovery.check(session: session, sync: sync) }
                    } label: {
                        Label(waiting ? "Import when connected (\(selected.count))" : "Import selected (\(selected.count))",
                              systemImage: waiting ? "clock.arrow.circlepath" : "arrow.up.heart.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .tint(DreeveTheme.accent).foregroundStyle(DreeveTheme.background)
                    .disabled(selected.isEmpty || sync.isBusy || discovery.isChecking)
                    HStack {
                        Button("Later") { discovery.decide(.later, ids: selected, routes: routes, heartRate: heartRate) }
                        Spacer()
                        Button("Don’t ask for selected") { discovery.decide(.dismissed, ids: selected, routes: routes, heartRate: heartRate) }
                    }
                    .font(.subheadline).tint(DreeveTheme.muted).disabled(selected.isEmpty)
                }.padding(18).background(DreeveTheme.surface)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(30)
        .onAppear {
            selected = Set(discovery.promptEntries.filter { $0.status != .review && !discovery.isApproved($0.id) }.map(\.id))
        }
    }

    private func status(_ entry: HealthDiscoveryEntry) -> String {
        if discovery.isApproved(entry.id) { return entry.status == .review ? "Approved · possible duplicate needs review" : "Approved · waiting for verification" }
        switch entry.status {
        case .ready: return "Ready to import"
        case .unverified: return "Import status not verified"
        case .review: return "Possible existing activity · review first"
        }
    }
    private func workoutCard(_ entry: HealthDiscoveryEntry) -> some View {
        SurfaceCard {
            HStack(spacing: 14) {
                Image(systemName: activitySymbol(entry.workout.sportType))
                    .font(.title2).foregroundStyle(DreeveTheme.accent)
                VStack(alignment: .leading, spacing: 6) {
                    Text(entry.workout.sportType).font(.headline)
                    Text(entry.workout.start.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(DreeveTheme.muted)
                    Text("\(((entry.workout.distance ?? 0) / 1000).oneDecimal) km · \(Int(entry.workout.duration / 60)) min")
                        .font(.subheadline)
                    Text(status(entry)).font(.caption.weight(.medium))
                        .foregroundStyle(entry.status == .ready ? DreeveTheme.accent : DreeveTheme.muted)
                }
                Spacer(minLength: 0)
                Image(systemName: entry.status == .review ? "exclamationmark.circle" :
                    (selected.contains(entry.id) ? "checkmark.circle.fill" : "circle"))
                    .foregroundStyle(selected.contains(entry.id) ? DreeveTheme.accent : DreeveTheme.muted)
            }
        }
    }
}
