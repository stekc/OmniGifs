import AppKit

@MainActor
final class GIFCollectionView: NSCollectionView {
    var menuProvider: ((IndexPath) -> NSMenu?)?
    var primaryClickHandler: ((IndexPath) -> Void)?
    private(set) var isHandlingCommandSelection = false

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let clickedIndexPath = indexPathForItem(at: point)
        isHandlingCommandSelection = event.modifierFlags.contains(.command)
        super.mouseDown(with: event)
        if !isHandlingCommandSelection, let clickedIndexPath {
            primaryClickHandler?(clickedIndexPath)
        }
        isHandlingCommandSelection = false
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let indexPath = indexPathForItem(at: point) else { return nil }
        return menuProvider?(indexPath)
    }
}
