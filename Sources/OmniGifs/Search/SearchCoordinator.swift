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

    private let index: SQLiteSearchIndex?
    private var indexingIDs: Set<String> = []
    private var embeddingService: CLIPEmbeddingService?
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
            try index.prune(keeping: Set(favorites.map(\.id)))
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
        return true
    }

    func search(_ query: String, among favorites: [GIFFavorite]) async -> [GIFSearchResult] {
        guard SearchQueryPolicy.isSearchable(query) else { return [] }
        if SearchQueryPolicy.requiresStrictConjunction(query) {
            return await searchStrictConjunction(
                SearchQueryPolicy.commaSeparatedClauses(query),
                among: favorites
            )
        }
        let fts = index?.search(query) ?? []
        let direct = favorites.filter {
            URLSearchMatcher.matches(query, sourceURL: $0.sourceURL)
        }.map(\.id)
        let looksNatural = await SemanticQueryGate.looksNatural(query)
        let hasLexicalEvidence = !fts.isEmpty || !direct.isEmpty || looksNatural
        let embeddings = loadEmbeddingServiceIfNeeded()
        let queryVector: [Float]?
        do {
            queryVector = try await embeddings?.embed(text: query)
        } catch {
            queryVector = nil
            Self.logger.error(
                "Text embedding failed: \(error.localizedDescription, privacy: .public)")
        }
        let scoredSemantic =
            queryVector.flatMap {
                index?.searchScored(vector: $0, limit: 150)
            } ?? []
        let semantic = SemanticResultFilter.ids(
            from: scoredSemantic,
            hasLexicalEvidence: hasLexicalEvidence
        )
        let semanticScores = Dictionary(
            uniqueKeysWithValues: scoredSemantic.map { ($0.id, $0.score) })
        let directSet = Set(direct)
        let ocrSet = Set(fts)

        var scores: [String: Double] = [:]
        for (rank, id) in direct.enumerated() {
            scores[id, default: 0] += 4.0 / Double(1 + rank)
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
        return rankedIDs.map { id in
            let aiSimilarityPercentage: Int?
            if let score = semanticScores[id],
                semantic.contains(id)
            {
                aiSimilarityPercentage = SemanticResultFilter.similarityPercentage(for: score)
            } else {
                aiSimilarityPercentage = nil
            }
            return GIFSearchResult(
                id: id,
                matchedURL: directSet.contains(id),
                matchedOCR: ocrSet.contains(id),
                aiSimilarityPercentage: aiSimilarityPercentage
            )
        }
    }

    private func searchStrictConjunction(
        _ clauses: [String],
        among favorites: [GIFFavorite]
    ) async -> [GIFSearchResult] {
        let embeddings = loadEmbeddingServiceIfNeeded()
        let favoriteIDs = Set(favorites.map(\.id))
        let sourceURLs = Dictionary(
            uniqueKeysWithValues: favorites.map {
                (
                    $0.id,
                    URLSearchMatcher.canonicalText(
                        $0.sourceURL.absoluteString.removingPercentEncoding
                            ?? $0.sourceURL.absoluteString
                    )
                )
            })

        var clauseMatches: [Set<String>] = []
        var clauseOCR: [Set<String>] = []
        var clauseURL: [Set<String>] = []
        var clauseSemantic: [Set<String>] = []
        var clauseSemanticScores: [[String: Float]] = []

        for clause in clauses {
            let ocr = Set(index?.search(clause) ?? []).intersection(favoriteIDs)
            let folded = URLSearchMatcher.canonicalText(clause)
            let url = Set(
                sourceURLs.compactMap { id, sourceURL in
                    sourceURL.contains(folded) ? id : nil
                })
            let looksNatural = await SemanticQueryGate.looksNatural(clause)
            let vector: [Float]?
            do {
                vector = try await embeddings?.embed(text: clause)
            } catch {
                vector = nil
                Self.logger.error(
                    "Text embedding failed: \(error.localizedDescription, privacy: .public)"
                )
            }
            let scored =
                vector.flatMap {
                    index?.searchScored(vector: $0, limit: 150)
                } ?? []
            let semanticIDs = SemanticResultFilter.ids(
                from: scored,
                hasLexicalEvidence: !ocr.isEmpty || !url.isEmpty || looksNatural
            )
            let semantic = Set(semanticIDs).intersection(favoriteIDs)
            let matches = ocr.union(url).union(semantic)
            guard !matches.isEmpty else { return [] }

            clauseMatches.append(matches)
            clauseOCR.append(ocr)
            clauseURL.append(url)
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

            for index in clauses.indices {
                var strength = 0.0
                if clauseURL[index].contains(id) {
                    matchedURL = true
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

    /// The search index owns the durable vectors/OCR. Core ML encoders are
    /// transient and should not keep hundreds of MB resident while hidden.
    func releaseRuntimeResources() async {
        // The image encoder is released by the indexing job when it finishes.
        // Closing a popover must not tear the shared job down mid-inference.
        guard !isIndexing else { return }
        let service = embeddingService
        embeddingService = nil
        await service?.shutdown()
    }

    func clearLocalData() async throws {
        await releaseRuntimeResources()
        try index?.clear()
        indexingIDs.removeAll(keepingCapacity: false)
        latestProgress = nil
    }

    private func loadEmbeddingServiceIfNeeded() -> CLIPEmbeddingService? {
        if embeddingService == nil {
            embeddingService = CLIPEmbeddingService.loadIfInstalled()
        }
        return embeddingService
    }
}
