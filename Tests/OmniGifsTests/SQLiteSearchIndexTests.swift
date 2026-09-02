import Foundation
import Testing

@testable import OmniGifs

struct SQLiteSearchIndexTests {
    @Test func ocrPrefixSearchUsesIndexedText() throws {
        let index = try makeIndex()
        try index.upsert(
            id: "one",
            sourceURL: "https://cdn.example/first.gif",
            ocrText: "Lorem ipsum dolor",
            modelVersion: nil
        )
        try index.upsert(
            id: "two",
            sourceURL: "https://cdn.example/second.gif",
            ocrText: "Consectetur adipiscing elit",
            modelVersion: nil
        )

        #expect(index.search("ipsum") == ["one"])
        #expect(index.search("ips") == ["one"])
        #expect(index.search("adipiscing elit") == ["two"])
        #expect(index.search("first") == [])
    }

    @Test func vectorSearchRanksBestFramePerGIF() throws {
        let index = try makeIndex()
        try index.upsert(
            id: "near",
            sourceURL: "https://cdn.example/near.gif",
            ocrText: "",
            modelVersion: "test",
            embeddings: [[0, 1], [0.95, 0.05]]
        )
        try index.upsert(
            id: "far",
            sourceURL: "https://cdn.example/far.gif",
            ocrText: "",
            modelVersion: "test",
            embeddings: [[0.2, 0.8]]
        )

        #expect(index.search(vector: [1, 0]) == ["near", "far"])
        #expect(index.needsIndex("near", modelVersion: "test") == false)
        #expect(index.needsIndex("near", modelVersion: "new-version"))
    }

    @Test func commaSeparatedOCRTermsAreStrictAND() throws {
        let index = try makeIndex()
        try index.upsert(
            id: "exact",
            sourceURL: "https://cdn.example/exact.gif",
            ocrText: "lorem ipsum dolor",
            modelVersion: nil
        )
        try index.upsert(
            id: "partial",
            sourceURL: "https://cdn.example/partial.gif",
            ocrText: "lorem dolor sit",
            modelVersion: nil
        )

        #expect(index.search("lorem, ipsum") == ["exact"])
    }

    @Test func failedMediaDoesNotRetryOnEveryPopoverOpen() throws {
        let index = try makeIndex()
        let start = Date(timeIntervalSince1970: 1_000_000)
        let favorite = makeFavorite(
            source: "https://tenor.com/view/example",
            media: "https://media.tenor.com/example.mp4"
        )

        try index.recordFailure(
            favorite: favorite,
            modelVersion: "model-v1",
            now: start
        )

        #expect(index.unavailableCount() == 1)
        #expect(index.unavailableIDs() == [favorite.id])
        #expect(!index.needsIndex(favorite, modelVersion: "model-v1", now: start))
        #expect(
            !index.needsIndex(
                favorite,
                modelVersion: "model-v1",
                now: start.addingTimeInterval(6 * 60 * 60 - 1)
            ))
        #expect(
            index.needsIndex(
                favorite,
                modelVersion: "model-v1",
                now: start.addingTimeInterval(6 * 60 * 60)
            ))
    }

    @Test func changedMediaOrModelRetriesImmediately() throws {
        let index = try makeIndex()
        let start = Date(timeIntervalSince1970: 1_000_000)
        let favorite = makeFavorite(
            source: "https://tenor.com/view/example",
            media: "https://media.tenor.com/old.mp4"
        )
        try index.recordFailure(
            favorite: favorite,
            modelVersion: "model-v1",
            now: start
        )

        let changedMedia = makeFavorite(
            source: favorite.sourceURL.absoluteString,
            media: "https://media.tenor.com/new.mp4"
        )
        #expect(index.needsIndex(changedMedia, modelVersion: "model-v1", now: start))
        #expect(index.needsIndex(favorite, modelVersion: "model-v2", now: start))
    }

    @Test func pruningRemovesStaleTextAndVectors() throws {
        let index = try makeIndex()
        try index.upsert(
            id: "keep",
            sourceURL: "https://example.com/keep",
            ocrText: "lorem ipsum",
            modelVersion: "test",
            embeddings: [[1, 0]]
        )
        try index.upsert(
            id: "remove",
            sourceURL: "https://example.com/remove",
            ocrText: "dolor ipsum",
            modelVersion: "test",
            embeddings: [[0, 1]]
        )

        try index.prune(keeping: ["keep"])

        #expect(index.search("dolor").isEmpty)
        #expect(index.search(vector: [0, 1]) == ["keep"])
        #expect(index.contains("keep"))
        #expect(!index.contains("remove"))
    }

    private func makeIndex() throws -> SQLiteSearchIndex {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniGifsTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("Search.sqlite3")
        return try SQLiteSearchIndex(databaseURL: url)
    }

    private func makeFavorite(source: String, media: String) -> GIFFavorite {
        GIFFavorite(
            id: source,
            sourceURL: URL(string: source)!,
            mediaURL: URL(string: media),
            width: 480,
            height: 270,
            format: .video,
            sourceIndex: 0,
            discordOrder: nil
        )
    }
}
