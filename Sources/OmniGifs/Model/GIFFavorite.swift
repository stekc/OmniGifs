import Foundation

struct GIFFavorite: Identifiable, Hashable, Sendable {
    enum MediaFormat: Int, Sendable {
        case unknown = 0
        case image = 1
        case video = 2
    }

    let id: String
    let sourceURL: URL
    let mediaURL: URL?
    let width: Int
    let height: Int
    let format: MediaFormat
    let sourceIndex: Int
    let discordOrder: Int?

    var aspectRatio: CGFloat {
        guard width > 0, height > 0 else { return 4.0 / 3.0 }
        return CGFloat(width) / CGFloat(height)
    }
}

struct IndexedGIF: Sendable {
    let favorite: GIFFavorite
    let ocrText: String
    let semanticScore: Float
}
