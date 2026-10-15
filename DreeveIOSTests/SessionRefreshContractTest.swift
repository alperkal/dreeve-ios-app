import Foundation

// Isolate session refresh tests from device Keychain, CloudKit, and live servers.
enum KeychainStore {
    static func read() -> String? { "synthetic-test-token" }
    static func save(_ value: String) throws {}
    static func delete() {}
}
@MainActor final class GoalProgressStore {
    func selectInstance(_ value: String) {}
    func refresh(client: DreeveAPIClient) async {}
    func changed(_ activity: DreeveActivity) {}
    func changed(deletedID: String) {}
}

private final class OverviewRefreshProtocol: URLProtocol {
    enum Mode { case success, cancelled, serverFailure }
    static var mode: Mode = .success
    static var pages: [Int] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        precondition(request.url?.host == "overview-test.invalid")
        let query = Dictionary(uniqueKeysWithValues: URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
        let page = Int(query["pagination[page]"]!)!
        Self.pages.append(page)
        precondition(query["pagination[size]"] == "100")
        let start = Calendar.current.date(byAdding: .day, value: -29, to: Calendar.current.startOfDay(for: .now))!
        precondition(query["filters[from]"] == ActivityDates.calendarDate.string(from: start))
        if Self.mode == .cancelled {
            client!.urlProtocol(self, didFailWithError: URLError(.cancelled))
            return
        }
        let fail = Self.mode == .serverFailure && page == 2
        let body = fail ? #"{"error":"internal_error","message":"Fixture failure"}"# : """
        {"activities":[{"id":"run-\(page)","name":"Sample","sportType":"Run","startDateLocal":"2026-10-15T08:00:00","distanceInMeter":1000}],"pagination":{"page":\(page),"size":100,"total":2,"totalPages":2}}
        """
        client!.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: fail ? 500 : 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client!.urlProtocol(self, didLoad: Data(body.utf8))
        client!.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct SessionRefreshContractTest {
    @MainActor static func main() async {
        UserDefaults.standard.setVolatileDomain(["dreeve.url": "https://overview-test.invalid"], forName: UserDefaults.argumentDomain)
        precondition(URLProtocol.registerClass(OverviewRefreshProtocol.self))
        defer { URLProtocol.unregisterClass(OverviewRefreshProtocol.self) }
        let session = DreeveSession()
        await session.refreshInsights()
        precondition(session.didLoadInsights && session.insightsActivities.map(\.id) == ["run-1", "run-2"])
        precondition(OverviewRefreshProtocol.pages == [1, 2] && session.errorMessage == nil)

        // Cancel the caller before its body executes: SwiftUI refresh tasks can be cancelled.
        OverviewRefreshProtocol.pages = []
        let caller = Task { await session.refreshInsights() }
        caller.cancel()
        await caller.value
        precondition(OverviewRefreshProtocol.pages == [1, 2])
        precondition(session.errorMessage == nil && !session.isLoadingInsights)

        OverviewRefreshProtocol.mode = .cancelled
        await session.refreshInsights()
        precondition(session.errorMessage == nil && session.insightsActivities.count == 2 && !session.isLoadingInsights)

        // Partial fetches must retain the complete snapshot and report genuine failures.
        OverviewRefreshProtocol.mode = .serverFailure
        await session.refreshInsights()
        precondition(session.errorMessage?.contains("500") == true)
        precondition(session.insightsActivities.map(\.id) == ["run-1", "run-2"])
        precondition(!session.isLoadingInsights)

        OverviewRefreshProtocol.mode = .success
        await session.refreshInsights()
        precondition(session.errorMessage == nil && session.insightsActivities.count == 2)
        print("Overview refresh tests passed: pagination, caller cancellation, URLSession cancellation, genuine errors, saved data, and retry recovery.")
    }
}
