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
}
