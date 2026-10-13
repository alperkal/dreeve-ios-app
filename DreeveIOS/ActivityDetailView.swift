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
                                    AsyncImage(url: URL(string: image.url)) { photo in
                                        photo.resizable().scaledToFill()
                                    } placeholder: {
                                        RoundedRectangle(cornerRadius: 12).fill(DreeveTheme.surface)
                                            .overlay { ProgressView() }
                                    }
                                    .frame(width: 220, height: 150)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                }
                            }
                        }
                    }
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
