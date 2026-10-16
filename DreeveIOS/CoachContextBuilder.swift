import Foundation
import CryptoKit

// Descriptive duration bands, not physiological or injury-risk classifications.
enum WorkloadZone: String, Codable, Sendable {
    case baselineBuilding, lower, steady, elevated, spike
}

struct GoalRunRateSummary: Codable, Sendable, Equatable {
    let id: String
    let title: String
    let sportType: String
    let periodLabel: String
    let currentAmountText: String
    let targetAmountText: String
    let remainingAmountText: String
    let dailyAmountText: String
    let daysRemainingInPeriod: Int
    let isCompleted: Bool

    static func make(id: String, title: String, sport: String, metric: GoalMetric,
                     target: Double, current: Double, period: GoalPeriod, today: String,
                     frequency: GoalFrequency) -> Self? {
        guard target.isFinite, target > 0, current.isFinite, current >= 0,
              let start = GoalCalendar.formatter().date(from: today),
              let end = GoalCalendar.formatter().date(from: period.endExclusive), period.contains(today) else { return nil }
        let days = max(1, GoalCalendar.calendar.dateComponents([.day], from: start, to: end).day ?? 1)
        let remaining = max(0, target - current)
        func amount(_ value: Double) -> String {
            metric == .distance ? String(format: "%.1f km", value / 1000) : String(format: "%.0f sessions", value)
        }
        let daily = metric == .distance ? String(format: "%.2f km/day", remaining / 1000 / Double(days)) :
            String(format: "%.2f sessions/day on average", remaining / Double(days))
        return Self(id: id, title: String(title.prefix(160)), sportType: sport,
                    periodLabel: frequency == .weekly ? "week" : "month", currentAmountText: amount(current),
                    targetAmountText: amount(target), remainingAmountText: amount(remaining), dailyAmountText: daily,
                    daysRemainingInPeriod: days, isCompleted: current >= target)
    }
}

struct LatestWorkoutComparison: Codable, Sendable, Equatable {
    let activityId: String
    let name: String
    let sportType: String
    let localDayKey: String
    let distanceKm: Double
    let durationMinutes: Double
    let paceOrSpeedText: String
    let priorAveragePaceOrSpeedText: String?
    let distanceVs30DayAvgPercent: Double?
    let durationVs30DayAvgPercent: Double?
    let priorWorkoutCount: Int
}

struct CoachContextPayload: Codable, Sendable, Equatable {
    let instanceHash: String
    let referenceDayKey: String
    let activeDaysLast7: Int
    let acuteDistanceKm: Double
    let acuteDurationMinutes: Double
    let chronicWeeklyDistanceKm: Double
    let chronicWeeklyDurationMinutes: Double
    let workloadRatio: Double?
    let workloadZone: WorkloadZone
    let primarySport: String?
    let latestWorkout: LatestWorkoutComparison?
    let favoriteGoals: [GoalRunRateSummary]
    let unavailableFavoriteGoals: Int
    var stateFingerprint: String
}

enum CoachContextBuilder {
    private struct Signature: Codable {
        let id: String, name: String, sport: String, date: String, setting: String
        let meters: Double, seconds: Double, elevation: Double
    }
    static func build(instanceHash: String, todayDayKey: String,
                      activitiesLast30Days: [ActivitySummaryRecord], favoriteGoals: [GoalRunRateSummary], unavailableFavoriteGoals: Int = 0) -> CoachContextPayload {
        // Preserve local wall-clock dates; exclude future/out-of-window records and count IDs once.
        let validDay = GoalCalendar.formatter().date(from: todayDayKey).map { GoalCalendar.formatter().string(from: $0) == todayDayKey } == true
        let today = validDay ? todayDayKey : "1970-01-01"
        let from30 = GoalCalendar.addingDays(-29, to: today)
        let from28 = GoalCalendar.addingDays(-27, to: today)
        let from7 = GoalCalendar.addingDays(-6, to: today)
        let unique = Dictionary(activitiesLast30Days.map { ($0.id, $0) }, uniquingKeysWith: { _, edited in edited })
        let records = unique.values.filter { $0.localDayKey >= from30 && $0.localDayKey <= today }.sorted {
            $0.startDateLocal == $1.startDateLocal ? $0.id > $1.id : $0.startDateLocal > $1.startDateLocal
        }
        // Bound corrupt numeric inputs before aggregation; normal Dreeve values are far below these limits.
        func distance(_ a: ActivitySummaryRecord) -> Double { a.distanceMeters.isFinite ? min(max(0, a.distanceMeters), 1e9) : 0 }
        func seconds(_ a: ActivitySummaryRecord) -> Double { Double(min(max(0, a.movingTimeSeconds), 31 * 86400)) }
        func setting(_ a: ActivitySummaryRecord) -> String {
            if a.sportType.lowercased().hasPrefix("virtual") { return "virtual" }
            if a.encodedPolyline?.isEmpty == false { return "route" }
            if let data = a.payload, let activity = try? JSONDecoder().decode(DreeveActivity.self, from: data),
               let start = activity.startLatLng, start.count == 2,
               start[0].isFinite, start[1].isFinite, abs(start[0]) <= 90, abs(start[1]) <= 180 {
                return "route"
            }
            return "unspecified"
        }
        let rolling = records.filter { $0.localDayKey >= from28 }
        let acute = rolling.filter { $0.localDayKey >= from7 }
        let acuteMin = acute.reduce(0.0) { $0 + seconds($1) } / 60
        let weeklyMin = rolling.reduce(0.0) { $0 + seconds($1) } / 240
        let ratio = weeklyMin > 0 ? acuteMin / weeklyMin : nil
        let zone: WorkloadZone
        if rolling.count < 4 || weeklyMin < 15 { zone = .baselineBuilding }
        else if (ratio ?? 0) < 0.8 { zone = .lower }
        else if (ratio ?? 0) <= 1.3 { zone = .steady }
        else if (ratio ?? 0) <= 1.5 { zone = .elevated }
        else { zone = .spike }
        let counts = Dictionary(grouping: rolling, by: \.sportType)
        let primary = counts.keys.sorted { counts[$0]!.count == counts[$1]!.count ? $0 < $1 : counts[$0]!.count > counts[$1]!.count }.first
        var comparison: LatestWorkoutComparison?
        if let latest = records.first {
            // The latest workout is excluded from its own comparison. Virtual and route categories stay separate.
            let prior = records.filter { $0.id != latest.id && $0.sportType == latest.sportType && setting($0) == setting(latest) }
            let measurable = prior.filter { distance($0) > 0 && seconds($0) > 0 }
            let meanDistance = measurable.isEmpty ? 0 : measurable.reduce(0.0) { $0 + distance($1) } / Double(measurable.count)
            let meanSeconds = measurable.isEmpty ? 0 : measurable.reduce(0.0) { $0 + seconds($1) } / Double(measurable.count)
            func telemetry(_ meters: Double, _ time: Double) -> ShareCardTelemetry {
                ShareCardTelemetry(title: "", sportType: latest.sportType, dateText: "", distanceMeters: meters,
                                   movingTimeSeconds: Int(time), elevationGainMeters: 0, gearName: nil, encodedPolyline: nil)
            }
            func paceOrSpeed(_ meters: Double, _ time: Double) -> String? {
                let value = telemetry(meters, time)
                guard ["AVG PACE", "AVG SPEED"].contains(value.secondaryMetricLabel), value.secondaryMetricValue != "—" else { return nil }
                return value.secondaryMetricValue
            }
            let knownCategory = setting(latest) != "unspecified"
            let canCompare = measurable.count >= 2 && meanDistance >= 500 && knownCategory && distance(latest) > 0 && seconds(latest) > 0
            comparison = LatestWorkoutComparison(activityId: latest.id, name: String(latest.name.prefix(160)), sportType: latest.sportType,
                localDayKey: latest.localDayKey, distanceKm: distance(latest) / 1000, durationMinutes: seconds(latest) / 60,
                paceOrSpeedText: paceOrSpeed(distance(latest), seconds(latest)) ?? "—",
                priorAveragePaceOrSpeedText: canCompare ? paceOrSpeed(meanDistance, meanSeconds) : nil,
                distanceVs30DayAvgPercent: canCompare ? (distance(latest) / meanDistance - 1) * 100 : nil,
                durationVs30DayAvgPercent: canCompare ? (seconds(latest) / meanSeconds - 1) * 100 : nil,
                priorWorkoutCount: canCompare ? measurable.count : 0)
        }
        var context = CoachContextPayload(instanceHash: instanceHash, referenceDayKey: today,
            activeDaysLast7: Set(acute.map(\.localDayKey)).count,
            acuteDistanceKm: acute.reduce(0.0) { $0 + distance($1) } / 1000, acuteDurationMinutes: acuteMin,
            chronicWeeklyDistanceKm: rolling.reduce(0.0) { $0 + distance($1) } / 4000,
            chronicWeeklyDurationMinutes: weeklyMin, workloadRatio: ratio, workloadZone: zone,
            primarySport: primary, latestWorkout: comparison, favoriteGoals: Array(favoriteGoals.prefix(2)), unavailableFavoriteGoals: unavailableFavoriteGoals, stateFingerprint: "")
        let signatures = records.map { Signature(id: $0.id, name: $0.name, sport: $0.sportType, date: $0.startDateLocal,
            setting: setting($0), meters: distance($0), seconds: seconds($0), elevation: $0.elevationGainMeters.isFinite ? $0.elevationGainMeters : 0) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var bytes = Data("coach-v1".utf8)
        bytes.append((try? encoder.encode(context)) ?? Data())
        bytes.append((try? encoder.encode(signatures)) ?? Data())
        context.stateFingerprint = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return context
    }
}
