import Foundation
import CryptoKit
#if canImport(FoundationModels) && !COACH_RULES_ONLY
import FoundationModels

// The model curates verified facts; it cannot write numbers, workout names, advice,
// or goal targets into the displayed brief. This also prevents prompt injection
// through server-controlled activity/goal names.
@available(iOS 26.0, macOS 26.0, *)
@Generable enum CoachInsightFocus {
    case volume, latestSession, consistency
}

@available(iOS 26.0, macOS 26.0, *)
@Generable struct OnDeviceLLMCoachSchema {
    @Guide(description: "Order all three factual insight categories by relevance. Include each category once.", .count(3))
    var orderedInsights: [CoachInsightFocus]
}
#endif

struct CoachingBrief: Codable, Sendable, Equatable {
    let stateFingerprint: String
    let headline: String
    let workloadZone: WorkloadZone
    let workloadRatio: Double?
    let bulletInsights: [String]
    let goalActionPlan: String
    let generatedAt: Date
    let sourceEngine: String
}

actor CoachEngine {
    private let cacheDirectory: URL
    private let usesOnDeviceModel: Bool
    init(customCacheDirectory: URL? = nil, usesOnDeviceModel: Bool = true) {
        self.usesOnDeviceModel = usesOnDeviceModel
        cacheDirectory = customCacheDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DreeveCoachCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        var url = cacheDirectory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    func generateBrief(for context: CoachContextPayload, forceRefresh: Bool = false, now: Date = .now) async -> CoachingBrief {
        let available = onDeviceModelAvailable
        if !forceRefresh, let cache = readCachedBrief(instanceHash: context.instanceHash),
           cache.fingerprint == context.stateFingerprint, cache.modelAvailable == available {
            return cache.brief
        }
        let fallback = Self.generateDeterministicBrief(context: context, now: now)
        var brief = fallback
        #if canImport(FoundationModels) && !COACH_RULES_ONLY
        if available, !Task.isCancelled, #available(iOS 26.0, macOS 26.0, *),
           let order = await curatedOrder(context) {
            brief = CoachingBrief(stateFingerprint: context.stateFingerprint, headline: fallback.headline,
                workloadZone: fallback.workloadZone, workloadRatio: fallback.workloadRatio,
                bulletInsights: order.map { fallback.bulletInsights[$0] }, goalActionPlan: fallback.goalActionPlan,
                generatedAt: now, sourceEngine: "Apple Intelligence · on device")
        }
        #endif
        if !Task.isCancelled {
            let cache = Cache(fingerprint: context.stateFingerprint, modelAvailable: available, brief: brief)
            if let data = try? JSONEncoder().encode(cache) {
                #if os(iOS)
                try? data.write(to: cacheFileURL(context.instanceHash), options: [.atomic, .completeFileProtectionUnlessOpen])
                #else
                try? data.write(to: cacheFileURL(context.instanceHash), options: .atomic)
                #endif
            }
        }
        return brief
    }

    private var onDeviceModelAvailable: Bool {
        #if canImport(FoundationModels) && !COACH_RULES_ONLY
        if usesOnDeviceModel, #available(iOS 26.0, macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    #if canImport(FoundationModels) && !COACH_RULES_ONLY
    @available(iOS 26.0, macOS 26.0, *)
    private func curatedOrder(_ context: CoachContextPayload) async -> [Int]? {
        // Send only aggregate facts. Names, locations, routes, credentials and instance IDs are omitted.
        let prompt = Self.serializePromptInput(context)
        do {
            return try await withThrowingTaskGroup(of: [Int].self) { group in
                group.addTask {
                    let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: "Choose which supplied factual training-summary category to show first. This is a recorded-activity summary, not medical advice. Do not infer fitness or injury risk. Use each category exactly once.")
                    let response = try await session.respond(to: prompt, generating: OnDeviceLLMCoachSchema.self,
                        options: GenerationOptions(temperature: 0, maximumResponseTokens: 128))
                    let order = response.content.orderedInsights.map { focus in
                        switch focus { case .volume: return 0; case .latestSession: return 1; case .consistency: return 2 }
                    }
                    guard order.count == 3, Set(order) == Set([0, 1, 2]) else { return [] }
                    return order
                }
                group.addTask { try await Task.sleep(for: .seconds(12)); throw CancellationError() }
                defer { group.cancelAll() }
                let order = try await group.next() ?? []
                return order.count == 3 ? order : nil
            }
        } catch { return nil }
    }
    #endif

    static func serializePromptInput(_ ctx: CoachContextPayload) -> String {
        let ratio = ctx.workloadRatio.map { String(format: "%.2f", $0) } ?? "unavailable"
        return """
        Recorded moving-duration comparison, all sports; not a physiological load measurement.
        Active days: \(ctx.activeDaysLast7) of last 7.
        Recent duration: \(String(format: "%.1f", ctx.acuteDurationMinutes)) min in 7 days.
        Weekly average: \(String(format: "%.1f", ctx.chronicWeeklyDurationMinutes)) min across 28 days.
        Ratio: \(ratio). Descriptive band: \(ctx.workloadZone.rawValue).
        Latest distance: \(String(format: "%.2f", ctx.latestWorkout?.distanceKm ?? 0)) km.
        Prior comparable sessions: \(ctx.latestWorkout?.priorWorkoutCount ?? 0).
        Favorite goals pending: \(ctx.favoriteGoals.filter { !$0.isCompleted }.count).
        Order volume, latestSession, consistency by relevance.
        """
    }

    static func generateDeterministicBrief(context: CoachContextPayload, now: Date = .now) -> CoachingBrief {
        let ratio = context.workloadRatio.map { String(format: "%.2f×", $0) } ?? "unavailable"
        let headline: String
        switch context.workloadZone {
        case .baselineBuilding: headline = "Still building your recorded-activity baseline."
        case .lower: headline = "Recent moving time is below your four-week weekly average."
        case .steady: headline = "Recent moving time is close to your four-week weekly average."
        case .elevated: headline = "Recent moving time is above your four-week weekly average."
        case .spike: headline = "Recent moving time is substantially above your four-week weekly average."
        }
        let volume = String(format: "All sports · Last 7 days: %.1f km and %.1f min. Four-week weekly average: %.1f km and %.1f min. Duration ratio: %@.",
                            context.acuteDistanceKm, context.acuteDurationMinutes, context.chronicWeeklyDistanceKm,
                            context.chronicWeeklyDurationMinutes, ratio)
        var latestText = "No activities recorded in the last 30 days."
        if let latest = context.latestWorkout {
            latestText = String(format: "Latest %@: %.2f km in %.1f min", latest.sportType, latest.distanceKm, latest.durationMinutes)
            latestText += latest.paceOrSpeedText == "—" ? "." : " (\(latest.paceOrSpeedText))."
            if let delta = latest.distanceVs30DayAvgPercent, let duration = latest.durationVs30DayAvgPercent {
                latestText += String(format: " Versus %d prior matching sessions in 30 days: %+.0f%% distance, %+.0f%% duration.",
                                     latest.priorWorkoutCount, delta, duration)
                if let pace = latest.priorAveragePaceOrSpeedText { latestText += " Prior pace/speed: \(pace)." }
            } else { latestText += " Not enough comparable sessions for a benchmark." }
        }
        let consistency = "Activities logged on \(context.activeDaysLast7) of the last 7 days."
        let pending = context.favoriteGoals.filter { !$0.isCompleted }
        var plan: String
        if context.favoriteGoals.isEmpty && context.unavailableFavoriteGoals > 0 { plan = "Favorite goal progress is unavailable. Refresh Overview before planning remaining amounts." }
        else if context.favoriteGoals.isEmpty { plan = "Choose up to two favorites in Goals to see remaining amounts and daily averages." }
        else if pending.isEmpty { plan = "Your favorite goals for the current periods are complete." }
        else {
            plan = pending.map { "\($0.title): \($0.remainingAmountText) remaining this \($0.periodLabel), with \($0.daysRemainingInPeriod) day(s) including today — \($0.dailyAmountText)." }.joined(separator: "\n")
        }
        if context.unavailableFavoriteGoals > 0 && !context.favoriteGoals.isEmpty { plan += "\nSome favorite goal progress is unavailable; refresh Overview to update it." }
        return CoachingBrief(stateFingerprint: context.stateFingerprint, headline: headline,
            workloadZone: context.workloadZone, workloadRatio: context.workloadRatio,
            bulletInsights: [volume, latestText, consistency], goalActionPlan: plan, generatedAt: now,
            sourceEngine: "Local rule engine")
    }

    private struct Cache: Codable {
        let fingerprint: String
        let modelAvailable: Bool
        let brief: CoachingBrief
    }
    private func cacheFileURL(_ instance: String) -> URL {
        let safe = SHA256.hash(data: Data(instance.utf8)).map { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appendingPathComponent("coach-\(safe).json")
    }
    private func readCachedBrief(instanceHash: String) -> Cache? {
        guard let data = try? Data(contentsOf: cacheFileURL(instanceHash)), data.count <= 100_000,
              let cache = try? JSONDecoder().decode(Cache.self, from: data), cache.brief.bulletInsights.count == 3,
              cache.brief.stateFingerprint == cache.fingerprint else { return nil }
        return cache
    }
}
