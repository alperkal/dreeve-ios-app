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
    @Published private(set) var calendarMonthActivities: [DreeveActivity] = []
    @Published private(set) var hasMore = true
    @Published private(set) var isLoadingActivities = false
    @Published private(set) var isLoadingInsights = false
    @Published private(set) var didLoadInsights = false
    @Published var errorMessage: String?

    @Published private(set) var activityIndexRevision = 0
    @Published private(set) var isSyncingActivityIndex = false
    @Published private(set) var activityIndexComplete = false
    @Published private(set) var activityIndexCount = 0
    @Published private(set) var activitySyncError: String?
    @Published private(set) var lastActivitySync: Date?

    var showsActivityIndexStatus: Bool {
        isSyncingActivityIndex || !activityIndexComplete || activitySyncError != nil ||
            (lastActivitySync.map { Date.now.timeIntervalSince($0) > 300 } ?? false)
    }

    let activityIndexStore: ActivityIndexStore?
    private let activitySyncEngine: ActivitySyncEngine?
    private var indexSyncTask: (id: UUID, generation: Int, full: Bool, task: Task<Void, Never>)?
    private var connectionGeneration = 0
    private var lastImportIDs = Set<String>()
    private var pendingImportFilenames = Set<String>()

    let goalProgress = GoalProgressStore()

    private var page = 0
    private let pageSize = 25
    private var client: DreeveAPIClient? {
        guard let url = try? DreeveAPIClient.validatedURL(serverAddress), let key = KeychainStore.read() else { return nil }
        return DreeveAPIClient(baseURL: url, token: key)
    }

    init(activityIndexStore suppliedStore: ActivityIndexStore? = nil) {
        do {
            let store = try suppliedStore ?? ActivityIndexStore()
            activityIndexStore = store
            activitySyncEngine = ActivitySyncEngine(store: store)
        } catch {
            activityIndexStore = nil
            activitySyncEngine = nil
            activitySyncError = "Saved activities are unavailable. " + error.localizedDescription
        }
        serverAddress = UserDefaults.standard.string(forKey: "dreeve.url") ?? ""
        isConfigured = client != nil
        if let client { goalProgress.selectInstance(GoalEngine.instanceID(client.baseURL)) }
    }

    func configuredClient() throws -> DreeveAPIClient {
        guard let client else { throw APIError.notConfigured }
        return client
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
        resetIndexConnection()
        serverAddress = normalized
        goalProgress.selectInstance(GoalEngine.instanceID(url))
        serverVersion = status.version
        canUpload = status.canUpload
        activities = []
        insightsActivities = []
        calendarMonthActivities = []
        page = 0
        hasMore = true
        didLoadInsights = false
        isConfigured = true
    }

    func disconnect() {
        resetIndexConnection()
        goalProgress.selectInstance("")
        KeychainStore.delete()
        UserDefaults.standard.removeObject(forKey: "dreeve.url")
        serverAddress = ""
        serverVersion = ""
        canUpload = false
        isConfigured = false
        activities = []
        insightsActivities = []
        calendarMonthActivities = []
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

    private func syncErrorDescription(_ error: Error) -> String {
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return "You appear to be offline. Refresh when connected."
            case .timedOut:
                return "The connection timed out. Pull to try again."
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return "The server is unreachable. Check your connection and server address."
            default: break
            }
        }
        return error.localizedDescription
    }

    private func resetIndexConnection() {
        connectionGeneration += 1
        indexSyncTask = nil
        lastActivitySync = nil
        activitySyncError = nil
        activityIndexComplete = false
        activityIndexCount = 0
        isSyncingActivityIndex = false
        isLoadingInsights = false
        lastImportIDs = []
        pendingImportFilenames = []
        activityIndexRevision += 1
        goalProgress.finishIndexRefresh(error: nil)
    }

    /// Load cached summaries before waiting for the network. Partial cold histories
    /// remain available to Gear, but never replace a complete goal/dashboard snapshot.
    func loadCachedActivityIndex() async {
        guard let client, let store = activityIndexStore else { return }
        let generation = connectionGeneration
        let scope = GoalEngine.instanceID(client.baseURL)
        do {
            let status = try await store.cursorStatus(instanceHash: scope)
            guard generation == connectionGeneration else { return }
            activityIndexComplete = status.completed
            activityIndexCount = status.count
            activityIndexRevision += 1
            guard status.completed else { return }
            let week = GoalCalendar.period(.weekly)
            let month = GoalCalendar.period(.monthly)
            let today = GoalCalendar.today()
            let insightStart = GoalCalendar.addingDays(-29, to: today)
            let from = min(insightStart, min(week.start, month.start))
            let to = max(week.lastDay, month.lastDay)
            let revision = await store.mutationRevision(instanceHash: scope)
            let records = try await store.queryDateRange(instanceHash: scope, fromDayKeyInclusive: from, toDayKeyInclusive: to)
            let refreshed = try await store.lastSuccessfulSync(instanceHash: scope)
            // Loading an old index offline must not advance its history coverage.
            let historyDay = refreshed.map { min(today, GoalCalendar.today(now: $0)) }
            let streakHistory: GoalStreakHistory?
            if let historyDay { streakHistory = try await store.goalStreakHistory(instanceHash: scope, throughDay: historyDay) }
            else { streakHistory = nil }
            let currentRevision = await store.mutationRevision(instanceHash: scope)
            guard generation == connectionGeneration, revision == currentRevision else { return }
            insightsActivities = records.filter { $0.localDayKey >= insightStart && $0.localDayKey <= today }.map(\.activity)
            calendarMonthActivities = records.filter { $0.localDayKey >= month.start && $0.localDayKey <= today }.map(\.activity)
            didLoadInsights = true
            if let refreshed {
                lastActivitySync = refreshed
                goalProgress.acceptIndexSnapshot(GoalSnapshot(instanceID: scope, from: min(week.start, month.start),
                    to: to, refreshedAt: refreshed, activities: try records.map { try GoalActivity($0.activity) }, streakHistory: streakHistory))
            }
        } catch {
            if generation == connectionGeneration { activitySyncError = error.localizedDescription }
        }
    }

    func syncActivityIndex(forceFullReconcile: Bool = false, bypassThrottle: Bool = false) async {
        guard let client, let engine = activitySyncEngine else { return }
        let generation = connectionGeneration
        if let existing = indexSyncTask, existing.generation == generation {
            await existing.task.value
            if forceFullReconcile && !existing.full {
                await syncActivityIndex(forceFullReconcile: true)
            }
            return
        }
        // Multiple screens and the foreground timer share one refresh. A successful
        // just-completed refresh need not be repeated by another screen immediately.
        if !forceFullReconcile && !bypassThrottle, activityIndexComplete, let lastActivitySync,
           Date.now.timeIntervalSince(lastActivitySync) < 15, activitySyncError == nil {
            await loadCachedActivityIndex()
            return
        }
        let id = UUID()
        let scope = GoalEngine.instanceID(client.baseURL)
        let task = Task {
            guard generation == self.connectionGeneration else { return }
            self.isSyncingActivityIndex = true
            self.goalProgress.beginIndexRefresh()
            await self.loadCachedActivityIndex()
            do {
                // A local edit/delete invalidates an older in-flight scan. Retry it
                // once so the old response cannot resurrect the pre-edit activity.
                do { _ = try await engine.sync(instanceHash: scope, fetcher: client, forceFullReconcile: forceFullReconcile) }
                catch ActivitySyncError.changedDuringSync {
                    _ = try await engine.sync(instanceHash: scope, fetcher: client, forceFullReconcile: forceFullReconcile)
                }
                guard generation == self.connectionGeneration else { return }
                self.activitySyncError = nil
                await self.loadCachedActivityIndex()
                self.goalProgress.finishIndexRefresh(error: self.activitySyncError)
            } catch {
                guard generation == self.connectionGeneration else { return }
                // Keep cached values and label them stale. Cancellation isn't a request failure.
                let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
                self.activitySyncError = cancelled ? nil : self.syncErrorDescription(error)
                await self.loadCachedActivityIndex()
                self.goalProgress.finishIndexRefresh(error: self.activitySyncError)
            }
            guard generation == self.connectionGeneration else { return }
            self.isSyncingActivityIndex = false
            if self.indexSyncTask?.id == id { self.indexSyncTask = nil }
        }
        indexSyncTask = (id, generation, forceFullReconcile, task)
        await task.value
    }

    func refreshInsights(forceFullReconcile: Bool = false) async {
        let generation = connectionGeneration
        isLoadingInsights = true
        errorMessage = nil
        await syncActivityIndex(forceFullReconcile: forceFullReconcile)
        if generation == connectionGeneration { isLoadingInsights = false }
    }

    func refreshGoals(forceFullReconcile: Bool = false) async {
        var reconcile = forceFullReconcile
        if !pendingImportFilenames.isEmpty, let client {
            let generation = connectionGeneration
            if let imports = try? await client.fileImports().fileImports {
                guard generation == connectionGeneration else { return }
                reconcile = consumeCompletedImports(imports) || reconcile
            }
        }
        await syncActivityIndex(forceFullReconcile: reconcile)
    }

    func notePendingImport(filename: String) { pendingImportFilenames.insert(filename) }

    private func consumeCompletedImports(_ imports: [DreeveImport]) -> Bool {
        let completedFiles = Set(imports.filter { $0.activityId != nil }.map(\.filename))
        let finishedPending = !completedFiles.intersection(pendingImportFilenames).isEmpty
        pendingImportFilenames.subtract(completedFiles)
        let completedIDs = Set(imports.compactMap(\.activityId))
        let hasNew = !completedIDs.subtracting(lastImportIDs).isEmpty
        lastImportIDs = completedIDs
        return finishedPending || hasNew
    }

    func indexedActivities(gearID: String) async throws -> [DreeveActivity] {
        guard let client, let store = activityIndexStore else { throw APIError.notConfigured }
        let generation = connectionGeneration
        let records = try await store.queryByGear(instanceHash: GoalEngine.instanceID(client.baseURL), gearId: gearID)
        guard generation == connectionGeneration else { throw CancellationError() }
        return records.map(\.activity)
    }


    func getActivity(_ id: String) async throws -> DreeveActivity {
        guard let client else { throw APIError.notConfigured }
        return try await client.activity(id)
    }

    func saveActivity(_ id: String, patch: ActivityPatch) async throws -> DreeveActivity {
        guard let client else { throw APIError.notConfigured }
        let generation = connectionGeneration
        let changed = try await client.editActivity(id, patch: patch)
        guard generation == connectionGeneration else { return changed }
        var indexed = false
        if let store = activityIndexStore {
            do {
                try await store.applyWriteThroughEdit(instanceHash: GoalEngine.instanceID(client.baseURL), updated: ActivitySummaryRecord(changed))
                indexed = true
            } catch { if generation == connectionGeneration { activitySyncError = error.localizedDescription } }
        }
        guard generation == connectionGeneration else { return changed }
        activityIndexRevision += 1
        if let i = activities.firstIndex(where: { $0.id == id }) { activities[i] = changed }
        if let i = insightsActivities.firstIndex(where: { $0.id == id }) { insightsActivities[i] = changed }
        if let i = calendarMonthActivities.firstIndex(where: { $0.id == id }) { calendarMonthActivities[i] = changed }
        goalProgress.changed(changed)
        if indexed { await loadCachedActivityIndex() }
        return changed
    }

    func removeActivity(_ id: String) async throws {
        guard let client else { throw APIError.notConfigured }
        let generation = connectionGeneration
        try await client.deleteActivity(id)
        guard generation == connectionGeneration else { return }
        var indexed = false
        if let store = activityIndexStore {
            do {
                try await store.applyWriteThroughDelete(instanceHash: GoalEngine.instanceID(client.baseURL), activityId: id)
                indexed = true
            } catch { if generation == connectionGeneration { activitySyncError = error.localizedDescription } }
        }
        guard generation == connectionGeneration else { return }
        activityIndexRevision += 1
        activities.removeAll { $0.id == id }
        insightsActivities.removeAll { $0.id == id }
        calendarMonthActivities.removeAll { $0.id == id }
        goalProgress.changed(deletedID: id)
        if indexed { await loadCachedActivityIndex() }
    }

    func uploadActivity(_ url: URL) async throws -> UploadReceipt {
        guard let client else { throw APIError.notConfigured }
        let generation = connectionGeneration
        let receipt = try await client.uploadActivity(fileURL: url)
        guard generation == connectionGeneration else { return receipt }
        notePendingImport(filename: url.lastPathComponent)
        await syncActivityIndex(bypassThrottle: true)
        return receipt
    }

    func imports() async throws -> [DreeveImport] {
        guard let client else { throw APIError.notConfigured }
        let generation = connectionGeneration
        let imports = try await client.fileImports().fileImports
        guard generation == connectionGeneration else { throw CancellationError() }
        await syncActivityIndex(forceFullReconcile: consumeCompletedImports(imports))
        return imports
    }

    func gear() async throws -> [DreeveGear] {
        guard let client else { throw APIError.notConfigured }
        return try await client.gear()
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
