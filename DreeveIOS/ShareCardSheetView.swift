import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit

struct ShareCardSheetView: View {
    let telemetry: ShareCardTelemetry
    let gearThumbnail: UIImage?
    @Environment(\.dismiss) private var dismiss
    @State private var format: ShareCardFormat = .story9x16
    @State private var style: ShareCardBackgroundStyle = .transparentSticker
    @State private var selectedPhotoItem: PhotosPickerItem?
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
    private var isBusy: Bool { isExporting || isExtractingSubject || isRenderingMap }
    private var canExport: Bool { !isBusy && (style != .photoDepth || backgroundPhoto != nil) }

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
                        PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                            Label(backgroundPhoto == nil ? "Choose photo" : "Change photo", systemImage: "photo.badge.plus")
                        }.buttonStyle(.bordered)
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
                        if isRenderingMap || isExtractingSubject || isExporting {
                            ProgressView(isExporting ? "Preparing PNG…" : isExtractingSubject ? "Preparing photo…" : "Loading map…")
                                .padding(16).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Activity card preview")
                }

                HStack(spacing: 12) {
                    Button { export(copy: true) } label: {
                        Label(copied ? "Copied PNG" : style == .transparentSticker ? "Copy sticker" : "Copy PNG",
                              systemImage: copied ? "checkmark.circle.fill" : "doc.on.doc")
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                    }.buttonStyle(.bordered)
                    Button { export(copy: false) } label: {
                        Label("Share image", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                    }.buttonStyle(.borderedProminent).foregroundStyle(DreeveTheme.background)
                }
                .font(.subheadline.bold()).disabled(!canExport).padding(.horizontal)
                Text("PNG · \(Int(format.pixelSize.width)) × \(Int(format.pixelSize.height))")
                    .font(.caption).foregroundStyle(.secondary).padding(.bottom, 8)
            }
            .background(DreeveTheme.background)
            .navigationTitle("Share activity card").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .task(id: mapRequest) { await loadMap() }
            .task(id: selectedPhotoItem) { if let selectedPhotoItem { await loadPhoto(selectedPhotoItem) } }
            .task(id: copied) {
                guard copied else { return }
                do { try await Task.sleep(for: .seconds(2)); copied = false } catch {}
            }
            .sheet(isPresented: $showingShare, onDismiss: removeExport) {
                if let exportURL { ShareCardActivitySheet(url: exportURL) }
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

    private func loadPhoto(_ item: PhotosPickerItem) async {
        isExtractingSubject = true; foregroundCutout = nil; photoNotice = nil
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { throw ShareCardError.photo }
            try Task.checkCancellation()
            let result = await Task.detached(priority: .userInitiated) { () -> (UIImage?, UIImage?) in
                guard let photo = ShareCardRenderer.downsamplePhotoData(data) else { return (nil, nil) }
                return (photo, ShareCardRenderer.extractForegroundSubject(from: photo))
            }.value
            try Task.checkCancellation()
            guard let photo = result.0 else { throw ShareCardError.photo }
            backgroundPhoto = photo; foregroundCutout = result.1
            if result.1 == nil { photoNotice = "No clear subject detected. The route will stay over the photo." }
            isExtractingSubject = false
        } catch {
            guard !Task.isCancelled else { return }
            isExtractingSubject = false
            photoNotice = "This photo could not be opened. Choose another photo."
        }
    }

    private func export(copy: Bool) {
        guard canExport else { return }
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

private struct ShareCardActivitySheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
