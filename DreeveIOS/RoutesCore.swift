import Foundation
import MapKit
import CoreLocation

/// OSM route relations are collections of ways, not necessarily one continuous line.
struct MappedRoute: Identifiable {
    struct Point: Decodable { let lat: Double; let lon: Double }
    struct Member: Decodable { let type: String; let geometry: [Point]? }
    struct Element: Decodable { let id: Int64; let tags: [String: String]?; let members: [Member]? }
    struct Response: Decodable { let elements: [Element]; let remark: String? }
    let id: Int64
    let name: String
    let type: String
    let segments: [[CLLocationCoordinate2D]]
    let distance: Double
    let incomplete: Bool

    static func decode(_ data: Data) throws -> [MappedRoute] {
        let response = try JSONDecoder().decode(Response.self, from: data)
        if let remark = response.remark, !remark.isEmpty { throw RouteSearchError.incompleteResponse }
        return response.elements.compactMap { element in
            let ways = (element.members ?? []).filter { $0.type == "way" }
            let segments = ways.compactMap { member -> [CLLocationCoordinate2D]? in
                guard let geometry = member.geometry, geometry.count >= 2,
                      geometry.allSatisfy({ $0.lat.isFinite && $0.lon.isFinite && abs($0.lat) <= 90 && abs($0.lon) <= 180 }) else { return nil }
                return geometry.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
            }
            guard !segments.isEmpty else { return nil }
            let meters = segments.reduce(0.0) { total, segment in
                total + zip(segment, segment.dropFirst()).reduce(0.0) { value, pair in
                    value + CLLocation(latitude: pair.0.latitude, longitude: pair.0.longitude)
                        .distance(from: CLLocation(latitude: pair.1.latitude, longitude: pair.1.longitude))
                }
            }
            let type = element.tags?["route"] ?? "foot"
            return MappedRoute(id: element.id, name: element.tags?["name"] ?? "Unnamed \(type) route", type: type,
                               segments: segments, distance: meters, incomplete: segments.count != ways.count || (element.members ?? []).contains { $0.type == "relation" })
        }
    }
}

enum RouteSearchError: LocalizedError {
    case invalidLocation, invalidResponse, tooLarge, incompleteResponse, invalidEndpoint, missingKey
    case serviceUnavailable(Int)
    var errorDescription: String? {
        switch self {
        case .invalidLocation: return "Choose a valid location on the map."
        case .invalidEndpoint: return "Enter an HTTPS Overpass interpreter URL without credentials, query, or fragment."
        case .missingKey: return "Add an API key for this route provider in Settings."
        case .invalidResponse: return "The route service returned an unexpected response."
        case .serviceUnavailable(let code): return "The route service is unavailable (HTTP \(code)). Try again shortly."
        case .tooLarge: return "The route results were too large. Try another area."
        case .incompleteResponse: return "The route service returned incomplete results. Please try again."
        }
    }
}


enum RouteProviderAuth: String, CaseIterable, Identifiable {
    case none, bearer, apiKey
    var id: String { rawValue }
    var label: String {
        switch self { case .none: return "None"; case .bearer: return "Bearer token"; case .apiKey: return "X-API-Key" }
    }
}
struct RouteProviderConfiguration: Equatable {
    static let defaultEndpoint = "https://overpass-api.de/api/interpreter"
    let endpoint: URL
    let auth: RouteProviderAuth
    let key: String?
    static func validate(_ address: String) throws -> URL {
        let input = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: input), parts.scheme?.lowercased() == "https",
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, parts.port != 0 else { throw RouteSearchError.invalidEndpoint }
        parts.scheme = "https"; parts.host = host.lowercased()
        guard let url = parts.url else { throw RouteSearchError.invalidEndpoint }
        return url
    }
    func request(query: String) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"; request.timeoutInterval = 30
        request.setValue("Dreeve-iOS/1.0 (nearby route search)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        if auth != .none {
            guard let key, !key.isEmpty, !key.contains("\n"), !key.contains("\r") else { throw RouteSearchError.missingKey }
            switch auth {
            case .bearer: request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
            case .apiKey: request.setValue(key, forHTTPHeaderField: "X-API-Key")
            case .none: break
            }
        }
        var parts = URLComponents(); parts.queryItems = [URLQueryItem(name: "data", value: query)]
        request.httpBody = parts.percentEncodedQuery?.data(using: .utf8)
        return request
    }
}
/// Redirects are disabled, so a provider cannot forward credentials or coordinates to another host.
final class RouteRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
actor NearbyRouteService {
    private let session: URLSession
    private var cached: (key: String, provider: RouteProviderConfiguration, time: Date, routes: [MappedRoute])?
    init(session supplied: URLSession? = nil) {
        if let supplied { session = supplied }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil; config.urlCredentialStorage = nil
            session = URLSession(configuration: config, delegate: RouteRedirectGuard(), delegateQueue: nil)
        }
    }
    private var lastRequest: Date?
    func search(latitude: Double, longitude: Double, provider: RouteProviderConfiguration) async throws -> [MappedRoute] {
        guard latitude.isFinite, longitude.isFinite, abs(latitude) <= 90, abs(longitude) <= 180 else { throw RouteSearchError.invalidLocation }
        let key = String(format: "%.3f,%.3f", latitude, longitude)
        if let cached, cached.key == key, cached.provider == provider, Date.now.timeIntervalSince(cached.time) < 300 { return cached.routes }
        if let lastRequest {
            let delay = 2 - Date.now.timeIntervalSince(lastRequest)
            if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
        }
        try Task.checkCancellation()
        lastRequest = .now
        let query = String(format: "[out:json][timeout:20];rel[\"type\"=\"route\"][\"route\"~\"^(running|foot|hiking)$\"](around:3000,%.5f,%.5f);out geom;", locale: Locale(identifier: "en_US_POSIX"), latitude, longitude)
        let request = try provider.request(query: query)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RouteSearchError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw RouteSearchError.serviceUnavailable(http.statusCode) }
        guard data.count <= 5_000_000 else { throw RouteSearchError.tooLarge }
        try Task.checkCancellation()
        let origin = CLLocation(latitude: latitude, longitude: longitude)
        let routes = try MappedRoute.decode(data).sorted { a, b in
            func nearest(_ route: MappedRoute) -> Double {
                route.segments.flatMap { $0 }.map { origin.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude)) }.min() ?? .infinity
            }
            return nearest(a) < nearest(b)
        }
        cached = (key, provider, .now, routes)
        return routes
    }
}

