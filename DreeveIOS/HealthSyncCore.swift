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

    var filename: String { "apple-health-\(id.uuidString.lowercased()).tcx" }
}

struct HealthTrackpoint {
    let date: Date
    var latitude: Double? = nil
    var longitude: Double? = nil
    var altitude: Double? = nil
    var heartRate: Int? = nil
}

enum HealthTCXExporter {
    static func data(workout: HealthWorkoutSummary, samples: [HealthTrackpoint]) throws -> Data {
        let elapsed = workout.end.timeIntervalSince(workout.start)
        guard elapsed > 0, elapsed <= 7 * 86400, workout.duration > 0,
              workout.duration.isFinite, workout.duration <= elapsed + 1 else {
            throw HealthSyncError.invalidWorkout
        }
        // Time-only markers let Dreeve import indoor workouts and sparse recordings.
        // These markers contain no invented GPS, heart rate, or distance readings.
        var points: [Double: HealthTrackpoint] = [:]
        for offset in stride(from: 0.0, to: elapsed, by: 30.0) {
            points[offset] = HealthTrackpoint(date: workout.start.addingTimeInterval(offset))
        }
        points[elapsed] = HealthTrackpoint(date: workout.end)
        for point in samples where point.date >= workout.start && point.date <= workout.end {
            let offset = point.date.timeIntervalSince(workout.start)
            var existing = points[offset] ?? HealthTrackpoint(date: point.date)
            if let latitude = point.latitude, let longitude = point.longitude,
               latitude.isFinite, longitude.isFinite, abs(latitude) <= 90, abs(longitude) <= 180 {
                existing.latitude = latitude
                existing.longitude = longitude
                existing.altitude = point.altitude.flatMap { $0.isFinite ? $0 : nil }
            }
            if let heartRate = point.heartRate, heartRate > 0 { existing.heartRate = heartRate }
            points[offset] = existing
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func timestamp(_ date: Date) -> String { formatter.string(from: date) }
        func number(_ value: Double) -> String { String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value) }
        let distance = workout.distance.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        let tcxSport = workout.sportType == "Run" || workout.sportType == "VirtualRun" ? "Running" :
            (workout.sportType == "Ride" || workout.sportType == "VirtualRide" ? "Biking" : "Other")
        var track = ""
        for offset in points.keys.sorted() {
            let point = points[offset]!
            track += "<Trackpoint><Time>\(timestamp(point.date))</Time>"
            if let latitude = point.latitude, let longitude = point.longitude {
                track += "<Position><LatitudeDegrees>\(number(latitude))</LatitudeDegrees><LongitudeDegrees>\(number(longitude))</LongitudeDegrees></Position>"
            }
            if let altitude = point.altitude { track += "<AltitudeMeters>\(number(altitude))</AltitudeMeters>" }
            // Known workout distance at its boundaries only; don't fabricate a distance stream.
            if let distance, offset == 0 || offset == elapsed {
                track += "<DistanceMeters>\(number(offset == 0 ? 0 : distance))</DistanceMeters>"
            }
            if let heartRate = point.heartRate { track += "<HeartRateBpm><Value>\(heartRate)</Value></HeartRateBpm>" }
            track += "</Trackpoint>"
        }
        let calories = workout.calories.flatMap { $0.isFinite && $0 >= 0 && $0 < Double(Int.max) ? Int($0.rounded()) : nil }
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
          <Activities><Activity Sport="\(tcxSport)"><Id>\(timestamp(workout.start))</Id>
          <Lap StartTime="\(timestamp(workout.start))"><TotalTimeSeconds>\(number(workout.duration))</TotalTimeSeconds><DistanceMeters>\(number(distance ?? 0))</DistanceMeters>\(calories.map { "<Calories>\($0)</Calories>" } ?? "")<Intensity>Active</Intensity><TriggerMethod>Manual</TriggerMethod><Track>\(track)</Track></Lap>
          <Notes>Apple Health workout \(workout.id.uuidString)</Notes>
          <Creator xsi:type="Device_t"><Name>\(escape(workout.source))</Name><UnitId>0</UnitId><ProductID>0</ProductID><Version><VersionMajor>1</VersionMajor><VersionMinor>0</VersionMinor><BuildMajor>0</BuildMajor><BuildMinor>0</BuildMinor></Version></Creator>
          </Activity></Activities>
        </TrainingCenterDatabase>
        """
        return Data(xml.utf8)
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
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
