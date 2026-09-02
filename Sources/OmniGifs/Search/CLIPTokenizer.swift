import Foundation

/// OpenAI CLIP's byte-pair tokenizer.
final class CLIPTokenizer {
    enum TokenizerError: Error {
        case missingResources
        case malformedResources
        case unknownToken(String)
    }

    private struct BytePair: Hashable {
        let first: String
        let second: String
    }

    private static let contextLength = 77
    private static let mergeCount = 49_152 - 256 - 2
    private static let vocabularySize = 49_408
    private static let startToken = "<|startoftext|>"
    private static let endToken = "<|endoftext|>"
    private static let tokenExpression = try! NSRegularExpression(
        pattern:
            #"<\|startoftext\|>|<\|endoftext\|>|'s|'t|'re|'ve|'m|'ll|'d|[\p{L}]+|[\p{N}]|[^\s\p{L}\p{N}]+"#
    )

    private let ranks: [BytePair: Int]
    private let encoder: [String: Int]
    private let byteEncoder: [UInt8: String]
    private var cache = [startToken: startToken, endToken: endToken]

    var mergeRuleCount: Int { ranks.count }
    var tokenCount: Int { encoder.count }

    convenience init(bundle: Bundle = AppResources.bundle) throws {
        guard let mergesURL = bundle.url(forResource: "clip-merges", withExtension: "txt")
        else {
            throw TokenizerError.missingResources
        }
        try self.init(mergesText: String(contentsOf: mergesURL, encoding: .utf8))
    }

    init(mergesText: String) throws {
        let lines = mergesText.split(whereSeparator: \Character.isNewline)
        guard lines.first == "#version: 0.2", lines.count == Self.mergeCount + 1 else {
            throw TokenizerError.malformedResources
        }

        var merges: [BytePair] = []
        merges.reserveCapacity(Self.mergeCount)
        var ranks: [BytePair: Int] = [:]
        ranks.reserveCapacity(Self.mergeCount)
        for (rank, line) in lines.dropFirst().enumerated() {
            let components = line.split(whereSeparator: \Character.isWhitespace)
            guard components.count == 2 else { throw TokenizerError.malformedResources }
            let pair = BytePair(first: String(components[0]), second: String(components[1]))
            guard ranks.updateValue(rank, forKey: pair) == nil else {
                throw TokenizerError.malformedResources
            }
            merges.append(pair)
        }

        let byteVocabulary = Self.makeByteVocabulary()
        var vocabulary = byteVocabulary.symbols
        vocabulary.append(contentsOf: byteVocabulary.symbols.map { $0 + "</w>" })
        vocabulary.append(contentsOf: merges.map { $0.first + $0.second })
        vocabulary.append(Self.startToken)
        vocabulary.append(Self.endToken)
        guard vocabulary.count == Self.vocabularySize,
            Set(vocabulary).count == Self.vocabularySize
        else {
            throw TokenizerError.malformedResources
        }

        self.ranks = ranks
        encoder = Dictionary(
            uniqueKeysWithValues: vocabulary.enumerated().map { (token: $0.element, id: $0.offset) }
        )
        byteEncoder = byteVocabulary.encoder
    }

    func encode(_ text: String) throws -> [Int32] {
        let normalized = text.precomposedStringWithCanonicalMapping.lowercased()
        let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
        let pieces = Self.tokenExpression.matches(in: normalized, range: range).compactMap {
            match -> String? in
            guard let range = Range(match.range, in: normalized) else { return nil }
            return String(normalized[range])
        }

        var tokens: [Int] = []
        for piece in pieces {
            let encodedBytes = piece.utf8.compactMap { byteEncoder[$0] }.joined()
            for mergedToken in bpe(encodedBytes).split(separator: " ").map(String.init) {
                guard let id = encoder[mergedToken] else {
                    throw TokenizerError.unknownToken(mergedToken)
                }
                tokens.append(id)
            }
        }

        guard let start = encoder[Self.startToken], let end = encoder[Self.endToken] else {
            throw TokenizerError.malformedResources
        }
        let payload = Array(tokens.prefix(Self.contextLength - 2))
        var result = [Int32](repeating: 0, count: Self.contextLength)
        result[0] = Int32(start)
        for (index, token) in payload.enumerated() { result[index + 1] = Int32(token) }
        result[payload.count + 1] = Int32(end)
        return result
    }

    private func bpe(_ token: String) -> String {
        if let cached = cache[token] { return cached }
        var word = token.map(String.init)
        guard !word.isEmpty else { return "" }
        word[word.count - 1] += "</w>"

        while word.count > 1 {
            let pairs = zip(word, word.dropFirst()).map(BytePair.init)
            guard
                let best = pairs.compactMap({ pair in ranks[pair].map { (pair, $0) } })
                    .min(by: { $0.1 < $1.1 })?.0
            else { break }

            var merged: [String] = []
            var index = 0
            while index < word.count {
                if index + 1 < word.count,
                    word[index] == best.first,
                    word[index + 1] == best.second
                {
                    merged.append(best.first + best.second)
                    index += 2
                } else {
                    merged.append(word[index])
                    index += 1
                }
            }
            word = merged
        }

        let result = word.joined(separator: " ")
        cache[token] = result
        return result
    }

    private static func makeByteVocabulary() -> (encoder: [UInt8: String], symbols: [String]) {
        var bytes = Array(33...126) + Array(161...172) + Array(174...255)
        var codepoints = bytes
        var extra = 0
        for byte in 0...255 where !bytes.contains(byte) {
            bytes.append(byte)
            codepoints.append(256 + extra)
            extra += 1
        }

        var encoder: [UInt8: String] = [:]
        var symbols: [String] = []
        symbols.reserveCapacity(256)
        for (byte, codepoint) in zip(bytes, codepoints) {
            guard let scalar = UnicodeScalar(codepoint) else { continue }
            let symbol = String(scalar)
            encoder[UInt8(byte)] = symbol
            symbols.append(symbol)
        }
        return (encoder, symbols)
    }
}
