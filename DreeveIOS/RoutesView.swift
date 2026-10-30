import SwiftUI
import MapKit
import CoreLocation

@MainActor final class RouteLocation: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    @Published var location: CLLocationCoordinate2D?
    @Published var error: String?
    @Published var searching = false
    private let manager = CLLocationManager()
    private var requested = false
    override init() { super.init(); manager.delegate = self; manager.desiredAccuracy = kCLLocationAccuracyHundredMeters }
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

struct RoutesView: View {
    @StateObject private var location = RouteLocation()
    @AppStorage("routes.provider.endpoint") private var providerEndpoint = RouteProviderConfiguration.defaultEndpoint
    @AppStorage("routes.provider.auth") private var providerAuth = RouteProviderAuth.none.rawValue
    @State private var service = NearbyRouteService()
    @State private var camera: MapCameraPosition = .automatic
    @State private var mapCenter: CLLocationCoordinate2D?
    @State private var routes: [MappedRoute] = []
    @State private var selectedID: Int64?
    @State private var loading = false
    @State private var searched = false
    @State private var error: String?
    @State private var requestID = UUID()
    private var selected: MappedRoute? { routes.first { $0.id == selectedID } }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Map(position: $camera) {
                        ForEach(routes) { route in
                            ForEach(Array(route.segments.enumerated()), id: \.offset) { _, segment in
                                MapPolyline(coordinates: segment)
                                    .stroke(route.id == selectedID ? DreeveTheme.accent : .gray.opacity(0.65), lineWidth: route.id == selectedID ? 5 : 2)
                            }
                            if let point = route.segments.first?.first {
                                Annotation(route.name, coordinate: point) {
                                    Button { select(route) } label: {
                                        Image(systemName: "figure.run.circle.fill").font(.title2)
                                            .foregroundStyle(route.id == selectedID ? DreeveTheme.accent : .white)
                                    }.accessibilityLabel("Select \(route.name)")
                                }
                            }
                        }
                    }
                    .onMapCameraChange(frequency: .onEnd) { mapCenter = $0.region.center }
                    .frame(height: 330).clipShape(RoundedRectangle(cornerRadius: 18))
                    HStack {
                        Button { location.locate() } label: { Label("Near me", systemImage: "location.fill") }
                            .buttonStyle(.borderedProminent).disabled(loading || location.searching)
                        Button("Search this area") { if let mapCenter { search(mapCenter) } }
                            .buttonStyle(.bordered).disabled(loading || mapCenter == nil)
                    }
                    Text("Searches send the selected location to your route provider. Routes are mapped by OpenStreetMap contributors.")
                        .font(.caption).foregroundStyle(DreeveTheme.muted)
                    if loading || location.searching { ProgressView("Finding routes…") }
                    if let issue = error ?? location.error { Text(issue).foregroundStyle(.orange).font(.subheadline) }
                    if let selected {
                        SurfaceCard {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(selected.name).font(.headline)
                                Text("\((selected.distance / 1000).oneDecimal) km · \(selected.type.capitalized)")
                                    .foregroundStyle(DreeveTheme.accent)
                                if selected.incomplete { Text("Some route geometry is missing; distance may be incomplete.").font(.caption).foregroundStyle(DreeveTheme.muted) }
                            }
                        }
                    }
                    if searched && routes.isEmpty && !loading && error == nil {
                        Text("No mapped routes found nearby. Try another area.").foregroundStyle(DreeveTheme.muted)
                    }
                    if !routes.isEmpty {
                        Text("NEARBY ROUTES").font(.caption.bold()).foregroundStyle(DreeveTheme.muted)
                        ForEach(routes) { route in
                            Button { select(route) } label: {
                                HStack {
                                    Image(systemName: route.id == selectedID ? "checkmark.circle.fill" : "figure.run")
                                    Text(route.name).lineLimit(2)
                                    Spacer()
                                    Text("\((route.distance / 1000).oneDecimal) km").monospacedDigit()
                                }.padding(12).background(DreeveTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                            }.buttonStyle(.plain)
                        }
                    }
                    Link("Route data © OpenStreetMap contributors", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                        .font(.caption).foregroundStyle(DreeveTheme.muted)
                }.padding(18)
            }
            .dreeveBackground().navigationTitle("Routes").navigationBarTitleDisplayMode(.inline)
            .onChange(of: providerEndpoint) { _, _ in invalidateProvider() }
            .onChange(of: providerAuth) { _, _ in invalidateProvider() }
            .onReceive(location.$location.compactMap { $0 }) { coordinate in
                camera = .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 8000, longitudinalMeters: 8000))
                search(coordinate)
            }
        }
    }
    private func invalidateProvider() {
        requestID = UUID(); loading = false; routes = []; selectedID = nil; searched = false; error = nil
    }
    private func select(_ route: MappedRoute) {
        selectedID = route.id
        let rect = route.segments.flatMap { $0 }.reduce(MKMapRect.null) { current, coordinate in
            let point = MKMapPoint(coordinate)
            return current.union(MKMapRect(x: point.x, y: point.y, width: 1, height: 1))
        }
        if !rect.isNull {
            camera = .rect(rect.insetBy(dx: -max(rect.width * 0.15, 1000), dy: -max(rect.height * 0.15, 1000)))
        }
    }
    private func search(_ coordinate: CLLocationCoordinate2D) {
        let id = UUID(); requestID = id; loading = true; error = nil; searched = true
        routes = []; selectedID = nil
        Task {
            do {
                let endpoint = try RouteProviderConfiguration.validate(providerEndpoint)
                guard let auth = RouteProviderAuth(rawValue: providerAuth) else { throw RouteSearchError.invalidEndpoint }
                let provider = RouteProviderConfiguration(endpoint: endpoint, auth: auth, key: KeychainStore.readRouteKey(endpoint: endpoint))
                let found = try await service.search(latitude: coordinate.latitude, longitude: coordinate.longitude, provider: provider)
                guard requestID == id else { return }
                routes = found; selectedID = nil; loading = false
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
    @State private var draftEndpoint = ""
    @State private var draftAuth = RouteProviderAuth.none
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
        .onAppear { draftEndpoint = endpoint; draftAuth = RouteProviderAuth(rawValue: authValue) ?? .none; updateKeyStatus() }
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
            endpoint = url.absoluteString; authValue = draftAuth.rawValue
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
