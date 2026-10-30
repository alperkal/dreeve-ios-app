import Foundation

struct HealthWorkoutSummary: Codable, Identifiable {
    let id: UUID
    let sportType: String
    let start: Date
    let end: Date
    let duration: Double
    let distance: Double?
    let calories: Double?
    let source: String
    let timeZoneIdentifier: String

    var filename: String { "apple-health-\(id.uuidString.lowercased()).fit" }
    var legacyFilename: String { "apple-health-\(id.uuidString.lowercased()).tcx" }
    var importFilenames: [String] { [filename, legacyFilename] }
}

struct HealthTrackpoint {
    let date: Date
    var latitude: Double? = nil
    var longitude: Double? = nil
    var altitude: Double? = nil
    var heartRate: Int? = nil
    var speed: Double? = nil
    var cadence: Double? = nil // FIT cycles/min; running steps/min divided by two
    var power: Double? = nil // watts
}

struct HealthMetricSample {
    let start: Date
    let end: Date
    let value: Double
}

/// Resample only covered measurement intervals onto FIT's one-second timeline.
/// Overlapping/duplicate readings never add together; missing intervals stay absent.
enum HealthMetricTimeline {
    static func runningCadence(_ steps: [HealthMetricSample]) -> [HealthMetricSample] {
        steps.compactMap { sample in
            let duration = sample.end.timeIntervalSince(sample.start)
            guard duration.isFinite, duration > 0, sample.value.isFinite, sample.value >= 0 else { return nil }
            return HealthMetricSample(start: sample.start, end: sample.end, value: sample.value * 30 / duration)
        }
    }

    static func seconds(_ samples: [HealthMetricSample], workout: HealthWorkoutSummary,
                        events: [HealthTimerEvent], upperBound: Double) -> [Date: Double] {
        struct Bucket { var total = 0.0; var duration = 0.0 }
        var buckets: [Int: Bucket] = [:]
        var previousEnd = workout.start.timeIntervalSince1970
        let pauses = events.filter { $0.date >= workout.start && $0.date <= workout.end }.sorted { $0.date < $1.date }
        var pausedIntervals: [DateInterval] = []
        var pauseStart: Date?
        for event in pauses {
            if event.isPaused {
                if pauseStart == nil { pauseStart = event.date }
            } else if let start = pauseStart {
                pausedIntervals.append(DateInterval(start: start, end: event.date)); pauseStart = nil
            }
        }
        if let start = pauseStart { pausedIntervals.append(DateInterval(start: start, end: workout.end)) }
        // A deterministic single series avoids double-counting overlapping Health samples.
        for sample in samples.sorted(by: { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }) {
            guard sample.value.isFinite, sample.value >= 0, sample.value < upperBound,
                  sample.start.timeIntervalSince1970.isFinite, sample.end.timeIntervalSince1970.isFinite,
                  sample.end >= sample.start else { continue }
            let start = max(sample.start.timeIntervalSince1970, workout.start.timeIntervalSince1970, previousEnd)
            let rawEnd = sample.end == sample.start ? sample.start.timeIntervalSince1970 + 1 : sample.end.timeIntervalSince1970
            let end = min(rawEnd, workout.end.timeIntervalSince1970)
            guard end > start else { continue }
            previousEnd = end
            for second in Int(floor(start))..<Int(ceil(end)) {
                let from = max(Double(second), start), through = min(Double(second + 1), end)
                let pausedDuration = pausedIntervals.reduce(0.0) { duration, interval in
                    duration + max(0, min(through, interval.end.timeIntervalSince1970) - max(from, interval.start.timeIntervalSince1970))
                }
                let covered = through - from - pausedDuration
                // Do not turn paused time into zero readings or carry data across gaps.
                guard covered > 0 else { continue }
                var bucket = buckets[second] ?? Bucket()
                bucket.total += sample.value * covered
                bucket.duration += covered
                buckets[second] = bucket
            }
        }
        return Dictionary(uniqueKeysWithValues: buckets.map { (Date(timeIntervalSince1970: Double($0.key)), $0.value.total / $0.value.duration) })
    }
}

enum HealthSyncState: String, Codable {
    case queued, imported, skipped, failed, uncertain, needsDetails, deleted
    var label: String {
        switch self {
        case .queued: return "Queued for import"
        case .imported: return "Synced"
        case .skipped: return "Already imported (server)"
        case .failed: return "Failed — select to retry"
        case .deleted: return "Deleted from Dreeve — select to re-import"
        case .uncertain: return "Upload unconfirmed — refresh status"
        case .needsDetails: return "Imported — finishing details"
        }
    }
}

struct HealthSyncRecord: Codable, Identifiable {
    let server: String
    let workout: HealthWorkoutSummary
    var state: HealthSyncState
    var activityID: String?
    var message: String?
    // Old journal entries omitted this field and used TCX. Keep their exact import
    // filename during reconciliation; new uploads explicitly record the FIT name.
    var uploadFilename: String? = nil
    var preview: HealthImportPreview? = nil
    var feedHandoffPending: Bool? = nil
    var filename: String { uploadFilename ?? workout.legacyFilename }
    var id: String { server + "|" + workout.id.uuidString }
}

/// A compact local-only route, captured from the already-authorized FIT export.
/// Stored in the protected import journal, never the activity index or CloudKit.
struct HealthImportPreview: Codable {
    let route: [[Double]]
    init(samples: [HealthTrackpoint]) {
        let coordinates = samples.sorted { $0.date < $1.date }.compactMap { sample -> [Double]? in
            guard let lat = sample.latitude, let lon = sample.longitude,
                  lat.isFinite, lon.isFinite, abs(lat) <= 90, abs(lon) <= 180 else { return nil }
            return [lat, lon]
        }
        // Bound journal size while preserving both endpoints of long recordings.
        if coordinates.count <= 2000 { route = coordinates }
        else {
            route = (0..<2000).map { coordinates[$0 * (coordinates.count - 1) / 1999] }
        }
    }
}

struct HealthWorkoutExport {
    let data: Data
    let preview: HealthImportPreview
}

enum HealthActivityFeedEntry: Identifiable {
    case activity(DreeveActivity)
    case importing(HealthSyncRecord)
    var id: String {
        switch self {
        case .activity(let activity): return activity.id
        case .importing(let record): return "health-import|" + record.id
        }
    }
    var summary: DreeveActivity {
        switch self {
        case .activity(let activity): return activity
        case .importing(let record): return record.feedActivity
        }
    }
}

extension HealthSyncRecord {
    var awaitingFeedHandoff: Bool {
        feedHandoffPending == true && [.imported, .skipped].contains(state)
    }
    var appearsInImportFeed: Bool {
        [.queued, .uncertain, .needsDetails].contains(state) || (state == .failed && preview != nil) || awaitingFeedHandoff
    }
    var feedStatus: String {
        switch state {
        case .queued: return "Import queue"
        case .uncertain: return "Upload unconfirmed"
        case .failed: return "Import failed"
        case .needsDetails: return "Finishing import"
        case .imported, .skipped: return "Imported · loading activity"
        default: return state.label
        }
    }
    /// A display-only summary. Never insert this into the server replica or goals.
    var feedActivity: DreeveActivity {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: workout.timeZoneIdentifier) ?? .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return DreeveActivity(id: "health-import|" + id, name: workout.sportType + " · Apple Health", description: nil,
            sportType: workout.sportType, startDateLocal: formatter.string(from: workout.start),
            distanceInMeter: workout.distance, elevationInMeter: nil, movingTimeInSeconds: Int(workout.duration),
            elapsedTimeInSeconds: Int(workout.end.timeIntervalSince(workout.start)), averageSpeedInKmPerHour: nil,
            maxSpeedInKmPerHour: nil, calories: workout.calories.map { Int($0.rounded()) }, averageHeartRate: nil,
            maxHeartRate: nil, averagePower: nil, averageCadence: nil, gearId: nil, location: nil,
            startLatLng: preview?.route.first, encodedPolyline: nil, images: nil)
    }
}

enum HealthActivityFeed {
    static func entries(activities: [DreeveActivity], records: [HealthSyncRecord], server: String,
                        knownActivities: [DreeveActivity] = []) -> [HealthActivityFeedEntry] {
        let knownIDs = Set((activities + knownActivities).map(\.id))
        var seen = Set<String>()
        let pending = records.filter { record in
            record.server == server && record.appearsInImportFeed &&
                (record.activityID.map { !knownIDs.contains($0) } ?? true)
        }.map(HealthActivityFeedEntry.importing)
        return (activities.map(HealthActivityFeedEntry.activity) + pending)
            .filter { seen.insert($0.id).inserted }
            .sorted { lhs, rhs in
                lhs.summary.startDateLocal == rhs.summary.startDateLocal ? lhs.id < rhs.id :
                    lhs.summary.startDateLocal > rhs.summary.startDateLocal
            }
    }
}

final class HealthSyncLedger {
    private let url: URL
    private(set) var records: [HealthSyncRecord]

    init(url: URL) throws {
        self.url = url
        records = FileManager.default.fileExists(atPath: url.path) ?
            try JSONDecoder().decode([HealthSyncRecord].self, from: Data(contentsOf: url)) : []
    }

    func save(_ record: HealthSyncRecord) throws {
        var next = records.filter { $0.id != record.id }
        next.append(record)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(next)
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: url, options: .atomic)
        #endif
        var excludedURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excludedURL.setResourceValues(values)
        records = next
    }
}

enum HealthSyncRecovery {
    static func verify(_ record: HealthSyncRecord, client: DreeveAPIClient) async throws -> HealthSyncRecord {
        guard [.imported, .skipped, .needsDetails].contains(record.state),
              let id = record.activityID, !id.isEmpty else { return record }
        do { _ = try await client.activity(id); return record }
        catch APIError.http(404, _) { return deleted(record) }
        // Authorization, decoding, timeout and other server errors are not deletion evidence.
    }

    static func deleted(_ record: HealthSyncRecord) -> HealthSyncRecord {
        var updated = record
        updated.state = .deleted
        updated.activityID = nil
        updated.message = "The linked activity was deleted from Dreeve. Select this workout to import it again as FIT."
        return updated
    }
}

enum HealthImportHistory {
    static func find(client: DreeveAPIClient, filenames: [String]) async throws -> DreeveImport? {
        var latestFailure: DreeveImport?
        for filename in filenames {
            var page = 1
            while true {
                try Task.checkCancellation()
                let result = try await client.fileImports(page: page, size: 100, filename: filename)
                guard result.pagination.page == page,
                      !result.fileImports.isEmpty || page >= result.pagination.totalPages else {
                    throw APIError.decoding("Incomplete import history. Refresh status before retrying.")
                }
                // Server filename filtering is substring-based. Exhaust pages and prefer
                // any accepted import over a newer failed attempt of the same filename.
                for item in result.fileImports where item.filename == filename {
                    if ["success", "skipped"].contains(item.status), let id = item.activityId, !id.isEmpty {
                        do { _ = try await client.activity(id) }
                        catch APIError.http(404, _) { continue } // retained history of a deleted activity
                    }
                    if item.status != "failed" { return item }
                    if latestFailure == nil { latestFailure = item }
                }
                if page >= result.pagination.totalPages { break }
                page += 1
            }
        }
        return latestFailure
    }
}

enum HealthWorkoutMatcher {
    // Heuristic candidates always require the user's confirmation; never auto-link.
    static func candidates(for workout: HealthWorkoutSummary, activities: [DreeveActivity]) -> [DreeveActivity] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: workout.timeZoneIdentifier) ?? .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return activities.filter { activity in
            guard let start = formatter.date(from: String(activity.startDateLocal.prefix(19))) else { return false }
            // Include any sport at a near-identical time: older exporters may label sports differently.
            return abs(start.timeIntervalSince(workout.start)) <= 120
        }
    }
}

enum HealthSyncError: LocalizedError {
    case unavailable, invalidWorkout, fileModeRequired, serverChanged, storageUnavailable
    var errorDescription: String? {
        switch self {
        case .unavailable: return "Apple Health is not available on this device."
        case .invalidWorkout: return "This workout has an invalid or unsupported duration."
        case .fileModeRequired: return "Dreeve needs IMPORT_MODE=files to sync Apple Health workouts."
        case .serverChanged: return "The Dreeve connection changed. Reload workouts before syncing."
        case .storageUnavailable: return "Sync history could not be saved. Sync is paused to prevent duplicate uploads."
        }
    }
}

// Decisions are independent of import results: approval is durable, not proof of upload.
enum HealthDiscoveryAction: String, Codable { case approved, dismissed, later }
struct HealthDiscoveryDecision: Codable {
    let scope: String
    let workoutID: UUID
    let action: HealthDiscoveryAction
    let date: Date
    let routes: Bool
    let heartRate: Bool
}

final class HealthDiscoveryJournal {
    private let url: URL
    private(set) var decisions: [HealthDiscoveryDecision]
    init(url: URL) throws {
        self.url = url
        decisions = FileManager.default.fileExists(atPath: url.path) ?
            try JSONDecoder().decode([HealthDiscoveryDecision].self, from: Data(contentsOf: url)) : []
    }
    func decision(scope: String, id: UUID) -> HealthDiscoveryDecision? {
        decisions.first { $0.scope == scope && $0.workoutID == id }
    }
    func set(_ values: [HealthDiscoveryDecision]) throws {
        let keys = Set(values.map { $0.scope + "|" + $0.workoutID.uuidString })
        let next = decisions.filter { !keys.contains($0.scope + "|" + $0.workoutID.uuidString) } + values
        try persist(next)
    }
    func remove(scope: String, id: UUID) throws {
        try persist(decisions.filter { !($0.scope == scope && $0.workoutID == id) })
    }
    private func persist(_ next: [HealthDiscoveryDecision]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(next)
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: url, options: .atomic)
        #endif
        var path = url
        var flags = URLResourceValues()
        flags.isExcludedFromBackup = true
        try path.setResourceValues(flags)
        decisions = next
    }
}

enum HealthDiscoveryStatus: Equatable { case ready, unverified, review }
struct HealthDiscoveryEntry: Identifiable {
    let workout: HealthWorkoutSummary
    let status: HealthDiscoveryStatus
    var id: UUID { workout.id }
}

enum HealthDiscoveryPolicy {
    /// A rolling calendar month, not 30 * 24 hours (month lengths and DST vary).
    static func start(now: Date = .now, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .month, value: -1, to: now) ?? now
    }
    static func recent(_ workout: HealthWorkoutSummary, now: Date = .now, calendar: Calendar = .current) -> Bool {
        workout.start >= start(now: now, calendar: calendar) && workout.end <= now && workout.end > workout.start
    }
    static func suppress(record: HealthSyncRecord?) -> Bool {
        // Deletions and failed attempts belong in manual recovery, never automatic re-import.
        record != nil
    }
    static func mayPrompt(_ decision: HealthDiscoveryDecision?, now: Date = .now) -> Bool {
        guard let decision else { return true }
        return decision.action == .later && now.timeIntervalSince(decision.date) >= 86400
    }
}

enum HealthDiscoveryVerifier {
    static func entries(workouts: [HealthWorkoutSummary], records: [HealthSyncRecord], server: String,
                        client: DreeveAPIClient, now: Date = .now) async throws -> [HealthDiscoveryEntry] {
        let eligible = workouts.filter { workout in
            HealthDiscoveryPolicy.recent(workout, now: now) &&
            !HealthDiscoveryPolicy.suppress(record: records.first { $0.server == server && $0.workout.id == workout.id })
        }
        guard let earliest = eligible.map(\.start).min() else { return [] }
        // Include adjacent days for timezone differences when finding heuristic candidates.
        let from = ActivityDates.calendarDate.string(from: earliest.addingTimeInterval(-2 * 86400))
        var activities: [DreeveActivity] = []
        var page = 1
        var expected: Int?
        while true {
            try Task.checkCancellation()
            let result = try await client.activities(page: page, size: 100, from: from)
            guard result.pagination.page == page, result.pagination.totalPages >= 0,
                  result.pagination.totalPages == (expected ?? result.pagination.totalPages),
                  result.pagination.totalPages > 0 || result.activities.isEmpty,
                  !result.activities.isEmpty || (page == 1 && result.pagination.totalPages <= 1) else {
                throw APIError.decoding("Incomplete activity history. Import status could not be verified.")
            }
            expected = result.pagination.totalPages
            activities += result.activities
            if page >= result.pagination.totalPages { break }
            page += 1
        }
        var entries: [HealthDiscoveryEntry] = []
        for workout in eligible {
            try Task.checkCancellation()
            if let remote = try await HealthImportHistory.find(client: client, filenames: workout.importFilenames),
               remote.status != "failed" { continue }
            let matches = HealthWorkoutMatcher.candidates(for: workout, activities: activities)
            entries.append(HealthDiscoveryEntry(workout: workout, status: matches.isEmpty ? .ready : .review))
        }
        return entries
    }
}
