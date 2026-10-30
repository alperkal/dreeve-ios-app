import Foundation
import CoreLocation

final class RouteMockProtocol: URLProtocol {
    static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"elements\":[]}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct RoutesContractTest {
    static func main() async throws {
        let data = Data("""
        {"elements":[
          {"id":10,"tags":{"route":"running","name":"Park circuit"},"members":[
            {"type":"way","geometry":[{"lat":48.2,"lon":16.3},{"lat":48.2,"lon":16.31}]},
            {"type":"way","geometry":[{"lat":48.5,"lon":16.8},{"lat":48.5,"lon":16.81}]},
            {"type":"way"}]},
          {"id":11,"tags":{"route":"foot"},"members":[{"type":"way","geometry":[{"lat":48.2,"lon":16.3},{"lat":48.21,"lon":16.3}]}]},
          {"id":12,"members":[{"type":"way","geometry":[{"lat":100,"lon":0},{"lat":0,"lon":0}]}]}
        ]}
        """.utf8)
        let routes = try MappedRoute.decode(data)
        precondition(routes.count == 2 && routes[0].name == "Park circuit")
        precondition(routes[0].segments.count == 2 && routes[0].incomplete)
        precondition(routes[0].distance > 1000 && routes[0].distance < 2000) // no false connection between ways
        precondition(routes[1].name == "Unnamed foot route" && !routes[1].incomplete)
        let line = (0...100).map { CLLocationCoordinate2D(latitude: 44.5, longitude: 11.3 + Double($0) * 0.00001) }
        let separate = [CLLocationCoordinate2D(latitude: 44.6, longitude: 11.4), CLLocationCoordinate2D(latitude: 44.61, longitude: 11.4)]
        let displayed = RouteDisplayGeometry.prepare([Array(line[0...50]), Array(line[50...100]), separate])
        precondition(displayed.count == 2 && displayed[0].count == 2 && displayed[1].count == 2)
        let grouped = RouteDisplayGeometry.multiPolyline(displayed)
        precondition(grouped?.polylines.count == 2 && RouteDisplayGeometry.multiPolyline([]) == nil)
        precondition(displayed[0].first!.longitude == line.first!.longitude && displayed[0].last!.longitude == line.last!.longitude)
        let corner = [CLLocationCoordinate2D(latitude: 44.5, longitude: 11.3), CLLocationCoordinate2D(latitude: 44.501, longitude: 11.301), CLLocationCoordinate2D(latitude: 44.5, longitude: 11.302)]
        precondition(RouteDisplayGeometry.prepare([corner])[0].count == 3)
        precondition(routes[0].segments.count == 2 && routes[0].displaySegments.count == 2)
        let empty = try MappedRoute.decode(Data("{\"elements\":[]}".utf8))
        precondition(empty.isEmpty)
        do { _ = try MappedRoute.decode(Data("{\"elements\":[],\"remark\":\"runtime error\"}".utf8)); preconditionFailure("Incomplete result accepted") }
        catch RouteSearchError.incompleteResponse {}
        let endpoint = try RouteProviderConfiguration.validate("https://Example.test/api/interpreter")
        precondition(endpoint.absoluteString == "https://example.test/api/interpreter")
        for invalid in ["http://example.test/api", "https://name:secret@example.test/api", "https://example.test/api?token=secret", "https://example.test/api#secret", "example.test/api"] {
            do { _ = try RouteProviderConfiguration.validate(invalid); preconditionFailure("Unsafe endpoint accepted") }
            catch RouteSearchError.invalidEndpoint {}
        }
        let publicProvider = RouteProviderConfiguration(endpoint: endpoint, auth: .none, key: "should-not-be-sent")
        let publicRequest = try publicProvider.request(query: "sample query")
        precondition(publicRequest.value(forHTTPHeaderField: "Authorization") == nil && publicRequest.value(forHTTPHeaderField: "X-API-Key") == nil)
        let bearer = RouteProviderConfiguration(endpoint: endpoint, auth: .bearer, key: "example-token")
        let bearerRequest = try bearer.request(query: "sample query")
        precondition(bearerRequest.value(forHTTPHeaderField: "Authorization") == "Bearer example-token")
        precondition(bearerRequest.value(forHTTPHeaderField: "X-API-Key") == nil && bearerRequest.url?.query == nil)
        let header = RouteProviderConfiguration(endpoint: endpoint, auth: .apiKey, key: "other-key")
        let headerRequest = try header.request(query: "sample query")
        precondition(headerRequest.value(forHTTPHeaderField: "X-API-Key") == "other-key")
        precondition(headerRequest.value(forHTTPHeaderField: "Authorization") == nil && headerRequest.url?.query == nil)
        do { _ = try RouteProviderConfiguration(endpoint: endpoint, auth: .bearer, key: nil).request(query: "x"); preconditionFailure("Missing key accepted") }
        catch RouteSearchError.missingKey {}
        do { _ = try RouteProviderConfiguration(endpoint: endpoint, auth: .bearer, key: "x\ny").request(query: "x"); preconditionFailure("Unsafe header accepted") }
        catch RouteSearchError.missingKey {}
        let mockConfig = URLSessionConfiguration.ephemeral
        mockConfig.protocolClasses = [RouteMockProtocol.self]
        let service = NearbyRouteService(session: URLSession(configuration: mockConfig))
        _ = try await service.search(latitude: 48.2, longitude: 16.3, types: [.running], provider: bearer)
        _ = try await service.search(latitude: 48.2, longitude: 16.3, types: [.running], provider: bearer)
        precondition(RouteMockProtocol.requests.count == 1) // same-provider cache
        let query = try NearbyRouteService.query(latitude: 48.2, longitude: 16.3, types: [.running], timeoutSeconds: 90)
        precondition(query.contains("around:4000,48.20000,16.30000") && query.contains("[timeout:90]"))
        precondition(query.contains("[\"route\"~\"^(running)$\"]") && !query.contains("hiking") && !query.contains("foot"))
        let allQuery = try NearbyRouteService.query(latitude: 44.4949, longitude: 11.3426, types: [.running, .foot, .hiking])
        precondition(allQuery.contains("^(running|foot|hiking)$"))
        let walkingQuery = try NearbyRouteService.query(latitude: 48.2, longitude: 16.3, types: [.foot, .hiking])
        precondition(walkingQuery.contains("^(foot|hiking)$") && !walkingQuery.contains("running"))
        do { _ = try NearbyRouteService.query(latitude: 48.2, longitude: 16.3, types: []); preconditionFailure("Empty selection accepted") }
        catch RouteSearchError.noRouteTypes {}
        _ = try await service.search(latitude: 48.2, longitude: 16.3, types: [.foot], provider: bearer)
        precondition(RouteMockProtocol.requests.count == 2) // filters do not reuse cached running results
        let slowProvider = RouteProviderConfiguration(endpoint: endpoint, auth: .none, key: nil, timeoutSeconds: 90)
        let slowRequest = try slowProvider.request(query: query)
        precondition(slowRequest.timeoutInterval == 90)
        precondition(RouteProviderConfiguration.boundedTimeout(0) == 15 && RouteProviderConfiguration.boundedTimeout(999) == 180)
        let otherEndpoint = try RouteProviderConfiguration.validate("https://other.test/interpreter")
        let other = RouteProviderConfiguration(endpoint: otherEndpoint, auth: .none, key: nil)
        _ = try await service.search(latitude: 48.2, longitude: 16.3, types: [.running], provider: other)
        precondition(RouteMockProtocol.requests.count == 3)
        precondition(RouteMockProtocol.requests[2].url == otherEndpoint && RouteMockProtocol.requests[2].value(forHTTPHeaderField: "Authorization") == nil)
        let guardDelegate = RouteRedirectGuard()
        let redirectSession = URLSession(configuration: .ephemeral)
        let redirectResponse = HTTPURLResponse(url: endpoint, statusCode: 302, httpVersion: nil, headerFields: nil)!
        var redirected: URLRequest? = bearerRequest
        guardDelegate.urlSession(redirectSession, task: redirectSession.dataTask(with: bearerRequest), willPerformHTTPRedirection: redirectResponse,
                                 newRequest: URLRequest(url: otherEndpoint)) { redirected = $0 }
        precondition(redirected == nil) // never forward keys or coordinates to redirects
        print("Routes tests passed: relation parsing, invalid coordinates, disconnected segments, missing geometry, provider validation/auth, credential isolation, redirect protection, provider cache isolation.")
    }
}
