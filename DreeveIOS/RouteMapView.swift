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
    static func decode(_ encoded: String) -> [CLLocationCoordinate2D] {
        RouteGeometryProjector.decodePolyline(encoded)
    }
}
