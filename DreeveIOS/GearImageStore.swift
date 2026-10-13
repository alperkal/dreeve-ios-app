import SwiftUI
import UIKit
import ImageIO

@MainActor
final class GearImageStore: ObservableObject {
    @Published private(set) var selection = GearPhotoSelection()
    @Published private(set) var image: UIImage?
    @Published private(set) var message: String?
    @Published private(set) var resultNumber = 0
    private let instanceID: String
    private let gear: DreeveGear
    private let cache: GearImageCache
    private let client: GearImageSearchClient
    private var results: [GearImageResult] = []
    private var nextIndex = 0
    private var work: Task<Void, Never>?
    private var confirmation: Task<Void, Never>?

    init(instanceID: String, gear: DreeveGear, cache: GearImageCache = GearImageCache(), client: GearImageSearchClient = GearImageSearchClient()) {
        self.instanceID = instanceID; self.gear = gear; self.cache = cache; self.client = client
        do {
            if let data = try cache.load(instanceID: instanceID, gearID: gear.id) { image = UIImage(data: data) }
        } catch { message = "Saved image could not be read. Tap to select another." }
    }
    func tap(endpoint: String, gearName: String? = nil) {
        if selection.expire() { results = []; nextIndex = 0; resultNumber = 0 }
        let action = selection.tap()
        guard action == .search || action == .next else { return }
        message = nil
        confirmation?.cancel()
        work?.cancel()
        work = Task { [weak self] in
            guard let self else { return }
            do {
                if action == .search {
                    results = []
                    nextIndex = 0
                    resultNumber = 0
                    results = try await client.search(gearName: gearName ?? gear.name, endpoint: endpoint)
                }
                try await showNextImage()
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled else { return }
                if case GearImageError.exhausted = error, resultNumber == 0 {
                    message = GearImageError.noResults.localizedDescription
                } else { message = error.localizedDescription }
                selection.failed(hasPreview: resultNumber > 0)
                if selection.phase == .choosing { startConfirmation() }
            }
        }
    }
    private func showNextImage() async throws {
        while nextIndex < results.count {
            try Task.checkCancellation()
            let index = nextIndex
            nextIndex += 1
            let result = results[index]
            var urls = [result.imageURL]
            if let thumbnail = result.thumbnailURL, thumbnail != result.imageURL { urls.append(thumbnail) }
            var png: Data?
            for url in urls {
                do {
                    let data = try await client.download(url)
                    png = try GearImageProcessing.centeredPNG(data)
                    break
                } catch is CancellationError { throw CancellationError() }
                catch { if Task.isCancelled { throw CancellationError() } }
            }
            guard let png else { continue }
            try Task.checkCancellation()
            // Storage errors stop selection without fetching every remaining result.
            try cache.replace(png, instanceID: instanceID, gearID: gear.id)
            image = UIImage(data: png)
            resultNumber = index + 1
            selection.displayed()
            startConfirmation()
            return
        }
        throw GearImageError.exhausted
    }
    private func startConfirmation() {
        confirmation?.cancel()
        confirmation = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(GearPhotoSelection.decisionSeconds)) }
            catch { return }
            guard let self else { return }
            if selection.expire() {
                results = []; nextIndex = 0; resultNumber = 0; message = nil
            }
        }
    }
    func resume() {
        if selection.expire() { results = []; nextIndex = 0; resultNumber = 0; message = nil }
        if image == nil, let data = try? cache.load(instanceID: instanceID, gearID: gear.id) { image = UIImage(data: data) }
    }
    func suspend() {
        work?.cancel()
        if selection.phase == .loading {
            selection.failed(hasPreview: resultNumber > 0)
            if selection.phase == .choosing { startConfirmation() }
            else { selection.reset() }
        } else if selection.phase == .unlocked { selection.reset() }
        if selection.phase == .locked { image = nil }
        // A displayed candidate keeps its original deadline across navigation.
    }
    func finish() {
        work?.cancel(); confirmation?.cancel()
        selection.reset(); results = []; nextIndex = 0; resultNumber = 0
        // The last displayed image is already stored locally and remains selected.
    }
    deinit { work?.cancel(); confirmation?.cancel() }
}

enum GearImageProcessing {
    static func centeredPNG(_ data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 512,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw GearImageError.invalidImage }
        let content = trimUniformBackground(thumbnail) ?? thumbnail
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1; format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 512, height: 512), format: format)
        let result = renderer.image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
            let scale = min(448 / CGFloat(content.width), 448 / CGFloat(content.height))
            let size = CGSize(width: CGFloat(content.width) * scale, height: CGFloat(content.height) * scale)
            UIImage(cgImage: content).draw(in: CGRect(x: (512 - size.width) / 2, y: (512 - size.height) / 2,
                                                    width: size.width, height: size.height))
        }
        guard let png = result.pngData() else { throw GearImageError.invalidImage }
        return png
    }
    // Product photos often have large white margins. Trim only a uniform light
    // background, then center the visible subject; keep complex scenes intact.
    private static func trimUniformBackground(_ image: CGImage) -> CGImage? {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.setFillColor(UIColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return nil }
        let corners = [0, (width - 1) * 4, (height - 1) * width * 4, (width * height - 1) * 4]
        guard corners.allSatisfy({ offset in (0..<3).allSatisfy { bytes[offset + $0] > 225 } }) else { return nil }
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                if min(bytes[offset], bytes[offset + 1], bytes[offset + 2]) < 245 {
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= minX, maxY >= minY, (maxX - minX + 1) * (maxY - minY + 1) > width * height / 100 else { return nil }
        // Bitmap row bounds and CGImage crop bounds both use the source pixel order.
        let crop = CGRect(x: max(0, minX - 8), y: max(0, minY - 8),
                          width: min(width, maxX + 9) - max(0, minX - 8),
                          height: min(height, maxY + 9) - max(0, minY - 8))
        return image.cropping(to: crop)
    }
}


@MainActor
final class GearImageRegistry: ObservableObject {
    private var stores: [String: GearImageStore] = [:]
    private let cache: GearImageCache
    private let client: GearImageSearchClient
    init(cache: GearImageCache = GearImageCache(), client: GearImageSearchClient = GearImageSearchClient()) {
        self.cache = cache; self.client = client
    }
    func store(instanceID: String, gear: DreeveGear) -> GearImageStore {
        let key = instanceID + "|" + gear.id
        if let stored = stores[key] { return stored }
        let stored = GearImageStore(instanceID: instanceID, gear: gear, cache: cache, client: client)
        stores[key] = stored
        return stored
    }
    func retainInstance(_ instanceID: String) {
        for key in Array(stores.keys) where !key.hasPrefix(instanceID + "|") {
            stores.removeValue(forKey: key)?.finish()
        }
    }
}
