import Foundation
import CoreGraphics
import CoreLocation

enum ShareCardFormat: String, CaseIterable, Identifiable, Sendable {
    case story9x16 = "Story 9:16", square1x1 = "Square 1:1"
    var id: String { rawValue }
    var pixelSize: CGSize { CGSize(width: 1080, height: self == .story9x16 ? 1920 : 1080) }
    var mapHeight: CGFloat { pixelSize.height * (self == .story9x16 ? 0.59 : 0.49) }
    var routeRect: CGRect { CGRect(x: 70, y: 65, width: 940, height: mapHeight - 140) }
}

enum ShareCardBackgroundStyle: String, CaseIterable, Identifiable, Sendable {
    case transparentSticker = "Sticker", darkMap = "Dark map", photoDepth = "Photo"
    var id: String { rawValue }
    var supportsImageSharing: Bool { self != .transparentSticker }
}

enum ShareCardPhotoChoice: Equatable {
    case none, activity(Int), library(UUID)
}

struct ShareCardTelemetry: Sendable, Equatable {
    let title: String
    let sportLabel: String
    let dateText: String
    let primaryMetricLabel: String
    let primaryMetricValue: String
    let secondaryMetricLabel: String
    let secondaryMetricValue: String
    let tertiaryMetricLabel: String
    let tertiaryMetricValue: String
    let gearName: String?
    let coordinates: [CLLocationCoordinate2D]

    init(title: String, sportType: String, dateText: String, distanceMeters: Double,
         movingTimeSeconds: Int, elevationGainMeters: Double, gearName: String?, encodedPolyline: String?) {
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? sportType : title
        sportLabel = sportType.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression).uppercased()
        self.dateText = dateText
        let meters = distanceMeters.isFinite ? max(0, distanceMeters) : 0
        let seconds = max(0, movingTimeSeconds)
        let elevation = elevationGainMeters.isFinite ? max(0, elevationGainMeters) : 0
        primaryMetricLabel = "DISTANCE"
        primaryMetricValue = meters >= 10 ? String(format: "%.2f km", meters / 1000) : "—"
        let sport = sportType.lowercased()
        if sport.contains("run") || sport.contains("walk") || sport.contains("hike") {
            secondaryMetricLabel = "AVG PACE"
            let pace = meters >= 50 && seconds > 0 ? (Double(seconds) / (meters / 1000)).rounded() : .infinity
            secondaryMetricValue = pace.isFinite && pace <= 86400 ? String(format: "%d:%02d /km", Int(pace) / 60, Int(pace) % 60) : "—"
        } else if sport.contains("ride") || sport.contains("cycl") || sport.contains("bike") {
            secondaryMetricLabel = "AVG SPEED"
            let speed = meters >= 100 && seconds > 0 ? (meters / 1000) / (Double(seconds) / 3600) : .infinity
            secondaryMetricValue = speed.isFinite ? String(format: "%.1f km/h", speed) : "—"
        } else {
            secondaryMetricLabel = "ELEVATION"
            secondaryMetricValue = String(format: "%.0f m", elevation)
        }
        tertiaryMetricLabel = "DURATION"
        let hours = seconds / 3600, minutes = (seconds % 3600) / 60, remainder = seconds % 60
        tertiaryMetricValue = hours > 0 ? "\(hours):" + String(format: "%02d:%02d", minutes, remainder) : String(format: "%d:%02d", minutes, remainder)
        self.gearName = gearName.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        coordinates = encodedPolyline.map(RouteGeometryProjector.decodePolyline) ?? []
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.title == rhs.title && lhs.sportLabel == rhs.sportLabel && lhs.dateText == rhs.dateText &&
        lhs.primaryMetricValue == rhs.primaryMetricValue && lhs.secondaryMetricLabel == rhs.secondaryMetricLabel &&
        lhs.secondaryMetricValue == rhs.secondaryMetricValue && lhs.tertiaryMetricValue == rhs.tertiaryMetricValue &&
        lhs.gearName == rhs.gearName && lhs.coordinates.count == rhs.coordinates.count &&
        zip(lhs.coordinates, rhs.coordinates).allSatisfy { pair in pair.0.latitude == pair.1.latitude && pair.0.longitude == pair.1.longitude }
    }
}

#if canImport(UIKit)
import UIKit
import SwiftUI
import MapKit
import Vision
import CoreImage
import ImageIO

@MainActor enum ShareCardRenderer {
    nonisolated static func downsamplePhotoData(_ data: Data, maxDimension: CGFloat = 2160) -> UIImage? {
        guard maxDimension.isFinite, maxDimension > 0, data.count <= 100 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: min(maxDimension, 4096)
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    nonisolated static func extractForegroundSubject(from image: UIImage) -> UIImage? {
        guard !Task.isCancelled, let cgImage = image.cgImage else { return nil }
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
            guard !Task.isCancelled, let result = request.results?.first, !result.allInstances.isEmpty else { return nil }
            let buffer = try result.generateMaskedImage(ofInstances: result.allInstances, from: handler, croppedToInstancesExtent: false)
            let context = CIContext(options: [.cacheIntermediates: false])
            let output = CIImage(cvPixelBuffer: buffer)
            guard let subject = context.createCGImage(output, from: output.extent) else { return nil }
            return UIImage(cgImage: subject)
        } catch { return nil }
    }

    static func renderDarkMapSnapshot(coordinates: [CLLocationCoordinate2D], format: ShareCardFormat) async -> UIImage? {
        guard coordinates.count >= 2 else { return nil }
        let size = CGSize(width: format.pixelSize.width, height: format.mapHeight)
        let options = MKMapSnapshotter.Options()
        options.size = size; options.scale = 1
        options.traitCollection = UITraitCollection(userInterfaceStyle: .dark)
        let configuration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        configuration.pointOfInterestFilter = .excludingAll
        options.preferredConfiguration = configuration
        let world = MKMapRect.world.size.width
        let xs = RouteGeometryProjector.unwrappedLongitudes(coordinates).map { ($0 + 180) / 360 * world }
        let ys = coordinates.map { MKMapPoint(CLLocationCoordinate2D(latitude: min(max($0.latitude, -85), 85), longitude: $0.longitude)).y }
        let route = format.routeRect.insetBy(dx: 40, dy: 40)
        let minExtent = 200 * MKMapPointsPerMeterAtLatitude(coordinates[0].latitude)
        let width = max(xs.max()! - xs.min()!, minExtent), height = max(ys.max()! - ys.min()!, minExtent)
        let scale = min(max(width / route.width, height / route.height), world / max(size.width, size.height))
        options.mapRect = MKMapRect(x: (xs.min()! + xs.max()!) / 2 - route.midX * scale,
            y: max(0, min(world - size.height * scale, (ys.min()! + ys.max()!) / 2 - route.midY * scale)),
            width: size.width * scale, height: size.height * scale)
        let snapshotter = MKMapSnapshotter(options: options)
        let timeout = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(20)); snapshotter.cancel() } catch {}
        }
        defer { timeout.cancel() }
        let snapshot: MKMapSnapshotter.Snapshot
        do {
            snapshot = try await withTaskCancellationHandler {
                try await snapshotter.start()
            } onCancel: { snapshotter.cancel() }
            try Task.checkCancellation()
        } catch { return nil }
        let imageFormat = UIGraphicsImageRendererFormat(); imageFormat.scale = 1; imageFormat.opaque = true
        return UIGraphicsImageRenderer(size: size, format: imageFormat).image { context in
            snapshot.image.draw(at: .zero)
            let points = coordinates.map { snapshot.point(for: $0) }
            let path = UIBezierPath(); path.move(to: points[0]); points.dropFirst().forEach { path.addLine(to: $0) }
            path.lineCapStyle = .round; path.lineJoinStyle = .round
            UIColor(red: 177/255, green: 244/255, blue: 82/255, alpha: 1).setStroke()
            context.cgContext.setShadow(offset: .zero, blur: 12, color: UIColor.black.withAlphaComponent(0.6).cgColor)
            path.lineWidth = 10; path.stroke()
            context.cgContext.setShadow(offset: .zero, blur: 0, color: nil)
            UIColor.white.withAlphaComponent(0.9).setStroke(); path.lineWidth = 3; path.stroke()
        }
    }

    static func renderPNGData(telemetry: ShareCardTelemetry, format: ShareCardFormat, style: ShareCardBackgroundStyle,
                              gearThumbnail: UIImage?, backgroundPhoto: UIImage?, foregroundCutout: UIImage?,
                              mapSnapshot: UIImage?, useDepthSandwich: Bool) -> Data? {
        let renderer = ImageRenderer(content: ShareCardCanvasView(telemetry: telemetry, format: format, style: style,
            gearThumbnail: gearThumbnail, backgroundPhoto: backgroundPhoto,
            foregroundCutout: useDepthSandwich ? foregroundCutout : nil, mapSnapshot: mapSnapshot)
            .frame(width: format.pixelSize.width, height: format.pixelSize.height)
            .environment(\.colorScheme, .dark))
        renderer.scale = 1; renderer.isOpaque = style != .transparentSticker
        return renderer.uiImage?.pngData()
    }
}

struct ShareCardCanvasView: View {
    let telemetry: ShareCardTelemetry
    let format: ShareCardFormat
    let style: ShareCardBackgroundStyle
    let gearThumbnail: UIImage?
    let backgroundPhoto: UIImage?
    let foregroundCutout: UIImage?
    let mapSnapshot: UIImage?

    private var story: Bool { format == .story9x16 }
    private var size: CGSize { format.pixelSize }
    private var footerTop: CGFloat { size.height * (story ? 0.64 : 0.54) }

    var body: some View {
        let projected = RouteGeometryProjector.project(coordinates: telemetry.coordinates, into: format.routeRect, paddingFraction: 0.1)
        ZStack(alignment: .topLeading) {
            if style != .transparentSticker { DreeveTheme.background }
            if style == .darkMap, let mapSnapshot {
                // Keep the snapshot's attribution edge visible above the telemetry.
                Image(uiImage: mapSnapshot).resizable().frame(width: size.width, height: format.mapHeight)
            }
            if style == .photoDepth, let backgroundPhoto {
                photoLayer(backgroundPhoto)
            }
            if style != .darkMap || mapSnapshot == nil {
                if projected.points.isEmpty {
                    Image(systemName: "figure.run.circle")
                        .font(.system(size: story ? 200 : 130, weight: .ultraLight))
                        .foregroundStyle(DreeveTheme.accent.opacity(0.8))
                        .frame(width: size.width, height: format.mapHeight)
                } else { RouteVectorLayer(projected: projected).frame(width: size.width, height: size.height) }
            }
            if style == .photoDepth, let foregroundCutout { photoLayer(foregroundCutout) }
            if style == .photoDepth {
                LinearGradient(colors: [.clear, DreeveTheme.background.opacity(0.9)], startPoint: .top, endPoint: .bottom)
                    .frame(height: size.height - footerTop + 120).offset(y: footerTop - 120)
            }
            footer.frame(width: size.width - 120, height: size.height - footerTop - 48, alignment: .topLeading)
                .offset(x: 60, y: footerTop)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    private func photoLayer(_ image: UIImage) -> some View {
        Image(uiImage: image).resizable().scaledToFill().frame(width: size.width, height: size.height).clipped()
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: story ? 24 : 14) {
            HStack(spacing: 18) {
                Text(telemetry.sportLabel).font(.system(size: story ? 23 : 18, weight: .heavy, design: .rounded))
                    .foregroundStyle(DreeveTheme.background).padding(.horizontal, 18).padding(.vertical, 10)
                    .background(DreeveTheme.accent, in: Capsule()).lineLimit(1).minimumScaleFactor(0.65)
                Text(telemetry.dateText).font(.system(size: story ? 24 : 20, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85)).lineLimit(1).minimumScaleFactor(0.7)
            }
            Text(telemetry.title).font(.system(size: story ? 54 : 42, weight: .bold, design: .rounded))
                .foregroundStyle(.white).lineLimit(2).minimumScaleFactor(0.65)
                .shadow(color: .black.opacity(0.65), radius: 8, y: 3)
            HStack(spacing: 20) {
                metric(telemetry.primaryMetricLabel, telemetry.primaryMetricValue)
                metric(telemetry.secondaryMetricLabel, telemetry.secondaryMetricValue)
                metric(telemetry.tertiaryMetricLabel, telemetry.tertiaryMetricValue)
            }
            .padding(story ? 30 : 24).frame(maxWidth: .infinity)
            .background(DreeveTheme.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: 26))
            if let name = telemetry.gearName {
                HStack(spacing: 18) {
                    Group {
                        if let gearThumbnail { Image(uiImage: gearThumbnail).resizable().scaledToFit() }
                        else { Image(systemName: "shoeprints.fill").font(.system(size: 30)).foregroundStyle(DreeveTheme.accent) }
                    }
                    .frame(width: story ? 70 : 54, height: story ? 70 : 54)
                    .background(DreeveTheme.surface, in: RoundedRectangle(cornerRadius: 16))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("GEAR").font(.system(size: 16, weight: .bold)).foregroundStyle(DreeveTheme.muted)
                        Text(name).font(.system(size: story ? 26 : 22, weight: .semibold)).foregroundStyle(.white)
                            .lineLimit(2).minimumScaleFactor(0.7)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(label).font(.system(size: story ? 19 : 16, weight: .bold)).foregroundStyle(DreeveTheme.muted)
            Text(value).font(.system(size: story ? 44 : 37, weight: .heavy, design: .rounded))
                .foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.5)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct RouteVectorLayer: View {
    let projected: ProjectedRoute
    var body: some View {
        Canvas { context, _ in
            guard let first = projected.startPoint else { return }
            var path = Path(); path.move(to: first)
            projected.points.dropFirst().forEach { path.addLine(to: $0) }
            var glow = context
            glow.addFilter(.shadow(color: DreeveTheme.accent.opacity(0.7), radius: 18))
            glow.stroke(path, with: .color(DreeveTheme.accent), style: StrokeStyle(lineWidth: 13, lineCap: .round, lineJoin: .round))
            context.stroke(path, with: .color(.white.opacity(0.95)), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            for point in [projected.startPoint, projected.isClosedLoop ? nil : projected.endPoint].compactMap({ $0 }) {
                let marker = Path(ellipseIn: CGRect(x: point.x - 11, y: point.y - 11, width: 22, height: 22))
                context.fill(marker, with: .color(DreeveTheme.accent))
                context.stroke(marker, with: .color(.white), lineWidth: 3)
            }
        }
    }
}
#endif
