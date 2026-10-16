import Foundation

@main struct GoalSportMatchingTest {
    static func main() throws {
        func activity(_ id: String, sport: String, day: String = "2026-10-14", meters: Double) throws -> GoalActivity {
            let data = try JSONSerialization.data(withJSONObject: [
                "id": id, "name": id, "sportType": sport,
                "startDateLocal": day + "T12:00:00", "distanceInMeter": meters
            ])
            return try GoalActivity(JSONDecoder().decode(DreeveActivity.self, from: data))
        }
        let now = GoalCalendar.formatter().date(from: "2026-10-15")!
        let week = GoalCalendar.period(.weekly, now: now, timeZone: TimeZone(secondsFromGMT: 0)!)
        let month = GoalCalendar.period(.monthly, now: now, timeZone: TimeZone(secondsFromGMT: 0)!)
        for (real, virtual) in [("Run", "VirtualRun"), ("Ride", "VirtualRide"), ("Rowing", "VirtualRow")] {
            let outdoor = try activity("outside", sport: real, day: "2026-10-14", meters: 6000)
            let indoor = try activity("inside", sport: virtual, day: "2026-10-15", meters: 5000)
            let unrelated = try activity("other", sport: "Walk", meters: 9000)
            let future = try activity("future", sport: virtual, day: "2026-11-01", meters: 8000)
            let priorWeek = try activity("earlier", sport: virtual, day: "2026-10-01", meters: 2000)
            let records = [outdoor, indoor, unrelated, future, priorWeek, indoor]
            // Real and legacy virtual goal names share totals; duplicate IDs count once.
            for goal in [real, virtual] {
                precondition(GoalEngine.value(sport: goal, metric: .distance, period: week, activities: records) == 11000)
                precondition(GoalEngine.value(sport: goal, metric: .count, period: week, activities: records) == 2)
                precondition(GoalEngine.value(sport: goal, metric: .distance, period: month, activities: records) == 13000)
                precondition(GoalEngine.value(sport: goal, metric: .count, period: month, activities: records) == 3)
            }
            precondition(indoor.sport == virtual) // Raw API/cache types remain unchanged.
            // An edited virtual activity replaces its previous distance, including a type edit.
            let edited = try activity("inside", sport: real, day: "2026-10-15", meters: 7000)
            precondition(GoalEngine.value(sport: real, metric: .distance, period: week, activities: records + [edited]) == 13000)
            let reclassified = try activity("inside", sport: "Walk", day: "2026-10-15", meters: 7000)
            precondition(GoalEngine.value(sport: real, metric: .count, period: week, activities: records + [reclassified]) == 1)
            let deleted = records.filter { $0.id != "inside" }
            precondition(GoalEngine.value(sport: real, metric: .distance, period: week, activities: deleted) == 6000)
        }
        // Combining virtual pairs must not merge distinct sports such as trail running or e-biking.
        let mixed = try [activity("run", sport: "VirtualRun", meters: 5000),
                         activity("trail", sport: "TrailRun", meters: 6000),
                         activity("ride", sport: "VirtualRide", meters: 7000),
                         activity("ebike", sport: "EBikeRide", meters: 8000)]
        precondition(GoalEngine.value(sport: "Run", metric: .distance, period: week, activities: mixed) == 5000)
        precondition(GoalEngine.value(sport: "TrailRun", metric: .distance, period: week, activities: mixed) == 6000)
        precondition(GoalEngine.value(sport: "Ride", metric: .distance, period: week, activities: mixed) == 7000)
        precondition(GoalEngine.value(sport: "EBikeRide", metric: .distance, period: week, activities: mixed) == 8000)
        print("Goal sport tests passed: 6+5 km=11 km, run/ride/rowing virtual pairs, count/distance, week/month boundaries, legacy goals, deduplication, edits/deletions, and unrelated sports.")
    }
}
