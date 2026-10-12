import MapKit
import SwiftUI

struct RouteMapView: View {
    let activity: DreeveActivity

    private var route: [CLLocationCoordinate2D] {
        guard let encoded = activity.encodedPolyline, !encoded.isEmpty else { return [] }
        return PolylineDecoder.decode(encoded)
    }

    private var start: CLLocationCoordinate2D? {
        guard let point = activity.startLatLng, point.count == 2 else { return nil }
        return CLLocationCoordinate2D(latitude: point[0], longitude: point[1])
    }

    var body: some View {
        if !route.isEmpty || start != nil {
            Map {
                if route.count >= 2 {
                    MapPolyline(coordinates: route)
                        .stroke(DreeveTheme.accent, lineWidth: 5)
                }
                if let start {
                    Annotation("Start", coordinate: start) {
                        Image(systemName: "location.circle.fill")
                            .font(.title2)
                            .foregroundStyle(DreeveTheme.accent)
                    }
                }
            }
            .mapStyle(.standard(elevation: .flat))
            .frame(height: 245)
            .clipShape(RoundedRectangle(cornerRadius: 18))
        }
    }
}

enum PolylineDecoder {
    // Google Encoded Polyline format, E5 precision.
    static func decode(_ encoded: String) -> [CLLocationCoordinate2D] {
        let bytes = Array(encoded.utf8)
        var index = 0
        var latitude = 0
        var longitude = 0
        var coordinates: [CLLocationCoordinate2D] = []

        func next() -> Int? {
            var result = 0
            var shift = 0
            while index < bytes.count {
                let byte = Int(bytes[index]) - 63
                index += 1
                guard byte >= 0 && byte <= 63 && shift <= 30 else { return nil }
                result |= (byte & 0x1F) << shift
                if byte < 0x20 { return (result & 1) != 0 ? ~(result >> 1) : result >> 1 }
                shift += 5
            }
            return nil
        }

        while index < bytes.count {
            guard let lat = next(), let lon = next() else { break }
            latitude += lat
            longitude += lon
            coordinates.append(CLLocationCoordinate2D(latitude: Double(latitude) / 1e5, longitude: Double(longitude) / 1e5))
        }
        return coordinates
    }
}
