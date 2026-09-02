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

    @Test func memoryVectorSnapshotExactlyMatchesDurableSearch() throws {
        let index = try makeIndex()
        try index.upsert(
            id: "first",
            sourceURL: "https://cdn.example/first.gif",
            ocrText: "",
            modelVersion: "test",
            embeddings: [[0.25, 0.75], [0.5, 0.5]]
        )
        try index.upsert(
            id: "second",
            sourceURL: "https://cdn.example/second.gif",
            ocrText: "",
            modelVersion: "test",
            embeddings: [[0.75, 0.25], [0.5, 0.5]]
        )
        let snapshot = try #require(index.makeVectorSearchSnapshot())

        for query: [Float] in [[1, 0], [0, 1], [0.5, 0.5]] {
            #expect(
                snapshot.searchScored(vector: query)
                    == index.searchScored(vector: query)
            )
        }
    }

    @Test func acceleratedVectorSearchMatchesDurableSearchAcrossLargeCorpus() throws {
        let index = try makeIndex()
        let dimension = 32
        for item in 0..<340 {
            let vectors = (0..<2).map { frame in
                (0..<dimension).map { component in
                    Float(sin(Double((item + 1) * (component + 3) + frame)))
                }
            }
            try index.upsert(
                id: "item-\(item)",
                sourceURL: "https://cdn.example/item-\(item).gif",
                ocrText: "",
                modelVersion: "test",
                embeddings: vectors
            )
        }
        let snapshot = try #require(index.makeVectorSearchSnapshot())

        for queryIndex in 0..<12 {
            let query = (0..<dimension).map { component in
                Float(cos(Double((queryIndex + 2) * (component + 1))))
            }
            #expect(
                snapshot.searchScored(vector: query)
                    == index.searchScored(vector: query)
            )
        }
    }

    @Test func queryEmbeddingCachePersistsExactVectorsByModelVersion() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniGifsTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("Search.sqlite3")
        let vector: [Float] = [0.125, -0.25, 0.5, 0.75]

        do {
            let index = try SQLiteSearchIndex(databaseURL: url)
            try index.storeQueryEmbeddings(
                [
                    (queryDigest: "opaque-digest", vector: vector),
                    (queryDigest: "second-digest", vector: Array(vector.reversed())),
                ],
                modelVersion: "model-a"
            )
        }

        let reopened = try SQLiteSearchIndex(databaseURL: url)
        #expect(
            reopened.cachedQueryEmbedding(
                queryDigest: "opaque-digest",
                modelVersion: "model-a"
            ) == vector
        )
        #expect(
            reopened.cachedQueryEmbedding(
                queryDigest: "opaque-digest",
                modelVersion: "model-b"
            ) == nil
        )
        #expect(
            reopened.cachedQueryEmbedding(
                queryDigest: "second-digest",
                modelVersion: "model-a"
            ) == Array(vector.reversed())
        )
        try reopened.clear()
        #expect(
            reopened.cachedQueryEmbedding(
                queryDigest: "opaque-digest",
                modelVersion: "model-a"
            ) == nil
        )
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
