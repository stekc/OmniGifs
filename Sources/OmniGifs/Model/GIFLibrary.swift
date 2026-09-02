import Foundation

@MainActor
final class GIFLibrary {
    static let shared = GIFLibrary()

    private(set) var favorites: [GIFFavorite] = []
    private(set) var filteredFavorites: [GIFFavorite] = []
    private(set) var query = ""
    private var hiddenIDs: Set<String> = []
    private var rankedIDs: [String]?
    private var searchResults: [String: GIFSearchResult] = [:]

    var onChange: (() -> Void)?

    private let cacheURL: URL

    init(cacheURL: URL? = nil) {
        if let cacheURL {
            self.cacheURL = cacheURL
        } else {
            let base = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            let directory = base.appendingPathComponent("OmniGifs", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            self.cacheURL = directory.appendingPathComponent("discord-favorites.json")
        }
        loadCachedFavorites()
    }

    @discardableResult
    func replace(with data: Data, persist: Bool = true) throws -> Bool {
        let decoded = try GIFImporter.decodeSnapshot(data)
        guard decoded != favorites else { return false }
        if persist {
            try data.write(to: cacheURL, options: .atomic)
        }
        favorites = decoded
        applyFilter()
        onChange?()
        return true
    }

    func clearLocalData() throws {
        if FileManager.default.fileExists(atPath: cacheURL.path) {
            try FileManager.default.removeItem(at: cacheURL)
        }
        favorites = []
        filteredFavorites = []
        query = ""
        hiddenIDs = []
        rankedIDs = nil
        searchResults = [:]
        onChange?()
    }

    func setQuery(_ query: String, preservingVisibleResults: Bool = false) {
        let candidate = SearchQueryPolicy.normalized(query)
        let normalized = SearchQueryPolicy.isSearchable(candidate) ? candidate : ""
        guard normalized != self.query else { return }
        rankedIDs = nil
        if !preservingVisibleResults { searchResults.removeAll() }
        self.query = normalized
        if preservingVisibleResults && !normalized.isEmpty {
            return
        }
        applyFilter()
        onChange?()
    }

    func setHiddenIDs(_ ids: Set<String>) {
        guard hiddenIDs != ids else { return }
        hiddenIDs = ids
        applyFilter()
        onChange?()
    }

    func applyRankedIDs(_ rankedIDs: [String]) {
        guard self.rankedIDs != rankedIDs else { return }
        self.rankedIDs = rankedIDs
        searchResults.removeAll()
        applyFilter()
        onChange?()
    }

    func applySearchResults(_ results: [GIFSearchResult]) {
        let rankedIDs = results.map(\.id)
        let byID = Dictionary(uniqueKeysWithValues: results.map { ($0.id, $0) })
        guard self.rankedIDs != rankedIDs || searchResults != byID else { return }
        self.rankedIDs = rankedIDs
        searchResults = byID
        applyFilter()
        onChange?()
    }

    func searchResult(for id: String) -> GIFSearchResult? {
        query.isEmpty ? nil : searchResults[id]
    }

    private func applyFilter() {
        guard !query.isEmpty else {
            filteredFavorites = favorites.filter { !hiddenIDs.contains($0.id) }
            return
        }
        if let rankedIDs {
            let byID = Dictionary(
                uniqueKeysWithValues:
                    favorites
                    .filter { !hiddenIDs.contains($0.id) }
                    .map { ($0.id, $0) })
            filteredFavorites = rankedIDs.compactMap { byID[$0] }
            return
        }
        let needle = query.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        filteredFavorites = favorites.filter {
            !hiddenIDs.contains($0.id)
                && $0.sourceURL.absoluteString.folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: .current
                ).contains(needle)
        }
    }

    private func loadCachedFavorites() {
        guard let data = try? Data(contentsOf: cacheURL),
            let decoded = try? GIFImporter.decodeSnapshot(data)
        else { return }
        favorites = decoded
        filteredFavorites = decoded
    }
}
