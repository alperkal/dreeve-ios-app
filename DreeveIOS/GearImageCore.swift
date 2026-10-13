import Foundation
import CryptoKit

enum GearPhotoPhase: Equatable { case locked, unlocked, loading, choosing }
enum GearPhotoAction: Equatable { case unlock, search, next, none }

/// One selection session: unlock -> fresh search -> next results -> accept after 10 seconds.
struct GearPhotoSelection {
    private(set) var phase: GearPhotoPhase = .locked
    private(set) var deadline: Date?
    static let decisionSeconds: TimeInterval = 10

    mutating func tap(now: Date = .now) -> GearPhotoAction {
        _ = expire(now: now)
        switch phase {
        case .locked: phase = .unlocked; return .unlock
        case .unlocked: phase = .loading; deadline = nil; return .search
        case .choosing: phase = .loading; deadline = nil; return .next
        case .loading: return .none
        }
    }
    mutating func displayed(now: Date = .now) {
        phase = .choosing
        deadline = now.addingTimeInterval(Self.decisionSeconds)
    }
    mutating func failed(hasPreview: Bool, now: Date = .now) {
        if hasPreview { displayed(now: now) }
        else { phase = .unlocked; deadline = nil }
    }
    @discardableResult mutating func expire(now: Date = .now) -> Bool {
        guard phase == .choosing, let deadline, now >= deadline else { return false }
        reset()
        return true
    }
    mutating func reset() { phase = .locked; deadline = nil }
    func secondsRemaining(now: Date = .now) -> Int {
        guard let deadline else { return 0 }
        return max(0, min(10, Int(ceil(deadline.timeIntervalSince(now)))))
    }
}

struct GearImageResult: Equatable, Sendable {
    let imageURL: URL
    let thumbnailURL: URL?
    let title: String
}

private struct SearXImagePage: Decodable { let results: [SearXImageHit] }
private struct SearXImageHit: Decodable {
    let img_src: String?
    let thumbnail_src: String?
    let thumbnail: String?
    let title: String?
}

enum GearImageError: LocalizedError {
    case invalidEndpoint, http(Int), notJSON, noResults, invalidImage, imageTooLarge, exhausted
    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return "Enter an HTTPS SearXNG search URL in Settings."
        case .http(let code): return code == 403
            ? "Search access denied. Check SearXNG access and enable JSON in search.formats."
            : "Image request failed (HTTP \(code)). Tap to retry."
        case .notJSON: return "SearXNG did not return JSON. Enable JSON in search.formats."
        case .noResults: return "No downloadable image results. Tap to search again."
        case .invalidImage: return "This result is not a supported image."
        case .imageTooLarge: return "This image is too large to use."
        case .exhausted: return "No more usable images. This image will save when the timer ends."
        }
    }
}

struct GearImageSearchClient: Sendable {
    static let defaultEndpoint = "https://search.home.alperkal.com/search"
    let urlSession: URLSession

    init(urlSession: URLSession? = nil) {
        if let urlSession { self.urlSession = urlSession }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.urlCache = nil
            config.httpShouldSetCookies = false
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.timeoutIntervalForRequest = 20
            config.timeoutIntervalForResource = 40
            self.urlSession = URLSession(configuration: config)
        }
    }
    static func endpoint(_ address: String) throws -> URL {
        guard var parts = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme?.lowercased() == "https", parts.host?.isEmpty == false,
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              parts.query == nil else { throw GearImageError.invalidEndpoint }
        if parts.path.isEmpty || parts.path == "/" { parts.path = "/search" }
        guard let url = parts.url else { throw GearImageError.invalidEndpoint }
        return url
    }
    private static func imageURL(_ text: String?) -> URL? {
        guard let text, let url = URL(string: text), url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false, url.user == nil, url.password == nil else { return nil }
        return url
    }
    static func decodeResults(_ data: Data) throws -> [GearImageResult] {
        guard data.count <= 4_000_000, let page = try? JSONDecoder().decode(SearXImagePage.self, from: data) else {
            throw GearImageError.notJSON
        }
        // Retain the search engine's result order. Unsupported HTTP/data URLs are skipped.
        let images = page.results.compactMap { hit -> GearImageResult? in
            let thumbnail = imageURL(hit.thumbnail_src) ?? imageURL(hit.thumbnail)
            guard let image = imageURL(hit.img_src) ?? thumbnail else { return nil }
            return GearImageResult(imageURL: image, thumbnailURL: thumbnail, title: hit.title ?? "")
        }
        guard !images.isEmpty else { throw GearImageError.noResults }
        return images
    }
    func search(gearName: String, endpoint address: String) async throws -> [GearImageResult] {
        var parts = URLComponents(url: try Self.endpoint(address), resolvingAgainstBaseURL: false)!
        parts.queryItems = [
            URLQueryItem(name: "q", value: gearName + " running shoe product photo"),
            URLQueryItem(name: "categories", value: "images"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "safesearch", value: "1"),
            URLQueryItem(name: "pageno", value: "1")
        ]
        var request = URLRequest(url: parts.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try Self.decodeResults(await boundedData(request, limit: 4_000_000))
    }
    static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw GearImageError.invalidImage }
        guard (200...299).contains(http.statusCode) else { throw GearImageError.http(http.statusCode) }
        guard http.url?.scheme?.lowercased() == "https" else { throw GearImageError.invalidImage }
    }
    func download(_ url: URL) async throws -> Data {
        guard Self.imageURL(url.absoluteString) != nil else { throw GearImageError.invalidImage }
        var request = URLRequest(url: url)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        return try await boundedData(request, limit: 12_000_000)
    }
    private func boundedData(_ request: URLRequest, limit: Int) async throws -> Data {
        let (bytes, response) = try await urlSession.bytes(for: request)
        try Self.check(response)
        guard response.expectedContentLength <= Int64(limit) else { throw GearImageError.imageTooLarge }
        var data = Data()
        for try await byte in bytes {
            if data.count >= limit { throw GearImageError.imageTooLarge }
            data.append(byte)
        }
        guard !data.isEmpty else { throw GearImageError.invalidImage }
        return data
    }
}

struct GearImageCache {
    let directory: URL
    init(directory: URL = URL.applicationSupportDirectory.appendingPathComponent("GearImages", isDirectory: true)) {
        self.directory = directory
    }
    func fileURL(instanceID: String, gearID: String) -> URL {
        let key = SHA256.hash(data: Data((instanceID + "\u{0}" + gearID).utf8))
            .map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(key + ".png")
    }
    func load(instanceID: String, gearID: String) throws -> Data? {
        let url = fileURL(instanceID: instanceID, gearID: gearID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }
    func replace(_ data: Data, instanceID: String, gearID: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var root = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? root.setResourceValues(values)
        // Exactly one file per gear/instance. Atomic replacement removes the previous image
        // only after the new image is ready; no result-history files accumulate.
        try data.write(to: fileURL(instanceID: instanceID, gearID: gearID), options: [.atomic, .completeFileProtectionUnlessOpen])
    }
}
