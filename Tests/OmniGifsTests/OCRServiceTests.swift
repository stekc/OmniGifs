import AppKit
import Testing

@testable import OmniGifs

struct OCRServiceTests {
    @Test func recognizesHighContrastCaptionText() async throws {
        let image = try #require(makeCaptionImage())
        let result = await OCRService.shared.recognizeText(in: image).uppercased()

        #expect(result.contains("LOREM"))
        #expect(result.contains("42"))
    }

    private func makeCaptionImage() -> CGImage? {
        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 900,
                pixelsHigh: 260,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        else { return nil }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 900, height: 260).fill()
        NSString(string: "LOREM IPSUM 42").draw(
            at: NSPoint(x: 36, y: 62),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 108, weight: .bold),
                .foregroundColor: NSColor.black,
            ]
        )
        return bitmap.cgImage
    }
}
