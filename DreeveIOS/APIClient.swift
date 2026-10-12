import Foundation

struct DreeveAPIClient: Sendable {
    let baseURL: URL
    let token: String

    static func validatedURL(_ address: String) throws -> URL {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parts = URLComponents(string: trimmed),
              parts.scheme?.lowercased() == "https", parts.host != nil,
              parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              let url = parts.url else { throw APIError.invalidURL }
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
        let (data, response) = try await URLSession.shared.data(for: request)
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

    func activities(page: Int = 1, size: Int = 25, from: String? = nil, sport: String? = nil) async throws -> ActivityPage {
        var query = [
            URLQueryItem(name: "pagination[page]", value: String(page)),
            URLQueryItem(name: "pagination[size]", value: String(size))
        ]
        if let from { query.append(URLQueryItem(name: "filters[from]", value: from)) }
        if let sport { query.append(URLQueryItem(name: "filters[sportType]", value: sport)) }
        return try await perform(path: "activities", query: query)
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
        let (data, response) = try await URLSession.shared.data(for: request)
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

    func fileImports() async throws -> ImportPage {
        try await perform(path: "file-imports", query: [URLQueryItem(name: "pagination[size]", value: "50")])
    }

    func gear() async throws -> [DreeveGear] {
        let result: GearPage = try await perform(path: "gear")
        return result.gear
    }

    func downloadGPX(_ id: String) async throws -> URL {
        var request = URLRequest(url: try endpoint("activities/\(safeSegment(id))/gpx"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
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
        let (responseData, response) = try await URLSession.shared.upload(for: request, from: payload)
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
