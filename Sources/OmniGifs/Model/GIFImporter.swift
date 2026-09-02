import Foundation

enum GIFImportError: LocalizedError {
    case unsupportedRoot
    case malformedEntry(Int)
    case empty

    var errorDescription: String? {
        switch self {
        case .unsupportedRoot:
            return "The JSON must be a Discord favorites object or an exported array."
        case .malformedEntry(let index):
            return "Favorite entry \(index) is missing a valid source URL."
        case .empty:
            return "The JSON contains no GIF favorites."
        }
    }
}

enum GIFImporter {
    /// Discord's export places newer items later. This method returns the
    /// canonical presentation order: newest first.
    static func decode(_ data: Data) throws -> [GIFFavorite] {
        try decode(data, allowingEmpty: false)
    }

    /// Decodes Discord's authoritative settings snapshot. Unlike a user-facing
    /// import, an empty favorites object is valid and must clear the local cache.
    static func decodeSnapshot(_ data: Data) throws -> [GIFFavorite] {
        try decode(data, allowingEmpty: true)
    }

    private static func decode(_ data: Data, allowingEmpty: Bool) throws -> [GIFFavorite] {
        let root = try JSONSerialization.jsonObject(with: data)
        let favorites: [GIFFavorite]

        if let array = root as? [[String: Any]] {
            favorites = try decodeArray(array)
        } else if let object = root as? [String: Any] {
            if let nested = nestedGIFObject(in: object) {
                favorites = decodeObject(nested)
            } else if object.values.allSatisfy({ $0 is [String: Any] }) {
                favorites = decodeObject(object)
            } else {
                throw GIFImportError.unsupportedRoot
            }
        } else {
            throw GIFImportError.unsupportedRoot
        }

        guard allowingEmpty || !favorites.isEmpty else { throw GIFImportError.empty }

        // Discord's numeric order is the picker order and is stable across
        // serialization. Fall back to the array convention when it is absent.
        if favorites.allSatisfy({ $0.discordOrder != nil }) {
            return favorites.sorted {
                ($0.discordOrder ?? .min, $0.sourceIndex) > (
                    $1.discordOrder ?? .min, $1.sourceIndex
                )
            }
        }
        return favorites.sorted { $0.sourceIndex > $1.sourceIndex }
    }

    private static func nestedGIFObject(in root: [String: Any]) -> [String: Any]? {
        if let favoriteGifs = root["favoriteGifs"] as? [String: Any],
            let gifs = favoriteGifs["gifs"] as? [String: Any]
        {
            return gifs
        }
        if let settings = root["settings"] as? [String: Any],
            let favoriteGifs = settings["favoriteGifs"] as? [String: Any],
            let gifs = favoriteGifs["gifs"] as? [String: Any]
        {
            return gifs
        }
        return nil
    }

    private static func decodeArray(_ entries: [[String: Any]]) throws -> [GIFFavorite] {
        try entries.enumerated().map { index, entry in
            let source =
                entry["url"] as? String
                ?? entry["sourceURL"] as? String
                ?? entry["source_url"] as? String
            guard let source, let sourceURL = normalizedURL(source) else {
                throw GIFImportError.malformedEntry(index)
            }
            return makeFavorite(sourceURL: sourceURL, metadata: entry, index: index)
        }
    }

    private static func decodeObject(_ entries: [String: Any]) -> [GIFFavorite] {
        entries.enumerated().compactMap { index, pair in
            guard let sourceURL = normalizedURL(pair.key),
                let metadata = pair.value as? [String: Any]
            else { return nil }
            return makeFavorite(sourceURL: sourceURL, metadata: metadata, index: index)
        }
    }

    private static func makeFavorite(
        sourceURL: URL,
        metadata: [String: Any],
        index: Int
    ) -> GIFFavorite {
        let mediaString =
            metadata["mediaUrl"] as? String
            ?? metadata["mediaURL"] as? String
            ?? metadata["src"] as? String
        let mediaURL = mediaString.flatMap(normalizedURL)
        let width = integer(metadata["width"]) ?? 0
        let height = integer(metadata["height"]) ?? 0
        let format = GIFFavorite.MediaFormat(rawValue: integer(metadata["format"]) ?? 0) ?? .unknown
        let order = integer(metadata["order"])

        return GIFFavorite(
            id: sourceURL.absoluteString,
            sourceURL: sourceURL,
            mediaURL: mediaURL,
            width: width,
            height: height,
            format: format,
            sourceIndex: index,
            discordOrder: order
        )
    }

    private static func normalizedURL(_ value: String) -> URL? {
        let normalized = value.hasPrefix("//") ? "https:\(value)" : value
        guard let url = URL(string: normalized),
            let scheme = url.scheme?.lowercased(),
            scheme == "https" || scheme == "http"
        else { return nil }
        return url
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }
}
