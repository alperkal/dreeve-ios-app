import Foundation

// Mock Page Fetcher for deterministic contract testing
actor MockActivityPageFetcher: ActivityPageFetching {
    var pages: [Int: [ActivitySummaryRecord]] = [:]
    var failOnPage: Int?
    private(set) var recordedRequests: [(page: Int, limit: Int, from: String?, to: String?)] = []
    private var pausePage: Int?
    private var pauseWaiter: CheckedContinuation<Void, Never>?
    private var releasePage: CheckedContinuation<Void, Never>?
    private var paused = false

    func pause(at page: Int) { pausePage = page; paused = false }
    func waitUntilPaused() async {
        if paused { return }
        await withCheckedContinuation { pauseWaiter = $0 }
    }
    func resume() { releasePage?.resume(); releasePage = nil; pausePage = nil }


    init(pages: [Int: [ActivitySummaryRecord]], failOnPage: Int? = nil) {
        self.pages = pages
        self.failOnPage = failOnPage
    }

    func setPages(_ newPages: [Int: [ActivitySummaryRecord]], failOnPage: Int? = nil) {
        self.pages = newPages
        self.failOnPage = failOnPage
    }

    func clearRequests() {
        recordedRequests.removeAll()
    }

    func fetchActivitiesPage(
        page: Int,
        limit: Int,
        fromDateFilter: String?,
        toDateFilter: String?
    ) async throws -> ActivityPageResponse {
        recordedRequests.append((page, limit, fromDateFilter, toDateFilter))
        if let failOnPage, page == failOnPage {
            throw URLError(.networkConnectionLost)
        }
        let totalPages = max(1, pages.keys.max() ?? 1)
        let items = pages[page] ?? []
        if pausePage == page {
            paused = true; pauseWaiter?.resume(); pauseWaiter = nil
            await withCheckedContinuation { releasePage = $0 }
        }
        return ActivityPageResponse(activities: items, currentPage: page, totalPages: totalPages)
    }
}

@main
struct ActivityIndexContractTest {
    static func assertTrue(_ condition: @autoclosure () -> Bool, _ message: String, file: StaticString = #file, line: UInt = #line) {
        if !condition() {
            fputs("FAIL [\(file):\(line)]: \(message)\n", stderr)
            exit(1)
        }
    }

    static func makeSample(
        id: String,
        date: String,
        sport: String = "Run",
        distance: Double = 10_000,
        gearId: String? = nil
    ) -> ActivitySummaryRecord {
        ActivitySummaryRecord(
            id: id,
            name: "Workout \(id)",
            sportType: sport,
            startDateLocal: date,
            distanceMeters: distance,
            movingTimeSeconds: 3000,
            elapsedTimeSeconds: 3100,
            elevationGainMeters: 85,
            gearId: gearId
        )
    }

    static func main() async throws {
        print("Running ActivityIndexContractTest...")

        // 1. Wall-clock date extraction without timezone drift
        let key1 = ActivitySummaryRecord.extractWallClockDayKey(from: "2026-10-12T23:45:00+03:00")
        assertTrue(key1 == "2026-10-12", "Expected wall-clock date 2026-10-12, got \(key1)")
        let keyInvalid = ActivitySummaryRecord.extractWallClockDayKey(from: "invalid-date")
        assertTrue(keyInvalid == "0000-00-00", "Invalid date should fallback to 0000-00-00")

        assertTrue(ActivitySummaryRecord.extractWallClockDayKey(from: "2026-02-30T12:00:00") == "0000-00-00", "Reject invalid calendar days")
        assertTrue(ActivitySyncEngine.shiftDayKey("2026-02-30", byDays: -14) == nil, "Invalid date math must fail")
        assertTrue(ActivitySyncEngine.shiftDayKey("2026-03-30", byDays: -14) == "2026-03-16", "UTC arithmetic survives DST")

        let travelInstant = ISO8601DateFormatter().date(from: "2026-10-18T23:30:00Z")!
        assertTrue(GoalCalendar.today(now: travelInstant, timeZone: TimeZone(identifier: "Europe/Vienna")!) == "2026-10-19", "Use the current device timezone for today")
        assertTrue(GoalCalendar.today(now: travelInstant, timeZone: TimeZone(identifier: "America/Los_Angeles")!) == "2026-10-18", "Travel must not shift recorded activity dates")

        // 2. Partial Cold Backfill Failure Does Not Mark Complete or Lose Earlier Pages
        let store = try ActivityIndexStore(inMemory: true)
        let engine = ActivitySyncEngine(store: store)
        let hashA = "instance-hash-alpha"

        let page1 = [
            makeSample(id: "act-3", date: "2026-10-15T08:00:00Z", gearId: "gear-ghost16"),
            makeSample(id: "act-2", date: "2026-10-10T08:00:00Z", gearId: "gear-ghost16")
        ]
        let page2 = [
            makeSample(id: "act-1", date: "2026-09-01T08:00:00Z", gearId: "gear-pegasus")
        ]

        let failingFetcher = MockActivityPageFetcher(pages: [1: page1, 2: page2], failOnPage: 2)
        var didThrow = false
        do {
            _ = try await engine.sync(instanceHash: hashA, fetcher: failingFetcher)
        } catch {
            didThrow = true
        }
        assertTrue(didThrow, "Expected page 2 failure to throw")
        let statusAfterFail = try await store.cursorStatus(instanceHash: hashA)
        assertTrue(!statusAfterFail.completed, "Backfill must remain incomplete after page 2 error")
        assertTrue(statusAfterFail.count == 2, "Page 1 records should still be persisted")

        // 3. Resumed Cold Backfill Completes All Pages & Enables Warm Delta Mode
        await failingFetcher.setPages([1: page1, 2: page2], failOnPage: nil)
        await failingFetcher.clearRequests()

        let coldResult = try await engine.sync(instanceHash: hashA, fetcher: failingFetcher)
        assertTrue(
            coldResult == .coldBackfillCompleted(totalIndexed: 3, prunedCount: 0, pagesFetched: 2),
            "Unexpected cold backfill result: \(coldResult)"
        )

        // 4. Subsequent Sync Uses Warm Delta with 14-Day Lookback (2026-10-15 -> 2026-10-01)
        let newActivity = makeSample(id: "act-4", date: "2026-10-16T07:30:00Z", gearId: "gear-ghost16")
        await failingFetcher.setPages([1: [newActivity, page1[0], page1[1]]], failOnPage: nil)
        await failingFetcher.clearRequests()

        let warmResult = try await engine.sync(instanceHash: hashA, fetcher: failingFetcher)
        assertTrue(
            warmResult == .warmDeltaCompleted(upsertedCount: 3, pagesFetched: 1, fromDateFilter: "2026-10-01"),
            "Expected warm delta from 2026-10-01, got \(warmResult)"
        )
        let reqs = await failingFetcher.recordedRequests
        assertTrue(reqs.count == 1 && reqs[0].from == "2026-10-01", "Warm delta should only fetch 1 page with from filter")

        // 5. Instant Local Gear Filtering & Write-Through PATCH/DELETE
        let ghostActivities = try await store.queryByGear(instanceHash: hashA, gearId: "gear-ghost16")
        assertTrue(ghostActivities.map(\.id) == ["act-4", "act-3", "act-2"], "Expected 3 Ghost 16 activities in reverse date order")

        // Simulate PATCH removing gear from act-3
        let act3NoGear = makeSample(id: "act-3", date: "2026-10-15T08:00:00Z", gearId: nil)
        try await store.applyWriteThroughEdit(instanceHash: hashA, updated: act3NoGear)
        let ghostAfterPatch = try await store.queryByGear(instanceHash: hashA, gearId: "gear-ghost16")
        assertTrue(ghostAfterPatch.map(\.id) == ["act-4", "act-2"], "Write-through nil gearId must immediately update gear query")

        // Simulate DELETE of act-4
        try await store.applyWriteThroughDelete(instanceHash: hashA, activityId: "act-4")
        let ghostAfterDelete = try await store.queryByGear(instanceHash: hashA, gearId: "gear-ghost16")
        assertTrue(ghostAfterDelete.map(\.id) == ["act-2"], "Write-through delete must immediately remove activity")

        // 6. Cross-Instance Isolation
        let hashB = "instance-hash-bravo"
        let bravoList = try await store.queryAll(instanceHash: hashB)
        assertTrue(bravoList.isEmpty, "Second Dreeve deployment instance must not see first instance activities")

        // 7. Full Reconcile Prunes Remotely Deleted Orphans
        // Server now only has act-2 (act-1 was deleted on web UI)
        await failingFetcher.setPages([1: [page1[1]]], failOnPage: nil)
        let reconcileResult = try await engine.sync(instanceHash: hashA, fetcher: failingFetcher, forceFullReconcile: true)
        assertTrue(
            reconcileResult == .coldBackfillCompleted(totalIndexed: 1, prunedCount: 2, pagesFetched: 1),
            "Expected 2 orphans pruned during forced full reconcile, got \(reconcileResult)"
        )

        // Empty successful deltas prune recent removals, but keep older history and
        // the boundary day where server timezone filtering may be ambiguous.
        let rangeStore = try ActivityIndexStore(inMemory: true)
        let rangeEngine = ActivitySyncEngine(store: rangeStore)
        let newest = makeSample(id: "newest", date: "2026-10-16T08:00:00")
        let boundary = makeSample(id: "boundary", date: "2026-10-02T08:00:00")
        let old = makeSample(id: "old", date: "2026-01-01T08:00:00")
        let rangeFetcher = MockActivityPageFetcher(pages: [1: [newest, boundary, old]])
        let fixedNow = GoalCalendar.formatter().date(from: "2026-10-16")!
        _ = try await rangeEngine.sync(instanceHash: hashA, fetcher: rangeFetcher, now: fixedNow)
        let priorSync = try await rangeStore.lastSuccessfulSync(instanceHash: hashA)
        await rangeFetcher.setPages([1: [makeSample(id: "uncommitted", date: "2026-10-17T08:00:00")], 2: [newest]], failOnPage: 2)
        do { _ = try await rangeEngine.sync(instanceHash: hashA, fetcher: rangeFetcher, now: fixedNow); assertionFailure("Delta failure accepted") }
        catch {}
        let afterDeltaFailure = try await rangeStore.queryAll(instanceHash: hashA)
        assertTrue(afterDeltaFailure.count == 3 && !afterDeltaFailure.contains { $0.id == "uncommitted" }, "Failed delta must be atomic")
        let failureSync = try await rangeStore.lastSuccessfulSync(instanceHash: hashA)
        assertTrue(failureSync == priorSync, "Failed delta must not advance freshness")
        await rangeFetcher.setPages([1: []])
        _ = try await rangeEngine.sync(instanceHash: hashA, fetcher: rangeFetcher, now: fixedNow)
        let retained = try await rangeStore.queryAll(instanceHash: hashA)
        assertTrue(Set(retained.map(\.id)) == ["boundary", "old"], "Only authoritative delta interior is pruned")

        // A local deletion while a full response is paused cannot be resurrected.
        await rangeFetcher.setPages([1: [boundary, old]])
        await rangeFetcher.pause(at: 1)
        let racing = Task { try await rangeEngine.sync(instanceHash: hashA, fetcher: rangeFetcher, forceFullReconcile: true, now: fixedNow) }
        await rangeFetcher.waitUntilPaused()
        try await rangeStore.applyWriteThroughDelete(instanceHash: hashA, activityId: "old")
        await rangeFetcher.resume()
        do { _ = try await racing.value; assertionFailure("Stale response accepted after delete") }
        catch ActivitySyncError.changedDuringSync {}
        let afterRace = try await rangeStore.queryAll(instanceHash: hashA)
        let raceStatus = try await rangeStore.cursorStatus(instanceHash: hashA)
        assertTrue(!afterRace.contains { $0.id == "old" } && !raceStatus.completed, "Mutation invalidates stale full scan")

        // Coalesced callers share one in-flight scan, even if one caller is cancelled.
        await rangeFetcher.setPages([1: [boundary]])
        await rangeFetcher.clearRequests()
        await rangeFetcher.pause(at: 1)
        let firstCaller = Task { try await rangeEngine.sync(instanceHash: hashA, fetcher: rangeFetcher, now: fixedNow) }
        await rangeFetcher.waitUntilPaused()
        firstCaller.cancel()
        let secondCaller = Task { try await rangeEngine.sync(instanceHash: hashA, fetcher: rangeFetcher, now: fixedNow) }
        await rangeFetcher.resume()
        _ = try await firstCaller.value
        _ = try await secondCaller.value
        let requestsAfterRace = await rangeFetcher.recordedRequests
        assertTrue(requestsAfterRace.count == 1, "Concurrent callers must share the scan")

        // Full reconciliation runs periodically, not just on manual refresh.
        await rangeFetcher.clearRequests()
        _ = try await rangeEngine.sync(instanceHash: hashA, fetcher: rangeFetcher, now: fixedNow.addingTimeInterval(8 * 86400))
        let periodicRequests = await rangeFetcher.recordedRequests
        assertTrue(periodicRequests.first?.from == nil, "Overdue reconciliation must scan all history")

        let futureStore = try ActivityIndexStore(inMemory: true)
        let futureEngine = ActivitySyncEngine(store: futureStore)
        let futureFetcher = MockActivityPageFetcher(pages: [1: [makeSample(id: "future", date: "2027-12-01T08:00:00")]])
        _ = try await futureEngine.sync(instanceHash: hashA, fetcher: futureFetcher, now: fixedNow)
        await futureFetcher.clearRequests()
        _ = try await futureEngine.sync(instanceHash: hashA, fetcher: futureFetcher, now: fixedNow)
        let futureRequests = await futureFetcher.recordedRequests
        assertTrue(futureRequests.first?.from == "2026-10-02", "Future-dated workouts cannot advance delta past today")

        // Malformed pagination never marks a backfill complete or prunes history.
        do { _ = try await rangeEngine.sync(instanceHash: hashA, fetcher: MalformedFetcher(), forceFullReconcile: true, now: fixedNow); assertionFailure("Bad page accepted") }
        catch APIError.decoding {}
        let malformedStatus = try await rangeStore.cursorStatus(instanceHash: hashA)
        assertTrue(!malformedStatus.completed && malformedStatus.count == 1, "Invalid pagination keeps saved rows")

        // A write-through on another instance cannot see or modify this instance's row.
        try await rangeStore.applyWriteThroughEdit(instanceHash: hashB, updated: makeSample(id: "boundary", date: "2026-10-03T08:00:00", gearId: "gear-other"))
        let isolatedA = try await rangeStore.queryAll(instanceHash: hashA)
        let isolatedB = try await rangeStore.queryAll(instanceHash: hashB)
        assertTrue(isolatedA.count == 1 && isolatedA[0].startDateLocal != isolatedB[0].startDateLocal, "Same ID is scoped per deployment")

        // Persistent SQLite storage survives store recreation, with backup exclusion.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let diskURL = directory.appendingPathComponent("ActivityIndex.store")
        var disk: ActivityIndexStore? = try ActivityIndexStore(customStoreURL: diskURL)
        try await disk!.upsertBatch(instanceHash: hashA, records: [newest, newest])
        _ = try await disk!.finalizeFullReconcile(instanceHash: hashA, authoritativeActivityIds: [newest.id])
        disk = nil
        let restored = try ActivityIndexStore(customStoreURL: diskURL)
        let saved = try await restored.queryAll(instanceHash: hashA)
        let savedStatus = try await restored.cursorStatus(instanceHash: hashA)
        assertTrue(saved == [newest] && savedStatus.completed, "Restore durable cached summary and cursor")
        let backupExcluded = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        assertTrue(backupExcluded == true, "Exclude the SQLite directory and sidecars from backup")

        print("PASS: ActivityIndexContractTest (pagination, cold/delta failure, lookback, pruning, mutations, concurrency, isolation, persistence and backup exclusion)")
    }
}

private struct MalformedFetcher: ActivityPageFetching {
    func fetchActivitiesPage(page: Int, limit: Int, fromDateFilter: String?, toDateFilter: String?) async throws -> ActivityPageResponse {
        ActivityPageResponse(activities: [], currentPage: page + 1, totalPages: 2)
    }
}
