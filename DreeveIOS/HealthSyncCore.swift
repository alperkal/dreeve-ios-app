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
}

enum HealthSyncState: String, Codable {
    case queued, imported, skipped, failed, uncertain, needsDetails
    var label: String {
        switch self {
        case .queued: return "Queued for import"
        case .imported: return "Synced"
        case .skipped: return "Already imported (server)"
        case .failed: return "Failed — select to retry"
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
