import Foundation
import SwiftData

final class GoalsMockProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@main struct GoalsContractTest {
    @MainActor static func main() async throws {
        func date(_ day: String) -> Date { GoalCalendar.formatter().date(from: day)! }
        func activity(_ id: String, _ day: String, sport: String = "Walk", meters: Double = 4000) throws -> DreeveActivity {
            let data = try JSONSerialization.data(withJSONObject: ["id":id, "name":id, "sportType":sport,
                "startDateLocal":day, "distanceInMeter":meters])
            return try JSONDecoder().decode(DreeveActivity.self, from: data)
        }
        let utc = TimeZone(secondsFromGMT: 0)!
        let week = GoalCalendar.period(.weekly, now: date("2026-10-15"), timeZone: utc)
        precondition(week.start == "2026-10-12" && week.endExclusive == "2026-10-19")
        precondition(GoalCalendar.period(.weekly, now: date("2026-10-18"), timeZone: utc) == week)
        precondition(GoalCalendar.period(.weekly, now: date("2026-10-19"), timeZone: utc).start == "2026-10-19")
        precondition(GoalCalendar.period(.weekly, now: date("2027-01-01"), timeZone: utc).start == "2026-12-28")
        let leap = GoalCalendar.period(.monthly, now: date("2024-02-20"), timeZone: utc)
        precondition(leap.start == "2024-02-01" && leap.lastDay == "2024-02-29" && leap.endExclusive == "2024-03-01")
        let dst = GoalCalendar.period(.weekly, now: date("2026-03-29"), timeZone: TimeZone(identifier: "Europe/Vienna")!)
        precondition(dst.start == "2026-03-23" && dst.lastDay == "2026-03-29")
        let instant = ISO8601DateFormatter().date(from: "2026-10-18T23:30:00Z")!
        precondition(GoalCalendar.period(.weekly, now: instant, timeZone: TimeZone(identifier: "Europe/Vienna")!).start == "2026-10-19")
        precondition(GoalCalendar.period(.weekly, now: instant, timeZone: TimeZone(identifier: "America/Los_Angeles")!).start == "2026-10-12")
        precondition(GoalCalendar.localDay("2026-10-12T00:05:00+14:00") == "2026-10-12")
        precondition(GoalCalendar.localDay("2026-10-12T23:59:59.123Z") == "2026-10-12")
        precondition(GoalCalendar.localDay("2026-02-30T10:00:00") == nil)
        precondition(GoalCalendar.localDay("invalid") == nil)
        let earlier = try activity("a", "2026-10-12T00:00:00")
        let second = try activity("b", "2026-10-14T23:59:59")
        let outside = try activity("c", "2026-10-19T00:00:00")
        var records = try [earlier, second, outside, earlier].map(GoalActivity.init)
        precondition(GoalEngine.value(sport: "Walk", metric: .count, period: week, activities: records) == 2)
        precondition(GoalEngine.value(sport: "Walk", metric: .distance, period: week, activities: records) == 8000)
        records.append(try GoalActivity(activity("a", "2026-10-12T00:00:00", sport: "Run", meters: 9000)))
        precondition(GoalEngine.value(sport: "Walk", metric: .count, period: week, activities: records) == 1)
        precondition(GoalEngine.value(sport: "Run", metric: .distance, period: week, activities: records) == 9000)
        records.removeAll { $0.id == "b" }
        precondition(GoalEngine.value(sport: "Walk", metric: .count, period: week, activities: records) == 0)
        let canonical = GoalEngine.instanceID(URL(string:"https://EXAMPLE.test:443/dreeve/")!)
        precondition(canonical == GoalEngine.instanceID(URL(string:"https://example.test/dreeve")!))
        precondition(canonical != GoalEngine.instanceID(URL(string:"https://example.test/other")!))

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GoalsMockProtocol.self]
        let client = DreeveAPIClient(baseURL: URL(string:"https://example.test/dreeve")!, token:"test", urlSession: URLSession(configuration: config))
        var calls = 0
        func page(_ page: Int, totalPages: Int, items: [[String: Any]]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["activities": items, "pagination": ["page":page,"size":100,"total":totalPages*100,"totalPages":totalPages]])
        }
        func row(_ id: String, day: String = "2026-10-12T12:00:00") -> [String: Any] {
            ["id":id,"name":id,"sportType":"Walk","startDateLocal":day,"distanceInMeter":4000]
        }
        GoalsMockProtocol.handler = { request in
            calls += 1
            precondition(request.url!.path == "/dreeve/api/v1/activities")
            let query = Dictionary(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) }, uniquingKeysWith: { first, _ in first })
            precondition(query["filters[from]"] == "2026-10-12" && query["filters[to]"] == "2026-10-18")
            precondition(query["pagination[size]"] == "100")
            let number = Int(query["pagination[page]"]!)!
            return (200, try page(number, totalPages: 3, items: number == 1 ? [row("a")] : number == 2 ? [row("a"), row("b")] : [row("c")]))
        }
        let fetched = try await client.allGoalActivities(from: week.start, to: week.lastDay)
        precondition(calls == 3 && fetched.count == 3)
        GoalsMockProtocol.handler = { request in
            let number = Int(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "pagination[page]" }!.value!)!
            return number == 1 ? (200, try page(1,totalPages:2,items:[row("a")])) : (503,Data("{}".utf8))
        }
        do { _ = try await client.allGoalActivities(from: week.start,to:week.lastDay); preconditionFailure("Partial fetch accepted") }
        catch APIError.http(let code, _) { precondition(code == 503) }
        GoalsMockProtocol.handler = { _ in (200,try page(1,totalPages:2,items:[])) }
        do { _ = try await client.allGoalActivities(from:week.start,to:week.lastDay); preconditionFailure("Incomplete pagination accepted") }
        catch APIError.decoding { }
        GoalsMockProtocol.handler = { _ in (200,try page(1,totalPages:1,items:[row("a",day:"bad-date")])) }
        do { _ = try await client.allGoalActivities(from:week.start,to:week.lastDay); preconditionFailure("Bad date accepted") }
        catch APIError.decoding { }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at:root) }
        let storeURL = root.appendingPathComponent("goals.store")
        func container() throws -> ModelContainer {
            try ModelContainer(for: TrainingGoal.self, configurations: ModelConfiguration(url:storeURL,cloudKitDatabase:.none))
        }
        var first: ModelContainer? = try container()
        let goal = TrainingGoal(instanceID:canonical,name:"Weekly walks",sport:"Walk",metric:.count,frequency:.weekly,target:3)
        goal.createdAt = date("2026-10-15") // Creation time is irrelevant to progress.
        first!.mainContext.insert(goal)
        for i in 0..<120 { first!.mainContext.insert(TrainingGoal(instanceID:canonical,name:"Goal \(i)",sport:"Run",metric:.distance,frequency:.monthly,target:100000)) }
        try first!.mainContext.save()
        let initialCount = try first!.mainContext.fetchCount(FetchDescriptor<TrainingGoal>())
        precondition(initialCount == 121)
        let goalID = goal.id
        first = nil
        let restored = try container()
        let all = try restored.mainContext.fetch(FetchDescriptor<TrainingGoal>())
        precondition(all.count == 121)
        let restoredGoal = all.first { $0.id == goalID }!
        precondition(restoredGoal.target == 3 && restoredGoal.createdAt == date("2026-10-15"))
        precondition(TrainingGoal.visible(all,instance:"another-instance").isEmpty)
        all[0].favoriteRank = 1; all[1].favoriteRank = 2; all[2].favoriteRank = 1
        precondition(TrainingGoal.favorites(all).count == 2)
        all[0].isArchived = true
        precondition(!TrainingGoal.favorites(all).contains { $0.id == all[0].id })
        restoredGoal.target = 4
        try restored.mainContext.save()
        precondition(restoredGoal.target == 4)

        let progress = GoalProgressStore(cacheDirectory: root.appendingPathComponent("cache"))
        progress.selectInstance(canonical)
        let currentDay = GoalCalendar.period(.weekly).start + "T12:00:00"
        GoalsMockProtocol.handler = { _ in (200,try page(1,totalPages:1,items:[row("a",day:currentDay)])) }
        await progress.refresh(client:client)
        precondition(progress.snapshot?.activities.count == 1 && progress.error == nil)
        precondition(progress.value(for:restoredGoal,now:.now) == 1)
        restoredGoal.metricRaw = "distance"
        precondition(progress.value(for:restoredGoal,now:.now) == 4000)
        restoredGoal.sportType = "Run"
        precondition(progress.value(for:restoredGoal,now:.now) == 0)
        restoredGoal.sportType = "Walk"; restoredGoal.metricRaw = "count"
        GoalsMockProtocol.handler = { _ in (503,Data("{}".utf8)) }
        await progress.refresh(client:client)
        precondition(progress.snapshot?.activities.count == 1 && progress.error != nil && progress.isStale(now:.now))
        let offline = GoalProgressStore(cacheDirectory: root.appendingPathComponent("cache"))
        offline.selectInstance(canonical)
        precondition(offline.snapshot?.activities.count == 1)
        progress.changed(deletedID:"a")
        precondition(progress.value(for:restoredGoal,now:.now) == 0)
        GoalsMockProtocol.handler = { _ in (200,try page(1,totalPages:0,items:[])) }
        await progress.refresh(client:client)
        precondition(progress.snapshot!.activities.isEmpty && progress.error == nil)
        precondition(progress.value(for:restoredGoal,now:date("2027-01-01")) == nil)
        // In-flight results must not resurrect a locally deleted activity.
        var slowCalls = 0
        GoalsMockProtocol.handler = { _ in
            slowCalls += 1
            if slowCalls == 1 {
                Thread.sleep(forTimeInterval: 0.15)
                return (200, try page(1,totalPages:1,items:[row("a",day:currentDay)]))
            }
            return (200, try page(1,totalPages:0,items:[]))
        }
        let inFlight = Task { await progress.refresh(client:client) }
        try await Task.sleep(for:.milliseconds(30))
        progress.changed(deletedID:"a")
        await inFlight.value
        precondition(slowCalls == 2 && progress.snapshot!.activities.isEmpty)
        // Results from a previous instance cannot cross into the current instance.
        GoalsMockProtocol.handler = { _ in
            Thread.sleep(forTimeInterval:0.15)
            return (200, try page(1,totalPages:1,items:[row("a",day:currentDay)]))
        }
        let switching = Task { await progress.refresh(client:client) }
        try await Task.sleep(for:.milliseconds(30))
        progress.selectInstance("other")
        await switching.value
        precondition(progress.snapshot == nil)
        precondition(progress.value(for:restoredGoal,now:.now) == nil)
        progress.selectInstance(canonical)
        var resumedCalls = 0
        GoalsMockProtocol.handler = { _ in
            resumedCalls += 1
            Thread.sleep(forTimeInterval:0.1)
            return (200,try page(1,totalPages:1,items:[row("a",day:currentDay)]))
        }
        let cancelledCaller = Task { await progress.refresh(client:client) }
        try await Task.sleep(for:.milliseconds(20))
        cancelledCaller.cancel()
        let resumedCaller = Task { await progress.refresh(client:client) }
        await cancelledCaller.value
        await resumedCaller.value
        precondition(resumedCalls == 2 && progress.snapshot!.activities.count == 1 && progress.error == nil)
        restored.mainContext.delete(restoredGoal)
        try restored.mainContext.save()
        let remaining = try restored.mainContext.fetchCount(FetchDescriptor<TrainingGoal>())
        precondition(remaining == 120)
        print("Goals tests passed: calendar/DST/travel, retroactive totals, edits/deletions, duplicate IDs, pagination/failure, 121 persistent goals, favorites, instance isolation, and offline cache.")
    }
}
