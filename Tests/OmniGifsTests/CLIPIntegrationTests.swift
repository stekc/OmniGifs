import CoreGraphics
import Foundation
import Testing

@testable import OmniGifs

struct CLIPIntegrationTests {
    @Test(
        .enabled(
            if: ProcessInfo.processInfo.environment["OMNIGIFS_MODEL_TEST_DIR"] != nil,
            "Requires OMNIGIFS_MODEL_TEST_DIR"
        ))
    func openAIClipPackagesMatchRuntimeContract() async throws {
        let directory = try #require(
            ProcessInfo.processInfo.environment["OMNIGIFS_MODEL_TEST_DIR"]
        )

        let service = try CLIPEmbeddingService(
            modelDirectory: URL(fileURLWithPath: directory, isDirectory: true)
        )
        let image = try #require(makeTestImage())
        let imageEmbedding = try await service.embed(image: image)
        // The test process is not the OmniGifs executable, so exercise the text
        // tower in-process; the packaged app helper is validated separately.
        let textEmbedding = try await service.embedTextInProcess("lorem ipsum")

        #expect(imageEmbedding.count == 512)
        #expect(textEmbedding.count == 512)
        #expect(abs(magnitude(imageEmbedding) - 1) < 0.001)
        #expect(abs(magnitude(textEmbedding) - 1) < 0.001)
        #expect(imageEmbedding.allSatisfy { $0.isFinite })
        #expect(textEmbedding.allSatisfy { $0.isFinite })
    }

    private func makeTestImage() -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard
            let context = CGContext(
                data: nil,
                width: 224,
                height: 224,
                bitsPerComponent: 8,
                bytesPerRow: 224 * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }
        context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 224, height: 224))
        return context.makeImage()
    }

    private func magnitude(_ vector: [Float]) -> Float {
        sqrt(vector.reduce(0) { $0 + $1 * $1 })
    }
}
