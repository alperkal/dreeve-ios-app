import SwiftUI

struct GearView: View {
    @EnvironmentObject private var session: DreeveSession
    @EnvironmentObject private var progress: GoalProgressStore
    @AppStorage("gear.imageSearchURL") private var imageSearchURL = GearImageSearchClient.defaultEndpoint
    @StateObject private var photos = GearImageRegistry()
    @State private var gear: [DreeveGear] = []
    @State private var requestID = UUID()
    @State private var loading = false
    @State private var message: String?
    @State private var search = ""
    @State private var showHelp = false

    private var visibleGear: [DreeveGear] {
        gear.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
            .sorted {
                if ($0.isRetired == true) != ($1.isRetired == true) { return $0.isRetired != true }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }
    var body: some View {
        NavigationStack {
            List {
                if let message {
                    Section { Text(message).font(.caption).foregroundStyle(.orange) }
                }
                Section {
                    if loading { ProgressView("Loading gear…") }
                    if !loading && gear.isEmpty && message == nil {
                        EmptyMessage(title: "No gear", message: "Your Dreeve gear inventory will appear here.", symbol: "shoe")
                            .listRowBackground(Color.clear)
                    }
                    ForEach(visibleGear) { item in
                        HStack(spacing: 16) {
                            GearImageButton(store: photos.store(instanceID: progress.instanceID, gear: item), gear: item, endpoint: imageSearchURL)
                                .id(progress.instanceID + "|" + item.id)
                            NavigationLink {
                                ActivitiesView(gear: item, embedded: true)
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(item.name).font(.headline)
                                    if item.isRetired == true {
                                        Text("Retired").font(.caption).foregroundStyle(.secondary)
                                    }
                                    if let meters = item.distanceInMeter {
                                        Text("\((meters / 1000).oneDecimal) km").font(.subheadline).monospacedDigit()
                                    }
                                    if let count = item.numberOfActivities {
                                        Text("\(count) activities").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }
                        .listRowBackground(DreeveTheme.surface)
                    }
                } header: { Text("Your gear") }
                footer: {
                    Text("Tap the picture to unlock, then tap again to search. Tap during the 10-second countdown to try the next image. The arrow opens this gear’s activities.")
                }
            }
            .scrollContentBackground(.hidden)
            .dreeveBackground()
            .searchable(text: $search, prompt: "Gear name")
            .navigationTitle("Gear")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Refresh gear", systemImage: "arrow.clockwise") { Task { await load() } }
                        .disabled(loading)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Image selection help", systemImage: "info.circle") { showHelp = true }
                }
            }
            .task(id: session.serverAddress) { photos.retainInstance(progress.instanceID); gear = []; await load() }
            .refreshable { await load() }
            .alert("Choose a gear picture", isPresented: $showHelp) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Tap once to unlock and once more to search your SearXNG instance. The first usable image is shown. Tap within 10 seconds to try the next result; each new picture gets a fresh countdown. Wait 10 seconds to keep it. A later selection starts with unlock and a new search. Pictures are stored only on this device.")
            }
        }
        .tint(DreeveTheme.accent)
    }
    private func load() async {
        let server = session.serverAddress
        let request = UUID(); requestID = request
        loading = true
        message = nil
        defer { if session.serverAddress == server, requestID == request { loading = false } }
        do {
            let items = try await session.gear()
            guard session.serverAddress == server, requestID == request, !Task.isCancelled else { return }
            gear = items
        } catch {
            if session.serverAddress == server, requestID == request, !Task.isCancelled { message = error.localizedDescription }
        }
    }
}

struct GearImageButton: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var store: GearImageStore
    let gear: DreeveGear
    let endpoint: String

    init(store: GearImageStore, gear: DreeveGear, endpoint: String) {
        self.gear = gear; self.endpoint = endpoint
        _store = ObservedObject(wrappedValue: store)
    }
    var body: some View {
        VStack(alignment: .center, spacing: 5) {
            Button { store.tap(endpoint: endpoint, gearName: gear.name) } label: {
                TimelineView(.periodic(from: .now, by: 0.2)) { timeline in
                    ZStack {
                        RoundedRectangle(cornerRadius: 21).fill(store.image == nil ? DreeveTheme.elevated : Color.white)
                        if let image = store.image {
                            Image(uiImage: image).resizable().scaledToFit().padding(3)
                        } else { RunningShoeGlyph().padding(16).foregroundStyle(DreeveTheme.accent) }
                        if store.selection.phase == .unlocked || store.selection.phase == .loading {
                            RoundedRectangle(cornerRadius: 21).fill(.black.opacity(0.65))
                            if store.selection.phase == .loading { ProgressView().tint(DreeveTheme.accent) }
                            else { Image(systemName: "lock.open.fill").font(.title2).foregroundStyle(DreeveTheme.accent) }
                        }
                        if store.selection.phase == .choosing {
                            let remaining = store.selection.secondsRemaining(now: timeline.date)
                            RoundedRectangle(cornerRadius: 21)
                                .trim(from: 0, to: CGFloat(remaining) / 10)
                                .stroke(DreeveTheme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            VStack {
                                Spacer()
                                HStack {
                                    Spacer()
                                    Text("\(remaining)s").font(.caption2.bold().monospacedDigit())
                                        .padding(.horizontal, 5).padding(.vertical, 3)
                                        .background(DreeveTheme.accent, in: Capsule()).foregroundStyle(.black)
                                }
                            }.padding(3)
                        }
                    }
                    .frame(width: 84, height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: 21))
                }
            }
            .buttonStyle(.plain)
            .disabled(store.selection.phase == .loading)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint("Pictures are stored locally. Wait 10 seconds to keep a result.")
            if store.selection.phase == .unlocked {
                Text("Tap to search").font(.caption2).foregroundStyle(DreeveTheme.accent)
            } else if store.selection.phase == .choosing {
                Text("Image \(store.resultNumber)").font(.caption2).foregroundStyle(.secondary)
            }
            if let message = store.message {
                Text(message).font(.caption2).foregroundStyle(.orange).frame(maxWidth: 100)
            }
        }
        .onAppear { store.resume() }
        .onDisappear { store.suspend() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { store.resume() } else { store.suspend() }
        }
    }
    private var accessibilityLabel: String {
        switch store.selection.phase {
        case .locked: return "Unlock picture for \(gear.name)"
        case .unlocked: return "Search picture for \(gear.name)"
        case .loading: return "Loading picture for \(gear.name)"
        case .choosing: return "Try next picture for \(gear.name)"
        }
    }
}

/// A read-only preview of the locally selected picture for the current instance.
struct GearThumbnail: View {
    @EnvironmentObject private var progress: GoalProgressStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var image: UIImage?
    let gearID: String

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(image == nil ? DreeveTheme.elevated : Color.white)
            if let image {
                Image(uiImage: image).resizable().scaledToFit().padding(2)
            } else {
                RunningShoeGlyph().padding(9).foregroundStyle(DreeveTheme.accent)
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityHidden(true)
        .task(id: progress.instanceID + "|" + gearID) { reload() }
        .onAppear { reload() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { reload() }
        }
    }

    private func reload() {
        image = (try? GearImageCache().load(instanceID: progress.instanceID, gearID: gearID))
            .flatMap { UIImage(data: $0) }
    }
}

/// A running-shoe placeholder that does not depend on newer SF Symbols versions.
private struct RunningShoeGlyph: View {
    var body: some View {
        GeometryReader { geometry in
            let w = geometry.size.width, h = geometry.size.height
            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: 0.1*w, y: 0.35*h))
                    p.addLine(to: CGPoint(x: 0.28*w, y: 0.45*h))
                    p.addLine(to: CGPoint(x: 0.4*w, y: 0.32*h))
                    p.addQuadCurve(to: CGPoint(x: 0.68*w, y: 0.58*h), control: CGPoint(x: 0.5*w, y: 0.52*h))
                    p.addQuadCurve(to: CGPoint(x: 0.94*w, y: 0.7*h), control: CGPoint(x: 0.94*w, y: 0.59*h))
                    p.addLine(to: CGPoint(x: 0.92*w, y: 0.8*h))
                    p.addLine(to: CGPoint(x: 0.07*w, y: 0.8*h))
                    p.addQuadCurve(to: CGPoint(x: 0.1*w, y: 0.35*h), control: CGPoint(x: 0.02*w, y: 0.62*h))
                    p.closeSubpath()
                }.fill()
                Path { p in
                    p.move(to: CGPoint(x: 0.09*w, y: 0.7*h)); p.addLine(to: CGPoint(x: 0.92*w, y: 0.7*h))
                    p.move(to: CGPoint(x: 0.4*w, y: 0.48*h)); p.addLine(to: CGPoint(x: 0.48*w, y: 0.43*h))
                    p.move(to: CGPoint(x: 0.48*w, y: 0.56*h)); p.addLine(to: CGPoint(x: 0.56*w, y: 0.5*h))
                }.stroke(DreeveTheme.elevated, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            }
        }
    }
}

@MainActor
final class GearActivitiesStore: ObservableObject {
    @Published private(set) var activities: [DreeveActivity] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    private var requestID = UUID()
    private var scope = ""

    func reset() { requestID = UUID(); activities = []; isLoading = false; error = nil }
    func load(client: DreeveAPIClient, gearID: String) async {
        let key = GoalEngine.instanceID(client.baseURL) + "|" + gearID
        if key != scope { activities = []; scope = key }
        let request = UUID()
        requestID = request
        isLoading = true; error = nil
        defer { if requestID == request { isLoading = false } }
        do {
            let values = try await client.activitiesForGear(gearID)
            guard requestID == request, !Task.isCancelled else { return }
            activities = values
        } catch {
            if requestID == request, !Task.isCancelled { self.error = error.localizedDescription }
        }
    }
}

struct GearImageSearchSettingsView: View {
    @AppStorage("gear.imageSearchURL") private var endpoint = GearImageSearchClient.defaultEndpoint
    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("Gear image search", systemImage: "photo.magnifyingglass").font(.headline)
                TextField("HTTPS SearXNG search URL", text: $endpoint)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    .padding(10).background(DreeveTheme.elevated, in: RoundedRectangle(cornerRadius: 10))
                if (try? GearImageSearchClient.endpoint(endpoint)) == nil {
                    Text("Use an HTTPS URL without credentials or query parameters.").font(.caption).foregroundStyle(.orange)
                }
                Text("Gear names are sent only when you tap to search. Pictures are downloaded from image sources and kept on this device. No Dreeve API key is sent with image requests.")
                    .font(.caption).foregroundStyle(DreeveTheme.muted)
            }
        }
    }
}
