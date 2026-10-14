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
    var filename: String { uploadFilename ?? workout.legacyFilename }
    var id: String { server + "|" + workout.id.uuidString }
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
