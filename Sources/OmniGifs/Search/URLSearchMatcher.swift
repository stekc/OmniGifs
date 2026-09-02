import Foundation

enum URLSearchMatcher {
    static func matches(_ query: String, sourceURL: URL) -> Bool {
        let needle = canonicalText(query)
        guard !needle.isEmpty else { return false }
        let decodedURL =
            sourceURL.absoluteString.removingPercentEncoding
            ?? sourceURL.absoluteString
        return canonicalText(decodedURL).contains(needle)
    }

    static func canonicalText(_ value: String) -> String {
        let folded = value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        return
            folded
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: " ")
    }
}

/// Immutable exact-substring index for the favorite URLs. Every two-byte
/// sequence maps to an ordered candidate list; the final `Data.range` check
/// preserves the match semantics and original ordering of a full URL scan.
struct URLSearchSnapshot {
    private struct Record {
        let id: String
        let value: Data
    }

    private let records: [Record]
    private let candidatesByBigram: [UInt16: [Int]]

    init(favorites: [GIFFavorite]) {
        var records: [Record] = []
        records.reserveCapacity(favorites.count)
        var candidates: [UInt16: [Int]] = [:]

        for favorite in favorites {
            let decoded =
                favorite.sourceURL.absoluteString.removingPercentEncoding
                ?? favorite.sourceURL.absoluteString
            let value = Data(URLSearchMatcher.canonicalText(decoded).utf8)
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

        self.records = records
        candidatesByBigram = candidates
    }

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
