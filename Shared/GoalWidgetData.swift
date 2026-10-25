import Foundation

struct WidgetGoal: Codable, Equatable, Identifiable {
    let id: String
    let title: String
    let sport: String
    let frequency: String
    let isDistance: Bool
    let target: Double // kilometres for distance goals
    let current: Double?
    let periodStart: String
    let periodEnd: String // exclusive local calendar day

    func value(at date: Date) -> Double? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let day = String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
        guard day >= periodStart, day < periodEnd, let current, current.isFinite,
              target.isFinite, target > 0 else { return nil }
        return max(0, current)
    }
    func fraction(at date: Date) -> Double { min(1, max(0, (value(at: date) ?? 0) / max(target, 0.0001))) }
    func isComplete(at date: Date) -> Bool { value(at: date).map { $0 >= target } ?? false }
    func progressText(at date: Date) -> String {
        let unit = isDistance ? " km" : " activities"
        return "\(value(at: date).map(Self.number) ?? "—") / \(Self.number(target))\(unit)"
    }
    static func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }
}

struct GoalWidgetSnapshot: Codable, Equatable {
    let instanceID: String // one-way hash, never a server URL or token
    let updatedAt: Date?
    let refreshFailed: Bool
    let favorites: [String]
    let goals: [WidgetGoal]
    static let empty = GoalWidgetSnapshot(instanceID: "", updatedAt: nil, refreshFailed: false, favorites: [], goals: [])

    func orderedGoals(limit: Int) -> [WidgetGoal] {
        let byID = Dictionary(goals.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        return (favorites.compactMap { byID[$0] } + goals).filter { seen.insert($0.id).inserted }.prefix(limit).map { $0 }
    }
    func selectedGoal(id: String?) -> WidgetGoal? {
        if let id { return goals.first { $0.id == id } }
        return orderedGoals(limit: 1).first
    }
    func isStale(at date: Date) -> Bool {
        guard let updatedAt else { return true }
        return refreshFailed || date.timeIntervalSince(updatedAt) > 900
    }
    /// A temporarily unavailable progress snapshot must not replace known values
    /// for the same instance, goal definition and calendar period.
    func retainingKnownProgress(from saved: GoalWidgetSnapshot?) -> GoalWidgetSnapshot {
        guard let saved, saved.instanceID == instanceID else { return self }
        var retained = false
        let merged = goals.map { goal -> WidgetGoal in
            guard goal.current == nil, let old = saved.goals.first(where: { $0.id == goal.id }),
                  old.sport == goal.sport, old.frequency == goal.frequency, old.isDistance == goal.isDistance,
                  old.target == goal.target, old.periodStart == goal.periodStart, old.periodEnd == goal.periodEnd,
                  let current = old.current, current.isFinite else { return goal }
            retained = true
            return WidgetGoal(id: goal.id, title: goal.title, sport: goal.sport, frequency: goal.frequency,
                isDistance: goal.isDistance, target: goal.target, current: current,
                periodStart: goal.periodStart, periodEnd: goal.periodEnd)
        }
        return GoalWidgetSnapshot(instanceID: instanceID, updatedAt: retained ? saved.updatedAt : updatedAt,
            refreshFailed: refreshFailed || retained, favorites: favorites, goals: merged)
    }

    static func example(now: Date = .now, complete: Bool = false) -> GoalWidgetSnapshot {
        let start = Calendar.current.startOfDay(for: now)
        let format = DateFormatter(); format.calendar = Calendar(identifier: .gregorian)
        format.locale = Locale(identifier: "en_US_POSIX"); format.dateFormat = "yyyy-MM-dd"
        return GoalWidgetSnapshot(instanceID: "preview", updatedAt: now, refreshFailed: false, favorites: ["walk", "run"], goals: [
            WidgetGoal(id: "walk", title: "Walk this week", sport: "Walk", frequency: "Weekly", isDistance: false, target: 3, current: complete ? 3 : 2,
                       periodStart: format.string(from: start), periodEnd: format.string(from: Calendar.current.date(byAdding: .day, value: 7, to: start)!)),
            WidgetGoal(id: "run", title: "Monthly running", sport: "Run", frequency: "Monthly", isDistance: true, target: 100, current: complete ? 112 : 64.2,
                       periodStart: format.string(from: start), periodEnd: format.string(from: Calendar.current.date(byAdding: .month, value: 1, to: start)!))
        ])
    }
}

enum GoalWidgetReadResult: Equatable {
    case available(GoalWidgetSnapshot)
    case unavailable
    var snapshot: GoalWidgetSnapshot? {
        if case .available(let value) = self { return value }
        return nil
    }
}

struct GoalWidgetStorage {
    static let kinds = ["DreeveGoalCircle", "DreeveGoalOverview"]
    let directory: URL?
    init(directory: URL? = Self.sharedDirectory()) { self.directory = directory }
    static func sharedDirectory() -> URL? {
        #if os(iOS) || os(watchOS)
        guard let group = Bundle.main.object(forInfoDictionaryKey: "DreeveAppGroup") as? String, !group.isEmpty else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
        #else
        return nil
        #endif
    }
    private var url: URL? { directory?.appendingPathComponent("goals-widget.json") }
    /// Missing, locked or damaged storage is different from a successfully saved
    /// empty goal list (including explicit logout/deletion).
    func readResult() -> GoalWidgetReadResult {
        guard let url else { return .unavailable }
        // Upgrade existing installs even when the snapshot hasn't changed and the
        // publisher would otherwise skip writing it. A locked legacy file can be
        // migrated on the next unlocked app/widget read.
        try? prepareForWidgetAccess()
        guard let data = try? Data(contentsOf: url), data.count <= 4_000_000,
              let snapshot = try? JSONDecoder().decode(GoalWidgetSnapshot.self, from: data) else { return .unavailable }
        return .available(snapshot)
    }
    func read() -> GoalWidgetSnapshot { readResult().snapshot ?? .empty }

    func prepareForWidgetAccess() throws {
        #if os(iOS) || os(watchOS)
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if attributes[.protectionKey] as? FileProtectionType != .completeUntilFirstUserAuthentication {
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        }
        #endif
    }
    func write(_ snapshot: GoalWidgetSnapshot) throws {
        guard let url else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(snapshot)
        #if os(iOS) || os(watchOS)
        // Encrypted at rest; readable after the first unlock following a restart,
        // including later locks when WidgetKit starts a new extension process.
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
        var file = url; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try file.setResourceValues(values)
    }
}
