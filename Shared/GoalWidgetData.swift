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

struct GoalWidgetStorage {
    static let kinds = ["DreeveGoalCircle", "DreeveGoalOverview"]
    let directory: URL?
    init(directory: URL? = Self.sharedDirectory()) { self.directory = directory }
    static func sharedDirectory() -> URL? {
        #if os(iOS)
        guard let group = Bundle.main.object(forInfoDictionaryKey: "DreeveAppGroup") as? String, !group.isEmpty else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
        #else
        return nil
        #endif
    }
    private var url: URL? { directory?.appendingPathComponent("goals-widget.json") }
    func read() -> GoalWidgetSnapshot {
        guard let url, let data = try? Data(contentsOf: url), data.count <= 4_000_000,
              let snapshot = try? JSONDecoder().decode(GoalWidgetSnapshot.self, from: data) else { return .empty }
        return snapshot
    }
    func write(_ snapshot: GoalWidgetSnapshot) throws {
        guard let url else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        var file = url; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try file.setResourceValues(values)
    }
}
