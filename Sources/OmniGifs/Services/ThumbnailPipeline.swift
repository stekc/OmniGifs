import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import OSLog
import UniformTypeIdentifiers

enum GIFPlaybackAsset: Sendable {
    case animatedImage(Data)
    case animatedWebP(Data)
    case video(URL)
    case transcodedWebP(URL)
}

actor ThumbnailPipeline {
    static let shared = ThumbnailPipeline()
    private static let logger = Logger(subsystem: "win.stkc.omnigifs", category: "Media")
    private static let posterMaximumPixelSize = 512

    private let memory = NSCache<NSString, CGImageBox>()
    private let directory: URL
    private var inFlight: [String: Task<CGImage?, Never>] = [:]
    private var mediaInFlight: [String: Task<Data?, Never>] = [:]
    private var memoryGeneration = 0

    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        directory =
            base
            .appendingPathComponent("OmniGifs", isDirectory: true)
            .appendingPathComponent("Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        memory.countLimit = 180
        memory.totalCostLimit = 96 * 1_024 * 1_024
    }

    func thumbnail(for favorite: GIFFavorite) async -> CGImage? {
        let key = favorite.id
        let requestGeneration = memoryGeneration
        if let cached = memory.object(forKey: key as NSString)?.image { return cached }
        if let task = inFlight[key] { return await task.value }

        let task = Task<CGImage?, Never> {
            let diskURL = self.thumbnailURL(for: key)
            if let data = try? Data(contentsOf: diskURL),
                let image = self.decodeImage(data)
            {
                return image
            }
            let image = await self.representativeFrames(
                for: favorite,
                maximumCount: 1,
                maximumPixelSize: Self.posterMaximumPixelSize
            ).first
            if let image { self.writePNG(image, to: diskURL) }
            return image
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image, requestGeneration == memoryGeneration {
            memory.setObject(
                CGImageBox(image),
                forKey: key as NSString,
                cost: image.bytesPerRow * image.height
            )
        }
        return image
    }

    func releaseMemoryCache() {
        memoryGeneration += 1
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll(keepingCapacity: false)
        memory.removeAllObjects()
    }

    func removeCachedData(for favoriteIDs: Set<String>) throws {
        for id in favoriteIDs {
            inFlight[id]?.cancel()
            inFlight[id] = nil
            mediaInFlight[id]?.cancel()
            mediaInFlight[id] = nil
            memory.removeObject(forKey: id as NSString)
            for fileExtension in ["png", "gif", "mp4", "media"] {
                let url = directory.appendingPathComponent("\(digest(id)).\(fileExtension)")
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            }
        }
    }

    func clearDiskCache() throws {
        releaseMemoryCache()
        for task in mediaInFlight.values { task.cancel() }
        mediaInFlight.removeAll(keepingCapacity: false)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    nonisolated static func cachedThumbnailOnDisk(for id: String) -> CGImage? {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let directory =
            base
            .appendingPathComponent("OmniGifs", isDirectory: true)
            .appendingPathComponent("Thumbnails", isDirectory: true)
        let digest = SHA256.hash(data: Data(id.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let url = directory.appendingPathComponent("\(digest).png")
        guard let data = try? Data(contentsOf: url),
            let source = CGImageSourceCreateWithData(data as CFData, nil)
        else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(
            source, 0,
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: posterMaximumPixelSize,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCache: true,
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary)
    }

    func representativeFrames(
        for favorite: GIFFavorite,
        maximumCount: Int = 8,
        maximumPixelSize: Int = 720
    ) async -> [CGImage] {
        guard maximumCount > 0, let data = await mediaData(for: favorite) else { return [] }
        return await decodeRepresentativeFrames(
            data: data,
            videoURL: mediaURL(for: favorite),
            maximumCount: maximumCount,
            maximumPixelSize: maximumPixelSize
        )
    }

    func decodeRepresentativeFrames(
        data: Data,
        videoURL: URL,
        maximumCount: Int,
        maximumPixelSize: Int = 720
    ) async -> [CGImage] {
        guard maximumCount > 0 else { return [] }
        if let source = CGImageSourceCreateWithData(data as CFData, nil) {
            let total = CGImageSourceGetCount(source)
            if total > 0 {
                let count = min(maximumCount, total)
                let indices = evenlySpacedIndices(total: total, count: count)
                return indices.compactMap { index in
                    CGImageSourceCreateThumbnailAtIndex(
                        source, index,
                        [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceShouldCache: true,
                            kCGImageSourceShouldCacheImmediately: true,
                        ] as CFDictionary
                    ).flatMap(self.eagerlyDecoded)
                }
            }
        }
        return await decodeVideoFrames(
            url: videoURL,
            maximumCount: maximumCount,
            maximumPixelSize: maximumPixelSize
        )
    }

    /// Collection-view reuse limits full-fidelity playback to visible cells;
    /// offscreen favorites remain cached media and inexpensive metadata.
    func playbackAsset(for favorite: GIFFavorite) async -> GIFPlaybackAsset? {
        guard let data = await mediaData(for: favorite) else { return nil }
        if favorite.format == .video {
            return .video(mediaURL(for: favorite))
        }
        if let source = CGImageSourceCreateWithData(data as CFData, nil) {
            guard CGImageSourceGetCount(source) > 1 else { return nil }
            if CGImageSourceGetType(source) as String? == UTType.webP.identifier {
                if let videoURL = await WebPVideoTranscoder.shared.cachedVideoURL(
                    for: favorite.id,
                    data: data
                ) {
                    return .transcodedWebP(videoURL)
                }
                await WebPVideoTranscoder.shared.schedule(
                    data: data,
                    cacheKey: favorite.id
                )
                return .animatedWebP(data)
            }
            return .animatedImage(data)
        }
        return .video(mediaURL(for: favorite))
    }

    private func mediaData(for favorite: GIFFavorite) async -> Data? {
        let key = favorite.id
        let diskURL = mediaURL(for: favorite)
        if let data = try? Data(contentsOf: diskURL, options: .mappedIfSafe) {
            if favorite.format == .video && Self.isWebM(data) {
                try? FileManager.default.removeItem(at: diskURL)
            } else {
                return data
            }
        }
        let legacyURL = legacyMediaURL(for: key)
        if let data = try? Data(contentsOf: legacyURL, options: .mappedIfSafe) {
            if favorite.format == .video && Self.isWebM(data) {
                try? FileManager.default.removeItem(at: legacyURL)
            } else {
                try? FileManager.default.moveItem(at: legacyURL, to: diskURL)
                return data
            }
        }
        if let task = mediaInFlight[key] { return await task.value }
        guard let mediaURL = favorite.mediaURL else { return nil }
        let remoteURL = Self.nativeMediaURL(for: mediaURL)

        let task = Task<Data?, Never> {
            do {
                let (data, response) = try await URLSession.shared.data(from: remoteURL)
                guard (response as? HTTPURLResponse)?.statusCode ?? 200 < 400 else { return nil }
                try data.write(to: diskURL, options: .atomic)
                return data
            } catch {
                Self.logger.error(
                    "Media download failed: \(error.localizedDescription, privacy: .public)"
                )
                return nil
            }
        }
        mediaInFlight[key] = task
        let result = await task.value
        mediaInFlight[key] = nil
        return result
    }

    static func nativeMediaURL(for url: URL) -> URL {
        guard url.host?.lowercased() == "media.tenor.com",
            url.pathExtension.lowercased() == "webm",
            url.path.contains("AAAPs/")
        else { return url }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var path = components?.path ?? url.path
        path = path.replacingOccurrences(of: "AAAPs/", with: "AAAPo/")
        path = (path as NSString).deletingPathExtension + ".mp4"
        components?.path = path
        return components?.url ?? url
    }

    private static func isWebM(_ data: Data) -> Bool {
        data.count >= 4 && data.prefix(4).elementsEqual([0x1A, 0x45, 0xDF, 0xA3])
    }

    private func decodeImage(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(
            source, 0,
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: Self.posterMaximumPixelSize,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCache: true,
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary
        ).flatMap(eagerlyDecoded)
    }

    private func eagerlyDecoded(_ image: CGImage) -> CGImage? {
        guard
            let context = CGContext(
                data: nil,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            )
        else { return image }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage() ?? image
    }

    private func decodeVideoFrames(
        url: URL,
        maximumCount: Int,
        maximumPixelSize: Int
    ) async -> [CGImage] {
        do {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            let seconds = max(CMTimeGetSeconds(duration), 0)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(
                width: maximumPixelSize,
                height: maximumPixelSize
            )
            let count = seconds > 0.2 ? maximumCount : 1
            var frames: [CGImage] = []
            frames.reserveCapacity(count)
            for index in 0..<count {
                let fraction = count == 1 ? 0 : Double(index) / Double(count - 1)
                let time = CMTime(
                    seconds: max(0, seconds * fraction - 0.001),
                    preferredTimescale: 600
                )
                if let image = try? await generator.image(at: time).image {
                    frames.append(image)
                }
            }
            return frames
        } catch {
            return []
        }
    }

    private func writePNG(_ image: CGImage, to url: URL) {
        guard
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
            )
        else { return }
        CGImageDestinationAddImage(destination, image, nil)
        if !CGImageDestinationFinalize(destination) {
            Self.logger.error("Unable to finalize cached thumbnail")
        }
    }

    private func thumbnailURL(for key: String) -> URL {
        directory.appendingPathComponent("\(digest(key)).png")
    }

    private func mediaURL(for favorite: GIFFavorite) -> URL {
        let fileExtension: String
        switch favorite.format {
        case .image: fileExtension = "gif"
        case .video: fileExtension = "mp4"
        case .unknown: fileExtension = "media"
        }
        return directory.appendingPathComponent("\(digest(favorite.id)).\(fileExtension)")
    }

    private func legacyMediaURL(for key: String) -> URL {
        directory.appendingPathComponent("\(digest(key)).media")
    }

    private func evenlySpacedIndices(total: Int, count: Int) -> [Int] {
        guard count > 1 else { return [0] }
        return (0..<count).map { index in
            Int(round(Double(index) * Double(total - 1) / Double(count - 1)))
        }
    }

    private func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

private final class CGImageBox {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}
