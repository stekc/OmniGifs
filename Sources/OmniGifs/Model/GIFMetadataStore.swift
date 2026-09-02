import Foundation
import SQLite3

struct GIFFolder: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let name: String
}

struct GIFTag: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let name: String
}

struct GIFTagSearchSnapshot: Sendable {
    private struct Record: Sendable {
        let id: String
        let value: Data
    }

    let version: UUID
    private let records: [Record]
    private let candidatesByBigram: [UInt16: [Int]]

    init(
        version: UUID,
        favorites: [GIFFavorite],
        tags: [GIFTag],
        tagIDsByGIF: [String: Set<UUID>]
    ) {
        let namesByID = Dictionary(
            uniqueKeysWithValues: tags.map {
                ($0.id, Data(URLSearchMatcher.canonicalText($0.name).utf8))
            }
        )
        var records: [Record] = []
        records.reserveCapacity(tagIDsByGIF.count)
        var candidates: [UInt16: [Int]] = [:]

        for favorite in favorites {
            guard let tagIDs = tagIDsByGIF[favorite.id], !tagIDs.isEmpty else { continue }
            let names = tagIDs.compactMap { namesByID[$0] }.sorted {
                $0.lexicographicallyPrecedes($1)
            }
            var value = Data()
            value.reserveCapacity(names.reduce(0) { $0 + $1.count + 1 })
            for name in names {
                if !value.isEmpty { value.append(0) }
                value.append(name)
            }
            guard !value.isEmpty else { continue }
            let recordIndex = records.count
            records.append(Record(id: favorite.id, value: value))

            let bytes = [UInt8](value)
            guard bytes.count >= 2 else { continue }
            var seen: Set<UInt16> = []
            seen.reserveCapacity(bytes.count - 1)
            for index in 0..<(bytes.count - 1) {
                let bigram = UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1])
                if seen.insert(bigram).inserted {
                    candidates[bigram, default: []].append(recordIndex)
                }
            }
        }

        self.version = version
        self.records = records
        candidatesByBigram = candidates
    }

    static let empty = GIFTagSearchSnapshot(
        version: UUID(),
        favorites: [],
        tags: [],
        tagIDsByGIF: [:]
    )

    var isEmpty: Bool { records.isEmpty }

    func matchingIDs(_ query: String) -> [String] {
        let needle = Data(URLSearchMatcher.canonicalText(query).utf8)
        guard !needle.isEmpty else { return [] }
        let bytes = [UInt8](needle)
        guard bytes.count >= 2 else {
            return records.compactMap { record in
                record.value.range(of: needle) == nil ? nil : record.id
            }
        }

        var bestCandidates: [Int]?
        for index in 0..<(bytes.count - 1) {
            let bigram = UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1])
            guard let candidates = candidatesByBigram[bigram] else { return [] }
            if bestCandidates == nil || candidates.count < bestCandidates!.count {
                bestCandidates = candidates
            }
        }
        guard let bestCandidates else { return [] }
        return bestCandidates.compactMap { index in
            let record = records[index]
            return record.value.range(of: needle) == nil ? nil : record.id
        }
    }
}

enum GIFMetadataError: LocalizedError {
    case emptyName
    case nameTooLong
    case unknownFolder
    case unknownTag
    case storageUnavailable
    case storage(String)

    var errorDescription: String? {
        switch self {
        case .emptyName:
            "Enter a name."
        case .nameTooLong:
            "Names can contain up to 64 characters."
        case .unknownFolder:
            "That folder no longer exists."
        case .unknownTag:
            "That tag no longer exists."
        case .storageUnavailable:
            "OmniGifs couldn’t open its folder and tag database."
        case .storage(let description):
            "OmniGifs couldn’t save this change: \(description)"
        }
    }
}

@MainActor
final class GIFMetadataStore {
    private final class Connection: @unchecked Sendable {
        var pointer: OpaquePointer?

        deinit { sqlite3_close(pointer) }
    }

    private struct Assignment: Equatable {
        var folderID: UUID?
        var tagIDs: Set<UUID>
    }

    private(set) var folders: [GIFFolder] = []
    private(set) var tags: [GIFTag] = []
    private(set) var selectedFolderID: UUID?
    private(set) var selectedTagIDs: Set<UUID> = []
    private var assignments: [String: Assignment] = [:]
    private(set) var tagVersion = UUID()

    private let connection = Connection()

    private var database: OpaquePointer? { connection.pointer }

    init(databaseURL: URL) {
        do {
            try FileManager.default.createDirectory(
                at: databaseURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            guard
                sqlite3_open_v2(
                    databaseURL.path,
                    &connection.pointer,
                    SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
                    nil
                ) == SQLITE_OK
            else {
                sqlite3_close(database)
                connection.pointer = nil
                return
            }
            try configureDatabase()
            load()
        } catch {
            sqlite3_close(database)
            connection.pointer = nil
        }
    }

    var hasActiveFilter: Bool {
        selectedFolderID != nil || !selectedTagIDs.isEmpty
    }

    func folderID(for favoriteID: String) -> UUID? {
        assignments[favoriteID]?.folderID
    }

    func tagIDs(for favoriteID: String) -> Set<UUID> {
        assignments[favoriteID]?.tagIDs ?? []
    }

    func matchesActiveFilters(_ favoriteID: String) -> Bool {
        let assignment = assignments[favoriteID]
        if let selectedFolderID, assignment?.folderID != selectedFolderID {
            return false
        }
        return selectedTagIDs.isSubset(of: assignment?.tagIDs ?? [])
    }

    func makeTagSearchSnapshot(favorites: [GIFFavorite]) -> GIFTagSearchSnapshot {
        GIFTagSearchSnapshot(
            version: tagVersion,
            favorites: favorites,
            tags: tags,
            tagIDsByGIF: assignments.mapValues(\.tagIDs)
        )
    }

    @discardableResult
    func createFolder(named rawName: String) throws -> GIFFolder {
        let name = try normalizedName(rawName)
        if let existing = folders.first(where: { namesEqual($0.name, name) }) {
            return existing
        }
        let folder = GIFFolder(id: UUID(), name: name)
        try run(
            "INSERT INTO metadata_folders(id, name) VALUES(?, ?)",
            strings: [folder.id.uuidString, folder.name]
        )
        folders.append(folder)
        sortGroups()
        return folder
    }

    @discardableResult
    func createTag(named rawName: String) throws -> GIFTag {
        let name = try normalizedName(rawName)
        if let existing = tags.first(where: { namesEqual($0.name, name) }) {
            return existing
        }
        let tag = GIFTag(id: UUID(), name: name)
        try run(
            "INSERT INTO metadata_tags(id, name) VALUES(?, ?)",
            strings: [tag.id.uuidString, tag.name]
        )
        tags.append(tag)
        sortGroups()
        tagVersion = UUID()
        return tag
    }

    @discardableResult
    func assign(_ favoriteID: String, toFolder folderID: UUID?) throws -> Bool {
        if let folderID, !folders.contains(where: { $0.id == folderID }) {
            throw GIFMetadataError.unknownFolder
        }
        var assignment = assignments[favoriteID] ?? Assignment(folderID: nil, tagIDs: [])
        guard assignment.folderID != folderID else { return false }
        if let folderID {
            try run(
                "INSERT INTO metadata_gif_folders(gif_id, folder_id) VALUES(?, ?) ON CONFLICT(gif_id) DO UPDATE SET folder_id=excluded.folder_id",
                strings: [favoriteID, folderID.uuidString]
            )
        } else {
            try run(
                "DELETE FROM metadata_gif_folders WHERE gif_id = ?",
                strings: [favoriteID]
            )
        }
        assignment.folderID = folderID
        store(assignment, for: favoriteID)
        return true
    }

    @discardableResult
    func assign(_ favoriteIDs: Set<String>, toFolder folderID: UUID?) throws -> Bool {
        if favoriteIDs.count == 1, let favoriteID = favoriteIDs.first {
            return try assign(favoriteID, toFolder: folderID)
        }
        if let folderID, !folders.contains(where: { $0.id == folderID }) {
            throw GIFMetadataError.unknownFolder
        }
        let changedIDs = favoriteIDs.filter { assignments[$0]?.folderID != folderID }
        guard !changedIDs.isEmpty else { return false }
        try execute("BEGIN IMMEDIATE")
        do {
            for favoriteID in changedIDs {
                if let folderID {
                    try run(
                        "INSERT INTO metadata_gif_folders(gif_id, folder_id) VALUES(?, ?) ON CONFLICT(gif_id) DO UPDATE SET folder_id=excluded.folder_id",
                        strings: [favoriteID, folderID.uuidString]
                    )
                } else {
                    try run(
                        "DELETE FROM metadata_gif_folders WHERE gif_id = ?",
                        strings: [favoriteID]
                    )
                }
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
        for favoriteID in changedIDs {
            var assignment = assignments[favoriteID] ?? Assignment(folderID: nil, tagIDs: [])
            assignment.folderID = folderID
            store(assignment, for: favoriteID)
        }
        return true
    }

    @discardableResult
    func toggleTag(_ tagID: UUID, for favoriteID: String) throws -> Bool {
        guard tags.contains(where: { $0.id == tagID }) else {
            throw GIFMetadataError.unknownTag
        }
        var assignment = assignments[favoriteID] ?? Assignment(folderID: nil, tagIDs: [])
        if assignment.tagIDs.remove(tagID) != nil {
            try run(
                "DELETE FROM metadata_gif_tags WHERE gif_id = ? AND tag_id = ?",
                strings: [favoriteID, tagID.uuidString]
            )
        } else {
            try run(
                "INSERT OR IGNORE INTO metadata_gif_tags(gif_id, tag_id) VALUES(?, ?)",
                strings: [favoriteID, tagID.uuidString]
            )
            assignment.tagIDs.insert(tagID)
        }
        store(assignment, for: favoriteID)
        tagVersion = UUID()
        return true
    }

    @discardableResult
    func setTag(_ tagID: UUID, for favoriteIDs: Set<String>, assigned: Bool) throws -> Bool {
        guard tags.contains(where: { $0.id == tagID }) else {
            throw GIFMetadataError.unknownTag
        }
        if favoriteIDs.count == 1, let favoriteID = favoriteIDs.first {
            let isAssigned = assignments[favoriteID]?.tagIDs.contains(tagID) ?? false
            guard isAssigned != assigned else { return false }
            return try toggleTag(tagID, for: favoriteID)
        }
        let changedIDs = favoriteIDs.filter {
            (assignments[$0]?.tagIDs.contains(tagID) ?? false) != assigned
        }
        guard !changedIDs.isEmpty else { return false }
        try execute("BEGIN IMMEDIATE")
        do {
            for favoriteID in changedIDs {
                if assigned {
                    try run(
                        "INSERT OR IGNORE INTO metadata_gif_tags(gif_id, tag_id) VALUES(?, ?)",
                        strings: [favoriteID, tagID.uuidString]
                    )
                } else {
                    try run(
                        "DELETE FROM metadata_gif_tags WHERE gif_id = ? AND tag_id = ?",
                        strings: [favoriteID, tagID.uuidString]
                    )
                }
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
        for favoriteID in changedIDs {
            var assignment = assignments[favoriteID] ?? Assignment(folderID: nil, tagIDs: [])
            if assigned {
                assignment.tagIDs.insert(tagID)
            } else {
                assignment.tagIDs.remove(tagID)
            }
            store(assignment, for: favoriteID)
        }
        tagVersion = UUID()
        return true
    }

    @discardableResult
    func selectFolder(_ folderID: UUID?) throws -> Bool {
        if let folderID, !folders.contains(where: { $0.id == folderID }) {
            throw GIFMetadataError.unknownFolder
        }
        guard selectedFolderID != folderID else { return false }
        if let folderID {
            try run(
                "INSERT INTO metadata_filter_state(key, value) VALUES('folder', ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                strings: [folderID.uuidString]
            )
        } else {
            try execute("DELETE FROM metadata_filter_state WHERE key = 'folder'")
        }
        selectedFolderID = folderID
        return true
    }

    @discardableResult
    func toggleSelectedTag(_ tagID: UUID) throws -> Bool {
        guard tags.contains(where: { $0.id == tagID }) else {
            throw GIFMetadataError.unknownTag
        }
        if selectedTagIDs.contains(tagID) {
            try run(
                "DELETE FROM metadata_selected_tags WHERE tag_id = ?",
                strings: [tagID.uuidString]
            )
            selectedTagIDs.remove(tagID)
        } else {
            try run(
                "INSERT OR IGNORE INTO metadata_selected_tags(tag_id) VALUES(?)",
                strings: [tagID.uuidString]
            )
            selectedTagIDs.insert(tagID)
        }
        return true
    }

    @discardableResult
    func clearSelectedTags() throws -> Bool {
        guard !selectedTagIDs.isEmpty else { return false }
        try execute("DELETE FROM metadata_selected_tags")
        selectedTagIDs.removeAll()
        return true
    }

    @discardableResult
    func deleteFolder(_ folderID: UUID) throws -> Bool {
        guard folders.contains(where: { $0.id == folderID }) else {
            throw GIFMetadataError.unknownFolder
        }
        try execute("BEGIN IMMEDIATE")
        do {
            try run(
                "DELETE FROM metadata_folders WHERE id = ?",
                strings: [folderID.uuidString]
            )
            try run(
                "DELETE FROM metadata_filter_state WHERE key = 'folder' AND value = ?",
                strings: [folderID.uuidString]
            )
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
        folders.removeAll { $0.id == folderID }
        let affectedIDs = assignments.compactMap { favoriteID, assignment in
            assignment.folderID == folderID ? favoriteID : nil
        }
        for favoriteID in affectedIDs {
            guard var assignment = assignments[favoriteID] else { continue }
            assignment.folderID = nil
            store(assignment, for: favoriteID)
        }
        if selectedFolderID == folderID { selectedFolderID = nil }
        return true
    }

    @discardableResult
    func deleteTag(_ tagID: UUID) throws -> Bool {
        guard tags.contains(where: { $0.id == tagID }) else {
            throw GIFMetadataError.unknownTag
        }
        try run(
            "DELETE FROM metadata_tags WHERE id = ?",
            strings: [tagID.uuidString]
        )
        tags.removeAll { $0.id == tagID }
        let affectedIDs = assignments.compactMap { favoriteID, assignment in
            assignment.tagIDs.contains(tagID) ? favoriteID : nil
        }
        for favoriteID in affectedIDs {
            guard var assignment = assignments[favoriteID] else { continue }
            assignment.tagIDs.remove(tagID)
            store(assignment, for: favoriteID)
        }
        selectedTagIDs.remove(tagID)
        tagVersion = UUID()
        return true
    }

    func clear() throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try execute("DELETE FROM metadata_selected_tags")
            try execute("DELETE FROM metadata_filter_state")
            try execute("DELETE FROM metadata_gif_tags")
            try execute("DELETE FROM metadata_gif_folders")
            try execute("DELETE FROM metadata_tags")
            try execute("DELETE FROM metadata_folders")
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
        folders = []
        tags = []
        assignments = [:]
        selectedFolderID = nil
        selectedTagIDs = []
        tagVersion = UUID()
    }

    private func load() {
        folders = queryGroups(
            sql: "SELECT id, name FROM metadata_folders ORDER BY name COLLATE NOCASE",
            make: { GIFFolder(id: $0, name: $1) }
        )
        tags = queryGroups(
            sql: "SELECT id, name FROM metadata_tags ORDER BY name COLLATE NOCASE",
            make: { GIFTag(id: $0, name: $1) }
        )
        sortGroups()
        assignments = [:]
        queryRows("SELECT gif_id, folder_id FROM metadata_gif_folders") { columns in
            guard let favoriteID = columns[0], let value = columns[1],
                let folderID = UUID(uuidString: value)
            else { return }
            assignments[favoriteID] = Assignment(folderID: folderID, tagIDs: [])
        }
        queryRows("SELECT gif_id, tag_id FROM metadata_gif_tags") { columns in
            guard let favoriteID = columns[0], let value = columns[1],
                let tagID = UUID(uuidString: value)
            else { return }
            var assignment = assignments[favoriteID] ?? Assignment(folderID: nil, tagIDs: [])
            assignment.tagIDs.insert(tagID)
            assignments[favoriteID] = assignment
        }
        queryRows("SELECT value FROM metadata_filter_state WHERE key = 'folder'") { columns in
            selectedFolderID = columns[0].flatMap(UUID.init(uuidString:))
        }
        selectedTagIDs = []
        queryRows("SELECT tag_id FROM metadata_selected_tags") { columns in
            if let value = columns[0], let tagID = UUID(uuidString: value) {
                selectedTagIDs.insert(tagID)
            }
        }
    }

    private func configureDatabase() throws {
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=NORMAL")
        try execute("PRAGMA foreign_keys=ON")
        try execute(
            "CREATE TABLE IF NOT EXISTS metadata_folders (id TEXT PRIMARY KEY, name TEXT NOT NULL UNIQUE COLLATE NOCASE)"
        )
        try execute(
            "CREATE TABLE IF NOT EXISTS metadata_tags (id TEXT PRIMARY KEY, name TEXT NOT NULL UNIQUE COLLATE NOCASE)"
        )
        try execute(
            "CREATE TABLE IF NOT EXISTS metadata_gif_folders (gif_id TEXT PRIMARY KEY, folder_id TEXT NOT NULL REFERENCES metadata_folders(id) ON DELETE CASCADE)"
        )
        try execute(
            "CREATE INDEX IF NOT EXISTS metadata_folder_assignments ON metadata_gif_folders(folder_id, gif_id)"
        )
        try execute(
            "CREATE TABLE IF NOT EXISTS metadata_gif_tags (gif_id TEXT NOT NULL, tag_id TEXT NOT NULL REFERENCES metadata_tags(id) ON DELETE CASCADE, PRIMARY KEY(gif_id, tag_id))"
        )
        try execute(
            "CREATE INDEX IF NOT EXISTS metadata_tag_assignments ON metadata_gif_tags(tag_id, gif_id)"
        )
        try execute(
            "CREATE TABLE IF NOT EXISTS metadata_filter_state (key TEXT PRIMARY KEY, value TEXT NOT NULL)"
        )
        try execute(
            "CREATE TABLE IF NOT EXISTS metadata_selected_tags (tag_id TEXT PRIMARY KEY REFERENCES metadata_tags(id) ON DELETE CASCADE)"
        )
    }

    private func execute(_ sql: String) throws {
        guard let database else { throw GIFMetadataError.storageUnavailable }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw GIFMetadataError.storage(String(cString: sqlite3_errmsg(database)))
        }
    }

    private func run(_ sql: String, strings: [String?]) throws {
        guard let database else { throw GIFMetadataError.storageUnavailable }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw GIFMetadataError.storage(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in strings.enumerated() {
            if let value {
                sqlite3_bind_text(
                    statement,
                    Int32(offset + 1),
                    value,
                    -1,
                    metadataSQLiteTransient
                )
            } else {
                sqlite3_bind_null(statement, Int32(offset + 1))
            }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw GIFMetadataError.storage(String(cString: sqlite3_errmsg(database)))
        }
    }

    private func queryGroups<T>(
        sql: String,
        make: (UUID, String) -> T
    ) -> [T] {
        var values: [T] = []
        queryRows(sql) { columns in
            guard let idValue = columns[0], let id = UUID(uuidString: idValue),
                let name = columns[1]
            else { return }
            values.append(make(id, name))
        }
        return values
    }

    private func queryRows(_ sql: String, consume: ([String?]) -> Void) {
        guard let database else { return }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return
        }
        defer { sqlite3_finalize(statement) }
        let columnCount = Int(sqlite3_column_count(statement))
        while sqlite3_step(statement) == SQLITE_ROW {
            let columns = (0..<columnCount).map { index -> String? in
                sqlite3_column_text(statement, Int32(index)).map(String.init(cString:))
            }
            consume(columns)
        }
    }

    private func store(_ assignment: Assignment, for favoriteID: String) {
        if assignment.folderID == nil && assignment.tagIDs.isEmpty {
            assignments.removeValue(forKey: favoriteID)
        } else {
            assignments[favoriteID] = assignment
        }
    }

    private func sortGroups() {
        folders.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        tags.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func normalizedName(_ value: String) throws -> String {
        let name = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !name.isEmpty else { throw GIFMetadataError.emptyName }
        guard name.count <= 64 else { throw GIFMetadataError.nameTooLong }
        return name
    }

    private func namesEqual(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }
}

private let metadataSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
