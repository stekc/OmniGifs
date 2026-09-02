import CryptoKit
import Darwin
import Foundation
import OSLog

enum SearchIndexProgress: Sendable, Equatable {
    case refreshingFavorites
    case checking
    case indexing(completed: Int, total: Int, semantic: Bool)
    case ready(semantic: Bool, unavailable: Int)
    case unavailable
}

actor SearchCoordinator {
    static let shared = SearchCoordinator()
    private static let logger = Logger(subsystem: "win.stkc.omnigifs", category: "SearchIndex")

    private enum EmbeddingOutcome: Sendable {
        case success([Float])
        case cancelled
        case failure(String)
    }

    private struct ResultCacheKey: Hashable, Sendable {
        let query: String
        let tagVersion: UUID
    }

    private enum PendingEmbedding {
        case cached([Float])
        case task(Task<EmbeddingOutcome, Never>)
        case unavailable

        func cancel() {
            if case .task(let task) = self { task.cancel() }
        }
    }

    private let index: SQLiteSearchIndex?
    private var indexingIDs: Set<String> = []
    private var embeddingService: CLIPEmbeddingService?
    private var vectorSearchSnapshot: SQLiteSearchIndex.VectorSearchSnapshot?
    private var cachedFavorites: [GIFFavorite] = []
    private var urlSearchSnapshot = URLSearchSnapshot(favorites: [])
    private var tagSearchSnapshot = GIFTagSearchSnapshot.empty
    private var resultCache: [ResultCacheKey: [GIFSearchResult]] = [:]
    private var resultCacheOrder: [ResultCacheKey] = []
    private var queryVectorCache: [String: [Float]] = [:]
    private var queryVectorCacheOrder: [String] = []
    private var pendingQueryVectorWrites: [String: [Float]] = [:]
    private var queryCachePersistenceTask: Task<Void, Never>?
    private var isIndexing = false
    private var latestProgress: SearchIndexProgress?
    private var progressContinuations: [UUID: AsyncStream<SearchIndexProgress>.Continuation] = [:]

    private init() {
        do {
            index = try SQLiteSearchIndex()
        } catch {
            index = nil
            Self.logger.error(
                "Unable to open search index: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Builds the compact vector view off the main thread during app startup,
    /// so the first popover and first query never pay SQLite decoding cost.
    func prepareForLaunch() {
        guard vectorSearchSnapshot == nil, !isIndexing else { return }
        vectorSearchSnapshot = index?.makeVectorSearchSnapshot()
        // Building the contiguous matrix briefly decodes thousands of SQLite
        // BLOBs. Keep the finished snapshot, but immediately return the much
        // larger temporary allocator regions instead of carrying them idle.
        malloc_zone_pressure_relief(nil, 0)
    }

    /// Starts the two expensive cold resources as soon as the popover opens,
    /// before a person can focus the field and type a searchable second
    /// character. Both are released again when the popover closes.
    func prepareForPresentation(
        _ favorites: [GIFFavorite],
        tagSnapshot: GIFTagSearchSnapshot
    ) async {
        prepareSearchCorpus(favorites, tagSnapshot: tagSnapshot)
        if vectorSearchSnapshot == nil, !isIndexing {
            vectorSearchSnapshot = index?.makeVectorSearchSnapshot()
        }
        guard !Task.isCancelled else { return }
        let embeddings = loadEmbeddingServiceIfNeeded()
        do {
            _ = try await embeddings?.embed(text: "gif")
        } catch is CancellationError {
            return
        } catch {
            Self.logger.error(
                "Text embedding warmup failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Progress belongs to the shared indexing job, not to any one popover.
    /// New picker controllers immediately receive the latest value, then all
    /// subsequent updates, so closing and reopening cannot lose status.
    func progressUpdates() -> AsyncStream<SearchIndexProgress> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: SearchIndexProgress.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        progressContinuations[id] = continuation
        if let latestProgress { continuation.yield(latestProgress) }
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeProgressContinuation(id) }
        }
        return stream
    }

    private func removeProgressContinuation(_ id: UUID) {
        progressContinuations.removeValue(forKey: id)
    }

    private func report(
        _ value: SearchIndexProgress,
        to callback: (@Sendable (SearchIndexProgress) -> Void)?
    ) {
        latestProgress = value
        callback?(value)
        for continuation in progressContinuations.values {
            continuation.yield(value)
        }
    }

    func index(
        _ favorites: [GIFFavorite],
        progress: (@Sendable (SearchIndexProgress) -> Void)? = nil
    ) async -> Bool {
        guard let index else {
            report(.unavailable, to: progress)
            return false
        }
        // Actor methods are reentrant at suspension points. A second popover
        // must observe the current job, never launch a duplicate reindex.
        guard !isIndexing else { return false }
        var storageErrorOccurred = false
        do {
            if try index.prune(keeping: Set(favorites.map(\.id))) {
                vectorSearchSnapshot = nil
                clearResultCache()
            }
        } catch {
            storageErrorOccurred = true
            Self.logger.error(
                "Unable to prune search index: \(error.localizedDescription, privacy: .public)")
        }
        let hasEmbeddingModels = CLIPEmbeddingService.isInstalled
        let modelVersion = hasEmbeddingModels ? CLIPEmbeddingService.modelVersion : nil
        let pending = favorites.filter {
            index.needsIndex($0, modelVersion: modelVersion)
                && !indexingIDs.contains($0.id)
        }
        guard !pending.isEmpty else {
            report(
                .ready(
                    semantic: hasEmbeddingModels,
                    unavailable: index.unavailableCount()
                ), to: progress)
            return false
        }

        isIndexing = true
        vectorSearchSnapshot = nil
        clearResultCache()
        defer { isIndexing = false }
        let embeddings = loadEmbeddingServiceIfNeeded()

        report(.checking, to: progress)
        report(
            .indexing(completed: 0, total: pending.count, semantic: embeddings != nil),
            to: progress
        )
        for (offset, favorite) in pending.enumerated() {
            indexingIDs.insert(favorite.id)
            let frames = await ThumbnailPipeline.shared.representativeFrames(
                for: favorite,
                maximumCount: 8
            )
            if frames.isEmpty {
                do {
                    try index.recordFailure(favorite: favorite, modelVersion: modelVersion)
                } catch {
                    storageErrorOccurred = true
                    Self.logger.error(
                        "Unable to record media failure: \(error.localizedDescription, privacy: .public)"
                    )
                }
            } else {
                var recognized: [String] = []
                var vectors: [[Float]] = []
                for frame in frames {
                    let text = await OCRService.shared.recognizeText(in: frame)
                    if !text.isEmpty { recognized.append(text) }
                    if let embeddings {
                        do {
                            vectors.append(try await embeddings.embed(image: frame))
                        } catch {
                            Self.logger.error(
                                "Image embedding failed: \(error.localizedDescription, privacy: .public)"
                            )
                        }
                    }
                }
                let text = Array(Set(recognized)).joined(separator: " \n")
                if embeddings != nil && vectors.isEmpty {
                    do {
                        try index.recordFailure(
                            favorite: favorite,
                            ocrText: text,
                            modelVersion: modelVersion
                        )
                    } catch {
                        storageErrorOccurred = true
                        Self.logger.error(
                            "Unable to record embedding failure: \(error.localizedDescription, privacy: .public)"
                        )
                    }
                } else {
                    do {
                        try index.upsert(
                            id: favorite.id,
                            sourceURL: favorite.sourceURL.absoluteString,
                            mediaURL: favorite.mediaURL?.absoluteString ?? "",
                            ocrText: text,
                            modelVersion: vectors.isEmpty
                                ? nil
                                : CLIPEmbeddingService.modelVersion,
                            embeddings: vectors.isEmpty ? nil : vectors
                        )
                    } catch {
                        storageErrorOccurred = true
                        Self.logger.error(
                            "Unable to persist search record: \(error.localizedDescription, privacy: .public)"
                        )
                    }
                }
            }
            indexingIDs.remove(favorite.id)
            report(
                .indexing(
                    completed: offset + 1,
                    total: pending.count,
                    semantic: embeddings != nil
                ), to: progress)
            if Task.isCancelled { break }
        }
        // The durable vectors are now in SQLite. Drop both Core ML towers and
        // return their allocator's empty pages immediately; leaving this until
        // the next popover close keeps hundreds of MB resident after indexing.
        embeddingService = nil
        await embeddings?.shutdown()
        _ = await Task.detached(priority: .background) {
            malloc_zone_pressure_relief(nil, 0)
        }.value
        if storageErrorOccurred {
            report(.unavailable, to: progress)
        } else {
            report(
                .ready(
                    semantic: embeddings != nil,
                    unavailable: index.unavailableCount()
                ), to: progress)
        }
        vectorSearchSnapshot = nil
        clearResultCache()
        return true
    }

    func search(
        _ query: String,
        among favorites: [GIFFavorite],
        tagSnapshot: GIFTagSearchSnapshot
    ) async -> [GIFSearchResult] {
        guard SearchQueryPolicy.isSearchable(query), !Task.isCancelled else { return [] }
        prepareSearchCorpus(favorites, tagSnapshot: tagSnapshot)
        let cacheKey = ResultCacheKey(query: query, tagVersion: tagSnapshot.version)
        if let cached = resultCache[cacheKey] {
            touchCachedResult(cacheKey)
            return cached
        }
        if SearchQueryPolicy.requiresStrictConjunction(query) {
            let results = await searchStrictConjunction(
                SearchQueryPolicy.commaSeparatedClauses(query),
                among: favorites
            )
            if !Task.isCancelled { cacheResults(results, for: cacheKey) }
            return results
        }
        let pendingQueryVector = beginEmbeddingVector(for: query)
        defer { pendingQueryVector.cancel() }
        let fts = index?.search(query) ?? []
        let direct = urlSearchSnapshot.matchingIDs(query)
        let tagged =
            tagSearchSnapshot.isEmpty ? [] : tagSearchSnapshot.matchingIDs(query)
        let looksNatural =
            fts.isEmpty && direct.isEmpty && tagged.isEmpty
            ? await SemanticQueryGate.looksNatural(query)
            : false
        guard !Task.isCancelled else { return [] }
        let hasLexicalEvidence = !fts.isEmpty || !direct.isEmpty || !tagged.isEmpty || looksNatural
        let queryVector = await finishEmbeddingVector(pendingQueryVector, for: query)
        guard !Task.isCancelled else { return [] }
        let scoredSemantic =
            queryVector.flatMap {
                semanticMatches(for: $0)
            } ?? []
        let semantic = SemanticResultFilter.ids(
            from: scoredSemantic,
            hasLexicalEvidence: hasLexicalEvidence
        )
        let semanticScores = Dictionary(
            uniqueKeysWithValues: scoredSemantic.map { ($0.id, $0.score) })
        let directSet = Set(direct)
        let tagSet = Set(tagged)
        let ocrSet = Set(fts)
        let semanticSet = Set(semantic)

        var scores: [String: Double] = [:]
        for (rank, id) in direct.enumerated() {
            scores[id, default: 0] += 4.0 / Double(1 + rank)
        }
        for (rank, id) in tagged.enumerated() {
            scores[id, default: 0] += 4.25 / Double(1 + rank)
        }
        for (rank, id) in fts.enumerated() {
            scores[id, default: 0] += 1.35 / Double(60 + rank)
        }
        for (rank, id) in semantic.enumerated() {
            scores[id, default: 0] += 1.0 / Double(60 + rank)
        }
        let rankedIDs = scores.sorted { lhs, rhs in
            lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
        }.map(\.key)
        let results = rankedIDs.map { id in
            let aiSimilarityPercentage: Int?
            if let score = semanticScores[id],
                semanticSet.contains(id)
            {
                aiSimilarityPercentage = SemanticResultFilter.similarityPercentage(for: score)
            } else {
                aiSimilarityPercentage = nil
            }
            return GIFSearchResult(
                id: id,
                matchedURL: directSet.contains(id),
                matchedTag: tagSet.contains(id),
                matchedOCR: ocrSet.contains(id),
                aiSimilarityPercentage: aiSimilarityPercentage
            )
        }
        cacheResults(results, for: cacheKey)
        return results
    }

    private func searchStrictConjunction(
        _ clauses: [String],
        among favorites: [GIFFavorite]
    ) async -> [GIFSearchResult] {
        guard !Task.isCancelled else { return [] }
        let favoriteIDs = Set(favorites.map(\.id))

        var clauseMatches: [Set<String>] = []
        var clauseOCR: [Set<String>] = []
        var clauseURL: [Set<String>] = []
        var clauseTag: [Set<String>] = []
        var clauseSemantic: [Set<String>] = []
        var clauseSemanticScores: [[String: Float]] = []

        for clause in clauses {
            guard !Task.isCancelled else { return [] }
            let pendingVector = beginEmbeddingVector(for: clause)
            defer { pendingVector.cancel() }
            let ocr = Set(index?.search(clause) ?? []).intersection(favoriteIDs)
            let url = Set(urlSearchSnapshot.matchingIDs(clause))
            let tag =
                tagSearchSnapshot.isEmpty
                ? []
                : Set(tagSearchSnapshot.matchingIDs(clause)).intersection(favoriteIDs)
            let looksNatural =
                ocr.isEmpty && url.isEmpty && tag.isEmpty
                ? await SemanticQueryGate.looksNatural(clause)
                : false
            guard !Task.isCancelled else { return [] }
            let vector = await finishEmbeddingVector(pendingVector, for: clause)
            guard !Task.isCancelled else { return [] }
            let scored =
                vector.flatMap {
                    semanticMatches(for: $0)
                } ?? []
            let semanticIDs = SemanticResultFilter.ids(
                from: scored,
                hasLexicalEvidence: !ocr.isEmpty || !url.isEmpty || !tag.isEmpty || looksNatural
            )
            let semantic = Set(semanticIDs).intersection(favoriteIDs)
            let matches = ocr.union(url).union(tag).union(semantic)
            guard !matches.isEmpty else { return [] }

            clauseMatches.append(matches)
            clauseOCR.append(ocr)
            clauseURL.append(url)
            clauseTag.append(tag)
            clauseSemantic.append(semantic)
            clauseSemanticScores.append(
                Dictionary(
                    uniqueKeysWithValues: scored.map { ($0.id, $0.score) }
                ))
        }

        let eligible = SearchQueryPolicy.intersectClauseMatches(clauseMatches)
        guard !eligible.isEmpty else { return [] }
        let originalOrder = Dictionary(
            uniqueKeysWithValues: favorites.enumerated().map {
                ($0.element.id, $0.offset)
            })

        struct RankedResult {
            let result: GIFSearchResult
            let score: Double
        }

        let ranked = eligible.map { id -> RankedResult in
            var clauseStrengths: [Double] = []
            var semanticPercentages: [Int] = []
            var matchedOCR = false
            var matchedURL = false
            var matchedTag = false

            for index in clauses.indices {
                var strength = 0.0
                if clauseURL[index].contains(id) {
                    matchedURL = true
                    strength = 1.0
                }
                if clauseTag[index].contains(id) {
                    matchedTag = true
                    strength = 1.0
                }
                if clauseOCR[index].contains(id) {
                    matchedOCR = true
                    strength = max(strength, 0.98)
                }
                if clauseSemantic[index].contains(id),
                    let score = clauseSemanticScores[index][id]
                {
                    let percentage = SemanticResultFilter.similarityPercentage(for: score)
                    semanticPercentages.append(percentage)
                    strength = max(strength, Double(percentage) / 100 * 0.9)
                }
                clauseStrengths.append(strength)
            }

            let weakestClause = clauseStrengths.min() ?? 0
            let average = clauseStrengths.reduce(0, +) / Double(clauseStrengths.count)
            let aiSimilarityPercentage =
                semanticPercentages.isEmpty
                ? nil
                : semanticPercentages.min()
            return RankedResult(
                result: GIFSearchResult(
                    id: id,
                    matchedURL: matchedURL,
                    matchedTag: matchedTag,
                    matchedOCR: matchedOCR,
                    aiSimilarityPercentage: aiSimilarityPercentage
                ),
                score: weakestClause + average * 0.05
            )
        }.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return originalOrder[lhs.result.id, default: .max]
                < originalOrder[rhs.result.id, default: .max]
        }
        return ranked.map(\.result)
    }

    func unavailableIDs() -> Set<String> {
        index?.unavailableIDs() ?? []
    }

    /// Core ML encoders are transient and should not keep hundreds of MB
    /// resident while hidden. The compact read-only vector snapshot remains
    /// alive for instant reopen searches and is invalidated whenever the index
    /// or favorite corpus changes.
    func releaseRuntimeResources() async {
        // The image encoder is released by the indexing job when it finishes.
        // Closing a popover must not tear the shared job down mid-inference.
        guard !isIndexing else { return }
        queryCachePersistenceTask?.cancel()
        queryCachePersistenceTask = nil
        persistPendingQueryVectors()
        let service = embeddingService
        embeddingService = nil
        await service?.shutdown()
    }

    func clearLocalData() async throws {
        await releaseRuntimeResources()
        try index?.clear()
        indexingIDs.removeAll(keepingCapacity: false)
        cachedFavorites.removeAll(keepingCapacity: false)
        urlSearchSnapshot = URLSearchSnapshot(favorites: [])
        tagSearchSnapshot = .empty
        clearResultCache()
        queryVectorCache.removeAll(keepingCapacity: false)
        queryVectorCacheOrder.removeAll(keepingCapacity: false)
        pendingQueryVectorWrites.removeAll(keepingCapacity: false)
        queryCachePersistenceTask?.cancel()
        queryCachePersistenceTask = nil
        vectorSearchSnapshot = nil
        latestProgress = nil
    }

    private func prepareSearchCorpus(
        _ favorites: [GIFFavorite],
        tagSnapshot: GIFTagSearchSnapshot
    ) {
        let favoritesChanged = favorites != cachedFavorites
        if favoritesChanged {
            cachedFavorites = favorites
            urlSearchSnapshot = URLSearchSnapshot(favorites: favorites)
            tagSearchSnapshot = tagSnapshot
            clearResultCache()
        }
        if !favoritesChanged && tagSnapshot.version != tagSearchSnapshot.version {
            tagSearchSnapshot = tagSnapshot
            clearResultCache()
        }
    }

    private func semanticMatches(for vector: [Float]) -> [SQLiteSearchIndex.VectorMatch] {
        if vectorSearchSnapshot == nil, !isIndexing {
            vectorSearchSnapshot = index?.makeVectorSearchSnapshot()
        }
        if let vectorSearchSnapshot, vectorSearchSnapshot.dimension == vector.count {
            return vectorSearchSnapshot.searchScored(vector: vector, limit: 150)
        }
        return index?.searchScored(vector: vector, limit: 150) ?? []
    }

    private func beginEmbeddingVector(for query: String) -> PendingEmbedding {
        let cacheKey = Self.embeddingCacheKey(for: query)
        if let cached = queryVectorCache[cacheKey] {
            touchCachedVector(cacheKey)
            return .cached(cached)
        }
        let queryDigest = Self.queryDigest(for: cacheKey)
        if CLIPEmbeddingService.isInstalled,
            let cached = index?.cachedQueryEmbedding(
                queryDigest: queryDigest,
                modelVersion: CLIPEmbeddingService.modelVersion
            )
        {
            cacheVectorInMemory(cached, for: cacheKey)
            scheduleVectorPersistence(cached, queryDigest: queryDigest)
            return .cached(cached)
        }
        guard !Task.isCancelled, let embeddings = loadEmbeddingServiceIfNeeded() else {
            return .unavailable
        }
        return .task(
            Task.detached(priority: .userInitiated) {
                do {
                    return .success(try await embeddings.embed(text: query))
                } catch is CancellationError {
                    return .cancelled
                } catch {
                    return .failure(error.localizedDescription)
                }
            })
    }

    private func finishEmbeddingVector(
        _ pending: PendingEmbedding,
        for query: String
    ) async -> [Float]? {
        switch pending {
        case .cached(let vector):
            return vector
        case .unavailable:
            return nil
        case .task(let task):
            let outcome = await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                task.cancel()
            }
            guard !Task.isCancelled else { return nil }
            switch outcome {
            case .success(let vector):
                let cacheKey = Self.embeddingCacheKey(for: query)
                cacheVectorInMemory(vector, for: cacheKey)
                scheduleVectorPersistence(
                    vector,
                    queryDigest: Self.queryDigest(for: cacheKey)
                )
                return vector
            case .cancelled:
                return nil
            case .failure(let description):
                Self.logger.error(
                    "Text embedding failed: \(description, privacy: .public)"
                )
                return nil
            }
        }
    }

    private func cacheResults(_ results: [GIFSearchResult], for key: ResultCacheKey) {
        guard !Task.isCancelled else { return }
        resultCache[key] = results
        touchCachedResult(key)
        if resultCacheOrder.count > 64 {
            let evicted = resultCacheOrder.removeFirst()
            resultCache.removeValue(forKey: evicted)
        }
    }

    private func touchCachedResult(_ key: ResultCacheKey) {
        resultCacheOrder.removeAll { $0 == key }
        resultCacheOrder.append(key)
    }

    private func touchCachedVector(_ query: String) {
        queryVectorCacheOrder.removeAll { $0 == query }
        queryVectorCacheOrder.append(query)
    }

    private func cacheVectorInMemory(_ vector: [Float], for cacheKey: String) {
        queryVectorCache[cacheKey] = vector
        touchCachedVector(cacheKey)
        if queryVectorCacheOrder.count > 64 {
            let evicted = queryVectorCacheOrder.removeFirst()
            queryVectorCache.removeValue(forKey: evicted)
        }
    }

    private func scheduleVectorPersistence(_ vector: [Float], queryDigest: String) {
        pendingQueryVectorWrites[queryDigest] = vector
        queryCachePersistenceTask?.cancel()
        queryCachePersistenceTask = Task(priority: .utility) { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await self?.flushScheduledQueryVectors()
        }
    }

    private func flushScheduledQueryVectors() {
        queryCachePersistenceTask = nil
        persistPendingQueryVectors()
    }

    private func persistPendingQueryVectors() {
        guard !pendingQueryVectorWrites.isEmpty else { return }
        let pending = pendingQueryVectorWrites
        pendingQueryVectorWrites.removeAll(keepingCapacity: true)
        do {
            try index?.storeQueryEmbeddings(
                pending.map { (queryDigest: $0.key, vector: $0.value) },
                modelVersion: CLIPEmbeddingService.modelVersion
            )
        } catch {
            Self.logger.error(
                "Unable to persist query acceleration: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private static func embeddingCacheKey(for query: String) -> String {
        query.precomposedStringWithCanonicalMapping.lowercased()
    }

    private static func queryDigest(for cacheKey: String) -> String {
        Data(SHA256.hash(data: Data(cacheKey.utf8))).base64EncodedString()
    }

    private func clearResultCache() {
        resultCache.removeAll(keepingCapacity: false)
        resultCacheOrder.removeAll(keepingCapacity: false)
    }

    private func loadEmbeddingServiceIfNeeded() -> CLIPEmbeddingService? {
        if embeddingService == nil {
            embeddingService = CLIPEmbeddingService.loadIfInstalled()
        }
        return embeddingService
    }
}
