import AppKit

@MainActor
final class GIFVisualCache {
    static let shared = GIFVisualCache()

    private let thumbnails = NSCache<NSString, NSImage>()
    private let animations = NSCache<NSString, NSImage>()

    private init() {
        thumbnails.countLimit = 120
        thumbnails.totalCostLimit = 64 * 1_024 * 1_024
        animations.countLimit = 6
        animations.totalCostLimit = 96 * 1_024 * 1_024
    }

    func thumbnail(for id: String) -> NSImage? {
        thumbnails.object(forKey: id as NSString)
    }

    func animation(for id: String) -> NSImage? {
        animations.object(forKey: id as NSString)
    }

    func storeThumbnail(_ image: NSImage, for id: String) {
        let pixels = Int(image.size.width * image.size.height)
        thumbnails.setObject(image, forKey: id as NSString, cost: pixels * 4)
    }

    func storeAnimation(_ image: NSImage, for id: String) {
        // NSImage's animated representation is lazily decoded and its true
        // backing cost is opaque. Charge a conservative fixed cost so a long
        // scroll cannot retain dozens of complete animations indefinitely.
        animations.setObject(image, forKey: id as NSString, cost: 16 * 1_024 * 1_024)
    }

    func removeAnimations() {
        animations.removeAllObjects()
    }

    func removeThumbnails() {
        thumbnails.removeAllObjects()
    }

}
