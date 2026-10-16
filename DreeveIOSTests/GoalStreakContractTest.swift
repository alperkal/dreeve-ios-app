import Foundation

@main struct GoalStreakContractTest {
    @MainActor static func main() async throws {
        let utc = TimeZone(secondsFromGMT: 0)!
        func date(_ day: String) -> Date { GoalCalendar.formatter().date(from: day)! }
        func day(_ date: String, _ meters: Double = 10000, count: Int = 1, sport: String = "Run") -> GoalStreakDay {
            GoalStreakDay(day: date, sport: sport, count: count, meters: meters)
        }
        let weeks = [day("2026-09-14"), day("2026-09-21"), day("2026-09-28"), day("2026-10-05")]
        func streak(_ days: [GoalStreakDay], today: String = "2026-10-16", through: String? = nil,
                    created: String = "2026-09-14", frequency: GoalFrequency = .weekly,
                    metric: GoalMetric = .distance, target: Double = 10000) -> GoalStreak? {
            GoalStreakEngine.streak(sport: "Run", metric: metric, frequency: frequency, target: target,
                createdAt: date(created), history: GoalStreakHistory(throughDay: through ?? today, days: days),
                now: date(today), timeZone: utc)
        }
        precondition(streak(weeks)?.completedPeriods == 4, "Pending current week preserves four completed weeks")
        precondition(streak(weeks)?.currentPeriodCompleted == false)
        let five = weeks + [day("2026-10-15")]
        precondition(streak(five)?.completedPeriods == 5 && streak(five)?.currentPeriodCompleted == true)
        precondition(streak(weeks, today:"2026-10-19")?.completedPeriods == 0, "Missed ended week breaks chain")
        precondition(streak(five, today:"2026-10-19")?.completedPeriods == 5, "Monday retains completed prior week")
        precondition(streak([day("2026-10-15")])?.completedPeriods == 1, "Missing older periods terminate the chain")
        precondition(streak([day("2026-09-14"), day("2026-10-01"), day("2026-10-05")])?.completedPeriods == 2)
        precondition(streak(five, created:"2026-10-14")?.completedPeriods == 1, "No retroactive streak before goal creation")
        precondition(streak([day("2026-10-12")], created:"2026-10-16")?.completedPeriods == 1, "Creation includes entire current period")
        precondition(streak(five, target:20000)?.completedPeriods == 0, "Target edits recalculate history")
        precondition(streak(five, metric:.count, target:1)?.completedPeriods == 5)
        precondition(streak(five, metric:.count, target:2)?.completedPeriods == 0)
        precondition(streak([day("2026-10-14",6000),day("2026-10-15",5000,sport:"VirtualRun")],target:11000)?.completedPeriods == 1)
        precondition(streak([day("2026-10-15",50000,sport:"Ride")])?.completedPeriods == 0)
        precondition(streak([day("2026-10-17")])?.completedPeriods == 0, "Future activity does not award streak")
        precondition(streak([],target:0) == nil && streak([],target:.nan) == nil)
        precondition(streak([],created:"2026-10-17") == nil)
        precondition(streak(five, through:"2026-10-10") == nil, "Incomplete ended period is unknown, not failed")
        precondition(streak(five, through:"2026-10-11") == nil, "A sync before rollover cannot prove the ended period's final result")
        precondition(streak(five, through:"2026-10-12")?.completedPeriods == 4, "Saved history synced this period preserves the prior chain")
        precondition(streak([day("2026-08-01"),day("2026-09-01"),day("2026-10-15")],created:"2026-08-14",frequency:.monthly)?.completedPeriods == 3)
        precondition(streak([day("2024-02-29"),day("2024-03-31")],today:"2024-04-01",created:"2024-02-20",frequency:.monthly)?.completedPeriods == 2, "Leap month and month rollover")
        precondition(streak([day("2026-12-28"),day("2027-01-04")],today:"2027-01-09",created:"2026-12-31")?.completedPeriods == 2, "ISO year boundary")
        let dstHistory = GoalStreakHistory(throughDay:"2026-03-30", days:[day("2026-03-23"),day("2026-03-30")])
        precondition(GoalStreakEngine.streak(sport:"Run",metric:.distance,frequency:.weekly,target:10000,
            createdAt:date("2026-03-25"),history:dstHistory,now:date("2026-03-30"),timeZone:TimeZone(identifier:"Europe/Vienna")!)?.completedPeriods == 2)

        // Exercise the same full-history aggregation used by Session, including mutations and isolation.
        let store = try ActivityIndexStore(inMemory:true)
        func record(_ id: String, _ date: String, meters: Double = 10000, sport: String = "Run") -> ActivitySummaryRecord {
            ActivitySummaryRecord(id:id,name:id,sportType:sport,startDateLocal:date+"T23:30:00-10:00",distanceMeters:meters,
                movingTimeSeconds:3600,elapsedTimeSeconds:3600,elevationGainMeters:0,gearId:nil)
        }
        try await store.upsertBatch(instanceHash:"one", records:[record("outdoor","2026-10-15",meters:6000),record("indoor","2026-10-15",meters:5000,sport:"VirtualRun"),record("future","2026-10-17")])
        let partial = try await store.goalStreakHistory(instanceHash:"one",throughDay:"2026-10-16")
        precondition(partial == nil, "Partial backfills cannot award streaks")
        _ = try await store.finalizeFullReconcile(instanceHash:"one",authoritativeActivityIds:["outdoor","indoor","future"])
        let history = try await store.goalStreakHistory(instanceHash:"one",throughDay:"2026-10-16")!
        precondition(history.days == [day("2026-10-15",11000,count:2)], "Virtual merging, day aggregation, future exclusion")
        let absent = try await store.goalStreakHistory(instanceHash:"two",throughDay:"2026-10-16")
        precondition(absent == nil, "Instance isolation")
        try await store.applyWriteThroughEdit(instanceHash:"one",updated:record("outdoor","2026-10-15",meters:2000))
        let edited = try await store.goalStreakHistory(instanceHash:"one",throughDay:"2026-10-16")!
        precondition(edited.days.first?.meters == 7000)
        try await store.applyWriteThroughDelete(instanceHash:"one",activityId:"indoor")
        let deleted = try await store.goalStreakHistory(instanceHash:"one",throughDay:"2026-10-16")!
        precondition(deleted.days.first?.meters == 2000 && deleted.days.first?.count == 1)

        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("streak-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at:cache) }
        let progress = GoalProgressStore(cacheDirectory:cache)
        progress.selectInstance("one")
        let goal = TrainingGoal(instanceID:"one",name:"Run",sport:"Run",metric:.distance,frequency:.weekly,target:10000)
        goal.createdAt = date("2026-09-14")
        let snapshot = GoalSnapshot(instanceID:"one",from:"2026-10-01",to:"2026-10-31",refreshedAt:date("2026-10-16"),activities:[],
            streakHistory:GoalStreakHistory(throughDay:"2026-10-16",days:five))
        progress.acceptIndexSnapshot(snapshot)
        precondition(progress.streak(for:goal,now:date("2026-10-16"))?.completedPeriods == 5)
        let relaunched = GoalProgressStore(cacheDirectory:cache); relaunched.selectInstance("one")
        precondition(relaunched.streak(for:goal,now:date("2026-10-16"))?.completedPeriods == 5, "Offline/relaunch persistence")
        relaunched.selectInstance("two")
        precondition(relaunched.streak(for:goal,now:date("2026-10-16")) == nil)
        progress.changed(deletedID:"outdoor")
        precondition(progress.streak(for:goal,now:date("2026-10-16")) == nil, "Don't retain stale streak during mutation rebuild")
        var object = try JSONSerialization.jsonObject(with:JSONEncoder().encode(snapshot)) as! [String:Any]
        object.removeValue(forKey:"streakHistory")
        let legacy = try JSONDecoder().decode(GoalSnapshot.self,from:JSONSerialization.data(withJSONObject:object))
        precondition(legacy.streakHistory == nil, "Older goal caches remain readable")
        print("PASS: GoalStreakContractTest (chains, grace period, gaps, creation, edits, virtual sports, calendar boundaries, authoritative history, mutations, offline cache and isolation)")
    }
}
