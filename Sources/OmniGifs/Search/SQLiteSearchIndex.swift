import Accelerate
import Foundation
import SQLite3

final class SQLiteSearchIndex {
    enum IndexError: Error {
        case open
        case statement(String)
    }

    struct VectorMatch: Sendable, Equatable {
        let id: String
        let score: Float
    }

    /// A read-optimized view of every frame embedding. SQLite is
    /// excellent durable storage, but stepping thousands of BLOB rows and
    /// issuing one vDSP call per row on every keystroke costs more than the
    /// actual dot products. This snapshot turns the same Float32 vectors into
    /// one contiguous matrix so Accelerate can score them without per-query
    /// SQLite decoding or vector allocation, while preserving exact precision.
    final class VectorSearchSnapshot {
        let dimension: Int
        private let matrix: [Float]
        private let gifIDs: [String]
        private let gifIndexByRow: [Int]
        private let rowIndicesByGIF: [[Int]]
        private var approximateFrameScores: [Float]
        private var approximateBestScores: [Float]
        private var candidateGIFIndices: [Int]
        private var exactMatches: [VectorMatch] = []

        fileprivate init(
            dimension: Int,
            matrix: [Float],
            gifIDs: [String],
            gifIndexByRow: [Int]
        ) {
            self.dimension = dimension
            self.matrix = matrix
            self.gifIDs = gifIDs
            self.gifIndexByRow = gifIndexByRow
            var rows = [[Int]](repeating: [], count: gifIDs.count)
            for (row, gifIndex) in gifIndexByRow.enumerated() {
                rows[gifIndex].append(row)
            }
            rowIndicesByGIF = rows
            approximateFrameScores = [Float](repeating: 0, count: gifIndexByRow.count)
            approximateBestScores = [Float](
                repeating: -.greatestFiniteMagnitude,
                count: gifIDs.count
            )
            candidateGIFIndices = Array(gifIDs.indices)
            exactMatches.reserveCapacity(gifIDs.count)
        }

        var rowCount: Int { gifIndexByRow.count }

        func searchScored(vector query: [Float], limit: Int = 150) -> [VectorMatch] {
            guard query.count == dimension, !gifIndexByRow.isEmpty else { return [] }

            query.withUnsafeBufferPointer { queryBuffer in
                matrix.withUnsafeBufferPointer { matrixBuffer in
                    guard let queryBase = queryBuffer.baseAddress,
                        let matrixBase = matrixBuffer.baseAddress
                    else { return }
                    vDSP_mmul(
                        matrixBase, 1,
                        queryBase, 1,
                        &approximateFrameScores, 1,
                        vDSP_Length(gifIndexByRow.count), 1,
                        vDSP_Length(dimension)
                    )
                }
            }

            approximateBestScores.withUnsafeMutableBufferPointer {
                $0.initialize(repeating: -.greatestFiniteMagnitude)
            }
            for row in gifIndexByRow.indices {
                let gifIndex = gifIndexByRow[row]
                approximateBestScores[gifIndex] = max(
                    approximateBestScores[gifIndex],
                    approximateFrameScores[row]
                )
            }

            // Matrix multiplication is dramatically faster than thousands of
            // individual dot products, but its accumulation order can differ by
            // a few Float32 ULPs. Use it only to choose an oversized candidate
            // set, then calculate every returned score with the legacy operation.
            let candidateCount = min(gifIDs.count, max(limit + 128, limit * 2))
            candidateGIFIndices.sort {
                if approximateBestScores[$0] == approximateBestScores[$1] {
                    return gifIDs[$0] < gifIDs[$1]
                }
                return approximateBestScores[$0] > approximateBestScores[$1]
            }

            exactMatches.removeAll(keepingCapacity: true)
            query.withUnsafeBufferPointer { queryBuffer in
                matrix.withUnsafeBufferPointer { matrixBuffer in
                    guard let queryBase = queryBuffer.baseAddress,
                        let matrixBase = matrixBuffer.baseAddress
                    else { return }
                    for gifIndex in candidateGIFIndices.prefix(candidateCount) {
                        var best: Float = -.greatestFiniteMagnitude
                        for row in rowIndicesByGIF[gifIndex] {
                            var score: Float = 0
                            vDSP_dotpr(
                                queryBase, 1,
                                matrixBase.advanced(by: row * dimension), 1,
                                &score,
                                vDSP_Length(dimension)
                            )
                            best = max(best, score)
                        }
                        exactMatches.append(VectorMatch(id: gifIDs[gifIndex], score: best))
                    }
                }
            }

            return exactMatches.sorted {
                $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score
            }.prefix(limit).map { $0 }
        }
    }

    private var database: OpaquePointer?
    private var ftsSearchStatement: OpaquePointer?
    private var queryEmbeddingLookupStatement: OpaquePointer?

    init(databaseURL: URL? = nil) throws {
        let url: URL
        if let databaseURL {
            url = databaseURL
        } else {
            let base = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            url =
                base
                .appendingPathComponent("OmniGifs", isDirectory: true)
                .appendingPathComponent("Search.sqlite3")
        }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        guard
            sqlite3_open_v2(
                url.path,
                &database,
                SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
                nil
            ) == SQLITE_OK
        else { throw IndexError.open }

        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=NORMAL")
        try execute(
            "CREATE TABLE IF NOT EXISTS indexed_gifs (id TEXT PRIMARY KEY, source_url TEXT NOT NULL, ocr_text TEXT NOT NULL DEFAULT '', model_version TEXT)"
        )
        try addColumnIfMissing("media_url", definition: "TEXT NOT NULL DEFAULT ''")
        try addColumnIfMissing("index_state", definition: "TEXT NOT NULL DEFAULT 'complete'")
        try addColumnIfMissing("failure_count", definition: "INTEGER NOT NULL DEFAULT 0")
        try addColumnIfMissing("next_retry_at", definition: "REAL")
        try execute(
            "CREATE VIRTUAL TABLE IF NOT EXISTS gif_fts USING fts5(id UNINDEXED, source_url, ocr_text, tokenize='unicode61 remove_diacritics 2')"
        )
        try execute(
            "CREATE TABLE IF NOT EXISTS gif_frame_embeddings (gif_id TEXT NOT NULL, frame_index INTEGER NOT NULL, dimension INTEGER NOT NULL, vector BLOB NOT NULL, PRIMARY KEY(gif_id, frame_index))"
        )
        try execute(
            "CREATE TABLE IF NOT EXISTS text_query_embeddings (query_digest TEXT PRIMARY KEY, model_version TEXT NOT NULL, dimension INTEGER NOT NULL, vector BLOB NOT NULL, last_used REAL NOT NULL)"
        )
        try execute(
            "CREATE INDEX IF NOT EXISTS text_query_embeddings_lru ON text_query_embeddings(last_used DESC)"
        )
    }

    deinit {
        sqlite3_finalize(ftsSearchStatement)
        sqlite3_finalize(queryEmbeddingLookupStatement)
        sqlite3_close(database)
    }

    func contains(_ id: String) -> Bool {
        (try? scalarInt("SELECT COUNT(*) FROM indexed_gifs WHERE id = ?", bind: id)) == 1
    }

    func unavailableCount() -> Int {
        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                database,
                "SELECT COUNT(*) FROM indexed_gifs WHERE index_state = 'failed'",
                -1,
                &statement,
                nil
            ) == SQLITE_OK
        else { return 0 }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(statement, 0))
    }

    func unavailableIDs() -> Set<String> {
        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                database,
                "SELECT id FROM indexed_gifs WHERE index_state = 'failed'",
                -1,
                &statement,
                nil
            ) == SQLITE_OK
        else { return [] }
        defer { sqlite3_finalize(statement) }
        var ids: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW,
            let value = sqlite3_column_text(statement, 0)
        {
            ids.insert(String(cString: value))
        }
        return ids
    }

    func needsIndex(_ id: String, modelVersion: String?) -> Bool {
        guard contains(id) else { return true }
        guard let modelVersion else { return false }
        return
            (try? scalarString(
                "SELECT model_version FROM indexed_gifs WHERE id = ?",
                bind: id
            )) != modelVersion
    }

    func needsIndex(
        _ favorite: GIFFavorite,
        modelVersion: String?,
        now: Date = Date()
    ) -> Bool {
        guard let record = indexRecord(for: favorite.id) else { return true }
        let sourceURL = favorite.sourceURL.absoluteString
        let mediaURL = favorite.mediaURL?.absoluteString ?? ""
        if record.sourceURL != sourceURL { return true }
        if !record.mediaURL.isEmpty && record.mediaURL != mediaURL { return true }

        if let modelVersion, record.modelVersion != modelVersion { return true }
        if record.state == "complete" { return false }
        return now.timeIntervalSince1970 >= (record.nextRetryAt ?? 0)
    }

    func upsert(
        id: String,
        sourceURL: String,
        mediaURL: String = "",
        ocrText: String,
        modelVersion: String?,
        embeddings: [[Float]]? = nil,
        indexState: String = "complete",
        failureCount: Int = 0,
        nextRetryAt: TimeInterval? = nil
    ) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try run(
                "INSERT INTO indexed_gifs(id, source_url, media_url, ocr_text, model_version, index_state, failure_count, next_retry_at) VALUES(?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET source_url=excluded.source_url, media_url=excluded.media_url, ocr_text=excluded.ocr_text, model_version=excluded.model_version, index_state=excluded.index_state, failure_count=excluded.failure_count, next_retry_at=excluded.next_retry_at",
                strings: [
                    id, sourceURL, mediaURL, ocrText, modelVersion, indexState,
                    String(failureCount), nextRetryAt.map { String($0) },
                ]
            )
            try run("DELETE FROM gif_fts WHERE id = ?", strings: [id])
            try run(
                "INSERT INTO gif_fts(id, source_url, ocr_text) VALUES(?, ?, ?)",
                strings: [id, sourceURL, ocrText]
            )
            if let embeddings {
                try replaceEmbeddings(id: id, vectors: embeddings)
            } else {
                try run("DELETE FROM gif_frame_embeddings WHERE gif_id = ?", strings: [id])
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func recordFailure(
        favorite: GIFFavorite,
        ocrText: String = "",
        modelVersion: String?,
        now: Date = Date()
    ) throws {
        let previous = indexRecord(for: favorite.id)
        let mediaURL = favorite.mediaURL?.absoluteString ?? ""
        let sameAttemptTarget =
            previous?.mediaURL == mediaURL
            && previous?.modelVersion == modelVersion
        let failureCount = sameAttemptTarget ? (previous?.failureCount ?? 0) + 1 : 1
        let retryDelay = min(6 * 60 * 60 * pow(2, Double(failureCount - 1)), 7 * 24 * 60 * 60)
        try upsert(
            id: favorite.id,
            sourceURL: favorite.sourceURL.absoluteString,
            mediaURL: mediaURL,
            ocrText: ocrText,
            modelVersion: modelVersion,
            embeddings: nil,
            indexState: "failed",
            failureCount: failureCount,
            nextRetryAt: now.timeIntervalSince1970 + retryDelay
        )
    }

    @discardableResult
    func prune(keeping ids: Set<String>) throws -> Bool {
        let staleIDs = allIDs().subtracting(ids)
        guard !staleIDs.isEmpty else { return false }
        try execute("BEGIN IMMEDIATE")
        do {
            for id in staleIDs {
                try run("DELETE FROM gif_frame_embeddings WHERE gif_id = ?", strings: [id])
                try run("DELETE FROM gif_fts WHERE id = ?", strings: [id])
                try run("DELETE FROM indexed_gifs WHERE id = ?", strings: [id])
            }
            try execute("COMMIT")
            return true
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func clear() throws {
        _ = try prune(keeping: [])
        try execute("DELETE FROM text_query_embeddings")
    }

    func cachedQueryEmbedding(queryDigest: String, modelVersion: String) -> [Float]? {
        let sql =
            "SELECT dimension, vector FROM text_query_embeddings WHERE query_digest = ? AND model_version = ?"
        if queryEmbeddingLookupStatement == nil,
            sqlite3_prepare_v2(database, sql, -1, &queryEmbeddingLookupStatement, nil)
                != SQLITE_OK
        {
            return nil
        }
        guard let statement = queryEmbeddingLookupStatement else { return nil }
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        defer { sqlite3_reset(statement) }
        sqlite3_bind_text(statement, 1, queryDigest, -1, sqliteTransient)
        sqlite3_bind_text(statement, 2, modelVersion, -1, sqliteTransient)
        guard sqlite3_step(statement) == SQLITE_ROW,
            let blob = sqlite3_column_blob(statement, 1)
        else { return nil }
        let dimension = Int(sqlite3_column_int(statement, 0))
        guard dimension > 0,
            sqlite3_column_bytes(statement, 1)
                == Int32(dimension * MemoryLayout<Float>.size)
        else { return nil }

        return Array(
            UnsafeBufferPointer(
                start: blob.assumingMemoryBound(to: Float.self),
                count: dimension
            ))
    }

    func storeQueryEmbedding(
        _ vector: [Float],
        queryDigest: String,
        modelVersion: String,
        maximumEntries: Int = 1_024
    ) throws {
        try storeQueryEmbeddings(
            [(queryDigest, vector)],
            modelVersion: modelVersion,
            maximumEntries: maximumEntries
        )
    }

    /// Commits all recently used query vectors in one transaction. Typing a
    /// phrase can produce several useful prefixes; batching them avoids one WAL
    /// sync and one LRU-prune query per character after the user stops typing.
    func storeQueryEmbeddings(
        _ entries: [(queryDigest: String, vector: [Float])],
        modelVersion: String,
        maximumEntries: Int = 1_024
    ) throws {
        let entries = entries.filter { !$0.vector.isEmpty }
        guard !entries.isEmpty, maximumEntries > 0 else { return }
        let sql =
            "INSERT INTO text_query_embeddings(query_digest, model_version, dimension, vector, last_used) VALUES(?, ?, ?, ?, ?) ON CONFLICT(query_digest) DO UPDATE SET model_version=excluded.model_version, dimension=excluded.dimension, vector=excluded.vector, last_used=excluded.last_used"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw IndexError.statement(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        try execute("BEGIN IMMEDIATE")
        do {
            let timestamp = Date().timeIntervalSince1970
            for entry in entries {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                sqlite3_bind_text(statement, 1, entry.queryDigest, -1, sqliteTransient)
                sqlite3_bind_text(statement, 2, modelVersion, -1, sqliteTransient)
                sqlite3_bind_int(statement, 3, Int32(entry.vector.count))
                _ = entry.vector.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(
                        statement, 4, bytes.baseAddress, Int32(bytes.count), sqliteTransient)
                }
                sqlite3_bind_double(statement, 5, timestamp)
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw IndexError.statement(String(cString: sqlite3_errmsg(database)))
                }
            }
            try run(
                "DELETE FROM text_query_embeddings WHERE rowid IN (SELECT rowid FROM text_query_embeddings ORDER BY last_used DESC LIMIT -1 OFFSET ?)",
                strings: [String(maximumEntries)]
            )
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func search(vector query: [Float], limit: Int = 150) -> [String] {
        searchScored(vector: query, limit: limit).map(\.id)
    }

    func makeVectorSearchSnapshot() -> VectorSearchSnapshot? {
        let sql = "SELECT gif_id, dimension, vector FROM gif_frame_embeddings"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        var dimension: Int?
        var matrix: [Float] = []
        var gifIDs: [String] = []
        var gifIndices: [String: Int] = [:]
        var gifIndexByRow: [Int] = []
        if let shape = vectorTableShape() {
            matrix.reserveCapacity(shape.rows * shape.dimension)
            gifIndexByRow.reserveCapacity(shape.rows)
            gifIDs.reserveCapacity(min(shape.rows, 1_024))
            gifIndices.reserveCapacity(min(shape.rows, 1_024))
        }

        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idBytes = sqlite3_column_text(statement, 0),
                let blob = sqlite3_column_blob(statement, 2)
            else { continue }
            let rowDimension = Int(sqlite3_column_int(statement, 1))
            guard rowDimension > 0,
                sqlite3_column_bytes(statement, 2)
                    == Int32(rowDimension * MemoryLayout<Float>.size)
            else { continue }
            if let dimension, dimension != rowDimension { continue }
            dimension = rowDimension

            let id = String(cString: idBytes)
            let gifIndex: Int
            if let existing = gifIndices[id] {
                gifIndex = existing
            } else {
                gifIndex = gifIDs.count
                gifIDs.append(id)
                gifIndices[id] = gifIndex
            }
            gifIndexByRow.append(gifIndex)
            matrix.append(
                contentsOf: UnsafeBufferPointer(
                    start: blob.assumingMemoryBound(to: Float.self),
                    count: rowDimension
                ))
        }

        guard let dimension, !matrix.isEmpty else { return nil }
        return VectorSearchSnapshot(
            dimension: dimension,
            matrix: matrix,
            gifIDs: gifIDs,
            gifIndexByRow: gifIndexByRow
        )
    }

    func searchScored(vector query: [Float], limit: Int = 150) -> [VectorMatch] {
        guard !query.isEmpty else { return [] }
        let sql = "SELECT gif_id, dimension, vector FROM gif_frame_embeddings WHERE dimension = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(query.count))

        var bestScores: [String: Float] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idBytes = sqlite3_column_text(statement, 0),
                let blob = sqlite3_column_blob(statement, 2)
            else { continue }
            let byteCount = Int(sqlite3_column_bytes(statement, 2))
            guard byteCount == query.count * MemoryLayout<Float>.size else { continue }
            let vector = blob.assumingMemoryBound(to: Float.self)
            var score: Float = 0
            query.withUnsafeBufferPointer { queryBuffer in
                vDSP_dotpr(
                    queryBuffer.baseAddress!, 1,
                    vector, 1,
                    &score,
                    vDSP_Length(query.count)
                )
            }
            let id = String(cString: idBytes)
            bestScores[id] = max(bestScores[id] ?? -.greatestFiniteMagnitude, score)
        }
        var matches = bestScores.map { VectorMatch(id: $0.key, score: $0.value) }
        matches.sort {
            $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score
        }
        return Array(matches.prefix(limit))
    }

    func search(_ query: String, limit: Int = 150) -> [String] {
        let terms =
            query
            .split { !$0.isLetter && !$0.isNumber }
            .map { "\($0)*" }
        guard !terms.isEmpty else { return [] }

        let sql =
            "SELECT id FROM gif_fts WHERE gif_fts MATCH ? ORDER BY bm25(gif_fts, 0.0, 0.0, 2.2) LIMIT ?"
        if ftsSearchStatement == nil,
            sqlite3_prepare_v2(database, sql, -1, &ftsSearchStatement, nil) != SQLITE_OK
        {
            return []
        }
        guard let statement = ftsSearchStatement else { return [] }
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        defer { sqlite3_reset(statement) }
        let ocrExpression = "ocr_text : (\(terms.joined(separator: " ")))"
        sqlite3_bind_text(statement, 1, ocrExpression, -1, sqliteTransient)
        sqlite3_bind_int(statement, 2, Int32(limit))

        var ids: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let value = sqlite3_column_text(statement, 0) {
                ids.append(String(cString: value))
            }
        }
        return ids
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw IndexError.statement(String(cString: sqlite3_errmsg(database)))
        }
    }

    private func allIDs() -> Set<String> {
        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                database,
                "SELECT id FROM indexed_gifs",
                -1,
                &statement,
                nil
            ) == SQLITE_OK
        else { return [] }
        defer { sqlite3_finalize(statement) }
        var ids: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW,
            let value = sqlite3_column_text(statement, 0)
        {
            ids.insert(String(cString: value))
        }
        return ids
    }

    private func vectorTableShape() -> (rows: Int, dimension: Int)? {
        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                database,
                "SELECT COUNT(*), MAX(dimension) FROM gif_frame_embeddings",
                -1,
                &statement,
                nil
            ) == SQLITE_OK
        else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let rows = Int(sqlite3_column_int64(statement, 0))
        let dimension = Int(sqlite3_column_int(statement, 1))
        guard rows > 0, dimension > 0 else { return nil }
        return (rows, dimension)
    }

    private func addColumnIfMissing(_ name: String, definition: String) throws {
        guard !tableColumns("indexed_gifs").contains(name) else { return }
        try execute("ALTER TABLE indexed_gifs ADD COLUMN \(name) \(definition)")
    }

    private func tableColumns(_ table: String) -> Set<String> {
        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(database, "PRAGMA table_info(\(table))", -1, &statement, nil)
                == SQLITE_OK
        else {
            return []
        }
        defer { sqlite3_finalize(statement) }
        var columns: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW,
            let value = sqlite3_column_text(statement, 1)
        {
            columns.insert(String(cString: value))
        }
        return columns
    }

    private struct IndexRecord {
        let sourceURL: String
        let mediaURL: String
        let modelVersion: String?
        let state: String
        let failureCount: Int
        let nextRetryAt: TimeInterval?
    }

    private func indexRecord(for id: String) -> IndexRecord? {
        let sql =
            "SELECT source_url, media_url, model_version, index_state, failure_count, next_retry_at FROM indexed_gifs WHERE id = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, id, -1, sqliteTransient)
        guard sqlite3_step(statement) == SQLITE_ROW,
            let sourceBytes = sqlite3_column_text(statement, 0),
            let mediaBytes = sqlite3_column_text(statement, 1),
            let stateBytes = sqlite3_column_text(statement, 3)
        else { return nil }
        let modelVersion = sqlite3_column_text(statement, 2).map { String(cString: $0) }
        let retryAt =
            sqlite3_column_type(statement, 5) == SQLITE_NULL
            ? nil
            : sqlite3_column_double(statement, 5)
        return IndexRecord(
            sourceURL: String(cString: sourceBytes),
            mediaURL: String(cString: mediaBytes),
            modelVersion: modelVersion,
            state: String(cString: stateBytes),
            failureCount: Int(sqlite3_column_int(statement, 4)),
            nextRetryAt: retryAt
        )
    }

    private func run(_ sql: String, strings: [String?]) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw IndexError.statement(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in strings.enumerated() {
            if let value {
                sqlite3_bind_text(statement, Int32(offset + 1), value, -1, sqliteTransient)
            } else {
                sqlite3_bind_null(statement, Int32(offset + 1))
            }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw IndexError.statement(String(cString: sqlite3_errmsg(database)))
        }
    }

    private func scalarInt(_ sql: String, bind value: String) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw IndexError.statement(sql)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, value, -1, sqliteTransient)
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func scalarString(_ sql: String, bind value: String) throws -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw IndexError.statement(sql)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, value, -1, sqliteTransient)
        guard sqlite3_step(statement) == SQLITE_ROW,
            let value = sqlite3_column_text(statement, 0)
        else { return nil }
        return String(cString: value)
    }

    private func replaceEmbeddings(id: String, vectors: [[Float]]) throws {
        try run("DELETE FROM gif_frame_embeddings WHERE gif_id = ?", strings: [id])
        let sql =
            "INSERT INTO gif_frame_embeddings(gif_id, frame_index, dimension, vector) VALUES(?, ?, ?, ?)"
        for (frameIndex, vector) in vectors.enumerated() {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                throw IndexError.statement(String(cString: sqlite3_errmsg(database)))
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, id, -1, sqliteTransient)
            sqlite3_bind_int(statement, 2, Int32(frameIndex))
            sqlite3_bind_int(statement, 3, Int32(vector.count))
            _ = vector.withUnsafeBytes { bytes in
                sqlite3_bind_blob(
                    statement, 4, bytes.baseAddress, Int32(bytes.count), sqliteTransient)
            }
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw IndexError.statement(String(cString: sqlite3_errmsg(database)))
            }
        }
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
