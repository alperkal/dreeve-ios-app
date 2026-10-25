import Foundation

private final class DiscoveryProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> Data)!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let data = try Self.handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@main
struct HealthDiscoveryContractTest {
    static func main() async throws {
        let now = ISO8601DateFormatter().date(from: "2026-10-25T12:00:00Z")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let boundary = HealthDiscoveryPolicy.start(now: now, calendar: calendar)
        precondition(ISO8601DateFormatter().string(from: boundary) == "2026-09-25T12:00:00Z")
        let march = ISO8601DateFormatter().date(from: "2024-03-31T12:00:00Z")!
        precondition(ISO8601DateFormatter().string(from: HealthDiscoveryPolicy.start(now: march, calendar: calendar)) == "2024-02-29T12:00:00Z")
        func workout(start: Date) -> HealthWorkoutSummary {
            HealthWorkoutSummary(id: UUID(), sportType: "Run", start: start, end: start.addingTimeInterval(1800),
                duration: 1800, distance: 5000, calories: 200, source: "Synthetic Watch", timeZoneIdentifier: "UTC")
        }
        precondition(HealthDiscoveryPolicy.recent(workout(start: boundary), now: now, calendar: calendar))
        precondition(!HealthDiscoveryPolicy.recent(workout(start: boundary.addingTimeInterval(-1)), now: now, calendar: calendar))
        precondition(!HealthDiscoveryPolicy.recent(workout(start: now), now: now, calendar: calendar))
        let fresh = workout(start: now.addingTimeInterval(-7200))
        let possible = workout(start: now.addingTimeInterval(-14400))
        let imported = workout(start: now.addingTimeInterval(-21600))
        let queued = workout(start: now.addingTimeInterval(-28800))
        let uncertain = workout(start: now.addingTimeInterval(-36000))
        let old = workout(start: now.addingTimeInterval(-50 * 86400))
        for state in [HealthSyncState.imported, .skipped, .queued, .uncertain, .needsDetails, .deleted, .failed] {
            let record = HealthSyncRecord(server: "https://example.test", workout: uncertain, state: state)
            precondition(HealthDiscoveryPolicy.suppress(record: record))
        }
        precondition(!HealthDiscoveryPolicy.suppress(record: nil))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("decisions.json")
        let journal = try HealthDiscoveryJournal(url: url)
        let approval = HealthDiscoveryDecision(scope: "instance-a", workoutID: fresh.id, action: .approved,
            date: now, routes: false, heartRate: true)
        let dismissed = HealthDiscoveryDecision(scope: "instance-b", workoutID: fresh.id, action: .dismissed,
            date: now, routes: true, heartRate: false)
        try journal.set([approval, dismissed])
        let reopened = try HealthDiscoveryJournal(url: url)
        precondition(reopened.decision(scope: "instance-a", id: fresh.id)?.routes == false)
        precondition(reopened.decision(scope: "instance-a", id: fresh.id)?.action == .approved)
        precondition(reopened.decision(scope: "instance-b", id: fresh.id)?.action == .dismissed)
        precondition(!HealthDiscoveryPolicy.mayPrompt(approval, now: now))
        precondition(!HealthDiscoveryPolicy.mayPrompt(dismissed, now: now.addingTimeInterval(999999)))
        let later = HealthDiscoveryDecision(scope: "instance-a", workoutID: fresh.id, action: .later, date: now, routes: true, heartRate: true)
        precondition(!HealthDiscoveryPolicy.mayPrompt(later, now: now.addingTimeInterval(3600)))
        precondition(HealthDiscoveryPolicy.mayPrompt(later, now: now.addingTimeInterval(86400)))
        try reopened.remove(scope: "instance-a", id: fresh.id)
        precondition(reopened.decision(scope: "instance-a", id: fresh.id) == nil)
        precondition(reopened.decision(scope: "instance-b", id: fresh.id) != nil)
        // Corruption must block, not silently forget approvals and upload intentions.
        try Data("broken".utf8).write(to: url)
        do { _ = try HealthDiscoveryJournal(url: url); preconditionFailure("Corrupt journal accepted") }
        catch is DecodingError {}

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DiscoveryProtocol.self]
        let client = DreeveAPIClient(baseURL: URL(string: "https://example.test")!, token: "synthetic", urlSession: URLSession(configuration: config))
        let server = "https://example.test"
        let local = HealthSyncRecord(server: server, workout: uncertain, state: .uncertain)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let existing: [String: Any] = ["id": "activity-existing", "name": "Existing Run", "sportType": "Run",
            "startDateLocal": formatter.string(from: possible.start)]
        var pages: [Int] = []
        var queriedFiles = Set<String>()
        DiscoveryProtocol.handler = { request in
            precondition(request.httpMethod == "GET", "Discovery must never upload")
            let path = request.url!.path
            let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []).map { ($0.name, $0.value!) })
            if path == "/api/v1/activities/activity-existing" { return try JSONSerialization.data(withJSONObject: existing) }
            if path == "/api/v1/activities" {
                let page = Int(query["pagination[page]"]!)!
                pages.append(page)
                let filler: [String: Any] = ["id": "activity-filler", "name": "Walk", "sportType": "Walk", "startDateLocal": "2026-10-01T00:00:00"]
                return try JSONSerialization.data(withJSONObject: ["activities": page == 1 ? [filler] : [existing],
                    "pagination": ["page": page, "size": 100, "total": 2, "totalPages": 2]])
            }
            precondition(path == "/api/v1/file-imports")
            let filename = query["filters[filename]"]!
            queriedFiles.insert(filename)
            var items: [[String: Any]] = []
            if filename == imported.filename {
                items = [["filename": filename, "source": "file", "status": "success", "activityId": "activity-existing"]]
            } else if filename == queued.filename {
                items = [["filename": filename, "source": "file", "status": "queued"]]
            }
            return try JSONSerialization.data(withJSONObject: ["fileImports": items,
                "pagination": ["page": 1, "size": 100, "total": items.count, "totalPages": 1]])
        }
        let entries = try await HealthDiscoveryVerifier.entries(workouts: [fresh, possible, imported, queued, uncertain, old],
            records: [local], server: server, client: client, now: now)
        precondition(entries.count == 2 && entries.first { $0.id == fresh.id }?.status == .ready)
        precondition(entries.first { $0.id == possible.id }?.status == .review)
        precondition(pages == [1, 2])
        precondition(!queriedFiles.contains(old.filename) && !queriedFiles.contains(uncertain.filename))
        precondition(queriedFiles.contains(fresh.legacyFilename))
        DiscoveryProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        do {
            _ = try await HealthDiscoveryVerifier.entries(workouts: [fresh], records: [], server: server, client: client, now: now)
            preconditionFailure("Offline treated as verified absence")
        } catch let error as URLError { precondition(error.code == .notConnectedToInternet) }
        print("Health discovery tests passed: calendar-month bounds/leap day, completed workouts, durable scoped approvals/options/cancellation, snooze, corrupt journal, paginated duplicate checks, remote imports/queue, uncertain local uploads, legacy filenames and offline safety.")
    }
}
