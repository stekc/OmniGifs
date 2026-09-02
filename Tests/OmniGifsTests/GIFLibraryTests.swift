import Foundation
import Testing

@testable import OmniGifs

@MainActor
struct GIFLibraryTests {
    @Test func metadataFiltersComposeWithSearchAndTagsAreSearchable() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniGifsLibraryTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = GIFLibrary(
            cacheURL: directory.appendingPathComponent("Favorites.json"),
            metadataDatabaseURL: directory.appendingPathComponent("Search.sqlite3")
        )
        let data = Data(
            #"[{"url":"https://example.com/one"},{"url":"https://example.com/two"}]"#.utf8
        )
        try library.replace(with: data, persist: false)
        let folder = try library.createFolder(named: "Lorem")
        let tag = try library.createTag(named: "Ipsum")
        try library.assign("https://example.com/one", toFolder: folder.id)
        try library.toggleTag(tag.id, for: "https://example.com/one")

        #expect(library.tagSearchSnapshot.matchingIDs("ipsum") == ["https://example.com/one"])
        #expect(library.tagSearchSnapshot.matchingIDs("lorem").isEmpty)

        try library.selectFolderFilter(folder.id)
        #expect(library.filteredFavorites.map(\.id) == ["https://example.com/one"])
        library.setQuery("example")
        library.applyRankedIDs(["https://example.com/two", "https://example.com/one"])
        #expect(library.filteredFavorites.map(\.id) == ["https://example.com/one"])
    }

    @Test func oneCharacterQueryDoesNotSearchOrShowMatchMetadata() throws {
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniGifsTests-\(UUID().uuidString).json")
        let library = GIFLibrary(cacheURL: cacheURL)
        let data = Data(
            #"""
            [{"url":"https://tenor.com/n","src":"https://media.tenor.com/n.gif","format":1}]
            """#.utf8)
        try library.replace(with: data, persist: false)

        library.setQuery("n")
        library.applySearchResults([
            GIFSearchResult(
                id: "https://tenor.com/n",
                matchedURL: true,
                matchedOCR: true,
                aiSimilarityPercentage: 90
            )
        ])

        #expect(library.query.isEmpty)
        #expect(library.filteredFavorites.count == 1)
        #expect(library.searchResult(for: "https://tenor.com/n") == nil)
        #expect(SearchQueryPolicy.isSearchable("no"))
    }

    @Test func unavailableFavoritesStayOutOfGridAndSearchResults() throws {
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniGifsTests-\(UUID().uuidString).json")
        let library = GIFLibrary(cacheURL: cacheURL)
        let data = Data(
            #"""
            [
              {"url":"https://tenor.com/one","src":"https://media.tenor.com/one.gif","format":1},
              {"url":"https://tenor.com/two","src":"https://media.tenor.com/two.gif","format":1}
            ]
            """#.utf8)
        try library.replace(with: data, persist: false)

        library.setHiddenIDs(["https://tenor.com/two"])
        #expect(library.filteredFavorites.map(\.id) == ["https://tenor.com/one"])

        library.setQuery("two")
        #expect(library.filteredFavorites.isEmpty)
        library.applyRankedIDs(["https://tenor.com/two", "https://tenor.com/one"])
        #expect(library.filteredFavorites.map(\.id) == ["https://tenor.com/one"])
    }

    @Test func semanticRankingSurvivesFavoritesRefreshForRetainedQuery() throws {
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniGifsTests-\(UUID().uuidString).json")
        let library = GIFLibrary(cacheURL: cacheURL)
        let data = Data(
            #"""
            [
              {"url":"https://tenor.com/one","src":"https://media.tenor.com/one.gif","format":1},
              {"url":"https://tenor.com/two","src":"https://media.tenor.com/two.gif","format":1}
            ]
            """#.utf8)
        try library.replace(with: data, persist: false)

        library.setQuery("lorem ipsum dolor")
        library.applyRankedIDs(["https://tenor.com/two"])
        #expect(library.filteredFavorites.map(\.id) == ["https://tenor.com/two"])

        try library.replace(with: data, persist: false)
        #expect(library.query == "lorem ipsum dolor")
        #expect(library.filteredFavorites.map(\.id) == ["https://tenor.com/two"])
    }

    @Test func changingQueryCanKeepCurrentGridUntilNewRankingArrives() throws {
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniGifsTests-\(UUID().uuidString).json")
        let library = GIFLibrary(cacheURL: cacheURL)
        let data = Data(
            #"""
            [
              {"url":"https://tenor.com/one","src":"https://media.tenor.com/one.gif","format":1},
              {"url":"https://tenor.com/two","src":"https://media.tenor.com/two.gif","format":1}
            ]
            """#.utf8)
        try library.replace(with: data, persist: false)
        library.setQuery("lorem")
        library.applyRankedIDs(["https://tenor.com/one"])

        library.setQuery("lorem ipsum dolor", preservingVisibleResults: true)
        #expect(library.filteredFavorites.map(\.id) == ["https://tenor.com/one"])

        library.applyRankedIDs(["https://tenor.com/two"])
        #expect(library.filteredFavorites.map(\.id) == ["https://tenor.com/two"])
    }

    @Test func identicalRefreshDoesNotNotifyObservers() throws {
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniGifsTests-\(UUID().uuidString).json")
        let library = GIFLibrary(cacheURL: cacheURL)
        let data = Data(
            #"""
            [{"url":"https://tenor.com/one","src":"https://media.tenor.com/one.gif","format":1}]
            """#.utf8)
        var notifications = 0
        library.onChange = { notifications += 1 }

        #expect(try library.replace(with: data, persist: false))
        #expect(notifications == 1)
        #expect(try !library.replace(with: data, persist: false))
        #expect(notifications == 1)
    }

    @Test func refreshAddsNewestFavoriteAndRemovesMissingFavorite() throws {
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniGifsTests-\(UUID().uuidString).json")
        let library = GIFLibrary(cacheURL: cacheURL)
        let initial = Data(
            #"""
            {
              "https://example.com/lorem": {"order": 10},
              "https://example.com/ipsum": {"order": 20}
            }
            """#.utf8)
        let refreshed = Data(
            #"""
            {
              "https://example.com/ipsum": {"order": 20},
              "https://example.com/dolor": {"order": 30}
            }
            """#.utf8)

        try library.replace(with: initial, persist: false)
        try library.replace(with: refreshed, persist: false)

        #expect(library.favorites.count == 2)
        #expect(
            library.favorites.map(\.id) == [
                "https://example.com/dolor", "https://example.com/ipsum",
            ])
        #expect(!library.favorites.contains { $0.id == "https://example.com/lorem" })
    }

    @Test func emptyDiscordSnapshotClearsFavorites() throws {
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniGifsTests-\(UUID().uuidString).json")
        let library = GIFLibrary(cacheURL: cacheURL)
        try library.replace(
            with: Data(#"{"https://example.com/lorem":{"order":1}}"#.utf8),
            persist: false
        )

        try library.replace(with: Data("{}".utf8), persist: false)

        #expect(library.favorites.isEmpty)
        #expect(library.filteredFavorites.isEmpty)
    }

    @Test func logoutCleanupRemovesPersistedAndInMemoryFavorites() throws {
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniGifsTests-\(UUID().uuidString).json")
        let library = GIFLibrary(cacheURL: cacheURL)
        let data = Data(#"[{"url":"https://example.com/one"}]"#.utf8)
        try library.replace(with: data)
        #expect(FileManager.default.fileExists(atPath: cacheURL.path))

        try library.clearLocalData()

        #expect(library.favorites.isEmpty)
        #expect(library.filteredFavorites.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: cacheURL.path))
    }
}
