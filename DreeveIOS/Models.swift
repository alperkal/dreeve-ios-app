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

struct ActivityLocation: Decodable {
    let countryCode: String?
    let state: String?
    let city: String?
}

struct ActivityImage: Identifiable, Decodable {
    let id: String
    let url: String
}

struct DreeveActivity: Identifiable, Decodable {
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
    let hasGpx: Bool?
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
struct DreeveGear: Identifiable, Decodable {
    let id: String
    let name: String
    let type: String
    let isRetired: Bool?
    let distanceInMeter: Double?
    let numberOfActivities: Int?
}

struct WeightPage: Decodable { let weights: [DreeveWeight] }
struct DreeveWeight: Decodable, Identifiable {
    let on: String
    let weight: Double
    var id: String { on }
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
        Dictionary(grouping: activities, by: \.sportType)
            .map { SportCount(id: $0.key, count: $0.value.count) }
            .sorted { $0.count > $1.count }
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
