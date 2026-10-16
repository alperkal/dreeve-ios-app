import Foundation

// Exercise the real session/index/API integration without Keychain, CloudKit or sockets.
enum KeychainStore {
    static func read() -> String? { "synthetic-test-token" }
    static func save(_ value: String) throws {}
    static func delete() {}
}
@MainActor final class GoalProgressStore {
    var snapshot: GoalSnapshot?
    var error: String?
    var instanceID = ""
    func selectInstance(_ value: String) { instanceID = value; snapshot = nil }
    func changed(_ activity: DreeveActivity) {}
    func changed(deletedID: String) {}
    func beginIndexRefresh() {}
    func finishIndexRefresh(error: String?) { self.error = error }
    func acceptIndexSnapshot(_ value: GoalSnapshot) { snapshot = value }
}

private final class OverviewRefreshProtocol: URLProtocol {
    enum Mode { case success, cancelled, serverFailure }
    static var mode: Mode = .success
    static var pages: [Int] = []
    static var fromFilters: [String?] = []
    static var includeHistoricalImport = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        precondition(request.url?.host == "overview-test.invalid")
        let today = ActivityDates.calendarDate.string(from: .now)
        if request.httpMethod == "DELETE" { respond(status: 204, body: ""); return }
        if request.httpMethod == "PATCH" {
            respond(body: """
            {"id":"run-2","name":"Edited run","sportType":"Run","startDateLocal":"\(today)T08:00:00","distanceInMeter":7000}
            """)
            return
        }
        if request.url!.path.hasSuffix("file-imports") {
            respond(body: #"{"fileImports":[{"id":"import-1","filename":"historical.fit","source":"file","status":"imported","activityId":"historical","importedOn":"2026-10-16"}],"pagination":{"page":1,"size":50,"total":1,"totalPages":1}}"#)
            return
        }
        let query = Dictionary(uniqueKeysWithValues: URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
        let page = Int(query["pagination[page]"]!)!
        Self.pages.append(page)
        Self.fromFilters.append(query["filters[from]"])
        precondition(query["pagination[size]"] == "100" && query["page"] == nil && query["limit"] == nil)
        if Self.mode == .cancelled {
            client!.urlProtocol(self, didFailWithError: URLError(.cancelled)); return
        }
        let fail = Self.mode == .serverFailure && page == 2
        let historical = Self.includeHistoricalImport && page == 2 && query["filters[from]"] == nil ? #",{"id":"historical","name":"Older import","sportType":"Run","startDateLocal":"2026-01-01T08:00:00","distanceInMeter":3000}"# : ""
        let body = fail ? #"{"error":"internal_error","message":"Fixture failure"}"# : """
        {"activities":[{"id":"run-\(page)","name":"Sample","sportType":"\(page == 1 ? "Run" : "VirtualRun")","startDateLocal":"\(today)T08:00:00","distanceInMeter":\(page == 1 ? 6000 : 5000),"gearId":"gear-shoe","location":{"city":"Demo city"}}\(historical)],"pagination":{"page":\(page),"size":100,"total":2,"totalPages":2}}
        """
        respond(status: fail ? 500 : 200, body: body)
    }
    private func respond(status: Int = 200, body: String) {
        client!.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client!.urlProtocol(self, didLoad: Data(body.utf8))
        client!.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct SessionRefreshContractTest {
    @MainActor static func main() async throws {
        UserDefaults.standard.setVolatileDomain(["dreeve.url": "https://overview-test.invalid"], forName: UserDefaults.argumentDomain)
        precondition(URLProtocol.registerClass(OverviewRefreshProtocol.self))
        defer { URLProtocol.unregisterClass(OverviewRefreshProtocol.self) }
        let store = try ActivityIndexStore(inMemory: true)
        let session = DreeveSession(activityIndexStore: store)
        await session.refreshInsights()
        precondition(session.didLoadInsights && session.insightsActivities.count == 2)
        precondition(OverviewRefreshProtocol.pages == [1, 2] && session.activitySyncError == nil)
        precondition(OverviewRefreshProtocol.fromFilters.allSatisfy { $0 == nil })
        precondition(session.insightsActivities.allSatisfy { $0.locationLabel == "Demo city" })
        let snapshot = session.goalProgress.snapshot!
        precondition(GoalEngine.value(sport: "Run", metric: .distance, period: GoalCalendar.period(.monthly), activities: snapshot.activities) == 11000)

        // Goals/Overview share a just-completed sync: no second month-long fetch.
        OverviewRefreshProtocol.pages = []
        await session.refreshGoals()
        await session.refreshInsights()
        precondition(OverviewRefreshProtocol.pages.isEmpty)
        let gear = try await session.indexedActivities(gearID: "gear-shoe")
        precondition(gear.count == 2 && OverviewRefreshProtocol.pages.isEmpty)

        // Force a delta without waiting for the coalescing throttle.
        OverviewRefreshProtocol.fromFilters = []
        await session.syncActivityIndex(bypassThrottle: true)
        let today = ActivityDates.calendarDate.string(from: .now)
        precondition(OverviewRefreshProtocol.fromFilters == [GoalCalendar.addingDays(-14, to: today), GoalCalendar.addingDays(-14, to: today)])

        // Cancel the caller before its body executes. The session-owned fetch survives.
        OverviewRefreshProtocol.pages = []
        let caller = Task { await session.refreshInsights(forceFullReconcile: true) }
        caller.cancel()
        await caller.value
        precondition(OverviewRefreshProtocol.pages == [1, 2])
        precondition(session.errorMessage == nil && !session.isLoadingInsights)

        OverviewRefreshProtocol.mode = .cancelled
        await session.refreshInsights(forceFullReconcile: true)
        precondition(session.activitySyncError == nil && session.insightsActivities.count == 2 && !session.isLoadingInsights)

        OverviewRefreshProtocol.mode = .serverFailure
        await session.refreshInsights(forceFullReconcile: true)
        precondition(session.activitySyncError?.contains("500") == true)
        precondition(session.insightsActivities.count == 2 && session.goalProgress.snapshot?.activities.count == 2)
        precondition(!session.isLoadingInsights && !session.isSyncingActivityIndex)
        OverviewRefreshProtocol.mode = .success
        await session.refreshInsights(forceFullReconcile: true)
        precondition(session.activitySyncError == nil && session.insightsActivities.count == 2)

        // A new session can immediately show complete saved data before any network call.
        let relaunched = DreeveSession(activityIndexStore: store)
        OverviewRefreshProtocol.pages = []
        await relaunched.loadCachedActivityIndex()
        precondition(relaunched.didLoadInsights && relaunched.insightsActivities.count == 2 && OverviewRefreshProtocol.pages.isEmpty)

        // Import completion must force full history so backdated FIT workouts are indexed.
        session.notePendingImport(filename: "historical.fit")
        OverviewRefreshProtocol.includeHistoricalImport = true
        OverviewRefreshProtocol.fromFilters = []
        await session.refreshGoals()
        let scope = GoalEngine.instanceID(URL(string: "https://overview-test.invalid")!)
        let importedRows = try await store.queryAll(instanceHash: scope)
        precondition(importedRows.contains { $0.id == "historical" })
        precondition(OverviewRefreshProtocol.fromFilters == [nil, nil])
        OverviewRefreshProtocol.pages = []

        // PATCH/DELETE immediately affect local gear, dashboard and combined goals without scans.
        _ = try await session.saveActivity("run-2", patch: ActivityPatch(name: "Edited run", sportType: "Run", description: "", gear: .remove))
        let afterPatch = try await session.indexedActivities(gearID: "gear-shoe")
        precondition(afterPatch.map(\.id) == ["run-1"])
        precondition(GoalEngine.value(sport: "Run", metric: .distance, period: GoalCalendar.period(.monthly), activities: session.goalProgress.snapshot!.activities) == 13000)
        try await session.removeActivity("run-1")
        precondition(session.insightsActivities.map(\.id) == ["run-2"] && OverviewRefreshProtocol.pages.isEmpty)
        let remainingGear = try await session.indexedActivities(gearID: "gear-shoe")
        precondition(remainingGear.isEmpty)
        // Reopening old data offline must preserve the sync date used by streak coverage.
        let savedDay = GoalCalendar.addingDays(-8, to: GoalCalendar.today())
        let savedDate = GoalCalendar.formatter().date(from: savedDay)!
        let savedRows = try await store.queryAll(instanceHash: scope)
        _ = try await store.finalizeFullReconcile(instanceHash: scope, authoritativeActivityIds: Set(savedRows.map(\.id)), now: savedDate)
        let offline = DreeveSession(activityIndexStore: store)
        await offline.loadCachedActivityIndex()
        precondition(offline.goalProgress.snapshot?.streakHistory?.throughDay == savedDay)
        precondition(OverviewRefreshProtocol.pages.isEmpty, "Cached history reload makes no API request")
        print("Session/index tests passed: shared full/delta refresh, real API query names, local gear/location, cached relaunch, combined goals, cancellation, failure/retry, and write-through edits/deletions.")
    }
}
