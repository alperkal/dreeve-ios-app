import Foundation

private final class SportProtocol: URLProtocol {
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
struct OverviewSportsContractTest {
    static func main() async throws {
        func activity(_ id: String, _ sport: String, _ day: String) throws -> DreeveActivity {
            let json: [String: Any] = ["id": id, "name": id, "sportType": sport, "startDateLocal": day]
            return try JSONDecoder().decode(DreeveActivity.self, from: JSONSerialization.data(withJSONObject: json))
        }
        let now = ISO8601DateFormatter().date(from: "2026-03-30T12:00:00Z")!
        let zone = TimeZone(identifier: "Europe/Vienna")!
        let run = ActivitySportFilter(sport: "VirtualRun", now: now, timeZone: zone)
        precondition(run.sport == "Run" && run.from == "2026-03-01" && run.to == "2026-03-30")
        precondition(run.sportTypes == ["Run", "VirtualRun"])
        let rows = try [activity("a", "Run", "2026-03-01T00:00:00+14:00"),
                        activity("b", "VirtualRun", "2026-03-30T23:59:59-12:00"),
                        activity("c", "Ride", "2026-03-20T12:00:00"),
                        activity("d", "VirtualRide", "2026-03-20T12:00:00"),
                        activity("e", "Rowing", "2026-03-20T12:00:00"),
                        activity("f", "VirtualRow", "2026-03-20T12:00:00"),
                        activity("g", "Walk", "2026-03-20T12:00:00")]
        let summary = ActivityInsights(activities: rows, now: now)
        precondition(Dictionary(uniqueKeysWithValues: summary.sports.map { ($0.id, $0.count) }) ==
                     ["Run": 2, "Ride": 2, "Rowing": 2, "Walk": 1])
        precondition(rows.filter(run.matches).map(\.id) == ["a", "b"])
        let old = try activity("old", "Run", "2026-02-28T23:59:59")
        let future = try activity("future", "Run", "2026-03-31T00:00:00")
        precondition(!run.matches(old) && !run.matches(future))
        let invalid = try activity("bad", "Run", "invalid")
        precondition(!run.matches(invalid))
        precondition(SportFamily.types(for: "VirtualRide") == ["Ride", "VirtualRide"])
        precondition(SportFamily.types(for: "VirtualRow") == ["Rowing", "VirtualRow"])
        precondition(SportFamily.types(for: "TrailRun") == ["TrailRun"])
        let leapNow = ISO8601DateFormatter().date(from: "2024-03-01T12:00:00Z")!
        precondition(ActivitySportFilter(sport: "Walk", now: leapNow, timeZone: zone).from == "2024-02-01")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SportProtocol.self]
        let client = DreeveAPIClient(baseURL: URL(string: "https://example.test/dreeve")!, token: "test-token",
                                     urlSession: URLSession(configuration: config))
        func response(_ activities: [DreeveActivity], page: Int, pages: Int) throws -> Data {
            let encoded = try activities.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) }
            return try JSONSerialization.data(withJSONObject: ["activities": encoded,
                "pagination": ["page": page, "size": 100, "total": 5, "totalPages": pages]])
        }
        var requestedPages: [Int] = []
        SportProtocol.handler = { request in
            precondition(request.httpMethod == "GET" && request.url!.path == "/dreeve/api/v1/activities")
            let q = Dictionary(uniqueKeysWithValues: URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
            precondition(q["filters[from]"] == "2026-03-01" && q["filters[to]"] == "2026-03-30")
            precondition(q["filters[sportType]"] == "Run,VirtualRun")
            precondition(q["pagination[size]"] == "100")
            let page = Int(q["pagination[page]"]!)!
            requestedPages.append(page)
            return try response(page == 1 ? [rows[1], rows[2], old] : [rows[1], rows[0], future], page: page, pages: 2)
        }
        let result = try await client.activities(matching: run)
        precondition(requestedPages == [1, 2] && result.map(\.id) == ["b", "a"])
        // A later-page failure must not be mistaken for a complete, smaller list.
        SportProtocol.handler = { request in
            let page = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "pagination[page]" }!.value!
            if page == "2" { throw URLError(.notConnectedToInternet) }
            return try response([rows[0]], page: 1, pages: 2)
        }
        do { _ = try await client.activities(matching: run); preconditionFailure("Partial results accepted") }
        catch let error as URLError { precondition(error.code == .notConnectedToInternet) }
        SportProtocol.handler = { _ in try response([], page: 1, pages: 0) }
        let empty = try await client.activities(matching: run)
        precondition(empty.isEmpty)
        SportProtocol.handler = { _ in try response([rows[0]], page: 2, pages: 2) }
        do { _ = try await client.activities(matching: run); preconditionFailure("Wrong page accepted") }
        catch APIError.decoding {}
        print("Overview sports tests passed: shared virtual grouping, local dates/DST/leap boundaries, exact API filters, pagination, deduplication, sorting, empty results and failure recovery.")
    }
}
