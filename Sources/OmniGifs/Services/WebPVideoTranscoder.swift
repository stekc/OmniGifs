import AVFoundation
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

extension Notification.Name {
    static let omniGifsWebPVideoReady = Notification.Name("OmniGifsWebPVideoReady")
}

actor WebPVideoTranscoder {
    static let shared = WebPVideoTranscoder()

    private struct Request: Sendable {
        let data: Data
        let cacheKey: String
        let destination: URL
    }

    private let directory: URL
    private var pending: [Request] = []
    private var pendingKeys: Set<String> = []
    private var failedKeys: Set<String> = []
    private var worker: Task<Void, Never>?
    private var generation = 0
    private var isActive = false

    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        directory =
            base
            .appendingPathComponent("OmniGifs", isDirectory: true)
            .appendingPathComponent("WebPVideo", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func cachedVideoURL(for cacheKey: String, data: Data) -> URL? {
        let url = videoURL(for: cacheKey, data: data)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func schedule(data: Data, cacheKey: String) {
        let destination = videoURL(for: cacheKey, data: data)
        guard isActive,
            !FileManager.default.fileExists(atPath: destination.path),
            !pendingKeys.contains(destination.lastPathComponent),
            !failedKeys.contains(destination.lastPathComponent),
            pending.count < 16
        else { return }
        pending.append(Request(data: data, cacheKey: cacheKey, destination: destination))
        pendingKeys.insert(destination.lastPathComponent)
        startWorkerIfNeeded()
    }

    func activate() {
        isActive = true
    }

    func cancelAll() {
        isActive = false
        generation += 1
        worker?.cancel()
        worker = nil
        pending.removeAll(keepingCapacity: false)
        pendingKeys.removeAll(keepingCapacity: false)
    }

    func clearCache() throws {
        cancelAll()
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        failedKeys.removeAll(keepingCapacity: false)
    }

    func removeCachedVideos(for favoriteIDs: Set<String>) throws {
        guard !favoriteIDs.isEmpty,
            let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )
        else { return }
        let prefixes = Set(favoriteIDs.map { keyHash($0) + "-" })
        for file in files where prefixes.contains(where: file.lastPathComponent.hasPrefix) {
            try FileManager.default.removeItem(at: file)
        }
    }

    func transcodeForTesting(_ data: Data, to destination: URL) async -> Bool {
        await Self.transcode(data, to: destination)
    }

    private func startWorkerIfNeeded() {
        guard worker == nil else { return }
        let workerGeneration = generation
        worker = Task(priority: .utility) { [weak self] in
            await self?.drainQueue(generation: workerGeneration)
        }
    }

    private func drainQueue(generation workerGeneration: Int) async {
        while !Task.isCancelled,
            workerGeneration == generation,
            let request = nextRequest()
        {
            let succeeded = await Self.transcode(request.data, to: request.destination)
            guard !Task.isCancelled, workerGeneration == generation else { break }
            pendingKeys.remove(request.destination.lastPathComponent)
            if succeeded {
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .omniGifsWebPVideoReady,
                        object: request.cacheKey,
                        userInfo: ["url": request.destination]
                    )
                }
            } else {
                failedKeys.insert(request.destination.lastPathComponent)
            }
        }
        if workerGeneration == generation { worker = nil }
    }

    private func nextRequest() -> Request? {
        guard !pending.isEmpty else { return nil }
        return pending.removeFirst()
    }

    private func videoURL(for cacheKey: String, data: Data) -> URL {
        let contentHash = SHA256.hash(data: data).prefix(8)
            .map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(keyHash(cacheKey))-\(contentHash)-v3.mov")
    }

    private func keyHash(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func transcode(_ data: Data, to destination: URL) async -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
            let sourceWidth = properties[kCGImagePropertyPixelWidth] as? Int,
            let sourceHeight = properties[kCGImagePropertyPixelHeight] as? Int
        else { return false }
        let frameCount = CGImageSourceGetCount(source)
        guard sourceWidth > 0, sourceHeight > 0, frameCount > 1 else { return false }

        let scale = min(1, 720.0 / Double(max(sourceWidth, sourceHeight)))
        let width = max(Int((Double(sourceWidth) * scale).rounded()).roundedUpToEven, 2)
        let height = max(Int((Double(sourceHeight) * scale).rounded()).roundedUpToEven, 2)
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).mov")
        var completed = false
        defer {
            if !completed { try? FileManager.default.removeItem(at: temporary) }
        }

        do {
            let writer = try AVAssetWriter(outputURL: temporary, fileType: .mov)
            let input = AVAssetWriterInput(
                mediaType: .video,
                outputSettings: [
                    AVVideoCodecKey: AVVideoCodecType.hevcWithAlpha,
                    AVVideoWidthKey: width,
                    AVVideoHeightKey: height,
                    AVVideoCompressionPropertiesKey: [
                        AVVideoAllowFrameReorderingKey: false,
                        AVVideoQualityKey: 0.82,
                    ],
                ]
            )
            input.expectsMediaDataInRealTime = false
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: width,
                    kCVPixelBufferHeightKey as String: height,
                    kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                ]
            )
            guard writer.canAdd(input) else { return false }
            writer.add(input)
            guard writer.startWriting() else { return false }
            writer.startSession(atSourceTime: .zero)

            var presentationMilliseconds: Int64 = 0
            for frameIndex in 0..<frameCount {
                guard !Task.isCancelled else {
                    writer.cancelWriting()
                    return false
                }
                while !input.isReadyForMoreMediaData {
                    if writer.status == .failed || Task.isCancelled {
                        writer.cancelWriting()
                        return false
                    }
                    try await Task.sleep(for: .milliseconds(1))
                }
                guard let image = CGImageSourceCreateImageAtIndex(source, frameIndex, nil),
                    let pool = adaptor.pixelBufferPool
                else { return false }
                var optionalBuffer: CVPixelBuffer?
                guard
                    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &optionalBuffer)
                        == kCVReturnSuccess,
                    let pixelBuffer = optionalBuffer
                else { return false }
                CVPixelBufferLockBaseAddress(pixelBuffer, [])
                let rendered = render(
                    image: image,
                    into: pixelBuffer,
                    width: width,
                    height: height
                )
                CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
                guard rendered else { return false }
                let presentationTime = CMTime(value: presentationMilliseconds, timescale: 1_000)
                guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
                    return false
                }
                let delay = max(
                    Int64((frameDelay(source: source, index: frameIndex) * 1_000).rounded()),
                    17
                )
                presentationMilliseconds += delay
            }
            input.markAsFinished()
            writer.endSession(
                atSourceTime: CMTime(value: presentationMilliseconds, timescale: 1_000)
            )
            await writer.finishWriting()
            guard writer.status == .completed else { return false }
            if FileManager.default.fileExists(atPath: destination.path) {
                try? FileManager.default.removeItem(at: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
            completed = true
            return true
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            return false
        }
    }

    private nonisolated static func render(
        image: CGImage,
        into pixelBuffer: CVPixelBuffer,
        width: Int,
        height: Int
    ) -> Bool {
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer),
            let context = CGContext(
                data: baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
            )
        else { return false }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }

    private nonisolated static func frameDelay(
        source: CGImageSource,
        index: Int
    ) -> TimeInterval {
        guard
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
                as? [CFString: Any],
            let webP = properties[kCGImagePropertyWebPDictionary] as? [CFString: Any]
        else { return 1.0 / 15.0 }
        if let delay = webP[kCGImagePropertyWebPUnclampedDelayTime] as? Double {
            return max(delay, 1.0 / 60.0)
        }
        if let delay = webP[kCGImagePropertyWebPDelayTime] as? Double {
            return max(delay, 1.0 / 60.0)
        }
        return 1.0 / 15.0
    }
}

extension Int {
    fileprivate var roundedUpToEven: Int { isMultiple(of: 2) ? self : self + 1 }
}
