import CoreGraphics
import Foundation
import ImageIO
import QuartzCore

private struct AnimatedWebPFrame: @unchecked Sendable {
    let image: CGImage
    let delay: TimeInterval
}

/// ImageIO decodes one display-sized frame at a time. This avoids retaining a
/// full decoded animation while preserving native animated WebP support.
private actor AnimatedWebPDecoder {
    nonisolated let frameCount: Int
    private let source: CGImageSource
    private let maximumPixelSize: Int
    private var frameIndex = 0

    init?(data: Data, maximumPixelSize: Int) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 1 else { return nil }
        self.source = source
        self.maximumPixelSize = max(maximumPixelSize, 1)
        frameCount = count
    }

    func nextFrame() -> AnimatedWebPFrame? {
        let index = frameIndex
        frameIndex = (frameIndex + 1) % frameCount
        guard
            let image = CGImageSourceCreateThumbnailAtIndex(
                source, index,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                ] as CFDictionary)
        else { return nil }
        return AnimatedWebPFrame(
            image: image,
            delay: Self.frameDelay(source: source, index: index)
        )
    }

    private static func frameDelay(source: CGImageSource, index: Int) -> TimeInterval {
        guard
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
                as? [CFString: Any]
        else { return 1.0 / 15.0 }

        if let webP = properties[kCGImagePropertyWebPDictionary] as? [CFString: Any] {
            if let delay = webP[kCGImagePropertyWebPUnclampedDelayTime] as? Double {
                return max(delay, 1.0 / 60.0)
            }
            if let delay = webP[kCGImagePropertyWebPDelayTime] as? Double {
                return max(delay, 1.0 / 60.0)
            }
        }
        if let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
            if let delay = gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double {
                return max(delay, 1.0 / 60.0)
            }
            if let delay = gif[kCGImagePropertyGIFDelayTime] as? Double {
                return max(delay, 1.0 / 60.0)
            }
        }
        return 1.0 / 15.0
    }
}

@MainActor
final class AnimatedWebPPlayer {
    private let decoder: AnimatedWebPDecoder
    private weak var layer: CALayer?
    private var playbackTask: Task<Void, Never>?
    private var playbackGeneration: UInt64 = 0

    init?(cacheKey _: String, data: Data, layer: CALayer, maximumPixelSize: Int) {
        guard
            let decoder = AnimatedWebPDecoder(
                data: data,
                maximumPixelSize: maximumPixelSize
            )
        else { return nil }
        self.decoder = decoder
        self.layer = layer
    }

    func play() {
        guard playbackTask == nil else { return }
        playbackGeneration &+= 1
        let generation = playbackGeneration
        playbackTask = Task { [weak self, decoder] in
            guard let self else { return }
            while !Task.isCancelled {
                guard let frame = await decoder.nextFrame(), !Task.isCancelled else { break }
                layer?.contents = frame.image
                do {
                    try await Task.sleep(for: .seconds(frame.delay))
                } catch {
                    break
                }
            }
            if playbackGeneration == generation {
                playbackTask = nil
            }
        }
    }

    func pause() {
        playbackGeneration &+= 1
        playbackTask?.cancel()
        playbackTask = nil
    }

    func restart() {
        pause()
        play()
    }

    func stop() {
        pause()
    }
}
