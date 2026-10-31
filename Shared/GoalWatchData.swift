import Foundation

/// Versioned, ordered snapshots. No activity records, URLs or credentials cross devices.
struct GoalWatchEnvelope: Codable, Equatable {
    let version: Int
    let senderID: String
    let revision: Int
    let sentAt: Date
    let snapshot: GoalWidgetSnapshot
    var appearance: ThemePreference? = nil // Optional for backward-compatible cached envelopes.

    static let maximumBytes = 4_000_000
    static let contextBytes = 55_000
    static func decode(_ data: Data) throws -> GoalWatchEnvelope {
        guard data.count <= maximumBytes else { throw CocoaError(.fileReadTooLarge) }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.version == 1, UUID(uuidString: value.senderID) != nil, value.revision > 0,
              value.snapshot.goals.allSatisfy({ $0.target.isFinite && $0.target > 0 &&
                  ($0.current == nil || $0.current!.isFinite) && $0.periodStart < $0.periodEnd }),
              !value.snapshot.instanceID.isEmpty || value.snapshot == .empty else { throw CocoaError(.fileReadCorruptFile) }
        return value
    }
    static func recoverableSnapshot(_ cached: GoalWidgetSnapshot?, after latest: GoalWatchEnvelope?) -> GoalWidgetSnapshot? {
        guard let cached, !cached.instanceID.isEmpty,
              latest == nil || latest?.snapshot.instanceID == cached.instanceID,
              let updated = cached.updatedAt, updated > (latest?.snapshot.updatedAt ?? .distantPast) else { return nil }
        return cached
    }
    func contextPayload() throws -> [String: Any] {
        let data = try JSONEncoder().encode(self)
        _ = try Self.decode(data)
        if data.count <= Self.contextBytes { return ["goalEnvelope": data] }
        return ["goalFilePending": true, "revision": revision, "senderID": senderID]
    }
    func matches(payload: [String: Any]) -> Bool {
        if let data = payload["goalEnvelope"] as? Data,
           let envelope = try? Self.decode(data) {
            return envelope.senderID == senderID && envelope.revision == revision
        }
        return payload["senderID"] as? String == senderID && payload["revision"] as? Int == revision
    }
    func supersedes(_ previous: GoalWatchEnvelope?) -> Bool {
        guard let previous else { return true }
        if senderID == previous.senderID { return revision > previous.revision }
        // A fresh phone installation has a new sender. Reject older queued deliveries.
        return sentAt > previous.sentAt
    }
    func needsTimelineReload(replacing previous: GoalWatchEnvelope?, force: Bool = false) -> Bool {
        let duplicate = previous?.senderID == senderID && previous?.revision == revision
        guard supersedes(previous) || duplicate else { return false }
        return force || changesVisibleGoals(from: previous)
    }
    func changesVisibleGoals(from previous: GoalWatchEnvelope?) -> Bool {
        guard let old = previous?.snapshot else { return true }
        return snapshot.instanceID != old.instanceID || snapshot.goals != old.goals || snapshot.favorites != old.favorites ||
            (appearance ?? .dark) != (previous?.appearance ?? .dark)
    }
}

struct WatchGoalSelection: Hashable {
    let instanceID: String
    let goalID: String
    var entityID: String { instanceID + "|" + goalID }
    init(instanceID: String, goalID: String) { self.instanceID = instanceID; self.goalID = goalID }
    init?(entityID: String) {
        let parts = entityID.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        self.init(instanceID: parts[0], goalID: parts[1])
    }
    func goal(in snapshot: GoalWidgetSnapshot) -> WidgetGoal? {
        guard instanceID == snapshot.instanceID else { return nil }
        return snapshot.selectedGoal(id: goalID)
    }
    var url: URL {
        var parts = URLComponents()
        parts.scheme = "dreevewatch"; parts.host = "goal"
        parts.queryItems = [URLQueryItem(name: "instance", value: instanceID), URLQueryItem(name: "id", value: goalID)]
        return parts.url!
    }
    init?(url: URL) {
        guard url.scheme == "dreevewatch", url.host == "goal",
              let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let instance = query.first(where: { $0.name == "instance" })?.value, !instance.isEmpty,
              let id = query.first(where: { $0.name == "id" })?.value, !id.isEmpty else { return nil }
        self.init(instanceID: instance, goalID: id)
    }
}

/// One atomic envelope is the source for both the Watch app and complication extension.
struct GoalWatchStorage {
    let directory: URL?
    init(directory: URL? = GoalWidgetStorage.sharedDirectory()) { self.directory = directory }
    private var url: URL? { directory?.appendingPathComponent("watch-goals.json") }
    func envelope() -> GoalWatchEnvelope? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? GoalWatchEnvelope.decode(data)
    }
    func readResult() -> GoalWidgetReadResult {
        envelope().map { .available($0.snapshot) } ?? .unavailable
    }
    func remove() throws {
        guard let url else { return }
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    func write(_ envelope: GoalWatchEnvelope) throws {
        guard let url else { throw CocoaError(.fileNoSuchFile) }
        let data = try JSONEncoder().encode(envelope)
        _ = try GoalWatchEnvelope.decode(data)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS) || os(watchOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
        var file = url; var flags = URLResourceValues(); flags.isExcludedFromBackup = true
        try file.setResourceValues(flags)
    }
    @discardableResult func accept(_ data: Data) throws -> Bool {
        let next = try GoalWatchEnvelope.decode(data)
        guard next.supersedes(envelope()) else { return false }
        try write(next)
        return true
    }
}

func watchGoalSymbol(_ sport: String) -> String {
    let sport = sport.lowercased()
    if sport.contains("run") { return "figure.run" }
    if sport.contains("ride") || sport.contains("cycl") { return "bicycle" }
    if sport.contains("walk") || sport.contains("hike") { return "figure.walk" }
    if sport.contains("swim") { return "figure.pool.swim" }
    if sport.contains("row") { return "figure.rower" }
    return "target"
}

/// Foreground requests survive activation/reachability transitions without
/// overlapping sends or letting a delayed callback finish a newer request.
struct WatchGoalRequestGate {
    var isForeground = false
    private var request: (id: UUID, started: Date)?
    mutating func begin(activated: Bool, reachable: Bool, now: Date) -> UUID? {
        guard isForeground, activated, reachable else { return nil }
        if let request, now.timeIntervalSince(request.started) < 30 { return nil }
        let id = UUID()
        request = (id, now)
        return id
    }
    @discardableResult mutating func finish(_ id: UUID) -> Bool {
        guard request?.id == id else { return false }
        request = nil
        return true
    }
}
