import Foundation

@main struct GoalWatchContractTest {
    static func main() throws {
        let now = Date.now
        let snapshot = GoalWidgetSnapshot.example(now: now)
        let sender = UUID().uuidString
        func envelope(_ revision: Int, snapshot: GoalWidgetSnapshot = snapshot, senderID: String = sender,
                      sentAt: Date = now, version: Int = 1) -> GoalWatchEnvelope {
            GoalWatchEnvelope(version: version, senderID: senderID, revision: revision, sentAt: sentAt, snapshot: snapshot)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = GoalWatchStorage(directory: root)
        precondition(cache.readResult() == .unavailable)
        let data = try JSONEncoder().encode(envelope(1))
        let decoded = try GoalWatchEnvelope.decode(data)
        precondition(decoded.snapshot == snapshot)
        let payload = try decoded.contextPayload()
        let payloadEnvelope = try GoalWatchEnvelope.decode(payload["goalEnvelope"] as! Data)
        precondition(payload.count == 1 && payloadEnvelope == decoded)
        let accepted1 = try cache.accept(data)
        precondition(accepted1)
        let reopened = GoalWatchStorage(directory: root)
        precondition(reopened.envelope() == decoded && reopened.readResult().snapshot == snapshot)
        let accepted2 = try !reopened.accept(data)
        precondition(accepted2)
        let cleared = envelope(3, snapshot: .empty)
        let accepted3 = try reopened.accept(JSONEncoder().encode(cleared))
        precondition(accepted3)
        precondition(reopened.readResult() == .available(.empty)) // logout != unreadable
        let accepted4 = try !reopened.accept(JSONEncoder().encode(envelope(2)))
        precondition(accepted4)
        precondition(reopened.readResult() == .available(.empty))
        let next = envelope(4)
        let accepted5 = try reopened.accept(JSONEncoder().encode(next))
        precondition(accepted5)
        let goal = snapshot.selectedGoal(id: nil)!
        precondition(goal.id == snapshot.favorites[0])
        let selection = WatchGoalSelection(instanceID: snapshot.instanceID, goalID: goal.id)
        precondition(WatchGoalSelection(entityID: selection.entityID) == selection)
        precondition(WatchGoalSelection(url: selection.url) == selection)
        precondition(selection.goal(in: snapshot) == goal)
        precondition(selection.goal(in: .empty) == nil)
        let other = GoalWidgetSnapshot(instanceID: "other", updatedAt: now, refreshFailed: false,
            favorites: snapshot.favorites, goals: snapshot.goals)
        precondition(selection.goal(in: other) == nil) // even if another instance reused the UUID
        let missing = WatchGoalSelection(instanceID: snapshot.instanceID, goalID: "deleted")
        precondition(missing.goal(in: snapshot) == nil) // no favorite substitution
        precondition(WatchGoalSelection(url: URL(string: "https://example.test/goal")!) == nil)
        precondition(WatchGoalSelection(entityID: "invalid") == nil)
        let encodedSelection = WatchGoalSelection(instanceID: "instance", goalID: "goal with ? and #")
        precondition(WatchGoalSelection(url: encodedSelection.url) == encodedSelection)
        let ended = Calendar.current.date(byAdding: .day, value: 40, to: now)!
        precondition(goal.value(at: ended) == nil && !goal.isComplete(at: ended))
        let complete = GoalWidgetSnapshot.example(now: now, complete: true)
        precondition(complete.goals.allSatisfy { $0.isComplete(at: now) && $0.fraction(at: now) == 1 })
        precondition(envelope(5, snapshot: complete).changesVisibleGoals(from: next))
        let timestampOnly = GoalWidgetSnapshot(instanceID: snapshot.instanceID, updatedAt: now.addingTimeInterval(60),
            refreshFailed: true, favorites: snapshot.favorites, goals: snapshot.goals)
        precondition(!envelope(5, snapshot: timestampOnly).changesVisibleGoals(from: next)) // preserve priority transfer budget
        precondition(!envelope(1, senderID: UUID().uuidString, sentAt: now.addingTimeInterval(-1)).supersedes(next))
        precondition(envelope(1, senderID: UUID().uuidString, sentAt: now.addingTimeInterval(1)).supersedes(next))
        let titles = String(repeating: "Synthetic long goal title ", count: 50)
        let manyGoals = (0..<200).map { index in
            WidgetGoal(id: "goal-\(index)", title: titles, sport: "Run", frequency: "Weekly", isDistance: true,
                       target: 30, current: 10, periodStart: goal.periodStart, periodEnd: goal.periodEnd)
        }
        let large = GoalWidgetSnapshot(instanceID: "instance", updatedAt: now, refreshFailed: false, favorites: [], goals: manyGoals)
        let marker = try envelope(5, snapshot: large).contextPayload()
        precondition(marker["goalFilePending"] as? Bool == true && marker["goalEnvelope"] == nil)
        let validBeforeCorruption = reopened.envelope()
        for invalid in [Data("broken".utf8), try JSONEncoder().encode(envelope(6, version: 2)),
                        try JSONEncoder().encode(envelope(6, senderID: "not-a-sender")),
                        Data(repeating: 0, count: GoalWatchEnvelope.maximumBytes + 1)] {
            do { _ = try reopened.accept(invalid); preconditionFailure("Invalid transfer accepted") } catch {}
            precondition(reopened.envelope() == validBeforeCorruption)
        }
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let snapshotJSON = json["snapshot"] as! [String: Any]
        precondition(Set(snapshotJSON.keys).isSubset(of: ["instanceID", "updatedAt", "refreshFailed", "favorites", "goals"]))
        let text = String(decoding: data, as: UTF8.self).lowercased()
        for forbidden in ["https://", "authorization", "bearer", "api_key", "healthkit", "latitude", "longitude"] {
            precondition(!text.contains(forbidden))
        }
        print("Watch goal tests passed: durable offline snapshots, ordered transfer/logout, instance-scoped selection/deep links, missing goals, rollover/completion, file fallback, priority budget, invalid payload preservation and credential-free schema.")
    }
}
