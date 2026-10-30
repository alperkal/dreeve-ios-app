import SwiftUI
import MapKit
import CoreLocation
import UIKit

@MainActor final class RouteLocation: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    @Published var location: CLLocationCoordinate2D?
    @Published var error: String?
    @Published var searching = false
    private let manager = CLLocationManager()
    private var requested = false
    override init() { super.init(); manager.delegate = self; manager.desiredAccuracy = kCLLocationAccuracyHundredMeters }
    func locateIfAuthorized() {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: locate()
        default: break
        }
    }
    func locate() {
        requested = true; searching = true; error = nil
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse: manager.requestLocation()
        default: searching = false; requested = false; error = "Location access is off. You can move the map and search that area."
        }
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard requested else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: manager.requestLocation()
        case .denied, .restricted: searching = false; requested = false; error = "Location access is off. Move the map and search that area."
        default: break
        }
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let value = locations.last?.coordinate else { return }
        requested = false; searching = false; location = value
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        requested = false; searching = false; self.error = "Couldn’t get your location. Move the map and search that area."
    }
}

// Map movement must not invalidate the SwiftUI view and rebuild every overlay.
@MainActor final class RouteMapCenter: ObservableObject {
    var value: CLLocationCoordinate2D?
}

private struct RouteMapTarget {
    enum Area { case region(MKCoordinateRegion), rect(MKMapRect) }
    let id = UUID()
    let area: Area
}

private final class RouteAnnotation: NSObject, MKAnnotation {
    let routeID: Int64
    let coordinate: CLLocationCoordinate2D
    let title: String?
    init(route: MappedRoute, coordinate: CLLocationCoordinate2D) {
        routeID = route.id; self.coordinate = coordinate; title = route.name
    }
}

/// Group same-style route segments into a pair of renderers, keeping annotation selection independent.
private struct RoutesMap: UIViewRepresentable {
    let routes: [MappedRoute]
    let revision: UUID
    let selectedID: Int64?
    let target: RouteMapTarget?
    let centerChanged: (CLLocationCoordinate2D) -> Void
    let selectRoute: (Int64) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        return map
    }
    func updateUIView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.centerChanged = centerChanged
        coordinator.selectRoute = selectRoute
        if coordinator.revision != revision {
            coordinator.revision = revision
            coordinator.routes = routes
            if let overlay = coordinator.baseOverlay { map.removeOverlay(overlay) }
            if let overlay = coordinator.selectedOverlay { map.removeOverlay(overlay) }
            coordinator.selectedOverlay = nil
            coordinator.baseOverlay = RouteDisplayGeometry.multiPolyline(routes.flatMap(\.displaySegments))
            if let overlay = coordinator.baseOverlay { map.addOverlay(overlay) }
            map.removeAnnotations(map.annotations.compactMap { $0 as? RouteAnnotation })
            map.addAnnotations(routes.compactMap { route in
                route.segments.first?.first.map { RouteAnnotation(route: route, coordinate: $0) }
            })
            coordinator.selectedID = nil
        }
        if coordinator.selectedID != selectedID || (selectedID != nil && coordinator.selectedOverlay == nil) {
            coordinator.selectedID = selectedID
            if let overlay = coordinator.selectedOverlay { map.removeOverlay(overlay) }
            coordinator.selectedOverlay = routes.first(where: { $0.id == selectedID }).flatMap { RouteDisplayGeometry.multiPolyline($0.displaySegments) }
            if let overlay = coordinator.selectedOverlay { map.addOverlay(overlay) }
        }
        if let target, coordinator.targetID != target.id {
            coordinator.targetID = target.id
            switch target.area {
            case .region(let region): map.setRegion(region, animated: true)
            case .rect(let rect): map.setVisibleMapRect(rect, animated: true)
            }
        }
    }
    final class Coordinator: NSObject, MKMapViewDelegate {
        var revision: UUID?
        var selectedID: Int64?
        var targetID: UUID?
        var routes: [MappedRoute] = []
        var baseOverlay: MKMultiPolyline?
        var selectedOverlay: MKMultiPolyline?
        var centerChanged: ((CLLocationCoordinate2D) -> Void)?
        var selectRoute: ((Int64) -> Void)?

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let overlay = overlay as? MKMultiPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKMultiPolylineRenderer(multiPolyline: overlay)
            let isSelected = overlay === selectedOverlay
            renderer.strokeColor = isSelected ? UIColor(DreeveTheme.accent) : UIColor.gray.withAlphaComponent(0.65)
            renderer.lineWidth = isSelected ? 5 : 2
            return renderer
        }
        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard annotation is RouteAnnotation else { return nil }
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: "route") as? MKMarkerAnnotationView ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: "route")
            view.annotation = annotation
            view.markerTintColor = UIColor(DreeveTheme.accent)
            view.glyphImage = UIImage(systemName: "figure.run")
            view.canShowCallout = false
            return view
        }
        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let annotation = view.annotation as? RouteAnnotation else { return }
            selectRoute?(annotation.routeID)
            mapView.deselectAnnotation(annotation, animated: false)
        }
        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            let center = mapView.region.center
            DispatchQueue.main.async { [weak self] in self?.centerChanged?(center) }
        }
    }
}

struct RoutesView: View {
    @StateObject private var location = RouteLocation()
    @AppStorage("routes.provider.endpoint") private var providerEndpoint = RouteProviderConfiguration.defaultEndpoint
    @AppStorage("routes.provider.auth") private var providerAuth = RouteProviderAuth.none.rawValue
    @AppStorage("routes.provider.timeout") private var providerTimeout = RouteProviderConfiguration.defaultTimeout
    @State private var service = NearbyRouteService()
    @State private var mapTarget: RouteMapTarget?
    @State private var routesRevision = UUID()
    @StateObject private var mapCenter = RouteMapCenter()
    @State private var mapReady = false
    @State private var routes: [MappedRoute] = []
    @State private var selectedID: Int64?
    @State private var loading = false
    @State private var searched = false
    @State private var error: String?
    @State private var requestID = UUID()
    @State private var searchAfterLocation = false
    @State private var showRouteList = false
    @State private var selectedTypes: Set<RouteType> = Set(RouteType.allCases)
    private var selected: MappedRoute? { routes.first { $0.id == selectedID } }
    var body: some View {
            ZStack(alignment: .top) {
                RoutesMap(routes: routes, revision: routesRevision, selectedID: selectedID, target: mapTarget,
                          centerChanged: { center in
                              mapCenter.value = center
                              if !mapReady { mapReady = true }
                          }, selectRoute: { id in
                              if let route = routes.first(where: { $0.id == id }) { select(route) }
                          })

                VStack(spacing: 10) {
                    HStack(spacing: 14) {
                        ForEach(RouteType.allCases) { type in
                            Button {
                                if selectedTypes.contains(type) { selectedTypes.remove(type) }
                                else { selectedTypes.insert(type) }
                                invalidateProvider()
                            } label: {
                                Label(type.label, systemImage: selectedTypes.contains(type) ? "checkmark.square.fill" : "square")
                                    .font(.subheadline)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(selectedTypes.contains(type) ? DreeveTheme.accent : DreeveTheme.muted)
                            .accessibilityAddTraits(selectedTypes.contains(type) ? .isSelected : [])
                        }
                    }
                    .padding(10)
                    .background(DreeveTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                    if selectedTypes.isEmpty {
                        Text("Select at least one route type to search.")
                            .font(.caption).padding(8)
                            .background(DreeveTheme.surface, in: RoundedRectangle(cornerRadius: 10))
                    }
                    if loading || location.searching {
                        HStack { ProgressView(); Text(loading ? "Finding routes…" : "Finding your location…") }
                            .font(.caption).padding(10)
                            .background(DreeveTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                    }
                    if let issue = error ?? location.error {
                        Text(issue).foregroundStyle(.orange).font(.subheadline).padding(10)
                            .background(DreeveTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                    }
                    Spacer(minLength: 0)
                    if let selected {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(selected.name).font(.headline)
                            Text("\((selected.distance / 1000).oneDecimal) km · \(selected.type.capitalized)")
                                .foregroundStyle(DreeveTheme.accent)
                            if selected.incomplete { Text("Some route geometry is missing; distance may be incomplete.").font(.caption).foregroundStyle(DreeveTheme.muted) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                        .background(DreeveTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                    }
                    if searched && routes.isEmpty && !loading && error == nil {
                        Text("No mapped routes found nearby. Try another area.")
                            .font(.subheadline).padding(10)
                            .background(DreeveTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                    }
                    if !routes.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Button { showRouteList.toggle() } label: {
                                HStack {
                                    Text("Nearby routes (\(routes.count))").font(.headline)
                                    Spacer()
                                    Image(systemName: showRouteList ? "chevron.down" : "chevron.up")
                                }
                            }.buttonStyle(.plain)
                            if showRouteList {
                                ScrollView {
                                    VStack(spacing: 4) {
                                        ForEach(routes) { route in
                                            Button { select(route); showRouteList = false } label: {
                                                HStack {
                                                    Image(systemName: route.id == selectedID ? "checkmark.circle.fill" : "figure.run")
                                                    Text(route.name).lineLimit(2)
                                                    Spacer()
                                                    Text("\((route.distance / 1000).oneDecimal) km").monospacedDigit()
                                                }.padding(.vertical, 8)
                                            }.buttonStyle(.plain)
                                        }
                                    }
                                }.frame(maxHeight: 180)
                            }
                        }
                        .padding(12).background(DreeveTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                    }
                    HStack {
                        Button {
                            searchAfterLocation = true
                            location.locate()
                        } label: { Label("Near me", systemImage: "location.fill") }
                            .buttonStyle(.borderedProminent).disabled(loading || location.searching || selectedTypes.isEmpty)
                        Button("Search this area") { if let center = mapCenter.value { search(center) } }
                            .buttonStyle(.bordered).disabled(loading || !mapReady || selectedTypes.isEmpty)
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .background(DreeveTheme.surface, in: RoundedRectangle(cornerRadius: 16))

                    HStack {
                        Link("Route data © OpenStreetMap contributors", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                            .font(.caption2).padding(6)
                            .background(DreeveTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                        Spacer()
                    }
                }
                .padding(12)
                .allowsHitTesting(true)
            }
            .dreeveBackground().navigationTitle("Routes").navigationBarTitleDisplayMode(.inline)
            .onAppear { location.locateIfAuthorized() }
            .onChange(of: location.error) { _, issue in if issue != nil { searchAfterLocation = false } }
            .onChange(of: providerEndpoint) { _, _ in invalidateProvider() }
            .onChange(of: providerAuth) { _, _ in invalidateProvider() }
            .onChange(of: providerTimeout) { _, _ in invalidateProvider() }
            .onReceive(location.$location.compactMap { $0 }) { coordinate in
                mapTarget = RouteMapTarget(area: .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 8000, longitudinalMeters: 8000)))
                mapCenter.value = coordinate
                mapReady = true
                if searchAfterLocation { searchAfterLocation = false; search(coordinate) }
            }
    }
    private func invalidateProvider() {
        requestID = UUID(); loading = false; routes = []; routesRevision = UUID(); selectedID = nil; searched = false; error = nil; showRouteList = false
    }
    private func select(_ route: MappedRoute) {
        selectedID = route.id
        let rect = route.segments.flatMap { $0 }.reduce(MKMapRect.null) { current, coordinate in
            let point = MKMapPoint(coordinate)
            return current.union(MKMapRect(x: point.x, y: point.y, width: 1, height: 1))
        }
        if !rect.isNull {
            mapTarget = RouteMapTarget(area: .rect(rect.insetBy(dx: -max(rect.width * 0.15, 1000), dy: -max(rect.height * 0.15, 1000))))
        }
    }
    private func search(_ coordinate: CLLocationCoordinate2D) {
        guard !selectedTypes.isEmpty else { return }
        let types = selectedTypes
        let id = UUID(); requestID = id; loading = true; error = nil; searched = true
        routes = []; routesRevision = UUID(); selectedID = nil; showRouteList = false
        Task {
            do {
                let endpoint = try RouteProviderConfiguration.validate(providerEndpoint)
                guard let auth = RouteProviderAuth(rawValue: providerAuth) else { throw RouteSearchError.invalidEndpoint }
                let provider = RouteProviderConfiguration(endpoint: endpoint, auth: auth, key: KeychainStore.readRouteKey(endpoint: endpoint), timeoutSeconds: providerTimeout)
                let found = try await service.search(latitude: coordinate.latitude, longitude: coordinate.longitude, types: types, provider: provider)
                guard requestID == id else { return }
                routes = found; routesRevision = UUID(); selectedID = nil; loading = false
            } catch {
                guard requestID == id else { return }
                self.error = "Couldn’t load routes. \(error.localizedDescription)"; loading = false
            }
        }
    }
}

struct RouteProviderSettingsView: View {
    @AppStorage("routes.provider.endpoint") private var endpoint = RouteProviderConfiguration.defaultEndpoint
    @AppStorage("routes.provider.auth") private var authValue = RouteProviderAuth.none.rawValue
    @AppStorage("routes.provider.timeout") private var timeoutValue = RouteProviderConfiguration.defaultTimeout
    @State private var draftEndpoint = ""
    @State private var draftAuth = RouteProviderAuth.none
    @State private var draftTimeout = RouteProviderConfiguration.defaultTimeout
    @State private var newKey = ""
    @State private var keySaved = false
    @State private var message: String?
    @State private var error: String?

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("Route search provider", systemImage: "map").font(.headline)
                Text("Use an Overpass-compatible HTTPS interpreter URL without a key in the address. Searches send the selected location to this provider.")
                    .font(.caption).foregroundStyle(DreeveTheme.muted)
                TextField("https://example.com/api/interpreter", text: $draftEndpoint)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    .padding(12).background(DreeveTheme.elevated, in: RoundedRectangle(cornerRadius: 12))
                Picker("Authentication", selection: $draftAuth) {
                    ForEach(RouteProviderAuth.allCases) { mode in Text(mode.label).tag(mode) }
                }
                Stepper("Search timeout: \(draftTimeout) seconds", value: $draftTimeout, in: 15...180, step: 15)
                Text("Maximum time to wait for a search; the same limit is requested from the provider.")
                    .font(.caption).foregroundStyle(DreeveTheme.muted)
                if draftAuth != .none {
                    SecureField(keySaved ? "Replace saved API key (optional)" : "API key", text: $newKey)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .padding(12).background(DreeveTheme.elevated, in: RoundedRectangle(cornerRadius: 12))
                    Text(keySaved ? "A key is saved for this endpoint." : "No key is saved for this endpoint.")
                        .font(.caption).foregroundStyle(DreeveTheme.muted)
                }
                HStack {
                    Button("Save provider") { save() }.buttonStyle(.borderedProminent)
                    if keySaved { Button("Remove key", role: .destructive) { removeKey() }.buttonStyle(.bordered) }
                }
                if let message { Text(message).font(.caption).foregroundStyle(DreeveTheme.accent) }
                if let error { Text(error).font(.caption).foregroundStyle(.orange) }
                Text("The key stays in your device Keychain and is used only with this endpoint. Choose the header your provider supports; URL and query-string keys are not supported. Redirects are blocked.")
                    .font(.caption).foregroundStyle(DreeveTheme.muted)
            }
        }
        .onAppear { draftEndpoint = endpoint; draftAuth = RouteProviderAuth(rawValue: authValue) ?? .none; draftTimeout = RouteProviderConfiguration.boundedTimeout(timeoutValue); updateKeyStatus() }
        .onChange(of: draftEndpoint) { _, _ in updateKeyStatus() }
    }
    private func updateKeyStatus() {
        keySaved = (try? RouteProviderConfiguration.validate(draftEndpoint)).flatMap { KeychainStore.readRouteKey(endpoint: $0) } != nil
    }
    private func save() {
        do {
            let url = try RouteProviderConfiguration.validate(draftEndpoint)
            let key = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                guard !key.contains("\n"), !key.contains("\r") else { throw RouteSearchError.missingKey }
                try KeychainStore.saveRouteKey(key, endpoint: url)
            }
            if draftAuth != .none, KeychainStore.readRouteKey(endpoint: url)?.isEmpty != false { throw RouteSearchError.missingKey }
            endpoint = url.absoluteString; authValue = draftAuth.rawValue; timeoutValue = draftTimeout
            newKey = ""; updateKeyStatus(); error = nil; message = "Route provider saved."
        } catch { self.error = error.localizedDescription; message = nil }
    }
    private func removeKey() {
        do {
            let url = try RouteProviderConfiguration.validate(draftEndpoint)
            try KeychainStore.deleteRouteKey(endpoint: url)
            newKey = ""; updateKeyStatus(); error = nil; message = "Key removed."
        } catch { self.error = error.localizedDescription; message = nil }
    }
}
