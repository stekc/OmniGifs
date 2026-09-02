import Testing

@testable import OmniGifs

struct GIFSearchResultTests {
    @Test func formatsCombinedMatchProvenance() {
        #expect(
            GIFSearchResult(
                id: "one",
                matchedURL: true,
                matchedOCR: false,
                aiSimilarityPercentage: nil
            ).matchDescription == "URL")

        #expect(
            GIFSearchResult(
                id: "two",
                matchedURL: true,
                matchedOCR: true,
                aiSimilarityPercentage: nil
            ).matchDescription == "URL, OCR")

        #expect(
            GIFSearchResult(
                id: "three",
                matchedURL: false,
                matchedOCR: true,
                aiSimilarityPercentage: 90
            ).matchDescription == "OCR, AI (90%)")
    }
}
