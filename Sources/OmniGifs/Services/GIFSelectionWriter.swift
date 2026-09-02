import AppKit

enum GIFSelectionWriter {
    @discardableResult
    static func copySourceURL(
        of favorite: GIFFavorite,
        to pasteboard: NSPasteboard = .general
    ) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(favorite.sourceURL.absoluteString, forType: .string)
    }
}
