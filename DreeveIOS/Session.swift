import Foundation
import SwiftUI

@MainActor
final class DreeveSession: ObservableObject {
    @Published private(set) var isConfigured: Bool = false
    @Published private(set) var serverAddress: String = ""
    @Published private(set) var serverVersion: String = ""
    @Published private(set) var canUpload: Bool = false
    @Published private(set) var activities: [DreeveActivity] = []
    @Published private(set) var insightsActivities: [DreeveActivity] = []
    @Published private(set) var hasMore = true
    @Published private(set) var isLoadingActivities = false
    @Published private(set) var isLoadingInsights = false
    @Published private(set) var didLoadInsights = false
    @Published var errorMessage: String?

    private var page = 0
    private let pageSize = 25
    private var client: DreeveAPIClient? {
        guard let url = try? DreeveAPIClient.validatedURL(serverAddress), let key = KeychainStore.read() else { return nil }
        return DreeveAPIClient(baseURL: url, token: key)
    }

    init() {
        serverAddress = UserDefaults.standard.string(forKey: "dreeve.url") ?? ""
        isConfigured = client != nil
    }

    func connect(address: String, key: String) async throws {
        let url = try DreeveAPIClient.validatedURL(address)
        let token = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.hasPrefix("drv_"), token.count == 68,
              token.dropFirst(4).allSatisfy({ $0.isHexDigit }) else {
            throw APIError.http(400, "Expected a Dreeve API key starting with drv_ followed by 64 hexadecimal characters.")
        }
        let testClient = DreeveAPIClient(baseURL: url, token: token)
        let status = try await testClient.status()
        guard status.app == "dreeve" else { throw APIError.unexpectedResponse }
        try KeychainStore.save(token)
        let normalized = address.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        UserDefaults.standard.set(normalized, forKey: "dreeve.url")
        serverAddress = normalized
        serverVersion = status.version
        canUpload = status.canUpload
        activities = []
        insightsActivities = []
        page = 0
        hasMore = true
        didLoadInsights = false
        isConfigured = true
    }

    func disconnect() {
        KeychainStore.delete()
        UserDefaults.standard.removeObject(forKey: "dreeve.url")
        serverAddress = ""
        serverVersion = ""
        canUpload = false
        isConfigured = false
        activities = []
        insightsActivities = []
        page = 0
        hasMore = true
        didLoadInsights = false
    }

    func testConnection() async throws -> DreeveStatus {
        guard let client else { throw APIError.notConfigured }
        let status = try await client.status()
        serverVersion = status.version
        canUpload = status.canUpload
        return status
    }

    func reloadActivities() async {
        guard !isLoadingActivities else { return }
        page = 0
        hasMore = true
        activities = []
        await loadMoreActivities()
    }

    func loadMoreActivities() async {
        guard !isLoadingActivities, hasMore, let client else { return }
        isLoadingActivities = true
        defer { isLoadingActivities = false }
        do {
            let next = page + 1
            let result = try await client.activities(page: next, size: pageSize)
            activities += result.activities
            page = next
            hasMore = next < result.pagination.totalPages
        } catch { errorMessage = error.localizedDescription }
    }

    func refreshInsights() async {
        guard !isLoadingInsights, let client else { return }
        isLoadingInsights = true
        defer { isLoadingInsights = false }
        do {
            let start = Calendar.current.date(byAdding: .day, value: -29, to: Calendar.current.startOfDay(for: .now)) ?? .now
            let date = ActivityDates.calendarDate.string(from: start)
            var all: [DreeveActivity] = []
            var next = 1
            // Exhaust all pages for the selected 30-day period, no sampling.
            while true {
                let result = try await client.activities(page: next, size: 100, from: date)
                all += result.activities
                if next >= result.pagination.totalPages { break }
                next += 1
            }
            insightsActivities = all
            didLoadInsights = true
        } catch { errorMessage = error.localizedDescription }
    }

    func getActivity(_ id: String) async throws -> DreeveActivity {
        guard let client else { throw APIError.notConfigured }
        return try await client.activity(id)
    }

    func saveActivity(_ id: String, patch: ActivityPatch) async throws -> DreeveActivity {
        guard let client else { throw APIError.notConfigured }
        let changed = try await client.editActivity(id, patch: patch)
        if let i = activities.firstIndex(where: { $0.id == id }) { activities[i] = changed }
        if let i = insightsActivities.firstIndex(where: { $0.id == id }) { insightsActivities[i] = changed }
        return changed
    }

    func removeActivity(_ id: String) async throws {
        guard let client else { throw APIError.notConfigured }
        try await client.deleteActivity(id)
        activities.removeAll { $0.id == id }
        insightsActivities.removeAll { $0.id == id }
    }

    func uploadActivity(_ url: URL) async throws -> UploadReceipt {
        guard let client else { throw APIError.notConfigured }
        return try await client.uploadActivity(fileURL: url)
    }

    func imports() async throws -> [DreeveImport] {
        guard let client else { throw APIError.notConfigured }
        return try await client.fileImports().fileImports
    }

    func gpx(_ id: String) async throws -> URL {
        guard let client else { throw APIError.notConfigured }
        return try await client.downloadGPX(id)
    }

    func attachImage(_ id: String, data: Data) async throws {
        guard let client else { throw APIError.notConfigured }
        _ = try await client.uploadImage(id, imageData: data)
    }
}
