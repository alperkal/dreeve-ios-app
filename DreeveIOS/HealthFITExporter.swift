import Foundation

struct HealthTimerEvent {
    let date: Date
    let isPaused: Bool
}

/// FIT activity writer using the public FIT protocol/profile. Missing sensor values
/// use FIT invalid sentinels; only Health's known totals and measured samples are exported.
enum HealthFITExporter {
    static let epoch: TimeInterval = 631_065_600 // 1989-12-31 UTC

    static func data(workout: HealthWorkoutSummary, samples: [HealthTrackpoint], events: [HealthTimerEvent] = []) throws -> Data {
        let elapsed = workout.end.timeIntervalSince(workout.start)
        guard elapsed.isFinite, elapsed > 0, elapsed <= 7 * 86400,
              workout.duration.isFinite, workout.duration > 0, workout.duration <= elapsed + 1 else {
            throw HealthSyncError.invalidWorkout
        }
        let start = try timestamp(workout.start), end = try timestamp(workout.end)
        let sport = sport(workout.sportType)
        let elapsedMS = scaled(elapsed, scale: 1000)
        let activeMS = scaled(workout.duration, scale: 1000)
        let distance = scaled(workout.distance, scale: 100)
        let calories = small(workout.calories)
        var writer = Writer()
        // File ID, activity type (4). Development manufacturer identifies this exporter,
        // not a claimed Garmin/Apple hardware model. Stable UUID filename identifies the workout.
        writer.message(0, local: 0, fields: [.enum8(0, 4), .u16(1, 255), .u16(2, 0), .u32(4, start)])
        writer.message(23, local: 6, fields: [.u32(253, start), .u8(0, 0), .u16(2, 255),
                                            .string(27, workout.source)])

        // Standard FIT records have second-resolution timestamps. Merge sensor values
        // within a second in chronological order, retaining the latest measured value.
        var points: [UInt32: HealthTrackpoint] = [start: HealthTrackpoint(date: workout.start), end: HealthTrackpoint(date: workout.end)]
        for point in samples.sorted(by: { $0.date < $1.date }) where point.date >= workout.start && point.date <= workout.end {
            let time = try timestamp(point.date)
            var merged = points[time] ?? HealthTrackpoint(date: point.date)
            if let lat = point.latitude, let lon = point.longitude,
               lat.isFinite, lon.isFinite, abs(lat) <= 90, abs(lon) <= 180 {
                merged.latitude = lat; merged.longitude = lon
            }
            if let altitude = point.altitude, altitude.isFinite { merged.altitude = altitude }
            if let rate = point.heartRate, (1...254).contains(rate) { merged.heartRate = rate }
            if let speed = point.speed, speed.isFinite, speed >= 0 { merged.speed = speed }
            if let cadence = point.cadence, cadenceParts(cadence).0 != .max { merged.cadence = cadence }
            if let power = point.power, small(power) != .max { merged.power = power }
            points[time] = merged
        }
        var timerEvents: [(UInt32, UInt8)] = [(start, 0)] // timer start
        for event in events.sorted(by: { $0.date < $1.date }) where event.date > workout.start && event.date < workout.end {
            timerEvents.append((try timestamp(event.date), event.isPaused ? 1 : 0))
        }
        timerEvents.append((end, 4)) // stop_all
        var eventIndex = 0
        for time in points.keys.sorted() {
            while eventIndex < timerEvents.count && timerEvents[eventIndex].0 <= time {
                let event = timerEvents[eventIndex]
                writer.message(21, local: 1, fields: [.u32(253, event.0), .enum8(0, 0), .enum8(1, event.1)])
                eventIndex += 1
            }
            let point = points[time]!
            let altitude = scaled(point.altitude.map { $0 + 500 }, scale: 5)
            let speed = scaled(point.speed, scale: 1000)
            let cadence = cadenceParts(point.cadence)
            writer.message(20, local: 2, fields: [
                .u32(253, time), .i32(0, semicircles(point.latitude)), .i32(1, semicircles(point.longitude)),
                .u16(2, altitude < UInt16.max ? UInt16(altitude) : .max),
                .u8(3, point.heartRate.map(UInt8.init) ?? .max),
                .u8(4, cadence.0), .u8(53, cadence.1), .u16(7, small(point.power)),
                .u16(6, speed < UInt16.max ? UInt16(speed) : .max),
                .u32(73, speed), .u32(78, altitude)
            ])
        }
        // Exactly one lap/session and activity. Distinguish wall-clock elapsed time
        // from Health's active duration rather than deriving it from sparse GPS samples.
        var totals: [Field] = [.u32(253, end), .u16(254, 0), .u32(2, start),
                               .u32(7, elapsedMS), .u32(8, activeMS), .u32(9, distance), .u16(11, calories)]
        let cadenceValues = points.values.compactMap(\.cadence)
        let powerValues = points.values.compactMap(\.power)
        let averageCadence = cadenceParts(average(cadenceValues))
        let maximumCadence = cadenceParts(cadenceValues.max())
        let powerSummary: [Field] = [.u16(19, small(average(powerValues))), .u16(20, small(powerValues.max()))]
        writer.message(19, local: 3, fields: totals + [.enum8(0, 9), .enum8(1, 1),
            .u8(17, averageCadence.0), .u8(18, maximumCadence.0), .u8(80, averageCadence.1), .u8(81, maximumCadence.1)] + powerSummary) // lap/stop
        totals += [.enum8(5, sport.0), .enum8(6, sport.1), .u16(25, 0), .u16(26, 1), .string(110, workout.sportType)]
        writer.message(18, local: 4, fields: totals + [.enum8(0, 8), .enum8(1, 1),
            .u8(18, averageCadence.0), .u8(19, maximumCadence.0), .u8(92, averageCadence.1), .u8(93, maximumCadence.1),
            .u16(20, small(average(powerValues))), .u16(21, small(powerValues.max()))]) // session/stop
        let zone = TimeZone(identifier: workout.timeZoneIdentifier) ?? TimeZone(secondsFromGMT: 0)!
        let localTime = Int64(end) + Int64(zone.secondsFromGMT(for: workout.end))
        writer.message(34, local: 5, fields: [.u32(253, end), .u32(0, activeMS), .u16(1, 1),
            .enum8(2, 0), .enum8(3, 26), .enum8(4, 1),
            .u32(5, localTime >= 0 && localTime < UInt32.max ? UInt32(localTime) : .max)])
        return writer.finish()
    }

    private static func average(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
    private static func cadenceParts(_ value: Double?) -> (UInt8, UInt8) {
        guard let value, value.isFinite, value >= 0, value < 255 else { return (.max, .max) }
        let quantized = (value * 128).rounded()
        guard quantized < 255 * 128 else { return (.max, .max) }
        return (UInt8(Int(quantized) / 128), UInt8(Int(quantized) % 128))
    }

    private static func timestamp(_ date: Date) throws -> UInt32 {
        let seconds = floor(date.timeIntervalSince1970 - epoch)
        guard seconds.isFinite, seconds >= 0x10000000, seconds < Double(UInt32.max) else { throw HealthSyncError.invalidWorkout }
        return UInt32(seconds)
    }
    private static func scaled(_ value: Double?, scale: Double) -> UInt32 {
        guard let value, value.isFinite, value >= 0 else { return .max }
        let encoded = (value * scale).rounded()
        guard encoded.isFinite, encoded < Double(UInt32.max) else { return .max }
        return UInt32(encoded)
    }
    private static func small(_ value: Double?) -> UInt16 {
        guard let value, value.isFinite, value >= 0, value.rounded() < Double(UInt16.max) else { return .max }
        return UInt16(value.rounded())
    }
    private static func semicircles(_ value: Double?) -> Int32 {
        guard let value else { return .max }
        // +180 degrees is the same meridian as -180; +2^31 cannot fit in sint32.
        let encoded = ((value == 180 ? -180 : value) * 2147483648 / 180).rounded()
        // Rounding at the positive antimeridian can hit the invalid sentinel or
        // overflow sint32; use the equivalent negative antimeridian instead.
        return encoded >= Double(Int32.max) ? Int32.min : Int32(encoded)
    }
    private static func sport(_ name: String) -> (UInt8, UInt8) {
        switch name {
        case "Run": return (1, 0)
        case "VirtualRun": return (1, 1)
        case "Ride": return (2, 0)
        case "VirtualRide": return (2, 6)
        case "Walk": return (11, 0)
        case "Hike": return (17, 0)
        case "Swim": return (5, 17)
        case "OpenWaterSwim": return (5, 18)
        case "Rowing": return (15, 0)
        case "VirtualRow": return (15, 14)
        case "Yoga": return (10, 43)
        case "Pilates": return (10, 44)
        case "WeightTraining": return (10, 20)
        case "HighIntensityIntervalTraining": return (62, 70)
        case "Elliptical": return (4, 15)
        case "StairStepper": return (4, 16)
        case "Dance": return (83, 0)
        case "Tennis": return (8, 0)
        case "Badminton": return (64, 95)
        case "TableTennis": return (64, 97)
        case "Squash": return (64, 94)
        case "Racquetball": return (64, 96)
        case "Basketball": return (6, 0)
        case "Soccer": return (7, 0)
        case "Volleyball": return (75, 0)
        case "Golf": return (25, 0)
        case "RockClimbing": return (31, 0)
        case "StandUpPaddling": return (37, 0)
        case "Sail": return (32, 0)
        case "Surfing": return (38, 0)
        case "AlpineSki": return (13, 0)
        case "NordicSki": return (12, 0)
        case "Snowboard": return (14, 0)
        case "InlineSkate": return (30, 0)
        case "Wheelchair": return (65, 0)
        default: return (0, 0)
        }
    }

    private struct Field {
        let number: UInt8
        let type: UInt8
        let bytes: [UInt8]
        var definition: [UInt8] { [number, UInt8(bytes.count), type] }
        static func enum8(_ n: UInt8, _ v: UInt8) -> Field { Field(number: n, type: 0, bytes: [v]) }
        static func u8(_ n: UInt8, _ v: UInt8) -> Field { Field(number: n, type: 2, bytes: [v]) }
        static func u16(_ n: UInt8, _ v: UInt16) -> Field { Field(number: n, type: 0x84, bytes: little(v)) }
        static func u32(_ n: UInt8, _ v: UInt32) -> Field { Field(number: n, type: 0x86, bytes: little(v)) }
        static func i32(_ n: UInt8, _ v: Int32) -> Field { Field(number: n, type: 0x85, bytes: little(v)) }
        static func string(_ n: UInt8, _ value: String) -> Field {
            // Bound to 254 UTF-8 bytes, preserving complete characters, plus NUL.
            var bytes: [UInt8] = []
            for character in value {
                let next = Array(String(character).utf8)
                if bytes.count + next.count > 254 { break }
                bytes += next
            }
            return Field(number: n, type: 7, bytes: bytes + [0])
        }
    }
    private struct Writer {
        var data = Data()
        var definitions: [UInt8: [UInt8]] = [:]
        mutating func message(_ global: UInt16, local: UInt8, fields: [Field]) {
            let definition = little(global) + [UInt8(fields.count)] + fields.flatMap(\.definition)
            if definitions[local] != definition {
                data.append(contentsOf: [0x40 | local, 0, 0] + definition) // definition, reserved, little-endian
                definitions[local] = definition
            }
            data.append(local)
            for field in fields { data.append(contentsOf: field.bytes) }
        }
        func finish() -> Data {
            var file = Data([14, 0x20] + little(UInt16(21218)) + little(UInt32(data.count)) + Array(".FIT".utf8))
            file.append(contentsOf: little(crc(file)))
            file.append(data)
            file.append(contentsOf: little(crc(file)))
            return file
        }
    }
    private static func little<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian) { Array($0) }
    }
    private static func crc(_ data: Data) -> UInt16 {
        var value: UInt16 = 0
        for byte in data {
            value ^= UInt16(byte)
            for _ in 0..<8 { value = value & 1 == 1 ? (value >> 1) ^ 0xA001 : value >> 1 }
        }
        return value
    }
}
