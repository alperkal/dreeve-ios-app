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
        precondition(decoded.appearance == nil) // Older packets default to dark.
        var appearancePacket = envelope(2)
        appearancePacket.appearance = .light
        precondition(appearancePacket.changesVisibleGoals(from: decoded))
        let appearanceData = try JSONEncoder().encode(appearancePacket)
        let decodedAppearance = try GoalWatchEnvelope.decode(appearanceData)
        precondition(decodedAppearance.appearance == .light && decodedAppearance.snapshot == snapshot)
        precondition(decodedAppearance.needsTimelineReload(replacing: decoded))
        var systemPacket = envelope(3)
        systemPacket.appearance = .system
        precondition(systemPacket.changesVisibleGoals(from: appearancePacket))
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
        // Sunday completion -> Monday unknown -> first Monday run. Persisted outbox
        // and priority-send checkpoint differ when publication precedes WC activation.
        let dates = DateFormatter()
        dates.calendar = Calendar(identifier: .gregorian); dates.timeZone = .current
        dates.locale = Locale(identifier: "en_US_POSIX"); dates.dateFormat = "yyyy-MM-dd HH:mm"
        let sunday = dates.date(from: "2026-10-25 23:55")!
        let monday = dates.date(from: "2026-10-26 09:00")!
        func week(_ start: String, _ end: String, _ current: Double?, at date: Date) -> GoalWidgetSnapshot {
            GoalWidgetSnapshot(instanceID: "weekly-instance", updatedAt: date, refreshFailed: false, favorites: ["weekly"], goals: [
                WidgetGoal(id: "weekly", title: "Weekly run", sport: "Run", frequency: "Weekly", isDistance: true,
                    target: 30, current: current, periodStart: start, periodEnd: end)
            ])
        }
        let sundayPacket = envelope(10, snapshot: week("2026-10-19", "2026-10-26", 30, at: sunday))
        let rolloverPacket = envelope(11, snapshot: week("2026-10-26", "2026-11-02", nil, at: monday))
        let runPacket = envelope(12, snapshot: week("2026-10-26", "2026-11-02", 6, at: monday))
        precondition(sundayPacket.snapshot.goals[0].isComplete(at: sunday))
        precondition(sundayPacket.snapshot.goals[0].value(at: monday) == nil)
        precondition(!sundayPacket.snapshot.goals[0].isComplete(at: monday))
        let priority = GoalWatchStorage(directory: root.appendingPathComponent("priority"))
        let outbound = GoalWatchStorage(directory: root.appendingPathComponent("outbound"))
        try priority.write(sundayPacket)
        try outbound.write(rolloverPacket)
        try outbound.write(runPacket) // phone updated while the WC session was inactive
        let restartedOutbox = GoalWatchStorage(directory: root.appendingPathComponent("outbound"))
        precondition(restartedOutbox.envelope()!.changesVisibleGoals(from: priority.envelope()))
        try priority.write(runPacket) // only mark after actually queueing the priority transfer
        precondition(!runPacket.changesVisibleGoals(from: priority.envelope()))
        let runPayload = try runPacket.contextPayload()
        let rolloverPayload = try rolloverPacket.contextPayload()
        precondition(runPacket.matches(payload: runPayload))
        precondition(!runPacket.matches(payload: rolloverPayload))
        try priority.remove() // failed send re-arms the pending update
        precondition(runPacket.changesVisibleGoals(from: priority.envelope()))
        let watch = GoalWatchStorage(directory: root.appendingPathComponent("week-watch"))
        let acceptedSunday = try watch.accept(JSONEncoder().encode(sundayPacket))
        let acceptedRollover = try watch.accept(JSONEncoder().encode(rolloverPacket))
        precondition(acceptedSunday && acceptedRollover)
        precondition(watch.readResult().snapshot!.goals[0].value(at: monday) == nil)
        let acceptedRun = try watch.accept(JSONEncoder().encode(runPacket))
        precondition(acceptedRun)
        let runGoal = watch.readResult().snapshot!.goals[0]
        precondition(runGoal.value(at: monday) == 6 && runGoal.fraction(at: monday) == 0.2)
        let duplicatePriority = try watch.accept(JSONEncoder().encode(runPacket))
        precondition(!duplicatePriority) // a following priority callback still reloads this current revision
        precondition(watch.envelope()!.matches(payload: runPayload))
        let delayedRollover = try watch.accept(JSONEncoder().encode(rolloverPacket))
        precondition(!delayedRollover && watch.readResult().snapshot!.goals[0].value(at: monday) == 6)
        // Foreground refresh must recover after activation/reachability changes,
        // avoid overlapping requests, and ignore callbacks from timed-out requests.
        var gate = WatchGoalRequestGate()
        precondition(gate.begin(activated: true, reachable: true, now: now) == nil)
        gate.isForeground = true
        precondition(gate.begin(activated: false, reachable: false, now: now) == nil)
        precondition(gate.begin(activated: true, reachable: false, now: now) == nil)
        let firstRequest = gate.begin(activated: true, reachable: true, now: now)!
        precondition(gate.begin(activated: true, reachable: true, now: now.addingTimeInterval(15)) == nil)
        let timeoutRetry = gate.begin(activated: true, reachable: true, now: now.addingTimeInterval(31))!
        precondition(!gate.finish(firstRequest))
        precondition(gate.finish(timeoutRetry))
        let nextRequest = gate.begin(activated: true, reachable: true, now: now.addingTimeInterval(32))!
        precondition(gate.finish(nextRequest))
        gate.isForeground = false
        precondition(gate.begin(activated: true, reachable: true, now: now.addingTimeInterval(60)) == nil)
        // Polls persist metadata without repeatedly spending complication redraws.
        precondition(!envelope(5, snapshot: timestampOnly).needsTimelineReload(replacing: next))
        precondition(envelope(5, snapshot: complete).needsTimelineReload(replacing: next))
        precondition(!next.needsTimelineReload(replacing: next))
        precondition(next.needsTimelineReload(replacing: next, force: true))
        precondition(!envelope(2).needsTimelineReload(replacing: next, force: true))
        precondition(!envelope(1, senderID: UUID().uuidString, sentAt: now.addingTimeInterval(-1))
            .needsTimelineReload(replacing: next, force: true))
        precondition(cleared.needsTimelineReload(replacing: envelope(2)))
        // Recovery from the phone widget must never resurrect a logged-out instance
        // or overwrite an equally recent goal-definition edit with an older cache.
        precondition(GoalWatchEnvelope.recoverableSnapshot(timestampOnly, after: next) == timestampOnly)
        precondition(GoalWatchEnvelope.recoverableSnapshot(snapshot, after: next) == nil)
        precondition(GoalWatchEnvelope.recoverableSnapshot(other, after: next) == nil)
        precondition(GoalWatchEnvelope.recoverableSnapshot(snapshot, after: cleared) == nil)
        precondition(GoalWatchEnvelope.recoverableSnapshot(nil, after: next) == nil)
        precondition(GoalWatchEnvelope.recoverableSnapshot(snapshot, after: nil) == snapshot)

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
        print("Watch goal tests passed: durable offline snapshots, ordered transfer/logout, instance-scoped selection/deep links, missing goals, rollover/first-run recovery, pending priority delivery after activation/restart, duplicate priority arrivals, foreground activation/reachability retries and timeouts, unchanged-poll redraw suppression, scoped cache recovery, completion, file fallback, priority budget, invalid payload preservation and credential-free schema.")
    }
}
