import SwiftUI
import PhotosUI
import UIKit

struct ActivityDetailView: View {
    @EnvironmentObject private var session: DreeveSession
    @EnvironmentObject private var healthSync: HealthSyncStore
    @Environment(\.dismiss) private var dismiss
    let activityID: String

    @State private var activity: DreeveActivity?
    @State private var gear: [DreeveGear] = []
    @State private var loadingGear = true
    @State private var gearError: String?
    @State private var isEditing = false
    @State private var confirmDelete = false
    @State private var isBusy = false
    @State private var errorMessage: String?
    @State private var gpxFile: URL?
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showingShareCardSheet = false

    var body: some View {
        ScrollView {
            if let activity {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 11) {
                        Image(systemName: activitySymbol(activity.sportType))
                            .font(.title)
                            .foregroundStyle(DreeveTheme.accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(activity.sportType.uppercased())
                                .font(.caption.weight(.bold))
                                .foregroundStyle(DreeveTheme.accent)
                            Text(activity.startDate?.formatted(date: .complete, time: .shortened) ?? activity.startDateLocal)
                                .foregroundStyle(DreeveTheme.muted)
                                .font(.subheadline)
                        }
                    }
                    Text(activity.name)
                        .font(.largeTitle.bold())
                    if !activity.locationLabel.isEmpty {
                        Label(activity.locationLabel, systemImage: "mappin")
                            .foregroundStyle(DreeveTheme.muted)
                    }
                    SurfaceCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("GEAR").font(.caption.bold()).foregroundStyle(DreeveTheme.muted)
                            if let id = activity.gearId, !id.isEmpty {
                                if let item = gear.first(where: { $0.id == id }) {
                                    GearSummaryView(gear: item)
                                } else {
                                    Text("Assigned gear: \(id)")
                                    if loadingGear { ProgressView("Loading gear…") }
                                    else if gearError == nil {
                                        Text("This gear is no longer in the inventory.").font(.caption)
                                    }
                                }
                            } else {
                                Text("No gear assigned")
                            }
                            if let gearError {
                                Text(gearError).font(.caption).foregroundStyle(.red)
                                Button("Retry loading gear") { Task { await loadGear() } }
                                    .disabled(loadingGear)
                            }
                            Button("Change gear", systemImage: "pencil") { isEditing = true }
                                .disabled(!session.canUpload || isBusy)
                            if !session.canUpload {
                                Text("Changing gear requires Dreeve file import mode.").font(.caption)
                            }
                        }
                    }
                    if let healthWorkout = healthSync.linkedWorkout(activityID: activity.id, server: session.serverAddress) {
                        SurfaceCard {
                            VStack(alignment: .leading, spacing: 6) {
                                Label("Linked Apple Health workout", systemImage: "heart.fill")
                                    .font(.headline).foregroundStyle(DreeveTheme.accent)
                                Text(healthWorkout.source).font(.subheadline)
                                Text(healthWorkout.start.formatted(date: .abbreviated, time: .shortened))
                                Text("\(Int(healthWorkout.duration / 60)) min recorded in Apple Health")
                                    .font(.caption).foregroundStyle(DreeveTheme.muted)
                            }
                        }
                    }
                    RouteMapView(activity: activity)
                    LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 12) {
                        MetricView(title: "Distance", value: "\(activity.distanceKilometers.oneDecimal) km", symbol: "point.topleft.down.curvedto.point.bottomright.up")
                        MetricView(title: "Moving", value: "\(Int(activity.movingMinutes)) min", symbol: "clock")
                        MetricView(title: "Elevation", value: "\(Int(activity.elevationInMeter ?? 0)) m", symbol: "mountain.2")
                        MetricView(title: "Avg speed", value: "\((activity.averageSpeedInKmPerHour ?? 0).oneDecimal) km/h", symbol: "speedometer")
                        if let bpm = activity.averageHeartRate {
                            MetricView(title: "Avg heart rate", value: "\(bpm) bpm", symbol: "heart")
                        }
                        if let kcal = activity.calories {
                            MetricView(title: "Calories", value: "\(kcal) kcal", symbol: "flame")
                        }
                    }
                    if let description = activity.description, !description.isEmpty {
                        SurfaceCard {
                            Text("NOTES").font(.caption.bold()).foregroundStyle(DreeveTheme.muted)
                            Text(description).padding(.top, 6)
                        }
                    }
                    if let images = activity.images, !images.isEmpty {
                        Text("Photos").font(.title3.bold())
                        ScrollView(.horizontal) {
                            HStack(spacing: 10) {
                                ForEach(images) { image in
                                    ActivityPhotoView(source: image.url)
                                        .id("\(session.serverAddress)|\(image.url)")
                                }
                            }
                        }
                    }
                    Button { showingShareCardSheet = true } label: {
                        Label("Share activity card", systemImage: "sparkles.rectangle.stack")
                    }
                    .buttonStyle(.borderedProminent).tint(DreeveTheme.accent).foregroundStyle(DreeveTheme.background)

                    HStack(spacing: 12) {
                        PhotosPicker(selection: $selectedPhoto, matching: .images) {
                            Label("Add photo", systemImage: "photo.badge.plus")
                        }
                        .buttonStyle(.bordered)
                        .disabled(isBusy || !session.canUpload)
                        if activity.hasGpx == true {
                            if let gpxFile {
                                ShareLink(item: gpxFile) { Label("Share GPX", systemImage: "square.and.arrow.up") }
                                    .buttonStyle(.bordered)
                            } else {
                                Button("Prepare GPX") {
                                    Task {
                                        isBusy = true
                                        defer { isBusy = false }
                                        do { gpxFile = try await session.gpx(activityID) }
                                        catch { errorMessage = error.localizedDescription }
                                    }
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                    .tint(DreeveTheme.accent)
                    if !session.canUpload {
                        Text("Photo upload requires Dreeve file import mode.")
                            .font(.caption)
                            .foregroundStyle(DreeveTheme.muted)
                    }
                }
                .padding(18)
            } else {
                ProgressView("Loading activity…").frame(maxWidth: .infinity, minHeight: 300)
            }
        }
        .dreeveBackground()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if activity != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Edit", systemImage: "pencil") { isEditing = true }
                            .disabled(!session.canUpload || isBusy)
                        Button("Delete activity", systemImage: "trash", role: .destructive) { confirmDelete = true }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
        }
        .task { await load() }
        .sheet(isPresented: $showingShareCardSheet) {
            if let activity {
                ShareCardSheetView(telemetry: ShareCardTelemetry(title: activity.name, sportType: activity.sportType,
                    dateText: String(activity.startDateLocal.prefix(10)), distanceMeters: activity.distanceInMeter ?? 0,
                    movingTimeSeconds: activity.movingTimeInSeconds ?? 0, elevationGainMeters: activity.elevationInMeter ?? 0,
                    gearName: gear.first { $0.id == activity.gearId }?.name, encodedPolyline: activity.encodedPolyline),
                    gearThumbnail: shareGearThumbnail(for: activity))
            }
        }
        .sheet(isPresented: $isEditing) {
            if let activity {
                ActivityEditorView(activity: activity) { edited in
                    self.activity = edited
                    Task { await loadGear() }
                }
            }
        }
        .confirmationDialog("Delete this activity?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete permanently", role: .destructive) {
                Task {
                    do { try await session.removeActivity(activityID); dismiss() }
                    catch { errorMessage = error.localizedDescription }
                }
            }
        } message: { Text("This action removes the activity from Dreeve.") }
        .alert("Request failed", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "Unknown error") }
        .onChange(of: selectedPhoto) { _, newItem in
            guard let newItem else { return }
            Task {
                isBusy = true
                defer { isBusy = false }
                do {
                    guard let data = try await newItem.loadTransferable(type: Data.self),
                          let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.85)
                    else { throw APIError.unsupportedFile }
                    try await session.attachImage(activityID, data: jpeg)
                    await load()
                } catch { errorMessage = error.localizedDescription }
                selectedPhoto = nil
            }
        }
    }

    private func shareGearThumbnail(for activity: DreeveActivity) -> UIImage? {
        guard let id = activity.gearId, let client = try? session.configuredClient(),
              let data = try? GearImageCache().load(instanceID: GoalEngine.instanceID(client.baseURL), gearID: id) else { return nil }
        return UIImage(data: data)
    }

    private func load() async {
        do { activity = try await session.getActivity(activityID) }
        catch { errorMessage = error.localizedDescription }
        // Refresh capabilities after restoring a saved connection on app launch.
        do { _ = try await session.testConnection() }
        catch { errorMessage = error.localizedDescription }
        await loadGear()
    }

    private func loadGear() async {
        loadingGear = true
        gearError = nil
        defer { loadingGear = false }
        do { gear = try await session.gear() }
        catch { gearError = error.localizedDescription }
    }
}

struct GearSummaryView: View {
    let gear: DreeveGear

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                GearThumbnail(gearID: gear.id)
                Text(gear.name).font(.headline)
            }
            Text("\(gear.type.capitalized)\(gear.isRetired == true ? " · Retired" : "")")
                .font(.caption).foregroundStyle(DreeveTheme.muted)
            if let distance = gear.distanceInMeter {
                Text("\((distance / 1000).oneDecimal) km total").font(.subheadline)
            }
            if let count = gear.numberOfActivities {
                Text("\(count) activities").font(.caption).foregroundStyle(DreeveTheme.muted)
            }
        }
    }
}

struct ActivityEditorView: View {
    @EnvironmentObject private var session: DreeveSession
    @Environment(\.dismiss) private var dismiss
    let activity: DreeveActivity
    let didSave: (DreeveActivity) -> Void

    @State private var name: String
    @State private var description: String
    @State private var sportType: String
    @State private var selectedGearID: String?
    @State private var gear: [DreeveGear] = []
    @State private var loadingGear = true
    @State private var gearError: String?
    @State private var saving = false
    @State private var errorMessage: String?

    init(activity: DreeveActivity, didSave: @escaping (DreeveActivity) -> Void) {
        self.activity = activity
        self.didSave = didSave
        _name = State(initialValue: activity.name)
        _description = State(initialValue: activity.description ?? "")
        _sportType = State(initialValue: activity.sportType)
        _selectedGearID = State(initialValue: activity.gearId.flatMap { $0.isEmpty ? nil : $0 })
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                TextField("Sport type", text: $sportType)
                    .textInputAutocapitalization(.never)
                Section("Gear") {
                    Picker("Assigned gear", selection: $selectedGearID) {
                        Text("No gear").tag(String?.none)
                        if let id = activity.gearId, !id.isEmpty,
                           !gear.contains(where: { $0.id == id }) {
                            Text("Current gear (\(id))").tag(Optional(id))
                        }
                        ForEach(gear) { item in
                            Text("\(item.name)\(item.isRetired == true ? " (Retired)" : "")")
                                .tag(Optional(item.id))
                        }
                    }
                    .disabled(loadingGear || gearError != nil || !session.canUpload)
                    if loadingGear { ProgressView("Loading gear…") }
                    if let gearError {
                        Text(gearError).font(.caption).foregroundStyle(.red)
                        Button("Retry") { Task { await loadGear() } }
                    } else if !loadingGear && gear.isEmpty {
                        Text("Your Dreeve inventory is empty.").font(.caption)
                    }
                    if let item = gear.first(where: { $0.id == selectedGearID }) {
                        GearSummaryView(gear: item)
                    }
                    if !session.canUpload {
                        Text("Editing requires Dreeve file import mode.").font(.caption)
                    }
                }
                Section("Description") {
                    TextEditor(text: $description).frame(minHeight: 100)
                }
                Section {
                    Text("Sport type must match a Dreeve / Strava sport type, for example Run, Ride or Swim.")
                        .font(.caption)
                        .foregroundStyle(DreeveTheme.muted)
                }
            }
            .disabled(saving)
            .navigationTitle("Edit activity")
            .task { await loadGear() }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            saving = true
                            defer { saving = false }
                            do {
                                let value = try await session.saveActivity(activity.id, patch: ActivityPatch(name: name.trimmingCharacters(in: .whitespacesAndNewlines), sportType: sportType, description: description, gear: GearChange.between(original: activity.gearId.flatMap { $0.isEmpty ? nil : $0 }, selected: selectedGearID)))
                                didSave(value)
                                dismiss()
                            } catch { errorMessage = error.localizedDescription }
                        }
                    }
                    .disabled(saving || !session.canUpload || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sportType.isEmpty)
                }
            }
            .alert("Could not save", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK") { errorMessage = nil }
            } message: { Text(errorMessage ?? "Unknown error") }
        }
        .tint(DreeveTheme.accent)
        .interactiveDismissDisabled(saving)
    }

    private func loadGear() async {
        loadingGear = true
        gearError = nil
        defer { loadingGear = false }
        do { gear = try await session.gear() }
        catch { gearError = error.localizedDescription }
    }
}

private struct ActivityPhotoView: View {
    @EnvironmentObject private var session: DreeveSession
    let source: String
    @State private var photo: UIImage?
    @State private var isLoading = true
    @State private var failure: String?
    @State private var attempt = 0
    @State private var isShowingPhoto = false

    private var browserURL: URL? {
        try? session.configuredClient().activityPhotoURL(source)
    }

    var body: some View {
        ZStack {
            DreeveTheme.surface
            if let photo {
                Button { isShowingPhoto = true } label: {
                    Image(uiImage: photo).resizable().scaledToFill()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("View photo full screen")
            } else if isLoading {
                ProgressView("Loading photo…")
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "photo.badge.exclamationmark").foregroundStyle(DreeveTheme.muted)
                    Text(failure ?? "Photo unavailable.")
                        .font(.caption).multilineTextAlignment(.center)
                    HStack(spacing: 16) {
                        Button("Retry") { attempt += 1 }
                        if let browserURL { Link("Open in browser", destination: browserURL) }
                    }
                    .font(.caption.bold())
                }
                .padding(12)
            }
        }
        .frame(width: 220, height: 150)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .fullScreenCover(isPresented: $isShowingPhoto) {
            if let photo { ActivityPhotoViewer(photo: photo) }
        }
        .task(id: attempt) {
            isLoading = true
            failure = nil
            defer { isLoading = false }
            do {
                let client = try session.configuredClient()
                let data = try await client.activityPhoto(source)
                try Task.checkCancellation()
                guard let decoded = UIImage(data: data) else { throw ActivityPhotoError.notImage }
                photo = decoded
            } catch is CancellationError {
                failure = "Photo loading was interrupted. Try again."
            } catch let error as URLError where error.code == .cancelled {
                failure = "Photo loading was interrupted. Try again."
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}


private struct ActivityPhotoViewer: View {
    @Environment(\.dismiss) private var dismiss
    let photo: UIImage

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            ZoomableActivityPhoto(photo: photo, onSwipeDown: { dismiss() }).ignoresSafeArea()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.6), in: Circle())
            }
            .accessibilityLabel("Close photo")
            .padding(16)
        }
        .statusBarHidden()
    }
}

private struct ZoomableActivityPhoto: UIViewRepresentable {
    let photo: UIImage
    let onSwipeDown: () -> Void

    func makeUIView(context: Context) -> ActivityPhotoScrollView {
        ActivityPhotoScrollView(photo: photo, onSwipeDown: onSwipeDown)
    }
    func updateUIView(_ uiView: ActivityPhotoScrollView, context: Context) {
        uiView.onSwipeDown = onSwipeDown
    }
}

private final class ActivityPhotoScrollView: UIScrollView, UIScrollViewDelegate {
    private let photoView = UIImageView()
    private var viewportSize = CGSize.zero
    private var canDismissPan = false
    var onSwipeDown: () -> Void

    init(photo: UIImage, onSwipeDown: @escaping () -> Void) {
        self.onSwipeDown = onSwipeDown
        super.init(frame: .zero)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 5
        bouncesZoom = true
        alwaysBounceVertical = true
        panGestureRecognizer.addTarget(self, action: #selector(dismissPhotoWithPan(_:)))
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        backgroundColor = .black
        photoView.image = photo
        photoView.contentMode = .scaleAspectFit
        photoView.isAccessibilityElement = true
        photoView.accessibilityLabel = "Activity photo"
        photoView.accessibilityHint = "Pinch to zoom, drag to move, double tap to toggle zoom, or swipe down when zoomed out to close."
        addSubview(photoView)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Refit on rotation/resizing; ordinary zoom/pan layouts retain the user's scale.
        guard bounds.size != viewportSize, bounds.width > 0, bounds.height > 0 else { return }
        viewportSize = bounds.size
        setZoomScale(1, animated: false)
        photoView.transform = .identity
        photoView.frame = CGRect(origin: .zero, size: viewportSize)
        contentSize = viewportSize
        contentOffset = .zero
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { photoView }

    @objc private func dismissPhotoWithPan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            canDismissPan = zoomScale <= minimumZoomScale + 0.01 && !isZooming && gesture.numberOfTouches == 1
        case .changed:
            if zoomScale > minimumZoomScale + 0.01 || isZooming || gesture.numberOfTouches > 1 {
                canDismissPan = false
            }
        case .ended:
            defer { canDismissPan = false }
            guard canDismissPan, zoomScale <= minimumZoomScale + 0.01 else { return }
            let distance = gesture.translation(in: self)
            let velocity = gesture.velocity(in: self)
            let downward = distance.y > abs(distance.x) * 1.2
            let deliberate = distance.y >= 100 || (distance.y >= 50 && velocity.y >= 700)
            if downward && deliberate { onSwipeDown() }
        case .cancelled, .failed:
            canDismissPan = false
        default:
            break
        }
    }

    @objc private func toggleZoom(_ gesture: UITapGestureRecognizer) {
        guard zoomScale <= minimumZoomScale else {
            setZoomScale(minimumZoomScale, animated: true)
            return
        }
        let scale: CGFloat = 2.5
        let point = gesture.location(in: photoView)
        let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
        zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                        width: size.width, height: size.height), animated: true)
    }
}
