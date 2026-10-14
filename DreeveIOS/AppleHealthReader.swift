import Foundation
import HealthKit
import CoreLocation

@MainActor
final class AppleHealthReader {
    private let store = HKHealthStore()
    private var workouts: [UUID: HKWorkout] = [:]

    func authorize(routes: Bool, heartRate: Bool) async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw HealthSyncError.unavailable }
        var types: Set<HKObjectType> = [HKObjectType.workoutType()]
        for id: HKQuantityTypeIdentifier in [.activeEnergyBurned, .distanceWalkingRunning, .distanceCycling, .distanceSwimming, .distanceWheelchair] {
            types.insert(HKQuantityType(id))
        }
        if routes { types.insert(HKSeriesType.workoutRoute()) }
        if heartRate { types.insert(HKQuantityType(.heartRate)) }
        try await store.requestAuthorization(toShare: [], read: types)
        // Request completion does not imply read permission was granted.
    }

    func load(from: Date, through: Date = .now) async throws -> [HealthWorkoutSummary] {
        guard HKHealthStore.isHealthDataAvailable() else { throw HealthSyncError.unavailable }
        let predicate = HKQuery.predicateForSamples(withStart: from, end: through, options: [.strictStartDate, .strictEndDate])
        let result = try await HKSampleQueryDescriptor(predicates: [.workout(predicate)], sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)]).result(for: store)
        workouts = Dictionary(uniqueKeysWithValues: result.map { ($0.uuid, $0) })
        return result.map { workout in
            let sport = sportType(workout)
            let distanceType: HKQuantityTypeIdentifier? = switch workout.workoutActivityType {
            case .running, .walking, .hiking: .distanceWalkingRunning
            case .cycling: .distanceCycling
            case .swimming: .distanceSwimming
            case .wheelchairRunPace, .wheelchairWalkPace: .distanceWheelchair
            default: nil
            }
            let distance = distanceType.flatMap { workout.statistics(for: HKQuantityType($0))?.sumQuantity()?.doubleValue(for: .meter()) } ?? workout.totalDistance?.doubleValue(for: .meter())
            let calories = workout.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie()) ?? workout.totalEnergyBurned?.doubleValue(for: .kilocalorie())
            return HealthWorkoutSummary(id: workout.uuid, sportType: sport, start: workout.startDate, end: workout.endDate,
                duration: workout.duration, distance: distance, calories: calories,
                source: workout.sourceRevision.source.name,
                timeZoneIdentifier: workout.metadata?[HKMetadataKeyTimeZone] as? String ?? TimeZone.current.identifier)
        }
    }

    func export(_ summary: HealthWorkoutSummary, routes: Bool, heartRate: Bool) async throws -> Data {
        guard let workout = workouts[summary.id] else { throw HealthSyncError.invalidWorkout }
        var points: [HealthTrackpoint] = []
        if routes {
            let predicate = HKQuery.predicateForObjects(from: workout)
            let routeSamples = try await HKSampleQueryDescriptor(predicates: [.workoutRoute(predicate)], sortDescriptors: []).result(for: store)
            for route in routeSamples {
                for try await location in HKWorkoutRouteQueryDescriptor(route).results(for: store) where location.horizontalAccuracy >= 0 {
                    points.append(HealthTrackpoint(date: location.timestamp, latitude: location.coordinate.latitude,
                        longitude: location.coordinate.longitude, altitude: location.verticalAccuracy >= 0 ? location.altitude : nil,
                        speed: location.speedAccuracy >= 0 && location.speed >= 0 ? location.speed : nil))
                }
            }
        }
        if heartRate {
            let predicate = HKQuery.predicateForSamples(withStart: workout.startDate, end: workout.endDate, options: [.strictStartDate, .strictEndDate])
            let samples = try await HKSampleQueryDescriptor(predicates: [.quantitySample(type: HKQuantityType(.heartRate), predicate: predicate)], sortDescriptors: []).result(for: store)
            for sample in samples {
                let bpm = sample.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
                if bpm.isFinite, bpm > 0, bpm < Double(Int.max) {
                    points.append(HealthTrackpoint(date: sample.startDate, heartRate: Int(bpm.rounded())))
                }
            }
        }
        let events = (workout.workoutEvents ?? []).compactMap { event -> HealthTimerEvent? in
            switch event.type {
            case .pause, .motionPaused: return HealthTimerEvent(date: event.dateInterval.start, isPaused: true)
            case .resume, .motionResumed: return HealthTimerEvent(date: event.dateInterval.start, isPaused: false)
            default: return nil
            }
        }
        return try HealthFITExporter.data(workout: summary, samples: points, events: events)
    }

    private func sportType(_ workout: HKWorkout) -> String {
        let indoor = workout.metadata?[HKMetadataKeyIndoorWorkout] as? Bool == true
        switch workout.workoutActivityType {
        case .running: return indoor ? "VirtualRun" : "Run"
        case .cycling: return indoor ? "VirtualRide" : "Ride"
        case .walking: return "Walk"
        case .hiking: return "Hike"
        case .swimming: return (workout.metadata?[HKMetadataKeySwimmingLocationType] as? NSNumber)?.intValue == HKWorkoutSwimmingLocationType.openWater.rawValue ? "OpenWaterSwim" : "Swim"
        case .rowing: return indoor ? "VirtualRow" : "Rowing"
        case .yoga: return "Yoga"
        case .pilates: return "Pilates"
        case .traditionalStrengthTraining, .functionalStrengthTraining: return "WeightTraining"
        case .highIntensityIntervalTraining: return "HighIntensityIntervalTraining"
        case .elliptical: return "Elliptical"
        case .stairClimbing, .stairs: return "StairStepper"
        case .dance, .cardioDance, .socialDance: return "Dance"
        case .tennis: return "Tennis"
        case .badminton: return "Badminton"
        case .tableTennis: return "TableTennis"
        case .squash: return "Squash"
        case .racquetball: return "Racquetball"
        case .basketball: return "Basketball"
        case .soccer: return "Soccer"
        case .volleyball: return "Volleyball"
        case .golf: return "Golf"
        case .climbing: return "RockClimbing"
        case .paddleSports: return "StandUpPaddling"
        case .sailing: return "Sail"
        case .surfingSports: return "Surfing"
        case .downhillSkiing: return "AlpineSki"
        case .crossCountrySkiing: return "NordicSki"
        case .snowboarding: return "Snowboard"
        case .skatingSports: return "InlineSkate"
        case .wheelchairWalkPace, .wheelchairRunPace: return "Wheelchair"
        default: return "Workout"
        }
    }
}
