import AppKit
import Testing

@testable import OmniGifs

@MainActor
struct GIFCollectionItemTests {
    @Test func sameFavoriteUpdatesMatchOverlayWithoutRebuildingTheCell() throws {
        let item = GIFCollectionItem()
        item.view.frame = NSRect(x: 0, y: 0, width: 240, height: 140)
        let favorite = GIFFavorite(
            id: "https://example.com/lorem",
            sourceURL: try #require(URL(string: "https://example.com/lorem")),
            mediaURL: nil,
            width: 240,
            height: 140,
            format: .unknown,
            sourceIndex: 0,
            discordOrder: nil
        )
        item.configure(
            with: favorite,
            searchResult: GIFSearchResult(
                id: favorite.id,
                matchedURL: true,
                matchedOCR: false,
                aiSimilarityPercentage: nil
            )
        )
        let originalView = item.view

        item.configure(
            with: favorite,
            searchResult: GIFSearchResult(
                id: favorite.id,
                matchedURL: false,
                matchedOCR: true,
                aiSimilarityPercentage: 31
            )
        )

        #expect(item.view === originalView)
        #expect(
            textFields(in: item.view).contains { field in
                field.stringValue == "OCR, AI (31%)" && field.shadow != nil
            })
        #expect(!containsGradientLayer(in: item.view))
        item.tearDownPlayback()
        item.prepareForReuse()
    }

    private func textFields(in view: NSView) -> [NSTextField] {
        view.subviews.flatMap { subview in
            let current = (subview as? NSTextField).map { [$0] } ?? []
            return current + textFields(in: subview)
        }
    }

    private func containsGradientLayer(in view: NSView) -> Bool {
        if view.layer is CAGradientLayer { return true }
        return view.subviews.contains { containsGradientLayer(in: $0) }
    }
}
