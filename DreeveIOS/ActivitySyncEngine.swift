import Foundation

struct ActivityPageResponse: Sendable {
    let activities: [ActivitySummaryRecord]
    let currentPage: Int
    let totalPages: Int
}

protocol ActivityPageFetching: Sendable {
    func fetchActivitiesPage(page: Int, limit: Int, fromDateFilter: String?, toDateFilter: String?) async throws -> ActivityPageResponse
}

enum SyncModeResult: Sendable, Equatable {
    case coldBackfillCompleted(totalIndexed: Int, prunedCount: Int, pagesFetched: Int)
    case warmDeltaCompleted(upsertedCount: Int, pagesFetched: Int, fromDateFilter: String)
}

enum ActivitySyncError: LocalizedError {
    case changedDuringSync
    var errorDescription: String? { "An activity changed during refresh. Refresh again to finish updating the index." }
}

actor ActivitySyncEngine {
    private let store: ActivityIndexStore
    private var running: [String: (id: UUID, full: Bool, task: Task<SyncModeResult, Error>)] = [:]

    init(store: ActivityIndexStore) { self.store = store }

    func sync(instanceHash: String, fetcher: any ActivityPageFetching,
              forceFullReconcile: Bool = false, now: Date = .now) async throws -> SyncModeResult {
        if let existing = running[instanceHash] {
            let value = try await existing.task.value
            if !forceFullReconcile || existing.full { return value }
            if case .coldBackfillCompleted = value { return value }
            // A manual full refresh queued behind a delta must still run in full.
            if running[instanceHash]?.id == existing.id { running[instanceHash] = nil }
            else if running[instanceHash] != nil {
                return try await sync(instanceHash: instanceHash, fetcher: fetcher, forceFullReconcile: true, now: now)
            }
        }
        let id = UUID()
        let task = Task { try await self.performSync(instanceHash: instanceHash, fetcher: fetcher,
                                                   force: forceFullReconcile, now: now) }
        running[instanceHash] = (id, forceFullReconcile, task)
        defer { if running[instanceHash]?.id == id { running[instanceHash] = nil } }
        return try await task.value
    }

    private func performSync(instanceHash: String, fetcher: any ActivityPageFetching,
                             force: Bool, now: Date) async throws -> SyncModeResult {
        let status = try await store.cursorStatus(instanceHash: instanceHash)
        let overdue = status.lastReconcile.map { now.timeIntervalSince($0) >= 7 * 86400 } ?? true
        let full = force || !status.completed || overdue || status.newestDayKey == nil
        let today = GoalCalendar.today(now: now)
        // A bad future-dated workout must not move the delta beyond current activities.
        let newest = status.newestDayKey.map { min($0, today) }
        let from = full ? nil : newest.flatMap { Self.shiftDayKey($0, byDays: -14) }
        if full { try await store.beginFullReconcile(instanceHash: instanceHash) }
        let revision = await store.mutationRevision(instanceHash: instanceHash)
        var page = 1
        var expectedPages: Int?
        var seen = Set<String>()
        var collected: [ActivitySummaryRecord] = []
        while true {
            try Task.checkCancellation()
            let response = try await fetcher.fetchActivitiesPage(page: page, limit: 100,
                                                                 fromDateFilter: from, toDateFilter: nil)
            guard response.currentPage == page, response.totalPages >= 0,
                  response.totalPages > 0 || response.activities.isEmpty,
                  response.totalPages == (expectedPages ?? response.totalPages),
                  !response.activities.isEmpty || (page == 1 && response.totalPages <= 1) else {
                throw APIError.decoding("Incomplete or changing activity pagination. Saved activities were kept; refresh again.")
            }
            expectedPages = response.totalPages
            // Newest-first API: first occurrence wins for overlapping page boundaries.
            let unique = response.activities.filter { seen.insert($0.id).inserted }
            if full {
                try await store.upsertBatch(instanceHash: instanceHash, records: unique, now: now, expectedRevision: revision)
            } else { collected += unique }
            if page >= response.totalPages { break }
            page += 1
        }
        try Task.checkCancellation()
        if full {
            let pruned = try await store.finalizeFullReconcile(instanceHash: instanceHash,
                authoritativeActivityIds: seen, now: now, expectedRevision: revision)
            let final = try await store.cursorStatus(instanceHash: instanceHash)
            return .coldBackfillCompleted(totalIndexed: final.count, prunedCount: pruned, pagesFetched: page)
        }
        guard let from else { throw APIError.decoding("Invalid activity sync date.") }
        try await store.finalizeDelta(instanceHash: instanceHash, records: collected, from: from, now: now, expectedRevision: revision)
        return .warmDeltaCompleted(upsertedCount: collected.count, pagesFetched: page, fromDateFilter: from)
    }

    static func shiftDayKey(_ day: String, byDays days: Int) -> String? {
        guard GoalCalendar.localDay(day + "T00:00:00") != nil else { return nil }
        return GoalCalendar.addingDays(days, to: day)
    }
}

extension DreeveAPIClient: ActivityPageFetching {
    func fetchActivitiesPage(page: Int, limit: Int, fromDateFilter: String?, toDateFilter: String?) async throws -> ActivityPageResponse {
        // Preserve Dreeve's actual bracketed v1 query names, not ?page=&limit=.
        let result = try await activities(page: page, size: limit, from: fromDateFilter, to: toDateFilter)
        return ActivityPageResponse(activities: try result.activities.map(ActivitySummaryRecord.init),
                                    currentPage: result.pagination.page, totalPages: result.pagination.totalPages)
    }
}

extension ActivitySummaryRecord {
    init(_ activity: DreeveActivity) throws {
        guard GoalCalendar.localDay(activity.startDateLocal) != nil else { throw APIError.decoding("Invalid activity local date.") }
        self.init(id: activity.id, name: activity.name, sportType: activity.sportType,
                  startDateLocal: activity.startDateLocal, distanceMeters: activity.distanceInMeter ?? 0,
                  movingTimeSeconds: activity.movingTimeInSeconds ?? 0, elapsedTimeSeconds: activity.elapsedTimeInSeconds ?? 0,
                  elevationGainMeters: activity.elevationInMeter ?? 0, gearId: activity.gearId,
                  encodedPolyline: activity.encodedPolyline, payload: try JSONEncoder().encode(activity))
    }
    var activity: DreeveActivity {
        if let payload, let decoded = try? JSONDecoder().decode(DreeveActivity.self, from: payload) { return decoded }
        return DreeveActivity(id: id, name: name, description: nil, sportType: sportType, startDateLocal: startDateLocal,
            distanceInMeter: distanceMeters, elevationInMeter: elevationGainMeters, movingTimeInSeconds: movingTimeSeconds,
            elapsedTimeInSeconds: elapsedTimeSeconds, averageSpeedInKmPerHour: nil, maxSpeedInKmPerHour: nil, calories: nil,
            averageHeartRate: nil, maxHeartRate: nil, averagePower: nil, averageCadence: nil, gearId: gearId,
            location: nil, startLatLng: nil, encodedPolyline: encodedPolyline, hasGpx: nil, images: nil)
    }
}
