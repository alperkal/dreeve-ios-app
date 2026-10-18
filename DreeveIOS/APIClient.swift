import Foundation

struct DreeveAPIClient: Sendable {
    let baseURL: URL
    let token: String
    private let urlSession: URLSession

    init(baseURL: URL, token: String, urlSession: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.urlSession = urlSession
    }

    static func validatedURL(_ address: String) throws -> URL {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parts = URLComponents(string: trimmed),
              parts.scheme?.lowercased() == "https", parts.host != nil,
              parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              let url = parts.url else { throw APIError.invalidURL }
        return url
    }

    /// Website route, separate from /api/v1; never includes the API token.
    func activityWebURL(_ id: String) throws -> URL {
        let root = try Self.validatedURL(baseURL.absoluteString)
        guard id.hasPrefix("activity-"), id.count > "activity-".count,
              !id.contains("/"), !id.contains("\\"),
              let segment = id.addingPercentEncoding(withAllowedCharacters:
                CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))) else {
            throw APIError.invalidURL
        }
        let address = root.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: address + "/activities/" + segment) else { throw APIError.invalidURL }
        return url
    }

    private func endpoint(_ path: String, query: [URLQueryItem] = []) throws -> URL {
        // Relative to the deployment root, preserves an optional subpath.
        let root = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var parts = URLComponents(string: root + "/api/v1/" + path) else { throw APIError.invalidURL }
        parts.queryItems = query.isEmpty ? nil : query
        guard let url = parts.url else { throw APIError.invalidURL }
        return url
    }

    private func perform<T: Decodable>(
        _ method: String = "GET", path: String, query: [URLQueryItem] = [], body: Data? = nil
    ) async throws -> T {
        var request = URLRequest(url: try endpoint(path, query: query))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await urlSession.data(for: request)
        try check(response, data: data)
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw APIError.decoding(error.localizedDescription) }
    }

    private func check(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw APIError.unexpectedResponse }
        guard (200...299).contains(http.statusCode) else {
            let server = try? JSONDecoder().decode(ServerError.self, from: data)
            throw APIError.http(http.statusCode, server?.message ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
        }
    }

    func status() async throws -> DreeveStatus { try await perform(path: "status") }

    func activities(page: Int = 1, size: Int = 25, from: String? = nil, to: String? = nil, sport: String? = nil) async throws -> ActivityPage {
        var query = [
            URLQueryItem(name: "pagination[page]", value: String(page)),
            URLQueryItem(name: "pagination[size]", value: String(size))
        ]
        if let from { query.append(URLQueryItem(name: "filters[from]", value: from)) }
        if let to { query.append(URLQueryItem(name: "filters[to]", value: to)) }
        if let sport { query.append(URLQueryItem(name: "filters[sportType]", value: sport)) }
        return try await perform(path: "activities", query: query)
    }

    /// Public v1 has no gear filter. Read every page and match complete gear IDs locally.
    func activitiesForGear(_ gearID: String) async throws -> [DreeveActivity] {
        var matches: [DreeveActivity] = []
        var seen = Set<String>()
        var next = 1
        while true {
            try Task.checkCancellation()
            let result = try await activities(page: next, size: 100)
            guard result.pagination.page == next, result.pagination.totalPages >= 0,
                  !result.activities.isEmpty || next >= result.pagination.totalPages else {
                throw APIError.decoding("Incomplete activity history. Pull to refresh and try again.")
            }
            for activity in result.activities where seen.insert(activity.id).inserted {
                if activity.gearId == gearID { matches.append(activity) }
            }
            if next >= result.pagination.totalPages { break }
            next += 1
        }
        return matches
    }

    /// Date filters are inclusive local calendar days; size is capped at 100 by v1.
    func allGoalActivities(from: String, to: String) async throws -> [GoalActivity] {
        var unique: [String: GoalActivity] = [:]
        var page = 1
        while true {
            try Task.checkCancellation()
            let result = try await activities(page: page, size: 100, from: from, to: to)
            guard result.pagination.page == page, result.pagination.totalPages >= 0,
                  !result.activities.isEmpty || page >= result.pagination.totalPages else {
                throw APIError.decoding("Incomplete or invalid activity pagination; saved progress was kept.")
            }
            for activity in result.activities {
                let value = try GoalActivity(activity)
                // Newest-first API: preserve the first copy of overlapping page records.
                if unique[value.id] == nil { unique[value.id] = value }
            }
            if page >= result.pagination.totalPages { break }
            page += 1
        }
        return unique.values.sorted { $0.id < $1.id }
    }

    func activity(_ id: String) async throws -> DreeveActivity {
        try await perform(path: "activities/\(safeSegment(id))")
    }

    func editActivity(_ id: String, patch: ActivityPatch) async throws -> DreeveActivity {
        try await perform("PATCH", path: "activities/\(safeSegment(id))", body: try JSONEncoder().encode(patch))
    }

    func deleteActivity(_ id: String) async throws {
        var request = URLRequest(url: try endpoint("activities/\(safeSegment(id))"))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await urlSession.data(for: request)
        try check(response, data: data)
    }

    func uploadActivity(fileURL: URL) async throws -> UploadReceipt {
        let ext = fileURL.pathExtension.lowercased()
        guard ["fit", "tcx", "gpx"].contains(ext) else { throw APIError.unsupportedFile }
        let access = fileURL.startAccessingSecurityScopedResource()
        defer { if access { fileURL.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: fileURL)
        return try await upload(path: "activity/upload", data: data, filename: fileURL.lastPathComponent, mime: "application/octet-stream")
    }

    func uploadActivity(data: Data, filename: String) async throws -> UploadReceipt {
        guard ["fit", "tcx", "gpx"].contains(URL(fileURLWithPath: filename).pathExtension.lowercased()) else { throw APIError.unsupportedFile }
        return try await upload(path: "activity/upload", data: data, filename: filename, mime: "application/octet-stream")
    }

    func fileImports(page: Int = 1, size: Int = 50, filename: String? = nil) async throws -> ImportPage {
        var query = [URLQueryItem(name: "pagination[page]", value: String(page)),
                     URLQueryItem(name: "pagination[size]", value: String(size))]
        if let filename { query.append(URLQueryItem(name: "filters[filename]", value: filename)) }
        return try await perform(path: "file-imports", query: query)
    }

    func gear() async throws -> [DreeveGear] {
        let result: GearPage = try await perform(path: "gear")
        return result.gear
    }

    /// Local photo URLs are generated from Dreeve's APP_URL, which can differ from
    /// the HTTPS address reachable by this device (for example behind a reverse proxy).
    func activityPhotoURL(_ raw: String) throws -> URL {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, var parts = URLComponents(string: value),
              parts.user == nil, parts.password == nil else { throw ActivityPhotoError.invalidURL }
        if let route = parts.percentEncodedPath.range(of: "/files/activities/") {
            guard var configured = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
                throw ActivityPhotoError.invalidURL
            }
            let prefix = configured.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            configured.percentEncodedPath = (prefix.isEmpty ? "" : "/" + prefix) + String(parts.percentEncodedPath[route.lowerBound...])
            configured.percentEncodedQuery = parts.percentEncodedQuery
            parts = configured
        } else if parts.scheme == nil && parts.host == nil {
            let root = baseURL.appendingPathComponent("")
            guard let resolved = URL(string: value, relativeTo: root)?.absoluteURL,
                  let resolvedParts = URLComponents(url: resolved, resolvingAgainstBaseURL: false) else {
                throw ActivityPhotoError.invalidURL
            }
            parts = resolvedParts
        }
        guard parts.scheme?.lowercased() == "https", parts.host != nil,
              parts.user == nil, parts.password == nil, let url = parts.url else {
            throw ActivityPhotoError.invalidURL
        }
        return url
    }

    func activityPhoto(_ raw: String) async throws -> Data {
        // File URLs are website resources, not v1 endpoints. Never forward the API
        // bearer token to photo hosts or assume it authenticates the website login.
        var request = URLRequest(url: try activityPhotoURL(raw), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.unexpectedResponse }
        if [401, 403].contains(http.statusCode) { throw ActivityPhotoError.websiteLogin }
        guard (200...299).contains(http.statusCode) else { throw ActivityPhotoError.unavailable(http.statusCode) }
        if http.mimeType?.lowercased() == "text/html" { throw ActivityPhotoError.websiteLogin }
        guard data.count <= 25 * 1024 * 1024 else { throw ActivityPhotoError.tooLarge }
        guard !data.isEmpty else { throw ActivityPhotoError.notImage }
        return data
    }

    func downloadGPX(_ id: String) async throws -> URL {
        var request = URLRequest(url: try endpoint("activities/\(safeSegment(id))/gpx"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await urlSession.data(for: request)
        try check(response, data: data)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dreeve-\(safeFilename(id)).gpx")
        try data.write(to: url, options: .atomic)
        return url
    }

    func uploadImage(_ id: String, imageData: Data) async throws -> ActivityImage {
        try await upload(path: "activities/\(safeSegment(id))/images", data: imageData, filename: "photo.jpg", mime: "image/jpeg")
    }

    private func upload<T: Decodable>(path: String, data: Data, filename: String, mime: String) async throws -> T {
        let boundary = UUID().uuidString
        var request = URLRequest(url: try endpoint(path))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var payload = Data()
        payload.append(Data("--\(boundary)\r\n".utf8))
        payload.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(safeFilename(filename))\"\r\n".utf8))
        payload.append(Data("Content-Type: \(mime)\r\n\r\n".utf8))
        payload.append(data)
        payload.append(Data("\r\n--\(boundary)--\r\n".utf8))
        let (responseData, response) = try await urlSession.upload(for: request, from: payload)
        try check(response, data: responseData)
        return try JSONDecoder().decode(T.self, from: responseData)
    }

    private func safeSegment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?&#"))) ?? value
    }

    private func safeFilename(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "_").replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: "\r", with: "_").replacingOccurrences(of: "\n", with: "_")
    }
}

private struct ServerError: Decodable { let error: String; let message: String }

enum APIError: LocalizedError {
    case invalidURL
    case unexpectedResponse
    case http(Int, String)
    case decoding(String)
    case unsupportedFile
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Enter a valid HTTPS URL for your Dreeve instance."
        case .unexpectedResponse: return "Unexpected server response."
        case .http(let code, let message): return "Server returned \(code): \(message)"
        case .decoding(let info): return "Unexpected data from Dreeve: \(info)"
        case .unsupportedFile: return "Choose a .fit, .tcx or .gpx activity file."
        case .notConfigured: return "Connect your Dreeve instance in Settings first."
        }
    }
}

enum ActivityPhotoError: LocalizedError {
    case invalidURL, websiteLogin, notImage, tooLarge
    case unavailable(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "The photo link is not a valid HTTPS address."
        case .websiteLogin: return "This photo needs website access. Open it in your browser."
        case .notImage: return "The server did not return a supported photo."
        case .tooLarge: return "This photo is too large to display."
        case .unavailable(let code): return "Photo unavailable (HTTP \(code))."
        }
    }
}
