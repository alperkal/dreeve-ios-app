import Foundation
import CoreGraphics
import CoreLocation

@main
struct ShareCardContractTest {
    static func assertTrue(_ condition: @autoclosure () -> Bool, _ message: String, file: StaticString = #file, line: UInt = #line) {
        if !condition() {
            fputs("FAIL [\(file):\(line)]: \(message)\n", stderr)
            exit(1)
        }
    }

    static func main() {
        print("Running ShareCardContractTest...")

        // 1. Standard Google/Garmin Encoded Polyline Decoding
        // "_p~iF~ps|U_ulLnnqC_mqNvxq`@" -> (38.5, -120.2), (40.7, -120.95), (43.252, -126.453)
        let sampleEncoded = "_p~iF~ps|U_ulLnnqC_mqNvxq`@"
        let decoded = RouteGeometryProjector.decodePolyline(sampleEncoded)
        assertTrue(decoded.count == 3, "Expected 3 decoded coordinates, got \(decoded.count)")
        assertTrue(abs(decoded[0].latitude - 38.5) < 1e-4, "First lat mismatch: \(decoded[0].latitude)")
        assertTrue(abs(decoded[0].longitude - (-120.2)) < 1e-4, "First lon mismatch: \(decoded[0].longitude)")
        assertTrue(abs(decoded[2].latitude - 43.252) < 1e-3, "Third lat mismatch: \(decoded[2].latitude)")

        // 2. Empty / Indoor Workout Polyline Handling
        let emptyProjected = RouteGeometryProjector.project(
            coordinates: [],
            into: CGRect(x: 0, y: 0, width: 1080, height: 1080)
        )
        assertTrue(emptyProjected.points.isEmpty, "Empty coordinates must produce empty points")
        assertTrue(emptyProjected.startPoint == nil && emptyProjected.endPoint == nil, "No start/end on empty route")

        // 3. Single-Point GPS Lock Centers Cleanly Without NaN / Division by Zero
        let singleCoord = [CLLocationCoordinate2D(latitude: 48.2082, longitude: 16.3738)]
        let singleProjected = RouteGeometryProjector.project(
            coordinates: singleCoord,
            into: CGRect(x: 0, y: 0, width: 1000, height: 1000),
            paddingFraction: 0.10
        )
        assertTrue(singleProjected.points.count == 1, "Expected 1 projected point")
        assertTrue(
            abs(singleProjected.points[0].x - 500) < 0.01 && abs(singleProjected.points[0].y - 500) < 0.01,
            "Single point should center at (500, 500), got \(singleProjected.points[0])"
        )
        assertTrue(singleProjected.isClosedLoop, "Single point is trivially a closed loop")

        // 4. Antimeridian Crossing (+179.99 to -179.99) Projects as a Narrow Hop, Not a Global Wrap
        let antimeridianCoords = [
            CLLocationCoordinate2D(latitude: -16.8, longitude: 179.98),
            CLLocationCoordinate2D(latitude: -16.8, longitude: -179.98),
            CLLocationCoordinate2D(latitude: -16.84, longitude: -179.98)
        ]
        let box = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let antiProjected = RouteGeometryProjector.project(coordinates: antimeridianCoords, into: box, paddingFraction: 0.1)
        assertTrue(antiProjected.points.count == 3, "Expected 3 projected antimeridian points")
        for pt in antiProjected.points {
            assertTrue(!pt.x.isNaN && !pt.y.isNaN, "Projected point must never be NaN")
            assertTrue(box.contains(pt), "Point \(pt) must stay inside target canvas \(box)")
        }

        // 5. Telemetry Formatting: Running Pace vs Cycling Speed vs Indoor Fallback
        let runTelemetry = ShareCardTelemetry(
            title: "Morning Tempo",
            sportType: "running",
            dateText: "2026-10-16",
            distanceMeters: 10_000,
            movingTimeSeconds: 2700, // 45:00 -> 4:30 /km
            elevationGainMeters: 112,
            gearName: "Brooks Ghost 16",
            encodedPolyline: sampleEncoded
        )
        assertTrue(runTelemetry.primaryMetricValue == "10.00 km", "Expected 10.00 km, got \(runTelemetry.primaryMetricValue)")
        assertTrue(runTelemetry.secondaryMetricLabel == "AVG PACE", "Running should show AVG PACE")
        assertTrue(runTelemetry.secondaryMetricValue == "4:30 /km", "Expected 4:30 /km, got \(runTelemetry.secondaryMetricValue)")
        assertTrue(runTelemetry.tertiaryMetricValue == "45:00", "Expected 45:00, got \(runTelemetry.tertiaryMetricValue)")

        let rideTelemetry = ShareCardTelemetry(
            title: "Evening Spin",
            sportType: "cycling",
            dateText: "2026-10-16",
            distanceMeters: 30_000,
            movingTimeSeconds: 3600, // 1:00:00 -> 30.0 km/h
            elevationGainMeters: 420,
            gearName: nil,
            encodedPolyline: nil
        )
        assertTrue(rideTelemetry.secondaryMetricLabel == "AVG SPEED", "Cycling should show AVG SPEED")
        assertTrue(rideTelemetry.secondaryMetricValue == "30.0 km/h", "Expected 30.0 km/h, got \(rideTelemetry.secondaryMetricValue)")
        assertTrue(rideTelemetry.tertiaryMetricValue == "1:00:00", "Expected 1:00:00, got \(rideTelemetry.tertiaryMetricValue)")
        assertTrue(rideTelemetry.coordinates.isEmpty, "Nil polyline should produce empty coordinates")

        // Truncated and oversized varints cannot overflow or silently export a partial path.
        for malformed in ["_", "?", "\u{1}", String(repeating: "~", count: 1000), sampleEncoded + "_"] {
            assertTrue(RouteGeometryProjector.decodePolyline(malformed).isEmpty, "Malformed polyline must be rejected")
        }
        let vertical = RouteGeometryProjector.project(coordinates: [
            CLLocationCoordinate2D(latitude: 48, longitude: 16), CLLocationCoordinate2D(latitude: 48.1, longitude: 16)
        ], into: CGRect(x: 50, y: 100, width: 1000, height: 500))
        assertTrue(abs(vertical.points[0].x - 550) < 0.01 && vertical.points[0].y > vertical.points[1].y, "Vertical route must center and point north upward")
        let horizontal = RouteGeometryProjector.project(coordinates: [
            CLLocationCoordinate2D(latitude: 48, longitude: 16), CLLocationCoordinate2D(latitude: 48, longitude: 16.1)
        ], into: box)
        assertTrue(abs(horizontal.points[0].y - 500) < 0.01, "Horizontal route must center without infinity")
        let highLatitude = RouteGeometryProjector.project(coordinates: [
            CLLocationCoordinate2D(latitude: 80, longitude: 0), CLLocationCoordinate2D(latitude: 80.01, longitude: 0.01)
        ], into: box, paddingFraction: 0)
        let ratio = abs(highLatitude.points[1].x - highLatitude.points[0].x) / abs(highLatitude.points[1].y - highLatitude.points[0].y)
        assertTrue(abs(ratio - cos(80 * Double.pi / 180)) < 0.002, "High-latitude projection preserves local aspect ratio")
        let repeated = RouteGeometryProjector.project(coordinates: [singleCoord[0], singleCoord[0]], into: box)
        assertTrue(repeated.points.allSatisfy { $0 == CGPoint(x: 500, y: 500) }, "Repeated GPS lock remains finite")
        let invalid = RouteGeometryProjector.project(coordinates: [CLLocationCoordinate2D(latitude: .nan, longitude: 16)], into: box)
        assertTrue(invalid.points.isEmpty, "Invalid coordinates cannot appear in export")
        let zeroArea = RouteGeometryProjector.project(coordinates: decoded, into: .zero)
        assertTrue(zeroArea.points.isEmpty, "Invalid canvas is empty")
        let padding = RouteGeometryProjector.project(coordinates: decoded, into: box, paddingFraction: .nan)
        assertTrue(padding.points.allSatisfy { $0.x.isFinite && $0.y.isFinite }, "Nonfinite padding uses a safe default")
        let indoor = ShareCardTelemetry(title: "Indoor", sportType: "VirtualRun", dateText: "2026-10-16",
            distanceMeters: 0, movingTimeSeconds: -1, elevationGainMeters: -1, gearName: " ", encodedPolyline: nil)
        assertTrue(indoor.primaryMetricValue == "—" && indoor.secondaryMetricValue == "—" && indoor.tertiaryMetricValue == "0:00", "Missing/negative telemetry cannot produce invalid pace or duration")
        assertTrue(indoor.gearName == nil && indoor.sportLabel == "VIRTUAL RUN", "Readable sport and empty gear")
        let roundedPace = ShareCardTelemetry(title: "Run", sportType: "Run", dateText: "2026-10-16",
            distanceMeters: 1000, movingTimeSeconds: 300, elevationGainMeters: 0, gearName: nil, encodedPolyline: nil)
        assertTrue(roundedPace.secondaryMetricValue == "5:00 /km", "Pace carries seconds correctly")
        assertTrue(ShareCardFormat.story9x16.pixelSize == CGSize(width: 1080, height: 1920), "Story pixel size")
        assertTrue(ShareCardFormat.square1x1.pixelSize == CGSize(width: 1080, height: 1080), "Square pixel size")

        print("PASS: ShareCardContractTest (decoding, malformed data, antimeridian, latitude/aspect, degenerate routes, telemetry and pixel formats)")
    }
}
