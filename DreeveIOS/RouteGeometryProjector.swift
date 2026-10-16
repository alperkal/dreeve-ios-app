import Foundation
import CoreGraphics
import CoreLocation

struct ProjectedRoute: Sendable, Equatable {
    let points: [CGPoint]
    let startPoint: CGPoint?
    let endPoint: CGPoint?
    let isClosedLoop: Bool
}

enum RouteGeometryProjector {
    /// Standard E5 polyline. Reject malformed/oversized input rather than exporting
    /// a deceptively truncated route or shifting an integer beyond its bit width.
    static func decodePolyline(_ encoded: String) -> [CLLocationCoordinate2D] {
        guard !encoded.isEmpty, encoded.utf8.count <= 4_000_000 else { return [] }
        let bytes = Array(encoded.utf8)
        var index = 0
        var latitude: Int64 = 0
        var longitude: Int64 = 0
        var result: [CLLocationCoordinate2D] = []
        func next() -> Int64? {
            var value: Int64 = 0
            var shift = 0
            while index < bytes.count {
                let byte = Int64(bytes[index]) - 63
                index += 1
                guard (0...63).contains(byte), shift <= 30 else { return nil }
                value |= (byte & 31) << shift
                if byte < 32 { return value & 1 == 1 ? ~(value >> 1) : value >> 1 }
                shift += 5
            }
            return nil
        }
        while index < bytes.count {
            guard result.count < 100_000, let lat = next(), let lon = next() else { return [] }
            let (nextLat, latOverflow) = latitude.addingReportingOverflow(lat)
            let (nextLon, lonOverflow) = longitude.addingReportingOverflow(lon)
            guard !latOverflow, !lonOverflow, abs(nextLat) <= 9_000_000, abs(nextLon) <= 18_000_000 else { return [] }
            latitude = nextLat; longitude = nextLon
            result.append(CLLocationCoordinate2D(latitude: Double(latitude) / 1e5, longitude: Double(longitude) / 1e5))
        }
        return result
    }

    static func unwrappedLongitudes(_ coordinates: [CLLocationCoordinate2D]) -> [Double] {
        guard let first = coordinates.first else { return [] }
        var result = [first.longitude]
        for point in coordinates.dropFirst() {
            let previous = result.last!
            var longitude = point.longitude
            longitude += ((previous - longitude) / 360).rounded() * 360
            result.append(longitude)
        }
        return result
    }

    static func project(coordinates: [CLLocationCoordinate2D], into canvasRect: CGRect,
                        paddingFraction: CGFloat = 0.12) -> ProjectedRoute {
        let empty = ProjectedRoute(points: [], startPoint: nil, endPoint: nil, isClosedLoop: false)
        let valid = coordinates.filter { $0.latitude.isFinite && $0.longitude.isFinite && CLLocationCoordinate2DIsValid($0) }
        guard !valid.isEmpty, canvasRect.origin.x.isFinite, canvasRect.origin.y.isFinite,
              canvasRect.width.isFinite, canvasRect.height.isFinite,
              canvasRect.width > 0, canvasRect.height > 0 else { return empty }
        let padding = paddingFraction.isFinite ? min(max(paddingFraction, 0), 0.45) : 0.12
        let inset = canvasRect.insetBy(dx: canvasRect.width * padding, dy: canvasRect.height * padding)
        let xs = unwrappedLongitudes(valid).map { $0 * .pi / 180 }
        // Web Mercator preserves local angles/aspect at high latitudes. Clamp poles
        // to the finite range also supported by the basemap.
        let ys = valid.map { coordinate -> Double in
            let latitude = min(max(coordinate.latitude, -85.05112878), 85.05112878) * .pi / 180
            return log(tan(.pi / 4 + latitude / 2))
        }
        let minX = xs.min()!, maxX = xs.max()!, minY = ys.min()!, maxY = ys.max()!
        let width = maxX - minX, height = maxY - minY
        if width < 1e-12 && height < 1e-12 {
            let center = CGPoint(x: inset.midX, y: inset.midY)
            return ProjectedRoute(points: Array(repeating: center, count: valid.count), startPoint: center, endPoint: center, isClosedLoop: true)
        }
        let scale = min(width > 1e-12 ? Double(inset.width) / width : .greatestFiniteMagnitude,
                        height > 1e-12 ? Double(inset.height) / height : .greatestFiniteMagnitude)
        let offsetX = Double(inset.midX) - width * scale / 2
        let offsetY = Double(inset.midY) - height * scale / 2
        let points = xs.indices.map { CGPoint(x: offsetX + (xs[$0] - minX) * scale,
                                              y: offsetY + (maxY - ys[$0]) * scale) }
        let first = points.first!, last = points.last!
        return ProjectedRoute(points: points, startPoint: first, endPoint: last,
            isClosedLoop: hypot(last.x - first.x, last.y - first.y) <= min(inset.width, inset.height) * 0.04)
    }
}
