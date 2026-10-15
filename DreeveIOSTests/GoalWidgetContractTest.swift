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
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = GoalWidgetStorage(directory: directory)
        precondition(storage.read() == .empty)
        try storage.write(snapshot)
        precondition(storage.read() == snapshot)
        let encoded = try JSONEncoder().encode(snapshot)
        let text = String(decoding: encoded, as: UTF8.self)
        precondition(!text.contains("activities") && !text.contains("token") && !text.contains("https://"))
        let other = GoalWidgetSnapshot(instanceID: "other-server", updatedAt: now, refreshFailed: false, favorites: [], goals: [unknown])
        try storage.write(other)
        precondition(storage.read().goals.map(\.id) == [unknown.id]) // account switch replaces, never combines
        try storage.write(.empty)
        precondition(storage.read() == .empty) // logout clears old goal data
        try Data("invalid".utf8).write(to: directory.appendingPathComponent("goals-widget.json"))
        precondition(storage.read() == .empty)
        do { try GoalWidgetStorage(directory: nil).write(snapshot); preconditionFailure("Missing App Group ignored") }
        catch is CocoaError {}
        print("Goal widget tests passed: completion/overshoot, period rollover, unknown values, favorites/selection, freshness, atomic persistence, instance replacement/logout and credential-free payloads.")
    }
}
