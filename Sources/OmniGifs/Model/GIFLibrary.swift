import Foundation

@MainActor
final class GIFLibrary {
    static let shared = GIFLibrary()

    private(set) var favorites: [GIFFavorite] = []
    private(set) var filteredFavorites: [GIFFavorite] = []
    private(set) var query = ""
    private(set) var tagSearchSnapshot = GIFTagSearchSnapshot.empty
    private var hiddenIDs: Set<String> = []
    private var availableFavorites: [GIFFavorite] = []
    private var availableFavoritesByID: [String: GIFFavorite] = [:]
    private var rankedIDs: [String]?
    private var searchResults: [String: GIFSearchResult] = [:]

    var onChange: (() -> Void)?

    private let cacheURL: URL
    private let metadataStore: GIFMetadataStore

    init(cacheURL: URL? = nil, metadataDatabaseURL: URL? = nil) {
        let resolvedMetadataURL: URL
        if let cacheURL {
            self.cacheURL = cacheURL
            resolvedMetadataURL =
                metadataDatabaseURL ?? cacheURL.appendingPathExtension("metadata.sqlite3")
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
            resolvedMetadataURL =
                metadataDatabaseURL ?? directory.appendingPathComponent("Search.sqlite3")
        }
        metadataStore = GIFMetadataStore(databaseURL: resolvedMetadataURL)
        loadCachedFavorites()
    }

    var folders: [GIFFolder] { metadataStore.folders }
    var tags: [GIFTag] { metadataStore.tags }
    var selectedFolderID: UUID? { metadataStore.selectedFolderID }
    var selectedTagIDs: Set<UUID> { metadataStore.selectedTagIDs }
    var hasActiveMetadataFilter: Bool { metadataStore.hasActiveFilter }

    func folderID(for favoriteID: String) -> UUID? {
        metadataStore.folderID(for: favoriteID)
    }

    func tagIDs(for favoriteID: String) -> Set<UUID> {
        metadataStore.tagIDs(for: favoriteID)
    }

    @discardableResult
    func createFolder(named name: String) throws -> GIFFolder {
        try metadataStore.createFolder(named: name)
    }

    @discardableResult
    func createTag(named name: String) throws -> GIFTag {
        try metadataStore.createTag(named: name)
    }

    func assign(_ favoriteID: String, toFolder folderID: UUID?) throws {
        guard try metadataStore.assign(favoriteID, toFolder: folderID) else { return }
        applyFilter()
        onChange?()
    }

    func assign(_ favoriteIDs: [String], toFolder folderID: UUID?) throws {
        guard try metadataStore.assign(Set(favoriteIDs), toFolder: folderID) else { return }
        applyFilter()
        onChange?()
    }

    func toggleTag(_ tagID: UUID, for favoriteID: String) throws {
        guard try metadataStore.toggleTag(tagID, for: favoriteID) else { return }
        rebuildTagSearchSnapshot()
        applyFilter()
        onChange?()
    }

    func setTag(_ tagID: UUID, for favoriteIDs: [String], assigned: Bool) throws {
        guard try metadataStore.setTag(tagID, for: Set(favoriteIDs), assigned: assigned) else {
            return
        }
        rebuildTagSearchSnapshot()
        applyFilter()
        onChange?()
    }

    func selectFolderFilter(_ folderID: UUID?) throws {
        guard try metadataStore.selectFolder(folderID) else { return }
        applyFilter()
        onChange?()
    }

    func toggleTagFilter(_ tagID: UUID) throws {
        guard try metadataStore.toggleSelectedTag(tagID) else { return }
        applyFilter()
        onChange?()
    }

    func clearTagFilters() throws {
        guard try metadataStore.clearSelectedTags() else { return }
        applyFilter()
        onChange?()
    }

    func deleteFolder(_ folderID: UUID) throws {
        guard try metadataStore.deleteFolder(folderID) else { return }
        applyFilter()
        onChange?()
    }

    func deleteTag(_ tagID: UUID) throws {
        guard try metadataStore.deleteTag(tagID) else { return }
        rebuildTagSearchSnapshot()
        applyFilter()
        onChange?()
    }

    @discardableResult
    func replace(with data: Data, persist: Bool = true) throws -> Bool {
        let decoded = try GIFImporter.decodeSnapshot(data)
        guard decoded != favorites else { return false }
        if persist {
            try data.write(to: cacheURL, options: .atomic)
        }
        favorites = decoded
        rebuildAvailableFavorites()
        rebuildTagSearchSnapshot()
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
        availableFavorites = []
        availableFavoritesByID = [:]
        rankedIDs = nil
        searchResults = [:]
        try metadataStore.clear()
        tagSearchSnapshot = .empty
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
        rebuildAvailableFavorites()
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

    /// Dictionaries are copy-on-write, so the picker can compare the current
    /// metadata snapshot without rebuilding it from every visible favorite.
    var activeSearchResults: [String: GIFSearchResult] {
        query.isEmpty ? [:] : searchResults
    }

    private func applyFilter() {
        guard !query.isEmpty else {
            filteredFavorites =
                metadataStore.hasActiveFilter
                ? availableFavorites.filter {
                    metadataStore.matchesActiveFilters($0.id)
                }
                : availableFavorites
            return
        }
        if let rankedIDs {
            filteredFavorites =
                metadataStore.hasActiveFilter
                ? rankedIDs.compactMap { id in
                    guard metadataStore.matchesActiveFilters(id) else { return nil }
                    return availableFavoritesByID[id]
                }
                : rankedIDs.compactMap { availableFavoritesByID[$0] }
            return
        }
        let needle = query.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        let hasMetadataFilter = metadataStore.hasActiveFilter
        filteredFavorites = availableFavorites.filter {
            (!hasMetadataFilter || metadataStore.matchesActiveFilters($0.id))
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
        rebuildAvailableFavorites()
        rebuildTagSearchSnapshot()
        applyFilter()
    }

    private func rebuildAvailableFavorites() {
        availableFavorites = favorites.filter { !hiddenIDs.contains($0.id) }
        availableFavoritesByID = Dictionary(
            uniqueKeysWithValues: availableFavorites.map { ($0.id, $0) }
        )
    }

    private func rebuildTagSearchSnapshot() {
        tagSearchSnapshot = metadataStore.makeTagSearchSnapshot(favorites: favorites)
    }
}
