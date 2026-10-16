import Foundation
import SwiftData

// MARK: - Transfer DTO (Bridges your existing Models.swift Activity DTO)

public struct ActivitySummaryRecord: Sendable, Equatable {
    public let id: String
    public let name: String
    public let sportType: String
    public let startDateLocal: String
    public let localDayKey: String        // "YYYY-MM-DD"
    public let distanceMeters: Double
    public let movingTimeSeconds: Int
    public let elapsedTimeSeconds: Int
    public let elevationGainMeters: Double
    public let gearId: String?
    public let encodedPolyline: String?
    public let payload: Data?

    public init(
        id: String,
        name: String,
        sportType: String,
        startDateLocal: String,
        distanceMeters: Double,
        movingTimeSeconds: Int,
        elapsedTimeSeconds: Int,
        elevationGainMeters: Double,
        gearId: String?,
        encodedPolyline: String? = nil,
        payload: Data? = nil
    ) {
        self.id = id
        self.name = name
        self.sportType = sportType
        self.startDateLocal = startDateLocal
        self.localDayKey = Self.extractWallClockDayKey(from: startDateLocal)
        self.distanceMeters = max(0, distanceMeters)
        self.movingTimeSeconds = max(0, movingTimeSeconds)
        self.elapsedTimeSeconds = max(0, elapsedTimeSeconds)
        self.elevationGainMeters = max(0, elevationGainMeters)
        self.gearId = (gearId?.isEmpty == true) ? nil : gearId
        self.encodedPolyline = encodedPolyline
        self.payload = payload
    }

    /// Preserves the wall-clock YYYY-MM-DD prefix from ISO-8601 strings without shifting timezones.
    public static func extractWallClockDayKey(from isoString: String) -> String {
        GoalCalendar.localDay(isoString.trimmingCharacters(in: .whitespacesAndNewlines)) ?? "0000-00-00"
    }
}

// MARK: - SwiftData Schema

@Model
public final class IndexedActivity {
    @Attribute(.unique) public var scopedId: String
    public var instanceHash: String
    public var activityId: String
    public var name: String
    public var sportType: String
    public var startDateLocal: String
    public var localDayKey: String
    public var distanceMeters: Double
    public var movingTimeSeconds: Int
    public var elapsedTimeSeconds: Int
    public var elevationGainMeters: Double
    public var gearId: String?
    public var encodedPolyline: String?
    public var payload: Data?
    public var updatedAt: Date

    public init(instanceHash: String, record: ActivitySummaryRecord, now: Date = Date()) {
        self.scopedId = Self.makeScopedId(instanceHash: instanceHash, activityId: record.id)
        self.instanceHash = instanceHash
        self.activityId = record.id
        self.name = record.name
        self.sportType = record.sportType
        self.startDateLocal = record.startDateLocal
        self.localDayKey = record.localDayKey
        self.distanceMeters = record.distanceMeters
        self.movingTimeSeconds = record.movingTimeSeconds
        self.elapsedTimeSeconds = record.elapsedTimeSeconds
        self.elevationGainMeters = record.elevationGainMeters
        self.gearId = record.gearId
        self.encodedPolyline = record.encodedPolyline
        self.payload = record.payload
        self.updatedAt = now
    }

    public func apply(_ record: ActivitySummaryRecord, now: Date = Date()) {
        self.name = record.name
        self.sportType = record.sportType
        self.startDateLocal = record.startDateLocal
        self.localDayKey = record.localDayKey
        self.distanceMeters = record.distanceMeters
        self.movingTimeSeconds = record.movingTimeSeconds
        self.elapsedTimeSeconds = record.elapsedTimeSeconds
        self.elevationGainMeters = record.elevationGainMeters
        self.gearId = record.gearId
        if let poly = record.encodedPolyline {
            self.encodedPolyline = poly
        }
        self.payload = record.payload
        self.updatedAt = now
    }

    public func toRecord() -> ActivitySummaryRecord {
        ActivitySummaryRecord(
            id: activityId,
            name: name,
            sportType: sportType,
            startDateLocal: startDateLocal,
            distanceMeters: distanceMeters,
            movingTimeSeconds: movingTimeSeconds,
            elapsedTimeSeconds: elapsedTimeSeconds,
            elevationGainMeters: elevationGainMeters,
            gearId: gearId,
            encodedPolyline: encodedPolyline,
            payload: payload
        )
    }

    public static func makeScopedId(instanceHash: String, activityId: String) -> String {
        "\(instanceHash):\(activityId)"
    }
}

@Model
public final class InstanceSyncCursor {
    @Attribute(.unique) public var instanceHash: String
    public var newestLocalDayKey: String?
    public var fullBackfillCompleted: Bool
    public var lastDeltaSyncAt: Date?
    public var lastFullReconcileAt: Date?
    public var totalIndexedCount: Int

    public init(
        instanceHash: String,
        newestLocalDayKey: String? = nil,
        fullBackfillCompleted: Bool = false,
        lastDeltaSyncAt: Date? = nil,
        lastFullReconcileAt: Date? = nil,
        totalIndexedCount: Int = 0
    ) {
        self.instanceHash = instanceHash
        self.newestLocalDayKey = newestLocalDayKey
        self.fullBackfillCompleted = fullBackfillCompleted
        self.lastDeltaSyncAt = lastDeltaSyncAt
        self.lastFullReconcileAt = lastFullReconcileAt
        self.totalIndexedCount = totalIndexedCount
    }
}

// MARK: - Store Actor

public actor ActivityIndexStore {
    private let container: ModelContainer
    private var revisions: [String: Int] = [:]

    func mutationRevision(instanceHash: String) -> Int { revisions[instanceHash, default: 0] }
    private func checkRevision(_ expected: Int?, instance: String) throws {
        if let expected, expected != revisions[instance, default: 0] { throw ActivitySyncError.changedDuringSync }
    }

    public init(inMemory: Bool = false, customStoreURL: URL? = nil) throws {
        let schema = Schema([IndexedActivity.self, InstanceSyncCursor.self])
        let config: ModelConfiguration
        if inMemory {
            config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        } else if let customStoreURL {
            try FileManager.default.createDirectory(at: customStoreURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            var directory = customStoreURL.deletingLastPathComponent()
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
            config = ModelConfiguration(schema: schema, url: customStoreURL, cloudKitDatabase: .none)
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let storeDir = appSupport.appendingPathComponent("DreeveActivityIndex", isDirectory: true)
            try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            var mutableDir = storeDir
            try mutableDir.setResourceValues(resourceValues)
            let storeURL = storeDir.appendingPathComponent("ActivityIndex.store")
            config = ModelConfiguration(schema: schema, url: storeURL, cloudKitDatabase: .none)
        }
        self.container = try ModelContainer(for: schema, configurations: [config])
    }

    public func beginFullReconcile(instanceHash: String) throws {
        let context = ModelContext(container); context.autosaveEnabled = false
        let cursor = try fetchOrCreateCursor(instanceHash: instanceHash, in: context)
        cursor.fullBackfillCompleted = false
        try context.save()
    }

    // MARK: - Upsert Batch

    public func upsertBatch(
        instanceHash: String,
        records: [ActivitySummaryRecord],
        now: Date = Date(), expectedRevision: Int? = nil
    ) throws {
        try checkRevision(expectedRevision, instance: instanceHash)
        let context = ModelContext(container)
        context.autosaveEnabled = false

        // Deduplicate input batch by activity ID, preserving last occurrence
        var uniqueById: [String: ActivitySummaryRecord] = [:]
        for record in records {
            guard !record.id.isEmpty, record.localDayKey != "0000-00-00" else {
                throw APIError.decoding("Invalid activity ID or local date; saved activities were kept.")
            }
            uniqueById[record.id] = record
        }

        let existingDescriptor = FetchDescriptor<IndexedActivity>(
            predicate: #Predicate { $0.instanceHash == instanceHash }
        )
        let existingRows = try context.fetch(existingDescriptor)
        var existingMap: [String: IndexedActivity] = Dictionary(
            uniqueKeysWithValues: existingRows.map { ($0.activityId, $0) }
        )

        for (activityId, record) in uniqueById {
            if let existing = existingMap[activityId] {
                existing.apply(record, now: now)
            } else {
                let inserted = IndexedActivity(instanceHash: instanceHash, record: record, now: now)
                context.insert(inserted)
                existingMap[activityId] = inserted
            }
        }

        // Update cursor metadata
        let cursor = try fetchOrCreateCursor(instanceHash: instanceHash, in: context)
        let allValidDayKeys = existingMap.values
            .map(\.localDayKey)
            .filter { $0 != "0000-00-00" }
        cursor.newestLocalDayKey = allValidDayKeys.max()
        cursor.totalIndexedCount = existingMap.count
        try context.save()
    }

    // MARK: - Full Backfill Completion & Orphan Pruning

    public func finalizeFullReconcile(
        instanceHash: String,
        authoritativeActivityIds: Set<String>,
        now: Date = Date(), expectedRevision: Int? = nil
    ) throws -> Int {
        try checkRevision(expectedRevision, instance: instanceHash)
        let context = ModelContext(container)
        context.autosaveEnabled = false

        let descriptor = FetchDescriptor<IndexedActivity>(
            predicate: #Predicate { $0.instanceHash == instanceHash }
        )
        let allLocal = try context.fetch(descriptor)
        var prunedCount = 0
        var newestKey: String?

        for item in allLocal {
            if !authoritativeActivityIds.contains(item.activityId) {
                context.delete(item)
                prunedCount += 1
            } else if item.localDayKey != "0000-00-00" {
                if let currentMax = newestKey {
                    if item.localDayKey > currentMax { newestKey = item.localDayKey }
                } else {
                    newestKey = item.localDayKey
                }
            }
        }

        let cursor = try fetchOrCreateCursor(instanceHash: instanceHash, in: context)
        cursor.fullBackfillCompleted = true
        cursor.lastFullReconcileAt = now
        cursor.lastDeltaSyncAt = now
        cursor.newestLocalDayKey = newestKey
        cursor.totalIndexedCount = allLocal.count - prunedCount

        try context.save()
        return prunedCount
    }

    /// Commit a fully fetched delta in one transaction, pruning only its authoritative
    /// interior days. Boundary days retain a timezone safety buffer.
    public func finalizeDelta(instanceHash: String, records: [ActivitySummaryRecord], from: String,
                              now: Date = .now, expectedRevision: Int? = nil) throws {
        try checkRevision(expectedRevision, instance: instanceHash)
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let rows = try context.fetch(FetchDescriptor<IndexedActivity>(predicate: #Predicate { $0.instanceHash == instanceHash }))
        var map = Dictionary(uniqueKeysWithValues: rows.map { ($0.activityId, $0) })
        var unique: [String: ActivitySummaryRecord] = [:]
        for record in records where unique[record.id] == nil { unique[record.id] = record }
        for record in unique.values {
            guard !record.id.isEmpty, record.localDayKey != "0000-00-00" else { throw APIError.decoding("Invalid activity local date.") }
            if let row = map[record.id] { row.apply(record, now: now) }
            else { let row = IndexedActivity(instanceHash: instanceHash, record: record, now: now); context.insert(row); map[record.id] = row }
        }
        let interior = GoalCalendar.addingDays(1, to: from)
        for row in rows where row.localDayKey >= interior && unique[row.activityId] == nil {
            context.delete(row); map.removeValue(forKey: row.activityId)
        }
        let cursor = try fetchOrCreateCursor(instanceHash: instanceHash, in: context)
        cursor.totalIndexedCount = map.count
        cursor.newestLocalDayKey = map.values.map(\.localDayKey).max()
        cursor.lastDeltaSyncAt = now
        try context.save()
    }

    public func lastSuccessfulSync(instanceHash: String) throws -> Date? {
        let context = ModelContext(container)
        return try context.fetch(FetchDescriptor<InstanceSyncCursor>(predicate: #Predicate { $0.instanceHash == instanceHash })).first?.lastDeltaSyncAt
    }

    // MARK: - Write-Through Local Mutations (PATCH / DELETE)

    public func applyWriteThroughEdit(instanceHash: String, updated: ActivitySummaryRecord, now: Date = Date()) throws {
        revisions[instanceHash, default: 0] += 1
        try upsertBatch(instanceHash: instanceHash, records: [updated], now: now)
    }

    public func applyWriteThroughDelete(instanceHash: String, activityId: String) throws {
        revisions[instanceHash, default: 0] += 1
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let targetScopedId = IndexedActivity.makeScopedId(instanceHash: instanceHash, activityId: activityId)

        let descriptor = FetchDescriptor<IndexedActivity>(
            predicate: #Predicate { $0.scopedId == targetScopedId }
        )
        let matches = try context.fetch(descriptor)
        for match in matches {
            context.delete(match)
        }

        // Recompute cursor count & newest day key
        let remainingDescriptor = FetchDescriptor<IndexedActivity>(
            predicate: #Predicate { $0.instanceHash == instanceHash }
        )
        let remaining = try context.fetch(remainingDescriptor).filter { $0.activityId != activityId }
        let cursor = try fetchOrCreateCursor(instanceHash: instanceHash, in: context)
        cursor.totalIndexedCount = remaining.count
        cursor.newestLocalDayKey = remaining
            .map(\.localDayKey)
            .filter { $0 != "0000-00-00" }
            .max()

        try context.save()
    }

    /// Aggregate full, authoritative history without carrying routes/photos/payloads
    /// into the derived Goals cache. A partial backfill must not award a streak.
    func goalStreakHistory(instanceHash: String, throughDay: String) throws -> GoalStreakHistory? {
        guard try cursorStatus(instanceHash: instanceHash).completed else { return nil }
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<IndexedActivity>(predicate: #Predicate {
            $0.instanceHash == instanceHash && $0.localDayKey <= throughDay
        })
        descriptor.propertiesToFetch = [\.localDayKey, \.sportType, \.distanceMeters]
        var days: [String: GoalStreakDay] = [:]
        for activity in try context.fetch(descriptor) where activity.localDayKey != "0000-00-00" {
            let sport = GoalEngine.goalSport(activity.sportType)
            let key = activity.localDayKey + "|" + sport
            var day = days[key] ?? GoalStreakDay(day: activity.localDayKey, sport: sport, count: 0, meters: 0)
            day.count += 1
            day.meters += activity.distanceMeters.isFinite ? max(0, activity.distanceMeters) : 0
            days[key] = day
        }
        return GoalStreakHistory(throughDay: throughDay, days: days.values.sorted {
            $0.day == $1.day ? $0.sport < $1.sport : $0.day < $1.day
        })
    }

    // MARK: - Instant Local Queries

    public func queryByGear(instanceHash: String, gearId: String) throws -> [ActivitySummaryRecord] {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<IndexedActivity>(
            predicate: #Predicate { $0.instanceHash == instanceHash && $0.gearId == gearId },
            sortBy: [
                SortDescriptor(\.startDateLocal, order: .reverse),
                SortDescriptor(\.activityId, order: .reverse)
            ]
        )
        return try context.fetch(descriptor).map { $0.toRecord() }
    }

    public func queryDateRange(
        instanceHash: String,
        fromDayKeyInclusive: String,
        toDayKeyInclusive: String
    ) throws -> [ActivitySummaryRecord] {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<IndexedActivity>(
            predicate: #Predicate {
                $0.instanceHash == instanceHash &&
                $0.localDayKey >= fromDayKeyInclusive &&
                $0.localDayKey <= toDayKeyInclusive
            },
            sortBy: [
                SortDescriptor(\.startDateLocal, order: .reverse),
                SortDescriptor(\.activityId, order: .reverse)
            ]
        )
        return try context.fetch(descriptor).map { $0.toRecord() }
    }

    public func queryAll(instanceHash: String) throws -> [ActivitySummaryRecord] {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<IndexedActivity>(
            predicate: #Predicate { $0.instanceHash == instanceHash },
            sortBy: [
                SortDescriptor(\.startDateLocal, order: .reverse),
                SortDescriptor(\.activityId, order: .reverse)
            ]
        )
        return try context.fetch(descriptor).map { $0.toRecord() }
    }

    public func cursorStatus(instanceHash: String) throws -> (completed: Bool, newestDayKey: String?, count: Int, lastReconcile: Date?) {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<InstanceSyncCursor>(
            predicate: #Predicate { $0.instanceHash == instanceHash }
        )
        guard let cursor = try context.fetch(descriptor).first else {
            return (false, nil, 0, nil)
        }
        return (cursor.fullBackfillCompleted, cursor.newestLocalDayKey, cursor.totalIndexedCount, cursor.lastFullReconcileAt)
    }

    private func fetchOrCreateCursor(instanceHash: String, in context: ModelContext) throws -> InstanceSyncCursor {
        let descriptor = FetchDescriptor<InstanceSyncCursor>(
            predicate: #Predicate { $0.instanceHash == instanceHash }
        )
        if let existing = try context.fetch(descriptor).first {
            return existing
        }
        let created = InstanceSyncCursor(instanceHash: instanceHash)
        context.insert(created)
        return created
    }
}
