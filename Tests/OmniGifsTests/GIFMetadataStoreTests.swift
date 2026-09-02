import Foundation
import Testing

@testable import OmniGifs

@MainActor
struct GIFMetadataStoreTests {
    @Test func persistsGroupsAssignmentsAndFilters() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("Metadata.sqlite3")

        var store: GIFMetadataStore? = GIFMetadataStore(databaseURL: databaseURL)
        let folder = try #require(try store?.createFolder(named: "Lorem"))
        let tag = try #require(try store?.createTag(named: "Ipsum"))
        try store?.assign("one", toFolder: folder.id)
        try store?.toggleTag(tag.id, for: "one")
        try store?.selectFolder(folder.id)
        try store?.toggleSelectedTag(tag.id)
        store = nil

        let reopened = GIFMetadataStore(databaseURL: databaseURL)
        #expect(reopened.folders == [folder])
        #expect(reopened.tags == [tag])
        #expect(reopened.folderID(for: "one") == folder.id)
        #expect(reopened.tagIDs(for: "one") == [tag.id])
        #expect(reopened.selectedFolderID == folder.id)
        #expect(reopened.selectedTagIDs == [tag.id])
        #expect(reopened.matchesActiveFilters("one"))
        #expect(!reopened.matchesActiveFilters("two"))
    }

    @Test func folderAssignmentIsExclusiveAndTagsAreMultiple() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstFolder = try store.createFolder(named: "Lorem")
        let secondFolder = try store.createFolder(named: "Ipsum")
        let firstTag = try store.createTag(named: "Dolor")
        let secondTag = try store.createTag(named: "Sit Amet")

        try store.assign("one", toFolder: firstFolder.id)
        try store.assign("one", toFolder: secondFolder.id)
        try store.toggleTag(firstTag.id, for: "one")
        try store.toggleTag(secondTag.id, for: "one")

        #expect(store.folderID(for: "one") == secondFolder.id)
        #expect(store.tagIDs(for: "one") == [firstTag.id, secondTag.id])
    }

    @Test func selectedTagsUseAndFiltering() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstTag = try store.createTag(named: "Lorem")
        let secondTag = try store.createTag(named: "Ipsum")
        try store.toggleTag(firstTag.id, for: "one")
        try store.toggleTag(secondTag.id, for: "one")
        try store.toggleTag(firstTag.id, for: "two")
        try store.toggleSelectedTag(firstTag.id)
        try store.toggleSelectedTag(secondTag.id)

        #expect(store.matchesActiveFilters("one"))
        #expect(!store.matchesActiveFilters("two"))
    }

    @Test func tagSearchDoesNotIncludeFolderNames() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = try store.createFolder(named: "Lorem Folder")
        let tag = try store.createTag(named: "Ipsum Tag")
        try store.assign("one", toFolder: folder.id)
        try store.toggleTag(tag.id, for: "one")
        let favorite = try favorite(id: "one")
        let snapshot = store.makeTagSearchSnapshot(favorites: [favorite])

        #expect(snapshot.matchingIDs("ipsum") == ["one"])
        #expect(snapshot.matchingIDs("lorem").isEmpty)
    }

    @Test func duplicateNamesReuseExistingGroup() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = try store.createFolder(named: "Lorem Ipsum")
        let duplicate = try store.createFolder(named: "  lorem   ipsum ")
        let tag = try store.createTag(named: "Dolor")
        let duplicateTag = try store.createTag(named: "dolor")

        #expect(duplicate == folder)
        #expect(duplicateTag == tag)
        #expect(store.folders.count == 1)
        #expect(store.tags.count == 1)
    }

    @Test func clearRemovesAllMetadata() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = try store.createFolder(named: "Lorem")
        let tag = try store.createTag(named: "Ipsum")
        try store.assign("one", toFolder: folder.id)
        try store.toggleTag(tag.id, for: "one")
        try store.selectFolder(folder.id)
        try store.toggleSelectedTag(tag.id)

        try store.clear()

        #expect(store.folders.isEmpty)
        #expect(store.tags.isEmpty)
        #expect(store.folderID(for: "one") == nil)
        #expect(store.tagIDs(for: "one").isEmpty)
        #expect(!store.hasActiveFilter)
    }

    @Test func metadataAndSearchIndexShareDatabaseWithoutClearingEachOther() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("Search.sqlite3")
        let index = try SQLiteSearchIndex(databaseURL: databaseURL)
        let store = GIFMetadataStore(databaseURL: databaseURL)
        try index.upsert(
            id: "one",
            sourceURL: "https://example.com/one",
            ocrText: "Lorem ipsum",
            modelVersion: nil
        )
        _ = try store.createFolder(named: "Lorem")

        try store.clear()
        #expect(index.contains("one"))

        let folder = try store.createFolder(named: "Ipsum")
        try index.clear()
        #expect(store.folders == [folder])
    }

    @Test func groupsStayAlphabetical() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["Zulu", "Alpha", "Beta 10", "Beta 2"] {
            _ = try store.createFolder(named: name)
            _ = try store.createTag(named: name)
        }

        let expected = ["Alpha", "Beta 2", "Beta 10", "Zulu"]
        #expect(store.folders.map(\.name) == expected)
        #expect(store.tags.map(\.name) == expected)
    }

    @Test func deletingGroupsClearsAssignmentsAndActiveFilters() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("Metadata.sqlite3")
        let store = GIFMetadataStore(databaseURL: databaseURL)
        let folder = try store.createFolder(named: "Lorem")
        let tag = try store.createTag(named: "Ipsum")
        try store.assign("one", toFolder: folder.id)
        try store.toggleTag(tag.id, for: "one")
        try store.selectFolder(folder.id)
        try store.toggleSelectedTag(tag.id)

        try store.deleteFolder(folder.id)
        try store.deleteTag(tag.id)

        #expect(store.folders.isEmpty)
        #expect(store.tags.isEmpty)
        #expect(store.folderID(for: "one") == nil)
        #expect(store.tagIDs(for: "one").isEmpty)
        #expect(!store.hasActiveFilter)

        let reopened = GIFMetadataStore(databaseURL: databaseURL)
        #expect(reopened.folders.isEmpty)
        #expect(reopened.tags.isEmpty)
        #expect(reopened.folderID(for: "one") == nil)
        #expect(reopened.tagIDs(for: "one").isEmpty)
        #expect(!reopened.hasActiveFilter)
    }

    @Test func batchAssignmentAppliesOneFolderAndTagStateToEveryGIF() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = try store.createFolder(named: "Lorem")
        let tag = try store.createTag(named: "Ipsum")
        let ids: Set<String> = ["one", "two", "three"]
        try store.toggleTag(tag.id, for: "one")

        try store.assign(ids, toFolder: folder.id)
        try store.setTag(tag.id, for: ids, assigned: true)

        #expect(ids.allSatisfy { store.folderID(for: $0) == folder.id })
        #expect(ids.allSatisfy { store.tagIDs(for: $0).contains(tag.id) })

        try store.assign(ids, toFolder: nil)
        try store.setTag(tag.id, for: ids, assigned: false)
        #expect(ids.allSatisfy { store.folderID(for: $0) == nil })
        #expect(ids.allSatisfy { !store.tagIDs(for: $0).contains(tag.id) })
    }

    private func makeStore() -> (GIFMetadataStore, URL) {
        let directory = temporaryDirectory()
        let store = GIFMetadataStore(
            databaseURL: directory.appendingPathComponent("Metadata.sqlite3")
        )
        return (store, directory)
    }

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniGifsMetadataTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func favorite(id: String) throws -> GIFFavorite {
        GIFFavorite(
            id: id,
            sourceURL: try #require(URL(string: "https://example.com/\(id)")),
            mediaURL: nil,
            width: 100,
            height: 100,
            format: .unknown,
            sourceIndex: 0,
            discordOrder: nil
        )
    }
}
