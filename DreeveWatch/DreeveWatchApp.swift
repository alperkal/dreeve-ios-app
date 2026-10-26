import SwiftUI
import WidgetKit
import WatchConnectivity
import WatchKit

@MainActor
final class WatchGoalStore: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = WatchGoalStore()
    @Published private(set) var snapshot: GoalWidgetSnapshot
    @Published private(set) var unavailable: Bool
    @Published private(set) var message: String?
    private let storage = GoalWatchStorage()
    private var backgroundTasks: [WKRefreshBackgroundTask] = []
    private var activationCompleted = false
    private var sessionObservations: [NSKeyValueObservation] = []
    override init() {
        let result = GoalWatchStorage().readResult()
        snapshot = result.snapshot ?? .empty
        unavailable = result.snapshot == nil
        super.init()
        if WCSession.isSupported() {
            let session = WCSession.default
            session.delegate = self
            sessionObservations = [session.observe(\.activationState) { [weak self] _, _ in
                DispatchQueue.main.async { self?.completeBackgroundTasks() }
            }, session.observe(\.hasContentPending) { [weak self] _, _ in
                DispatchQueue.main.async { self?.completeBackgroundTasks() }
            }]
            session.activate()
        }
    }
    func reloadSaved() {
        if let saved = storage.readResult().snapshot { snapshot = saved; unavailable = false }
    }
    func requestLatest() {
        reloadSaved()
        let session = WCSession.default
        guard session.activationState == .activated else { message = "Connecting to iPhone…"; return }
        if let data = session.receivedApplicationContext["goalEnvelope"] as? Data { receive(data) }
        guard session.isReachable else { message = "iPhone unavailable. Showing saved progress."; return }
        message = "Checking iPhone…"
        session.sendMessage(["requestGoals": true], replyHandler: { reply in
            Task { @MainActor in self.receive(reply) }
        }, errorHandler: { _ in
            Task { @MainActor in self.message = "iPhone unavailable. Showing saved progress." }
        })
    }
    private func receive(_ payload: [String: Any]) {
        if let data = payload["goalEnvelope"] as? Data { receive(data) }
        else if payload["goalFilePending"] != nil {
            let cached = storage.envelope()
            if cached?.senderID == payload["senderID"] as? String,
               let revision = payload["revision"] as? Int, revision <= (cached?.revision ?? 0) {
                reloadSaved(); message = nil
            } else { message = "Goals are transferring from iPhone…" }
        } else { message = "Open Dreeve on iPhone to share your goals." }
        completeBackgroundTasks()
    }
    private func receive(_ data: Data) {
        do {
            let accepted = try storage.accept(data)
            // Context may arrive before its priority notification. The latter must
            // still request a timeline reload, even when its revision is a duplicate.
            if accepted || storage.envelope()?.matches(payload: ["goalEnvelope": data]) == true {
                WidgetCenter.shared.reloadTimelines(ofKind: "DreeveWatchGoal")
                WidgetCenter.shared.invalidateConfigurationRecommendations()
            }
            reloadSaved()
            message = nil
        } catch { message = "Couldn’t update saved goals. Open Dreeve on iPhone to retry." }
    }
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async {
            self.activationCompleted = true
            self.receive(WCSession.default.receivedApplicationContext)
        }
    }
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        DispatchQueue.main.async { self.receive(applicationContext) }
    }
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        DispatchQueue.main.async { self.receive(userInfo) }
    }
    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        // WCSession deletes the supplied file when this callback returns.
        guard let size = try? file.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= GoalWatchEnvelope.maximumBytes, let data = try? Data(contentsOf: file.fileURL) else { return }
        DispatchQueue.main.async { self.receive(data); self.completeBackgroundTasks() }
    }
    func handleBackground(_ tasks: Set<WKRefreshBackgroundTask>) {
        for task in tasks {
            if task is WKWatchConnectivityRefreshBackgroundTask { backgroundTasks.append(task) }
            else { task.setTaskCompletedWithSnapshot(false) }
        }
        completeBackgroundTasks()
    }
    private func completeBackgroundTasks() {
        let session = WCSession.default
        guard activationCompleted, session.activationState == .activated, !session.hasContentPending else { return }
        let finished = backgroundTasks; backgroundTasks = []
        for task in finished { task.setTaskCompletedWithSnapshot(false) }
    }
}
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        Task { @MainActor in WatchGoalStore.shared.handleBackground(backgroundTasks) }
    }
}
@main struct DreeveWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var delegate
    @StateObject private var store = WatchGoalStore.shared
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            WatchGoalsView().environmentObject(store)
                .tint(watchAccent)
                .task { store.requestLatest() }
                .onChange(of: phase) { _, value in if value == .active { store.requestLatest() } }
        }
    }
}
struct WatchGoalsView: View {
    @EnvironmentObject private var store: WatchGoalStore
    @State private var path: [WatchGoalSelection] = []
    var body: some View {
        NavigationStack(path: $path) {
            List {
                if store.unavailable {
                    Text("Open Dreeve on iPhone to send your goals.")
                } else if store.snapshot.goals.isEmpty {
                    Text("No goals. Create a goal on iPhone to get started.")
                }
                ForEach(store.snapshot.orderedGoals(limit: store.snapshot.goals.count)) { goal in
                    NavigationLink(value: WatchGoalSelection(instanceID: store.snapshot.instanceID, goalID: goal.id)) {
                        TimelineView(.periodic(from: .now, by: 60)) { timeline in
                            VStack(alignment: .leading, spacing: 5) {
                                Label(goal.title, systemImage: watchGoalSymbol(goal.sport)).font(.headline)
                                Text(goal.progressText(at: timeline.date)).font(.caption)
                                ProgressView(value: goal.fraction(at: timeline.date)).tint(watchAccent)
                            }
                        }
                    }
                }
                Button("Sync from iPhone") { store.requestLatest() }
                if let message = store.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                Text("Refresh Dreeve on iPhone to update activities.").font(.footnote).foregroundStyle(.secondary)
            }
            .navigationTitle("Your goals")
            .navigationDestination(for: WatchGoalSelection.self) { selection in
                WatchGoalDetail(selection: selection)
            }
            .onOpenURL { url in
                if let selection = WatchGoalSelection(url: url) { path = [selection] }
            }
        }
    }
}
let watchAccent = Color(red: 177/255, green: 244/255, blue: 82/255)
struct WatchGoalDetail: View {
    @EnvironmentObject private var store: WatchGoalStore
    let selection: WatchGoalSelection
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            ScrollView {
                if let goal = selection.goal(in: store.snapshot) {
                    VStack(spacing: 12) {
                        Text(goal.title).font(.headline).multilineTextAlignment(.center)
                        Gauge(value: goal.fraction(at: timeline.date)) {
                            Image(systemName: watchGoalSymbol(goal.sport))
                        } currentValueLabel: {
                            if goal.isComplete(at: timeline.date) { Image(systemName: "checkmark").foregroundStyle(watchAccent) }
                            else { Text(goal.value(at: timeline.date) == nil ? "—" : "\(Int((goal.fraction(at: timeline.date) * 100).rounded()))%") }
                        }.gaugeStyle(.accessoryCircular).tint(watchAccent).scaleEffect(1.3).padding(12)
                        Text(goal.progressText(at: timeline.date)).monospacedDigit()
                        Text(goal.frequency).font(.caption).foregroundStyle(.secondary)
                        if goal.value(at: timeline.date) == nil { Text("New period · refresh on iPhone").font(.caption) }
                        else if store.snapshot.isStale(at: timeline.date) { Text("Saved progress").font(.caption).foregroundStyle(.secondary) }
                        Button("Sync from iPhone") { store.requestLatest() }
                        if let message = store.message { Text(message).font(.caption).foregroundStyle(.secondary) }
                        Text("Refresh activities in Dreeve on iPhone.").font(.footnote).foregroundStyle(.secondary)
                    }.padding(.horizontal, 8)
                } else {
                    Text("Goal unavailable. Choose another goal in the complication settings.").padding()
                }
            }
        }
    }
}
