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

    private var database: OpaquePointer?

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
    }

    deinit { sqlite3_close(database) }

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

    func prune(keeping ids: Set<String>) throws {
        let staleIDs = allIDs().subtracting(ids)
        guard !staleIDs.isEmpty else { return }
        try execute("BEGIN IMMEDIATE")
        do {
            for id in staleIDs {
                try run("DELETE FROM gif_frame_embeddings WHERE gif_id = ?", strings: [id])
                try run("DELETE FROM gif_fts WHERE id = ?", strings: [id])
                try run("DELETE FROM indexed_gifs WHERE id = ?", strings: [id])
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func clear() throws {
        try prune(keeping: [])
    }

    func search(vector query: [Float], limit: Int = 150) -> [String] {
        searchScored(vector: query, limit: limit).map(\.id)
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
        return
            bestScores
            .map { VectorMatch(id: $0.key, score: $0.value) }
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { $0 }
    }

    func search(_ query: String, limit: Int = 150) -> [String] {
        let terms =
            query
            .split { !$0.isLetter && !$0.isNumber }
            .map { "\($0)*" }
        guard !terms.isEmpty else { return [] }

        let sql =
            "SELECT id FROM gif_fts WHERE gif_fts MATCH ? ORDER BY bm25(gif_fts, 0.0, 0.0, 2.2) LIMIT ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
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
