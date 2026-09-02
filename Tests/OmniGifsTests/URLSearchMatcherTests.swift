import Foundation
import Testing

@testable import OmniGifs

struct URLSearchMatcherTests {
    @Test func treatsURLSeparatorsAsSpaces() throws {
        let hyphenated = try #require(
            URL(string: "https://tenor.com/view/lorem-ipsum-example-123")
        )
        let underscored = try #require(
            URL(string: "https://example.com/lorem_ipsum.gif")
        )
        let encoded = try #require(
            URL(string: "https://example.com/lorem%20ipsum.gif")
        )

        #expect(URLSearchMatcher.matches("lorem ipsum", sourceURL: hyphenated))
        #expect(URLSearchMatcher.matches("Lorem Ipsum", sourceURL: underscored))
        #expect(URLSearchMatcher.matches("lorem ipsum", sourceURL: encoded))
    }

    @Test func preservesPhraseOrderAndDoesNotIntroduceTypoMatches() throws {
        let url = try #require(
            URL(string: "https://tenor.com/view/lorem-ipsum-example-123")
        )

        #expect(!URLSearchMatcher.matches("ipsum lorem", sourceURL: url))
        #expect(!URLSearchMatcher.matches("lorem ipmus", sourceURL: url))
    }

    @Test func indexedSearchExactlyMatchesOrderedFullScan() throws {
        let urls = [
            "https://tenor.com/view/lorem-ipsum-example-123",
            "https://example.com/dolor_sit_amet.gif",
            "https://example.com/lorem%20dolor.gif",
            "https://example.com/consectetur-adipiscing.gif",
        ]
        let favorites = try urls.enumerated().map { offset, value in
            GIFFavorite(
                id: String(offset),
                sourceURL: try #require(URL(string: value)),
                mediaURL: nil,
                width: 1,
                height: 1,
                format: .image,
                sourceIndex: offset,
                discordOrder: nil
            )
        }
        let snapshot = URLSearchSnapshot(favorites: favorites)

        for query in ["lo", "lorem", "lorem ipsum", "dolor", "adip", "not present"] {
            let fullScan = favorites.filter {
                URLSearchMatcher.matches(query, sourceURL: $0.sourceURL)
            }.map(\.id)
            #expect(snapshot.matchingIDs(query) == fullScan)
        }
    }
}
