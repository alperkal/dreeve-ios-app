import Foundation
import SwiftUI

@MainActor
final class HealthSyncStore: ObservableObject {
    @Published private(set) var workouts: [HealthWorkoutSummary] = []
    @Published private(set) var records: [HealthSyncRecord] = []
    @Published private(set) var candidates: [UUID: [DreeveActivity]] = [:]
    @Published private(set) var isBusy = false
    @Published private(set) var isReady = false
    @Published private(set) var progress = ""
    @Published var errorMessage: String?
    @Published private(set) var storageError: String?
    private let reader = AppleHealthReader()
    private var ledger: HealthSyncLedger?
    private var loadedServer = ""
    private var approvedNewUploads: Set<UUID> = []

    init() {
        do {
            let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let ledger = try HealthSyncLedger(url: root.appendingPathComponent("HealthSync/history.json"))
            self.ledger = ledger
            records = ledger.records
        } catch { storageError = error.localizedDescription }
    }

    func visibleWorkouts(server: String) -> [HealthWorkoutSummary] {
        loadedServer == server ? workouts : []
    }

    func authorizeRetry(_ workout: HealthWorkoutSummary, server: String) {
        guard !isBusy, loadedServer == server, var record = record(workout.id, server: server), record.state == .uncertain else { return }
        do {
            record.state = .failed
            record.message = "You authorized a retry. Dreeve import history will be checked again before uploading."
            try save(record)
        } catch { errorMessage = error.localizedDescription }
    }

    func allowNewUpload(_ workoutID: UUID) {
        approvedNewUploads.insert(workoutID)
        candidates[workoutID] = []
    }

    func record(_ workoutID: UUID, server: String) -> HealthSyncRecord? {
        records.first { $0.server == server && $0.workout.id == workoutID }
    }

    func linkedWorkout(activityID: String, server: String) -> HealthWorkoutSummary? {
        records.first { $0.server == server && $0.activityID == activityID }?.workout
    }

    func canSelect(_ workout: HealthWorkoutSummary, server: String) -> Bool {
        guard isReady, loadedServer == server, storageError == nil, !isBusy else { return false }
        let state = record(workout.id, server: server)?.state
        return (state == nil || state == .failed || state == .deleted) && (candidates[workout.id] ?? []).isEmpty
    }

    func load(session: DreeveSession, from: Date, routes: Bool, heartRate: Bool) async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        isReady = false
        workouts = []
        candidates = [:]
        approvedNewUploads = []
        let server = session.serverAddress
        defer { isBusy = false; progress = "" }
        do {
            guard ledger != nil, storageError == nil else { throw HealthSyncError.storageUnavailable }
            let client = try session.configuredClient()
            _ = try await session.testConnection()
            try ensureServer(session, server: server)
            progress = "Requesting Apple Health access…"
            try await reader.authorize(routes: routes, heartRate: heartRate)
            let loaded = try await reader.load(from: from)
            progress = "Checking existing Dreeve activities…"
            let existing = try await existingActivities(client: client, from: from.addingTimeInterval(-86400))
            try ensureServer(session, server: server)
            loadedServer = server
            workouts = loaded
            for workout in loaded {
                candidates[workout.id] = HealthWorkoutMatcher.candidates(for: workout, activities: existing)
            }
            try await reconcile(client: client, server: server)
            try ensureServer(session, server: server)
            isReady = true
        } catch { if !(error is CancellationError), !Task.isCancelled { errorMessage = error.localizedDescription } }
    }

    func refresh(session: DreeveSession) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false; progress = "" }
        do {
            progress = "Checking import status…"
            let server = session.serverAddress
            let client = try session.configuredClient()
            try await reconcile(client: client, server: server)
            try ensureServer(session, server: server)
            if loadedServer == server, let from = workouts.map(\.start).min() {
                let existing = try await existingActivities(client: client, from: from.addingTimeInterval(-86400))
                try ensureServer(session, server: server)
                for workout in workouts where !approvedNewUploads.contains(workout.id) {
                    candidates[workout.id] = HealthWorkoutMatcher.candidates(for: workout, activities: existing)
                }
            }
            await session.reloadActivities()
            await session.refreshGoals(forceFullReconcile: true)
        } catch { if !(error is CancellationError), !Task.isCancelled { errorMessage = error.localizedDescription } }
    }

    /// Foreground polling also runs outside Health Sync, including after relaunch.
    /// This only checks durable intents; it never uploads or automatically retries.
    func refreshQueuedImports(session: DreeveSession) async {
        let server = session.serverAddress
        let pending = Set(records.filter { $0.server == server && ([.queued, .uncertain, .needsDetails].contains($0.state) || $0.awaitingFeedHandoff) }.map(\.id))
        guard !isBusy, !pending.isEmpty else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let client = try session.configuredClient()
            try await reconcile(client: client, server: server, pendingOnly: true)
            try ensureServer(session, server: server)
        } catch {
            // Keep saved queue rows intact while offline; existing Health Sync
            // refresh exposes request errors when the person explicitly requests it.
        }
        // Even a partial reconciliation may have completed one of several imports.
        guard session.serverAddress == server, !Task.isCancelled else { return }
        if records.contains(where: { pending.contains($0.id) && [.imported, .skipped].contains($0.state) }) {
            await session.reloadActivities()
            await session.refreshGoals(forceFullReconcile: true)
            guard session.serverAddress == server else { return }
            let known = Set((session.activities + session.insightsActivities).map(\.id))
            for var record in records where record.server == server && record.awaitingFeedHandoff {
                if let id = record.activityID, known.contains(id) {
                    record.feedHandoffPending = false
                    try? save(record)
                }
            }
        }
    }

    func sync(ids: Set<UUID>, session: DreeveSession, routes: Bool, heartRate: Bool, continueWhile: () -> Bool = { true }) async {
        guard !isBusy, isReady, loadedServer == session.serverAddress else { return }
        let selected = workouts.filter { ids.contains($0.id) && canSelect($0, server: session.serverAddress) }
        isBusy = true
        let server = session.serverAddress
        defer { isBusy = false; progress = "" }
        do {
            let client = try session.configuredClient()
            guard try await client.status().canUpload else { throw HealthSyncError.fileModeRequired }
            try await reader.authorize(routes: routes, heartRate: heartRate)
            let from = selected.map(\.start).min() ?? .now
            // Refresh the duplicate review immediately before sending, not just when loading.
            let existing = try await existingActivities(client: client, from: from.addingTimeInterval(-86400))
            for (index, workout) in selected.enumerated() {
                try Task.checkCancellation()
                guard continueWhile() else { throw CancellationError() }
                try ensureServer(session, server: server)
                progress = "Syncing \(index + 1) of \(selected.count)…"
                if let remote = try await remoteImport(client: client, workout: workout) {
                    // A confirmed failed import may be retried. Anything else is reconciled.
                    if remote.status != "failed" {
                        try await apply(remote, workout: workout, client: client, server: server)
                        continue
                    }
                }
                let matches = HealthWorkoutMatcher.candidates(for: workout, activities: existing)
                if !matches.isEmpty && !approvedNewUploads.contains(workout.id) {
                    candidates[workout.id] = matches
                    continue
                }
                let exported = try await reader.export(workout, routes: routes, heartRate: heartRate)
                try ensureServer(session, server: server)
                try Task.checkCancellation()
                guard continueWhile() else { throw CancellationError() }
                var pending = HealthSyncRecord(server: server, workout: workout, state: .uncertain,
                    message: "Refresh status to confirm whether Dreeve accepted the file. No automatic retry will be made.", uploadFilename: workout.filename, preview: exported.preview, feedHandoffPending: true)
                // Persist intent BEFORE the request. A crash or timeout must not cause a blind reupload.
                try save(pending)
                do {
                    let receipt = try await client.uploadActivity(data: exported.data, filename: workout.filename)
                    guard receipt.status == "queued" else { throw APIError.unexpectedResponse }
                    session.notePendingImport(filename: workout.filename)
                    pending.state = .queued
                    pending.message = receipt.message
                    try save(pending)
                } catch {
                    if case APIError.http(let code, _) = error, (400...499).contains(code), code != 408 {
                        pending.state = .failed
                    }
                    pending.message = error.localizedDescription
                    try save(pending)
                    errorMessage = error.localizedDescription
                    break
                }
            }
            try await reconcile(client: client, server: server)
            try ensureServer(session, server: server)
            await session.reloadActivities()
            await session.refreshGoals(forceFullReconcile: true)
        } catch { if !(error is CancellationError), !Task.isCancelled { errorMessage = error.localizedDescription } }
    }

    // Called only after the person explicitly confirms an existing activity match.
    func link(_ workout: HealthWorkoutSummary, activity: DreeveActivity, server: String) {
        do {
            guard loadedServer == server, isReady, !isBusy else { throw HealthSyncError.serverChanged }
            try save(HealthSyncRecord(server: server, workout: workout, state: .imported, activityID: activity.id,
                message: "Linked to your existing Dreeve activity. No new file was uploaded."))
            candidates[workout.id] = []
        } catch { errorMessage = error.localizedDescription }
    }

    private func ensureServer(_ session: DreeveSession, server: String) throws {
        guard session.isConfigured, session.serverAddress == server else { throw HealthSyncError.serverChanged }
    }

    private func save(_ record: HealthSyncRecord) throws {
        guard let ledger, storageError == nil else { throw HealthSyncError.storageUnavailable }
        do {
            try ledger.save(record)
            records = ledger.records
        } catch {
            storageError = error.localizedDescription
            throw HealthSyncError.storageUnavailable
        }
    }

    private func existingActivities(client: DreeveAPIClient, from: Date) async throws -> [DreeveActivity] {
        var all: [DreeveActivity] = []
        var page = 1
        while true {
            try Task.checkCancellation()
            let result = try await client.activities(page: page, size: 100, from: ActivityDates.calendarDate.string(from: from))
            all += result.activities
            if page >= result.pagination.totalPages { return all }
            page += 1
        }
    }

    private func remoteImport(client: DreeveAPIClient, workout: HealthWorkoutSummary) async throws -> DreeveImport? {
        try await HealthImportHistory.find(client: client, filenames: workout.importFilenames)
    }

    private func remoteImport(client: DreeveAPIClient, filename: String) async throws -> DreeveImport? {
        try await HealthImportHistory.find(client: client, filenames: [filename])
    }

    private func reconcile(client: DreeveAPIClient, server: String, pendingOnly: Bool = false) async throws {
        let visibleIDs = Set(workouts.map(\.id))
        for record in records where record.server == server && (!pendingOnly || [.queued, .uncertain, .needsDetails].contains(record.state) || record.awaitingFeedHandoff) {
            try Task.checkCancellation()
            if [.imported, .skipped].contains(record.state), visibleIDs.contains(record.workout.id) || record.awaitingFeedHandoff {
                let verified = try await HealthSyncRecovery.verify(record, client: client)
                if verified.state == .deleted {
                    try save(verified)
                    candidates[record.workout.id] = candidates[record.workout.id]?.filter { $0.id != record.activityID }
                }
            } else if record.state == .needsDetails, let id = record.activityID {
                try await finish(record, id: id, client: client)
            } else if [.queued, .uncertain].contains(record.state),
                      let remote = try await remoteImport(client: client, filename: record.filename) {
                try await apply(remote, workout: record.workout, client: client, server: server)
            }
        }
    }

    private func apply(_ item: DreeveImport, workout: HealthWorkoutSummary, client: DreeveAPIClient, server: String) async throws {
        let state: HealthSyncState = switch item.status {
        case "success": .needsDetails
        case "failed": .failed
        case "skipped": .skipped
        default: .queued
        }
        let record = HealthSyncRecord(server: server, workout: workout, state: state, activityID: item.activityId, message: item.errorMessage, uploadFilename: item.filename,
            preview: record(workout.id, server: server)?.preview,
            feedHandoffPending: record(workout.id, server: server)?.feedHandoffPending)
        try save(record)
        if state == .needsDetails, let id = item.activityId { try await finish(record, id: id, client: client) }
    }

    private func finish(_ record: HealthSyncRecord, id: String, client: DreeveAPIClient) async throws {
        var updated = record
        do {
            let activity = try await client.activity(id)
            // Keep the original Health sport for legacy TCX and FIT/server mapping differences.
            if activity.sportType != record.workout.sportType {
                _ = try await client.editActivity(id, patch: ActivityPatch(name: activity.name, sportType: record.workout.sportType,
                    description: activity.description ?? ""))
            }
            updated.state = .imported
            updated.message = nil
            try save(updated)
        } catch {
            if case APIError.http(404, _) = error {
                updated = HealthSyncRecovery.deleted(record)
                candidates[record.workout.id] = candidates[record.workout.id]?.filter { $0.id != id }
            } else {
                updated.message = "The workout was imported. Refresh status to finish its sport details: \(error.localizedDescription)"
            }
            try save(updated)
        }
    }
}
