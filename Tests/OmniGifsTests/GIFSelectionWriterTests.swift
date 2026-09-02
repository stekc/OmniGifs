import AppKit
import Foundation
import Testing

@testable import OmniGifs

struct GIFSelectionWriterTests {
    @Test func copiesCanonicalSourceURL() throws {
        let sourceURL = try #require(URL(string: "https://tenor.com/view/example-123"))
        let favorite = GIFFavorite(
            id: sourceURL.absoluteString,
            sourceURL: sourceURL,
            mediaURL: nil,
            width: 480,
            height: 270,
            format: .image,
            sourceIndex: 0,
            discordOrder: nil
        )
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("OmniGifsTests.\(UUID().uuidString)")
        )

        #expect(GIFSelectionWriter.copySourceURL(of: favorite, to: pasteboard))
        #expect(pasteboard.string(forType: .string) == sourceURL.absoluteString)
    }
}
