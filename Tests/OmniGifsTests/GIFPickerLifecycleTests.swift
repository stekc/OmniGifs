import AppKit
import Foundation
import Testing

@testable import OmniGifs

@MainActor
struct GIFPickerLifecycleTests {
    @Test func emptyLoggedOutLibraryShowsDiscordLoginButton() throws {
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniGifsEmptyPickerTests-\(UUID().uuidString).json")
        let picker = GIFPickerViewController(
            library: GIFLibrary(cacheURL: cacheURL),
            session: .shared,
            search: .shared
        )

        let button = try #require(
            picker.view.descendants
                .compactMap { $0 as? NSButton }
                .first { $0.title == "Log In to Discord" }
        )
        #expect(!button.isHidden)
    }

    @Test func initiallyEmptyPickerCanCreateCellsAfterFavoritesArrive() throws {
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniGifsPopulatePickerTests-\(UUID().uuidString).json")
        let library = GIFLibrary(cacheURL: cacheURL)
        let picker = GIFPickerViewController(
            library: library,
            session: .shared,
            search: .shared
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 526, height: 650),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentViewController = picker
        window.layoutIfNeeded()

        try library.replace(
            with: Data(
                #"[{"url":"https://tenor.com/example","src":"https://media.tenor.com/example.gif","format":1,"width":320,"height":240}]"#
                    .utf8),
            persist: false
        )
        window.layoutIfNeeded()

        let collectionView = try #require(
            picker.view.descendants.compactMap { $0 as? NSCollectionView }.first
        )
        #expect(collectionView.numberOfItems(inSection: 0) == 1)
        let item = collectionView.makeItem(
            withIdentifier: GIFCollectionItem.identifier,
            for: IndexPath(item: 0, section: 0)
        )
        #expect(item is GIFCollectionItem)
    }

    @Test func repeatedPresentationKeepsTheSameViewAndReleasesPlaybackState() async {
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniGifsPickerTests-\(UUID().uuidString).json")
        let picker = GIFPickerViewController(
            library: GIFLibrary(cacheURL: cacheURL),
            session: .shared,
            search: .shared
        )
        let originalView = picker.view

        picker.didPresent()
        await Task.yield()
        picker.didDismiss()
        picker.didPresent()
        await Task.yield()
        picker.didDismiss()

        #expect(picker.view === originalView)
    }
}

extension NSView {
    fileprivate var descendants: [NSView] {
        subviews + subviews.flatMap(\.descendants)
    }
}
