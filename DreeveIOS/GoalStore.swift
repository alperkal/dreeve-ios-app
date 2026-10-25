import Foundation
import SwiftData
import CloudKit
import CoreData
import SwiftUI

@Model
final class TrainingGoal {
    // CloudKit-compatible defaults; no unique constraints or credentials.
    var id: UUID = UUID()
    var instanceID: String = ""
    var name: String = ""
    var sportType: String = "Run"
    var metricRaw: String = "count"
    var frequencyRaw: String = "weekly"
    var target: Double = 1
    var favoriteRank: Int = 0
    var isArchived: Bool = false
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now

    init(instanceID: String, name: String, sport: String, metric: GoalMetric,
         frequency: GoalFrequency, target: Double) {
        self.instanceID = instanceID
        self.name = name
        sportType = sport
        metricRaw = metric.rawValue
        frequencyRaw = frequency.rawValue
        self.target = target
    }
    var metric: GoalMetric { GoalMetric(rawValue: metricRaw) ?? .count }
    var frequency: GoalFrequency { GoalFrequency(rawValue: frequencyRaw) ?? .weekly }
    var title: String { name.isEmpty ? "\(sportType) · \(frequency.label)" : name }

    static func visible(_ goals: [TrainingGoal], instance: String) -> [TrainingGoal] {
        let matches = goals.filter { $0.instanceID == instance }
        // CloudKit doesn't support uniqueness constraints; resolve any UUID collisions
        // consistently without generating replacement records during a sync import.
        let unique = Dictionary(matches.map { ($0.id, $0) }, uniquingKeysWith: {
            $0.updatedAt >= $1.updatedAt ? $0 : $1
        })
        return unique.values.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
    static func favorites(_ goals: [TrainingGoal]) -> [TrainingGoal] {
        let sorted = goals.filter { !$0.isArchived && (1...2).contains($0.favoriteRank) }.sorted {
            if $0.favoriteRank != $1.favoriteRank { return $0.favoriteRank < $1.favoriteRank }
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        var ranks = Set<Int>()
        return sorted.filter { ranks.insert($0.favoriteRank).inserted }
    }
}

@MainActor
final class GoalPersistence: ObservableObject {
    let container: ModelContainer?
    let cloudEnabled: Bool
    @Published var status: String

    init() {
        let schema = Schema([TrainingGoal.self])
        let url = URL.applicationSupportDirectory.appendingPathComponent("TrainingGoals.store")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let identifier = Bundle.main.object(forInfoDictionaryKey: "GoalCloudContainer") as? String ?? ""
        #if targetEnvironment(simulator) && !DREEVE_SIMULATOR_CLOUDKIT
        // Unsigned simulator apps have no CloudKit entitlement. CloudKit can trap
        // asynchronously instead of throwing a catchable ModelContainer error.
        let configured = false
        #else
        let configured = !identifier.isEmpty && identifier.hasPrefix("iCloud.")
        #endif
        do {
            let config = ModelConfiguration("TrainingGoals", schema: schema, url: url,
                cloudKitDatabase: configured ? .private(identifier) : .none)
            container = try ModelContainer(for: schema, configurations: [config])
            cloudEnabled = configured
            status = configured ? "iCloud sync enabled · changes also saved on this device" : "Goals saved on this device · iCloud sync is off"
        } catch {
            // Keep the same on-disk store; never silently replace it with an empty memory store.
            do {
                container = try ModelContainer(for: schema, configurations: [
                    ModelConfiguration("TrainingGoals", schema: schema, url: url, cloudKitDatabase: .none)])
                cloudEnabled = false
                status = "iCloud unavailable · goals saved on this device. Check signing and capabilities."
            } catch {
                container = nil
                cloudEnabled = false
                status = "Goal storage could not open: \(error.localizedDescription)"
            }
        }
    }
    func checkAccount() async {
        guard cloudEnabled,
              let id = Bundle.main.object(forInfoDictionaryKey: "GoalCloudContainer") as? String else { return }
        do {
            let account = try await CKContainer(identifier: id).accountStatus()
            status = account == .available
                ? "iCloud sync enabled · changes also saved on this device"
                : "iCloud unavailable · changes saved locally until your iCloud account is available"
        } catch { status = "iCloud unavailable · changes saved locally; sync will retry" }
    }
    func received(_ event: NSPersistentCloudKitContainer.Event) {
        guard cloudEnabled else { return }
        if event.endDate == nil { status = "Syncing goals with iCloud…" }
        else if !event.succeeded { status = "iCloud sync delayed · changes saved locally; sync will retry" }
        else { status = "Goals synced with iCloud" }
    }
}

@MainActor
final class GoalProgressStore: ObservableObject {
    @Published private(set) var snapshot: GoalSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var error: String?
    @Published private(set) var instanceID = ""
    private var requestedClient: DreeveAPIClient?
    private var refreshAgain = false
    private var refreshTask: Task<Void, Never>?
    private var revision = 0

    private let cacheDirectory: URL

    init(cacheDirectory: URL = URL.cachesDirectory.appendingPathComponent("DreeveGoals", isDirectory: true)) {
        self.cacheDirectory = cacheDirectory
    }

    private func cacheURL(_ scope: String) -> URL {
        // Local derived cache only, outside the SwiftData / CloudKit schema and iCloud backup.
        cacheDirectory.appendingPathComponent(scope + ".json")
    }
    func selectInstance(_ scope: String) {
        guard scope != instanceID else { return }
        revision += 1
        instanceID = scope
        requestedClient = nil
        refreshAgain = false
        error = nil
        snapshot = nil
        if !scope.isEmpty, let data = try? Data(contentsOf: cacheURL(scope)),
           let cached = try? JSONDecoder().decode(GoalSnapshot.self, from: data), cached.instanceID == scope {
            snapshot = cached
        }
    }
    func changed(_ activity: DreeveActivity? = nil, deletedID: String? = nil) {
        revision += 1
        guard var value = snapshot else { return }
        value.streakHistory = nil // Rebuilt from the authoritative index after this mutation.
        if let deletedID { value.activities.removeAll { $0.id == deletedID } }
        if let activity {
            value.activities.removeAll { $0.id == activity.id }
            if let updated = try? GoalActivity(activity) { value.activities.append(updated) }
        }
        snapshot = value
        persist(value)
    }
    private func persist(_ value: GoalSnapshot) {
        do {
            let url = cacheURL(value.instanceID)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(value)
            #if os(iOS)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
            #else
            try data.write(to: url, options: .atomic)
            #endif
        } catch { self.error = "Progress is available, but its offline cache could not be saved." }
    }
    func refresh(client: DreeveAPIClient) async {
        let scope = GoalEngine.instanceID(client.baseURL)
        guard scope == instanceID else { return }
        requestedClient = client
        if let refreshTask {
            refreshAgain = true
            await refreshTask.value
            return
        }
        // An unstructured task survives cancellation of a foreground view task.
        // A quick background/foreground transition therefore cannot lose a refresh.
        let task = Task { await self.performRefresh() }
        refreshTask = task
        await task.value
    }
    private func performRefresh() async {
        isRefreshing = true
        defer { isRefreshing = false; refreshTask = nil }
        repeat {
            refreshAgain = false
            guard let currentClient = requestedClient else { break }
            let currentScope = GoalEngine.instanceID(currentClient.baseURL)
            let capturedRevision = revision
            let week = GoalCalendar.period(.weekly)
            let month = GoalCalendar.period(.monthly)
            let from = min(week.start, month.start)
            let to = max(week.lastDay, month.lastDay)
            do {
                // The docs specify inclusive day filters, but do not explicitly
                // promise which timezone server filtering uses. Fetch a one-day
                // buffer at both ends; exact membership always uses startDateLocal.
                let all = try await currentClient.allGoalActivities(
                    from: GoalCalendar.addingDays(-1, to: from),
                    to: GoalCalendar.addingDays(1, to: to))
                guard currentScope == instanceID, capturedRevision == revision else {
                    if requestedClient != nil { refreshAgain = true }
                    continue
                }
                let value = GoalSnapshot(instanceID: currentScope, from: from, to: to,
                                         refreshedAt: .now, activities: all)
                error = nil
                snapshot = value // Replace only after EVERY page succeeds: honor removals and edits.
                persist(value)
            } catch {
                if currentScope == instanceID, capturedRevision == revision {
                    self.error = "Progress refresh failed · showing saved data. \(error.localizedDescription)"
                }
            }
        } while refreshAgain && !Task.isCancelled
    }
    func beginIndexRefresh() { isRefreshing = true }
    func finishIndexRefresh(error message: String?) {
        isRefreshing = false
        error = message.map { "Progress refresh failed · showing saved data. " + $0 }
    }
    func acceptIndexSnapshot(_ value: GoalSnapshot) {
        guard value.instanceID == instanceID, snapshot != value else { return }
        snapshot = value
        persist(value)
    }

    func value(for goal: TrainingGoal, now: Date) -> Double? {
        let period = GoalCalendar.period(goal.frequency, now: now)
        guard let snapshot, snapshot.instanceID == goal.instanceID, snapshot.covers(period) else { return nil }
        return GoalEngine.value(sport: goal.sportType, metric: goal.metric, period: period, activities: snapshot.activities)
    }
    func streak(for goal: TrainingGoal, now: Date) -> GoalStreak? {
        guard let snapshot, snapshot.instanceID == goal.instanceID, let history = snapshot.streakHistory else { return nil }
        return GoalStreakEngine.streak(sport: goal.sportType, metric: goal.metric, frequency: goal.frequency,
            target: goal.target, createdAt: goal.createdAt, history: history, now: now)
    }
    func isStale(now: Date) -> Bool {
        guard let snapshot else { return true }
        return error != nil || now.timeIntervalSince(snapshot.refreshedAt) > 300 ||
            !snapshot.covers(GoalCalendar.period(.weekly, now: now)) ||
            !snapshot.covers(GoalCalendar.period(.monthly, now: now))
    }
}
