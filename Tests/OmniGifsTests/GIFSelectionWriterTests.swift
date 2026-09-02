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

    @Test func restoresClipboardOnlyWhenTemporaryURLIsStillCurrent() throws {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("OmniGifsTests.\(UUID().uuidString)")
        )
        pasteboard.clearContents()
        pasteboard.setString("Lorem ipsum", forType: .string)

        let transaction = try #require(
            GIFSelectionWriter.prepareTemporaryURL(
                "https://example.com/temporary",
                on: pasteboard
            )
        )
        #expect(pasteboard.string(forType: .string) == "https://example.com/temporary")
        #expect(GIFSelectionWriter.restorePasteboardIfUnchanged(transaction, on: pasteboard))
        #expect(pasteboard.string(forType: .string) == "Lorem ipsum")
    }

    @Test func doesNotOverwriteAClipboardChangeMadeAfterTemporaryURL() throws {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("OmniGifsTests.\(UUID().uuidString)")
        )
        pasteboard.clearContents()
        pasteboard.setString("Lorem ipsum", forType: .string)

        let transaction = try #require(
            GIFSelectionWriter.prepareTemporaryURL(
                "https://example.com/temporary",
                on: pasteboard
            )
        )
        pasteboard.clearContents()
        pasteboard.setString("Dolor sit amet", forType: .string)

        #expect(!GIFSelectionWriter.restorePasteboardIfUnchanged(transaction, on: pasteboard))
        #expect(pasteboard.string(forType: .string) == "Dolor sit amet")
    }
}
