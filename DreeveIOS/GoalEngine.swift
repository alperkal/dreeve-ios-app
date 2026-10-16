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
    static func today(now: Date = .now, timeZone: TimeZone = .current) -> String {
        var deviceCalendar = calendar
        deviceCalendar.timeZone = timeZone
        let components = deviceCalendar.dateComponents([.year, .month, .day], from: now)
        return formatter().string(from: calendar.date(from: components)!)
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
    /// Dreeve's virtual sports share goal progress with their real-world equivalents.
    /// Keep stored activity types intact so edits, cached records and API data retain fidelity.
    static func goalSport(_ sport: String) -> String {
        switch sport {
        case "VirtualRun": return "Run"
        case "VirtualRide": return "Ride"
        case "VirtualRow": return "Rowing"
        default: return sport
        }
    }

    static func value(sport: String, metric: GoalMetric, period: GoalPeriod,
                      activities: [GoalActivity]) -> Double {
        // Latest occurrence wins, including edited sport/date/distance.
        let unique = Dictionary(activities.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        let selectedSport = goalSport(sport)
        return unique.values.filter { goalSport($0.sport) == selectedSport && period.contains($0.localDay) }
            .reduce(0) { $0 + (metric == .count ? 1 : $1.meters) }
    }
}

struct GoalSnapshot: Codable, Equatable {
    let instanceID: String
    let from: String
    let to: String
    let refreshedAt: Date
    var activities: [GoalActivity]
    var streakHistory: GoalStreakHistory? = nil
    func covers(_ period: GoalPeriod) -> Bool { from <= period.start && to >= period.lastDay }
}

// Compact derived history stays local. Definitions remain the only CloudKit data.
struct GoalStreakDay: Codable, Equatable {
    let day: String
    let sport: String
    var count: Int
    var meters: Double
}

struct GoalStreakHistory: Codable, Equatable {
    let throughDay: String
    let days: [GoalStreakDay]
}

struct GoalStreak: Equatable {
    let completedPeriods: Int
    let currentPeriodCompleted: Bool
}

enum GoalStreakEngine {
    /// An in-progress current period is grace time. Only a missed, ended period
    /// breaks the chain. No achievements are awarded before the creation period.
    static func streak(sport: String, metric: GoalMetric, frequency: GoalFrequency, target: Double,
                       createdAt: Date, history: GoalStreakHistory, now: Date = .now,
                       timeZone: TimeZone = .current) -> GoalStreak? {
        guard target.isFinite, target > 0, createdAt <= now else { return nil }
        let current = GoalCalendar.period(frequency, now: now, timeZone: timeZone)
        let first = GoalCalendar.period(frequency, now: createdAt, timeZone: timeZone)
        // A sync in this period confirms all ended periods. An old offline index
        // cannot prove that an unfinished prior period was ultimately missed.
        guard history.throughDay >= current.start else { return nil }
        let selected = GoalEngine.goalSport(sport)
        var totals: [String: Double] = [:]
        let formatter = GoalCalendar.formatter()
        let today = GoalCalendar.today(now: now, timeZone: timeZone)
        let calendar = GoalCalendar.calendar
        func periodStart(_ date: Date) -> String {
            if frequency == .monthly { return String(formatter.string(from: date).prefix(7)) + "-01" }
            let weekday = calendar.component(.weekday, from: date)
            return formatter.string(from: calendar.date(byAdding: .day, value: -((weekday + 5) % 7), to: date)!)
        }
        for day in history.days where day.day >= first.start && day.day <= min(history.throughDay, today) && GoalEngine.goalSport(day.sport) == selected {
            guard let date = formatter.date(from: day.day), formatter.string(from: date) == day.day else { continue }
            let start = periodStart(date)
            let amount = metric == .count ? Double(max(0, day.count)) : (day.meters.isFinite ? max(0, day.meters) : 0)
            totals[start, default: 0] += amount
        }
        let complete = (totals[current.start] ?? 0) >= target
        var length = complete ? 1 : 0
        var start = current.start
        while start > first.start {
            let day = GoalCalendar.addingDays(-1, to: start)
            guard let date = formatter.date(from: day) else { break }
            let previous = periodStart(date)
            guard (totals[previous] ?? 0) >= target else { break }
            length += 1
            start = previous
        }
        return GoalStreak(completedPeriods: length, currentPeriodCompleted: complete)
    }
}
