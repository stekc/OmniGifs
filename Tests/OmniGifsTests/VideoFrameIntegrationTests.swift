import AVFoundation
import Foundation
import Testing

@testable import OmniGifs

struct VideoFrameIntegrationTests {
    private static let twoFrameWebP = Data(
        base64Encoded:
            "UklGRogAAABXRUJQVlA4WAoAAAACAAAAAQAAAQAAQU5JTQYAAAD/////AABBTk1GKgAAAAAAAAAAAAEAAAEAAGQAAABWUDhMEQAAAC8BQAAAB9D//ve//4GI6H8AAEFOTUYqAAAAAAAAAAAAAQAAAQAAZAAAAFZQOEwRAAAALwFAAAAH0P/+97//gYjofwAA"
    )!

    @MainActor
    private func waitForContents(
        on layer: CALayer,
        timeout: Duration = .seconds(2)
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while layer.contents == nil {
            guard clock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    @Test func tenorWebMResolvesToNativeMP4Variant() throws {
        let webm = try #require(
            URL(
                string: "https://media.tenor.com/ExampleIdentifierAAAPs/example.webm"
            ))
        #expect(
            ThumbnailPipeline.nativeMediaURL(for: webm).absoluteString
                == "https://media.tenor.com/ExampleIdentifierAAAPo/example.mp4"
        )
    }

    @Test(
        .enabled(
            if: ProcessInfo.processInfo.environment["OMNIGIFS_VIDEO_TEST_PATH"] != nil,
            "Requires OMNIGIFS_VIDEO_TEST_PATH"
        ))
    func avFoundationDecodesCachedMP4() async throws {
        let path = try #require(
            ProcessInfo.processInfo.environment["OMNIGIFS_VIDEO_TEST_PATH"]
        )
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let duration = try await asset.load(.duration)
        #expect(CMTimeGetSeconds(duration) > 0)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 720, height: 720)
        let result = try await generator.image(at: .zero)
        #expect(result.image.width > 0)
        #expect(result.image.height > 0)

        let frames = await ThumbnailPipeline.shared.decodeRepresentativeFrames(
            data: try Data(contentsOf: URL(fileURLWithPath: path)),
            videoURL: URL(fileURLWithPath: path),
            maximumCount: 3
        )
        #expect(frames.count == 3)
    }

    @Test func animatedWebPTranscodesToLoopableNativeVideo() async throws {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("omnigifs-webp-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: destination) }
        let succeeded = await WebPVideoTranscoder.shared.transcodeForTesting(
            Self.twoFrameWebP,
            to: destination
        )
        #expect(succeeded)
        let asset = AVURLAsset(url: destination)
        let duration = try await asset.load(.duration)
        #expect(CMTimeGetSeconds(duration) >= 0.19)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        #expect(tracks.count == 1)
    }

    @MainActor
    @Test func animatedWebPPlayerRendersAndRestarts() async throws {
        let layer = CALayer()
        layer.frame = CGRect(x: 0, y: 0, width: 64, height: 64)
        let player = try #require(
            AnimatedWebPPlayer(
                cacheKey: "fixture",
                data: Self.twoFrameWebP,
                layer: layer,
                maximumPixelSize: 64
            ))
        defer { player.stop() }

        player.play()
        let renderedInitialFrame = await waitForContents(on: layer)
        #expect(renderedInitialFrame)

        layer.contents = nil
        player.restart()
        let renderedFrameAfterRestart = await waitForContents(on: layer)
        #expect(renderedFrameAfterRestart)
    }
}
