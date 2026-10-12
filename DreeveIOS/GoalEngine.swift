import Foundation
import CryptoKit

enum GoalMetric: String, CaseIterable, Identifiable {
    case count, distance
    var id: String { rawValue }
    var label: String { self == .count ? "Activity count" : "Distance (km)" }
}

enum GoalFrequency: String, CaseIterable, Identifiable {
    case weekly, monthly
    var id: String { rawValue }
    var label: String { self == .weekly ? "Weekly" : "Monthly" }
}

struct GoalActivity: Codable, Equatable {
    let id: String
    let sport: String
    let localDay: String
    let meters: Double

    init(_ activity: DreeveActivity) throws {
        guard let day = GoalCalendar.localDay(activity.startDateLocal) else {
            throw APIError.decoding("Invalid activity local date; progress was not replaced.")
        }
        id = activity.id
        sport = activity.sportType
        localDay = day
        meters = max(0, activity.distanceInMeter ?? 0)
    }
}

struct GoalPeriod: Equatable {
    let start: String
    let endExclusive: String
    let lastDay: String
    func contains(_ day: String) -> Bool { day >= start && day < endExclusive }
}

// Floating calendar dates: activity timezone suffixes are deliberately NOT converted
// to UTC or the phone timezone. Dreeve's startDateLocal is a local wall-clock value.
// UTC here is only a DST-free arithmetic container for year/month/day components.
enum GoalCalendar {
    static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        value.firstWeekday = 2
        value.minimumDaysInFirstWeek = 4
        return value
    }
    static func formatter() -> DateFormatter {
        let value = DateFormatter()
        value.locale = Locale(identifier: "en_US_POSIX")
        value.calendar = calendar
        value.timeZone = calendar.timeZone
        value.dateFormat = "yyyy-MM-dd"
        value.isLenient = false
        return value
    }
    static func localDay(_ timestamp: String) -> String? {
        guard timestamp.count >= 19 else { return nil }
        let prefix = String(timestamp.prefix(19))
        let parser = formatter()
        parser.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        guard let date = parser.date(from: prefix), parser.string(from: date) == prefix else { return nil }
        return String(prefix.prefix(10))
    }
    static func addingDays(_ count: Int, to day: String) -> String {
        let formatter = formatter()
        let date = formatter.date(from: day)!
        return formatter.string(from: calendar.date(byAdding: .day, value: count, to: date)!)
    }
    static func period(_ frequency: GoalFrequency, now: Date = .now,
                       timeZone: TimeZone = .current) -> GoalPeriod {
        var deviceCalendar = calendar
        deviceCalendar.timeZone = timeZone
        let components = deviceCalendar.dateComponents([.year, .month, .day], from: now)
        let day = calendar.date(from: components)!
        let start: Date
        let end: Date
        if frequency == .weekly {
            let weekday = calendar.component(.weekday, from: day)
            start = calendar.date(byAdding: .day, value: -((weekday + 5) % 7), to: day)!
            end = calendar.date(byAdding: .day, value: 7, to: start)!
        } else {
            start = calendar.date(from: calendar.dateComponents([.year, .month], from: day))!
            end = calendar.date(byAdding: .month, value: 1, to: start)!
        }
        let format = formatter()
        return GoalPeriod(start: format.string(from: start), endExclusive: format.string(from: end),
                          lastDay: format.string(from: calendar.date(byAdding: .day, value: -1, to: end)!))
    }
}

enum GoalEngine {
    static func instanceID(_ url: URL) -> String {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        parts.scheme = parts.scheme?.lowercased()
        parts.host = parts.host?.lowercased()
        if parts.port == 443 { parts.port = nil }
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        let canonical = parts.string!
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func value(sport: String, metric: GoalMetric, period: GoalPeriod,
                      activities: [GoalActivity]) -> Double {
        // Latest occurrence wins, including edited sport/date/distance.
        let unique = Dictionary(activities.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        return unique.values.filter { $0.sport == sport && period.contains($0.localDay) }
            .reduce(0) { $0 + (metric == .count ? 1 : $1.meters) }
    }
}

struct GoalSnapshot: Codable {
    let instanceID: String
    let from: String
    let to: String
    let refreshedAt: Date
    var activities: [GoalActivity]
    func covers(_ period: GoalPeriod) -> Bool { from <= period.start && to >= period.lastDay }
}
