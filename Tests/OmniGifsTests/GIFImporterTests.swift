import XCTest

@testable import OmniGifs

final class GIFImporterTests: XCTestCase {
    func testArrayBottomEntryBecomesFirst() throws {
        let data = Data(
            #"""
            [
              {"url":"https://example.com/lorem","src":"https://cdn.example.com/lorem.mp4","width":400,"height":200,"order":1},
              {"url":"https://example.com/ipsum","src":"https://cdn.example.com/ipsum.mp4","width":200,"height":400,"order":999}
            ]
            """#.utf8)

        let result = try GIFImporter.decode(data)

        XCTAssertEqual(
            result.map(\.sourceURL.absoluteString),
            [
                "https://example.com/ipsum", "https://example.com/lorem",
            ])
        XCTAssertEqual(result.first?.aspectRatio, 0.5)
    }

    func testDiscordOrderOverridesObjectIteration() throws {
        let data = Data(
            #"""
            {
              "https://example.com/lorem": {"src":"//cdn.example.com/lorem.mp4","order":42},
              "https://example.com/ipsum": {"src":"https://cdn.example.com/ipsum.mp4","order":2}
            }
            """#.utf8)

        let result = try GIFImporter.decode(data)

        XCTAssertEqual(result.first?.sourceURL.absoluteString, "https://example.com/lorem")
        XCTAssertEqual(result.first?.mediaURL?.absoluteString, "https://cdn.example.com/lorem.mp4")
    }

    func testDataPackageNesting() throws {
        let data = Data(
            #"""
            {
              "settings": {"favoriteGifs": {"gifs": {
                "https://example.com/dolor": {"src":"https://cdn.example.com/dolor.gif","order":1}
              }}}
            }
            """#.utf8)

        XCTAssertEqual(try GIFImporter.decode(data).count, 1)
    }
}
