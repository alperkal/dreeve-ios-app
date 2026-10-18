import Foundation

@main struct GoalWidgetContractTest {
    static func main() throws {
        let now = ISO8601DateFormatter().date(from: "2026-10-15T12:00:00Z")!
        let nextWeek = ISO8601DateFormatter().date(from: "2026-10-19T12:00:00Z")!
        let weekly = WidgetGoal(id: "one", title: "Walk", sport: "Walk", frequency: "Weekly", isDistance: false,
            target: 3, current: 4, periodStart: "2026-10-12", periodEnd: "2026-10-19")
        precondition(weekly.isComplete(at: now) && weekly.fraction(at: now) == 1)
        precondition(!weekly.isComplete(at: nextWeek) && weekly.value(at: nextWeek) == nil)
        let unknown = WidgetGoal(id: "two", title: "Run", sport: "Run", frequency: "Monthly", isDistance: true,
            target: 100, current: nil, periodStart: "2026-10-01", periodEnd: "2026-11-01")
        precondition(!unknown.isComplete(at: now) && unknown.fraction(at: now) == 0)
        let half = WidgetGoal(id: "three", title: "Monthly run", sport: "Run", frequency: "Monthly", isDistance: true,
            target: 100, current: 50, periodStart: "2026-10-01", periodEnd: "2026-11-01")
        precondition(half.fraction(at: now) == 0.5 && half.progressText(at: now).contains("km"))
        let snapshot = GoalWidgetSnapshot(instanceID: "server-hash", updatedAt: now, refreshFailed: false,
            favorites: [half.id, weekly.id, weekly.id, "removed"], goals: [weekly, unknown, half])
        precondition(snapshot.orderedGoals(limit: 2).map(\.id) == [half.id, weekly.id])
        precondition(snapshot.orderedGoals(limit: 4).map(\.id) == [half.id, weekly.id, unknown.id])
        precondition(snapshot.selectedGoal(id: nil)?.id == half.id)
        precondition(snapshot.selectedGoal(id: "removed") == nil) // never silently show another goal
        precondition(!snapshot.isStale(at: now) && snapshot.isStale(at: now.addingTimeInterval(901)))
        let offline = GoalWidgetSnapshot(instanceID: "server-hash", updatedAt: now, refreshFailed: true, favorites: [], goals: [weekly])
        precondition(offline.isStale(at: now))
        let pending = WidgetGoal(id: weekly.id, title: "Renamed walk", sport: weekly.sport, frequency: weekly.frequency,
            isDistance: weekly.isDistance, target: weekly.target, current: nil, periodStart: weekly.periodStart, periodEnd: weekly.periodEnd)
        let notLoaded = GoalWidgetSnapshot(instanceID: snapshot.instanceID, updatedAt: nil, refreshFailed: false, favorites: [weekly.id], goals: [pending])
        let retained = notLoaded.retainingKnownProgress(from: snapshot)
        precondition(retained.goals.first?.current == 4 && retained.goals.first?.title == "Renamed walk")
        precondition(retained.updatedAt == now && retained.refreshFailed, "Retaining values must preserve their real freshness")
        precondition(notLoaded.retainingKnownProgress(from: .empty).goals.first?.current == nil, "Never merge across accounts")
        let newPeriod = WidgetGoal(id: weekly.id, title: weekly.title, sport: weekly.sport, frequency: weekly.frequency,
            isDistance: weekly.isDistance, target: weekly.target, current: nil, periodStart: "2026-10-19", periodEnd: "2026-10-26")
        let rollover = GoalWidgetSnapshot(instanceID: snapshot.instanceID, updatedAt: nil, refreshFailed: false, favorites: [], goals: [newPeriod])
        precondition(rollover.retainingKnownProgress(from: snapshot).goals.first?.current == nil)
        let changedTarget = WidgetGoal(id: weekly.id, title: weekly.title, sport: weekly.sport, frequency: weekly.frequency,
            isDistance: weekly.isDistance, target: 10, current: nil, periodStart: weekly.periodStart, periodEnd: weekly.periodEnd)
        let edited = GoalWidgetSnapshot(instanceID: snapshot.instanceID, updatedAt: nil, refreshFailed: false, favorites: [], goals: [changedTarget])
        precondition(edited.retainingKnownProgress(from: snapshot).goals.first?.current == nil)
        let removed = GoalWidgetSnapshot(instanceID: snapshot.instanceID, updatedAt: now, refreshFailed: false, favorites: [], goals: [])
        precondition(removed.retainingKnownProgress(from: snapshot).goals.isEmpty, "Confirmed empty inventory must remove old goals")
        precondition(snapshot.retainingKnownProgress(from: retained) == snapshot, "New known progress always wins")
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = GoalWidgetStorage(directory: directory)
        precondition(storage.read() == .empty)
        precondition(storage.readResult() == .unavailable, "Missing cache is not an empty saved inventory")
        try storage.write(snapshot)
        precondition(storage.read() == snapshot)
        precondition(storage.readResult() == .available(snapshot))
        let offlineStored = GoalWidgetSnapshot(instanceID: snapshot.instanceID, updatedAt: now, refreshFailed: true,
            favorites: snapshot.favorites, goals: snapshot.goals)
        try storage.write(offlineStored)
        precondition(storage.readResult().snapshot?.goals == snapshot.goals, "Failed refresh retains saved goal totals")
        let encoded = try JSONEncoder().encode(snapshot)
        let text = String(decoding: encoded, as: UTF8.self)
        precondition(!text.contains("activities") && !text.contains("token") && !text.contains("https://"))
        let other = GoalWidgetSnapshot(instanceID: "other-server", updatedAt: now, refreshFailed: false, favorites: [], goals: [unknown])
        try storage.write(other)
        precondition(storage.read().goals.map(\.id) == [unknown.id]) // account switch replaces, never combines
        try storage.write(.empty)
        precondition(storage.read() == .empty) // logout clears old goal data
        precondition(storage.readResult() == .available(.empty), "Explicit logout is authoritative empty data")
        try Data("invalid".utf8).write(to: directory.appendingPathComponent("goals-widget.json"))
        precondition(storage.read() == .empty)
        precondition(storage.readResult() == .unavailable, "Corrupt storage is not a no-goals response")
        try storage.write(snapshot)
        precondition(storage.readResult() == .available(snapshot), "Read recovers on a later widget refresh without app state")
        try FileManager.default.removeItem(at: directory.appendingPathComponent("goals-widget.json"))
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("goals-widget.json"), withIntermediateDirectories: false)
        precondition(storage.readResult() == .unavailable, "I/O read failure stays distinguishable")
        try FileManager.default.removeItem(at: directory.appendingPathComponent("goals-widget.json"))
        try storage.write(snapshot)
        precondition(storage.readResult() == .available(snapshot))
        do { try GoalWidgetStorage(directory: nil).write(snapshot); preconditionFailure("Missing App Group ignored") }
        catch is CocoaError {}
        print("Goal widget tests passed: completion/overshoot, period rollover, unknown values, favorites/selection, freshness, atomic persistence, instance replacement/logout, transient cache failures/recovery, retained progress and credential-free payloads.")
    }
}
