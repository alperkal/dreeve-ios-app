import Foundation

struct DreeveStatus: Decodable {
    let app: String
    let version: String
    let canUpload: Bool
}

struct ActivityPage: Decodable {
    let activities: [DreeveActivity]
    let pagination: Pagination
}

struct Pagination: Decodable {
    let page: Int
    let size: Int
    let total: Int
    let totalPages: Int
}

struct ActivityLocation: Codable, Sendable {
    let countryCode: String?
    let state: String?
    let city: String?
}

struct ActivityImage: Identifiable, Codable, Sendable {
    let id: String
    let url: String
}

struct DreeveActivity: Identifiable, Codable, Sendable {
    let id: String
    let name: String
    let description: String?
    let sportType: String
    let startDateLocal: String
    let distanceInMeter: Double?
    let elevationInMeter: Double?
    let movingTimeInSeconds: Int?
    let elapsedTimeInSeconds: Int?
    let averageSpeedInKmPerHour: Double?
    let maxSpeedInKmPerHour: Double?
    let calories: Int?
    let averageHeartRate: Int?
    let maxHeartRate: Int?
    let averagePower: Int?
    let averageCadence: Int?
    let gearId: String?
    let location: ActivityLocation?
    let startLatLng: [Double]?
    let encodedPolyline: String?
    let images: [ActivityImage]?

    var startDate: Date? {
        ActivityDates.local.date(from: String(startDateLocal.prefix(19)))
    }

    var distanceKilometers: Double { (distanceInMeter ?? 0) / 1000 }
    var movingMinutes: Double { Double(movingTimeInSeconds ?? 0) / 60 }
    var locationLabel: String {
        [location?.city, location?.state].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

enum ActivityDates {
    static let local: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }()
    static let calendarDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

struct ActivityPatch: Encodable {
    let name: String
    let sportType: String
    let description: String
    var gear: GearChange = .unchanged

    enum CodingKeys: String, CodingKey { case name, sportType, description, gearId }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(name, forKey: .name)
        try values.encode(sportType, forKey: .sportType)
        try values.encode(description, forKey: .description)
        switch gear {
        case .unchanged: break // Omit: preserve gear when editing other fields.
        case .assign(let id): try values.encode(id, forKey: .gearId)
        case .remove: try values.encodeNil(forKey: .gearId)
        }
    }
}

enum GearChange {
    case unchanged
    case assign(String)
    case remove

    static func between(original: String?, selected: String?) -> GearChange {
        guard original != selected else { return .unchanged }
        return selected.map { .assign($0) } ?? .remove
    }
}

struct UploadReceipt: Decodable {
    let status: String
    let message: String
}

struct ImportPage: Decodable {
    let fileImports: [DreeveImport]
    let pagination: Pagination
}

struct DreeveImport: Decodable, Identifiable {
    let id: String?
    let filename: String
    let source: String
    let status: String
    let errorMessage: String?
    let activityId: String?
    let importedOn: String?

    // Queued items have null ids. Filename + position is sufficient for list rendering here.
    var displayID: String { id ?? "queued-\(filename)" }
}

struct GearPage: Decodable { let gear: [DreeveGear] }
struct DreeveGear: Identifiable, Codable {
    let id: String
    let name: String
    let type: String
    let isRetired: Bool?
    let distanceInMeter: Double?
    let numberOfActivities: Int?
}

/// Local, instance-scoped inventory. Gear pictures are stored separately.
struct GearInventoryCache {
    let directory: URL
    init(directory: URL = URL.applicationSupportDirectory.appendingPathComponent("GearInventory", isDirectory: true)) {
        self.directory = directory
    }
    private func fileURL(instanceID: String) throws -> URL {
        guard instanceID.count == 64, instanceID.allSatisfy({ $0.isHexDigit && $0.isASCII }) else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        return directory.appendingPathComponent(instanceID + ".json")
    }
    func load(instanceID: String) throws -> [DreeveGear]? {
        let url = try fileURL(instanceID: instanceID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode([DreeveGear].self, from: Data(contentsOf: url))
    }
    func save(_ gear: [DreeveGear], instanceID: String) throws {
        let url = try fileURL(instanceID: instanceID)
        let data = try JSONEncoder().encode(gear)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var root = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? root.setResourceValues(values)
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        #else
        try data.write(to: url, options: .atomic)
        #endif
    }
}

struct WeightPage: Decodable { let weights: [DreeveWeight] }
struct DreeveWeight: Decodable, Identifiable {
    let on: String
    let weight: Double
    var id: String { on }
}

/// Shared grouping for goals and Overview; preserve original API types on activities.
enum SportFamily {
    static func canonical(_ sport: String) -> String {
        switch sport {
        case "VirtualRun": return "Run"
        case "VirtualRide": return "Ride"
        case "VirtualRow": return "Rowing"
        default: return sport
        }
    }

    static func types(for sport: String) -> [String] {
        switch canonical(sport) {
        case "Run": return ["Run", "VirtualRun"]
        case "Ride": return ["Ride", "VirtualRide"]
        case "Rowing": return ["Rowing", "VirtualRow"]
        default: return [sport]
        }
    }
}

struct SportCount: Identifiable {
    let id: String
    let count: Int
}

struct DailyDistance: Identifiable {
    let day: Date
    let km: Double
    var id: Date { day }
}

struct ActivityInsights {
    let activities: [DreeveActivity]
    let currentWeek: [DreeveActivity]

    init(activities: [DreeveActivity], now: Date = .now) {
        self.activities = activities
        let weekStart = Calendar.current.date(byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: now)) ?? now
        currentWeek = activities.filter { ($0.startDate ?? .distantPast) >= weekStart }
    }

    var weekKm: Double { currentWeek.reduce(0) { $0 + $1.distanceKilometers } }
    var weekMinutes: Double { currentWeek.reduce(0) { $0 + $1.movingMinutes } }
    var monthKm: Double { activities.reduce(0) { $0 + $1.distanceKilometers } }
    var monthElevation: Double { activities.reduce(0) { $0 + ($1.elevationInMeter ?? 0) } }
    var sports: [SportCount] {
        Dictionary(grouping: activities, by: { SportFamily.canonical($0.sportType) })
            .map { SportCount(id: $0.key, count: $0.value.count) }
            .sorted { $0.count == $1.count ? $0.id < $1.id : $0.count > $1.count }
    }
    var dailyDistances: [DailyDistance] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        return (0..<7).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let km = activities.filter { activity in
                guard let date = activity.startDate else { return false }
                return calendar.isDate(date, inSameDayAs: day)
            }.reduce(0) { $0 + $1.distanceKilometers }
            return DailyDistance(day: day, km: km)
        }
    }
}

/// The user's chosen sport applies only to the Overview distance trend.
enum DistanceTrendSport: String, CaseIterable, Identifiable {
    case running = "Run"
    case swimming = "Swim"
    var id: String { rawValue }
    var label: String { self == .running ? "Running" : "Swimming" }
    func matches(_ activity: DreeveActivity) -> Bool {
        switch self {
        case .running: return SportFamily.canonical(activity.sportType) == "Run"
        case .swimming: return activity.sportType == "Swim" || activity.sportType == "OpenWaterSwim"
        }
    }
}

/// The previous six calendar days and today, using activity-local wall dates.
struct LastSevenDaysDistance {
    let daily: [DailyDistance]
    var total: Double { daily.reduce(0) { $0 + $1.km } }
    init(activities: [DreeveActivity], sport: DistanceTrendSport, now: Date = .now, calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: now)
        guard let start = calendar.date(byAdding: .day, value: -6, to: today) else { daily = []; return }
        let buckets = Dictionary(grouping: activities.compactMap { activity -> (Date, Double)? in
            guard sport.matches(activity), let date = activity.startDate else { return nil }
            let day = calendar.startOfDay(for: date)
            guard day >= start && day <= today else { return nil }
            return (day, activity.distanceKilometers)
        }, by: { $0.0 })
        daily = (0..<7).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            return DailyDistance(day: day, km: (buckets[day] ?? []).reduce(0) { $0 + $1.1 })
        }
    }
}

/// Current calendar month through today, using activity-local wall dates.
struct CalendarMonthDistance {
    let daily: [DailyDistance]
    var total: Double { daily.reduce(0) { $0 + $1.km } }
    init(activities: [DreeveActivity], sport: DistanceTrendSport = .running, now: Date = .now, calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: now)
        guard let start = calendar.dateInterval(of: .month, for: today)?.start,
              let count = calendar.dateComponents([.day], from: start, to: today).day else { daily = []; return }
        let buckets = Dictionary(grouping: activities.compactMap { activity -> (Date, Double)? in
            guard sport.matches(activity), let date = activity.startDate else { return nil }
            let day = calendar.startOfDay(for: date)
            guard day >= start && day <= today else { return nil }
            return (day, activity.distanceKilometers)
        }, by: { $0.0 })
        daily = (0...count).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            return DailyDistance(day: day, km: (buckets[day] ?? []).reduce(0) { $0 + $1.1 })
        }
    }
}

/// Current calendar year through this month, grouped by local calendar month.
struct CalendarYearDistance {
    let monthly: [DailyDistance]
    var total: Double { monthly.reduce(0) { $0 + $1.km } }
    init(activities: [DreeveActivity], sport: DistanceTrendSport, now: Date = .now, calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: now)
        guard let year = calendar.dateInterval(of: .year, for: today)?.start,
              let currentMonth = calendar.dateInterval(of: .month, for: today)?.start,
              let count = calendar.dateComponents([.month], from: year, to: currentMonth).month else { monthly = []; return }
        let buckets = Dictionary(grouping: activities.compactMap { activity -> (Date, Double)? in
            guard sport.matches(activity), let date = activity.startDate else { return nil }
            let day = calendar.startOfDay(for: date)
            guard day >= year && day <= today,
                  let month = calendar.dateInterval(of: .month, for: day)?.start else { return nil }
            return (month, activity.distanceKilometers)
        }, by: { $0.0 })
        monthly = (0...count).compactMap { offset in
            guard let month = calendar.date(byAdding: .month, value: offset, to: year) else { return nil }
            return DailyDistance(day: month, km: (buckets[month] ?? []).reduce(0) { $0 + $1.1 })
        }
    }
}

extension Double {
    var oneDecimal: String { formatted(.number.precision(.fractionLength(1))) }
}

func activitySymbol(_ type: String) -> String {
    switch type.lowercased() {
    case let s where s.contains("run"): return "figure.run"
    case let s where s.contains("ride") || s.contains("cycl"): return "bicycle"
    case let s where s.contains("swim"): return "figure.pool.swim"
    case let s where s.contains("walk") || s.contains("hik"): return "figure.walk"
    case let s where s.contains("ski"): return "figure.skiing.downhill"
    default: return "figure.mixed.cardio"
    }
}

/// Exact API values from Dreeve's SportType enum. Keep virtual types distinct when editing.
/// Source: https://github.com/dreeveapp/dreeve/blob/master/src/Domain/Activity/SportType/SportType.php
enum ActivitySportTypes {
    static let supported: [String] = [
        "AlpineSki",
        "BackcountrySki",
        "Badminton",
        "Basketball",
        "Boxing",
        "Canoeing",
        "Cricket",
        "Crossfit",
        "Dance",
        "EBikeRide",
        "EMountainBikeRide",
        "Elliptical",
        "Golf",
        "GravelRide",
        "Handcycle",
        "HighIntensityIntervalTraining",
        "Hike",
        "IceSkate",
        "InlineSkate",
        "Kayaking",
        "Kitesurf",
        "MountainBikeRide",
        "NordicSki",
        "OpenWaterSwim",
        "Padel",
        "PhysicalTherapy",
        "Pickleball",
        "Pilates",
        "Racquetball",
        "Ride",
        "RockClimbing",
        "RollerSki",
        "Rowing",
        "Run",
        "Sail",
        "Skateboard",
        "Snowboard",
        "Snowshoe",
        "Soccer",
        "Squash",
        "StairStepper",
        "StandUpPaddling",
        "Surfing",
        "Swim",
        "TableTennis",
        "Tennis",
        "TrailRun",
        "Velomobile",
        "VirtualRide",
        "VirtualRow",
        "VirtualRun",
        "Volleyball",
        "Wakeboarding",
        "Walk",
        "WeightTraining",
        "Wheelchair",
        "Windsurf",
        "Workout",
        "Yoga",
    ]

    // A newer server may return a type this app does not yet know. Preserve it on edit.
    static func options(including current: String) -> [String] {
        Array(Set(supported + (current.isEmpty ? [] : [current]))).sorted()
    }
}
