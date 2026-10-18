import SwiftUI
import PhotosUI
import Photos
import UniformTypeIdentifiers
import UIKit

struct ShareCardSheetView: View {
    let telemetry: ShareCardTelemetry
    let gearThumbnail: UIImage?
    var activityImages: [ActivityImage] = []
    var activityPhotoClient: DreeveAPIClient? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var format: ShareCardFormat = .story9x16
    @State private var style: ShareCardBackgroundStyle = .transparentSticker
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var photoChoice: ShareCardPhotoChoice = .none
    @State private var photoAttempt = 0
    @State private var loadedPhotoChoice: ShareCardPhotoChoice = .none
    @State private var photoLoadFailed = false
    @State private var savedToPhotos = false
    @State private var pendingSaveError: String?
    @State private var backgroundPhoto: UIImage?
    @State private var foregroundCutout: UIImage?
    @State private var useDepthLayering = true
    @State private var mapSnapshot: UIImage?
    @State private var isRenderingMap = false
    @State private var isExtractingSubject = false
    @State private var isExporting = false
    @State private var copied = false
    @State private var error: String?
    @State private var photoNotice: String?
    @State private var mapNotice: String?
    @State private var exportURL: URL?
    @State private var showingShare = false

    private var mapRequest: String { style.rawValue + "|" + format.rawValue }
    private var isBusy: Bool { isExporting || (style == .photoDepth && isExtractingSubject) || (style == .darkMap && isRenderingMap) }
    private var canExport: Bool {
        !isBusy && (style != .photoDepth || (backgroundPhoto != nil && loadedPhotoChoice == photoChoice))
    }
    private struct PhotoRequest: Equatable { let choice: ShareCardPhotoChoice; let attempt: Int }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                VStack(spacing: 10) {
                    Picker("Style", selection: $style) {
                        ForEach(ShareCardBackgroundStyle.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented)
                    Picker("Format", selection: $format) {
                        ForEach(ShareCardFormat.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented)
                    if style == .photoDepth {
                        if !activityImages.isEmpty {
                            if case .activity(let index) = photoChoice {
                                HStack {
                                    Button { selectActivityPhoto(index - 1) } label: { Image(systemName: "chevron.left") }
                                        .disabled(index == 0).accessibilityLabel("Previous activity photo")
                                    Spacer()
                                    Text("Activity photo \(index + 1) of \(activityImages.count)").font(.subheadline)
                                    Spacer()
                                    Button { selectActivityPhoto(index + 1) } label: { Image(systemName: "chevron.right") }
                                        .disabled(index + 1 >= activityImages.count).accessibilityLabel("Next activity photo")
                                }
                            } else {
                                Button("Use activity photos") { selectActivityPhoto(0) }.font(.subheadline)
                            }
                        }
                        PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                            Label(activityImages.isEmpty && backgroundPhoto == nil ? "Choose photo" : "Choose another photo", systemImage: "photo.badge.plus")
                        }.buttonStyle(.bordered)
                        if photoLoadFailed { Button("Retry photo") { photoAttempt += 1 }.font(.subheadline) }
                        if foregroundCutout != nil {
                            Toggle("Place route behind subject", isOn: $useDepthLayering).font(.subheadline)
                        }
                        if let photoNotice { Text(photoNotice).font(.caption).foregroundStyle(.secondary) }
                    }
                    if style == .darkMap, let mapNotice { Text(mapNotice).font(.caption).foregroundStyle(.secondary) }
                    if telemetry.coordinates.isEmpty {
                        Text("No GPS route recorded. Your card will include activity details only.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal).disabled(isExporting)

                GeometryReader { geometry in
                    let size = format.pixelSize
                    let scale = max(0.01, min(max(1, geometry.size.width - 32) / size.width,
                                              max(1, geometry.size.height - 12) / size.height))
                    ZStack {
                        Checkerboard().frame(width: size.width * scale, height: size.height * scale)
                        ShareCardCanvasView(telemetry: telemetry, format: format, style: style,
                            gearThumbnail: gearThumbnail, backgroundPhoto: backgroundPhoto,
                            foregroundCutout: useDepthLayering ? foregroundCutout : nil, mapSnapshot: mapSnapshot)
                            .scaleEffect(scale).frame(width: size.width * scale, height: size.height * scale)
                        if isBusy {
                            ProgressView(isExporting ? "Preparing PNG…" : style == .photoDepth ? "Preparing photo…" : "Loading map…")
                                .padding(16).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Activity card preview")
                }

                if style != .photoDepth || backgroundPhoto != nil {
                    HStack(spacing: 12) {
                        Button { export(copy: true) } label: {
                            Label(copied ? "Copied" : "Copy sticker",
                                  systemImage: copied ? "checkmark.circle.fill" : "doc.on.doc")
                                .frame(maxWidth: .infinity).padding(.vertical, 10)
                        }.buttonStyle(.bordered)
                        if style.supportsImageSharing {
                            Button { export(copy: false) } label: {
                                Label("Share image", systemImage: "square.and.arrow.up")
                                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                            }.buttonStyle(.borderedProminent).foregroundStyle(DreeveTheme.background)
                        }
                    }
                    .font(.subheadline.bold()).disabled(!canExport).padding(.horizontal)
                }
                if savedToPhotos { Label("Saved to Photos", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(DreeveTheme.accent) }
                Text("PNG · \(Int(format.pixelSize.width)) × \(Int(format.pixelSize.height))")
                    .font(.caption).foregroundStyle(.secondary).padding(.bottom, 8)
            }
            .background(DreeveTheme.background)
            .navigationTitle("Share activity card").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .task(id: mapRequest) { await loadMap() }
            .onChange(of: style) { _, value in
                copied = false; savedToPhotos = false
                if value == .photoDepth && photoChoice == .none && !activityImages.isEmpty { selectActivityPhoto(0) }
            }
            .onChange(of: format) { _, _ in copied = false; savedToPhotos = false }
            .onChange(of: useDepthLayering) { _, _ in copied = false; savedToPhotos = false }
            .onChange(of: selectedPhotoItem) { _, item in
                if item != nil { photoChoice = .library(UUID()) }
            }
            .task(id: PhotoRequest(choice: photoChoice, attempt: photoAttempt)) { await loadChosenPhoto() }
            .task(id: copied) {
                guard copied else { return }
                do { try await Task.sleep(for: .seconds(2)); copied = false } catch {}
            }
            .sheet(isPresented: $showingShare, onDismiss: {
                removeExport()
                if let pendingSaveError { error = pendingSaveError; self.pendingSaveError = nil }
            }) {
                if let exportURL {
                    ShareCardActivitySheet(url: exportURL, onSave: { message in
                        pendingSaveError = message
                        savedToPhotos = message == nil
                        showingShare = false
                    }, onFinish: { showingShare = false })
                }
            }
            .onDisappear { if !showingShare { removeExport() } }
            .alert("Could not prepare card", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
        }
        .preferredColorScheme(.dark).tint(DreeveTheme.accent)
    }

    private func loadMap() async {
        mapSnapshot = nil; mapNotice = nil
        isRenderingMap = false
        guard style == .darkMap, telemetry.coordinates.count >= 2 else { return }
        let request = mapRequest
        isRenderingMap = true
        let snapshot = await ShareCardRenderer.renderDarkMapSnapshot(coordinates: telemetry.coordinates, format: format)
        guard !Task.isCancelled, request == mapRequest else { return }
        mapSnapshot = snapshot
        isRenderingMap = false
        if snapshot == nil { mapNotice = "Map unavailable. A route-only background will be used." }
    }

    private func selectActivityPhoto(_ index: Int) {
        guard activityImages.indices.contains(index) else { return }
        selectedPhotoItem = nil
        photoChoice = .activity(index)
    }

    private func loadChosenPhoto() async {
        let request = photoChoice
        guard request != .none else { return }
        isExtractingSubject = true; photoLoadFailed = false; photoNotice = nil; copied = false; savedToPhotos = false
        backgroundPhoto = nil; foregroundCutout = nil; loadedPhotoChoice = .none
        do {
            let data: Data
            switch request {
            case .activity(let index):
                guard activityImages.indices.contains(index), let activityPhotoClient else { throw ShareCardError.photo }
                data = try await activityPhotoClient.activityPhoto(activityImages[index].url)
            case .library:
                guard let selectedPhotoItem, let picked = try await selectedPhotoItem.loadTransferable(type: Data.self) else { throw ShareCardError.photo }
                data = picked
            case .none: return
            }
            try Task.checkCancellation()
            let processing = Task.detached(priority: .userInitiated) { () -> (UIImage?, UIImage?) in
                guard !Task.isCancelled, let photo = ShareCardRenderer.downsamplePhotoData(data) else { return (nil, nil) }
                return (photo, ShareCardRenderer.extractForegroundSubject(from: photo))
            }
            let result = await withTaskCancellationHandler { await processing.value } onCancel: { processing.cancel() }
            try Task.checkCancellation()
            guard request == photoChoice else { return }
            guard let photo = result.0 else { throw ShareCardError.photo }
            backgroundPhoto = photo; foregroundCutout = result.1; loadedPhotoChoice = request
            if result.1 == nil { photoNotice = "No clear subject detected. The route will stay over the photo." }
            isExtractingSubject = false
        } catch {
            guard !Task.isCancelled, request == photoChoice else { return }
            isExtractingSubject = false; photoLoadFailed = true
            if let photoError = error as? ActivityPhotoError { photoNotice = photoError.localizedDescription }
            else { photoNotice = "This photo could not be opened. Try again or choose another photo." }
        }
    }

    private func export(copy: Bool) {
        guard canExport, copy || style.supportsImageSharing else { return }
        isExporting = true
        Task { @MainActor in
            await Task.yield()
            defer { isExporting = false }
            guard let png = ShareCardRenderer.renderPNGData(telemetry: telemetry, format: format, style: style,
                gearThumbnail: gearThumbnail, backgroundPhoto: backgroundPhoto, foregroundCutout: foregroundCutout,
                mapSnapshot: mapSnapshot, useDepthSandwich: useDepthLayering) else {
                error = "The card could not be rendered. Try again."; return
            }
            if copy {
                UIPasteboard.general.setData(png, forPasteboardType: UTType.png.identifier)
                copied = true
            } else {
                do {
                    removeExport()
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("Dreeve-\(UUID().uuidString).png")
                    try png.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
                    exportURL = url; showingShare = true
                } catch { self.error = "The PNG could not be saved for sharing. Try again." }
            }
        }
    }
    private func removeExport() {
        if let exportURL { try? FileManager.default.removeItem(at: exportURL) }
        exportURL = nil
    }
}

private enum ShareCardError: Error { case photo }

private struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            for row in 0...Int(size.height / 14) {
                for column in 0...Int(size.width / 14) {
                    context.fill(Path(CGRect(x: column * 14, y: row * 14, width: 14, height: 14)),
                        with: .color((row + column).isMultiple(of: 2) ? Color(white: 0.14) : Color(white: 0.21)))
                }
            }
        }
    }
}

struct ShareCardActivitySheet: UIViewControllerRepresentable {
    let url: URL
    let onSave: (String?) -> Void
    let onFinish: () -> Void
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let save = SaveShareCardToPhotosActivity(url: url, onResult: onSave)
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: [save])
        // Our explicit action preserves the original PNG and works with URL-based sharing.
        controller.excludedActivityTypes = [.saveToCameraRoll]
        controller.completionWithItemsHandler = { type, _, _, _ in
            if type != SaveShareCardToPhotosActivity.type { onFinish() }
        }
        return controller
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

@MainActor final class SaveShareCardToPhotosActivity: UIActivity {
    static let type = UIActivity.ActivityType("app.dreeve.saveShareCardToPhotos")
    private let url: URL
    private let onResult: (String?) -> Void
    private var png: Data?
    init(url: URL, onResult: @escaping (String?) -> Void) { self.url = url; self.onResult = onResult; super.init() }
    override class var activityCategory: UIActivity.Category { .action }
    override var activityType: UIActivity.ActivityType? { Self.type }
    override var activityTitle: String? { "Save to Photos" }
    override var activityImage: UIImage? { UIImage(systemName: "square.and.arrow.down") }
    override func canPerform(withActivityItems activityItems: [Any]) -> Bool {
        activityItems.contains { ($0 as? URL) == url } && FileManager.default.fileExists(atPath: url.path)
    }
    override func prepare(withActivityItems activityItems: [Any]) { png = try? Data(contentsOf: url) }
    override func perform() {
        Task { @MainActor in
            let message: String?
            if let png {
                let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
                if status == .authorized || status == .limited {
                    do {
                        try await PHPhotoLibrary.shared().performChanges {
                            let options = PHAssetResourceCreationOptions()
                            options.uniformTypeIdentifier = UTType.png.identifier
                            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: png, options: options)
                        }
                        message = nil
                    } catch { message = "The image could not be saved to Photos. Try again." }
                } else { message = "Photos access is off. Allow Dreeve to add photos in iPhone Settings, then try again." }
            } else { message = "The PNG could not be opened. Prepare the card and try again." }
            activityDidFinish(message == nil)
            onResult(message)
        }
    }
}
