import AppKit

@MainActor
enum SemanticQueryGate {
    static func looksNatural(_ query: String) -> Bool {
        let words =
            query
            .split { !$0.isLetter }
            .map(String.init)
            .filter { $0.count > 1 }
        guard !words.isEmpty else { return false }

        return words.contains { word in
            let range = NSSpellChecker.shared.checkSpelling(
                of: word,
                startingAt: 0,
                language: nil,
                wrap: false,
                inSpellDocumentWithTag: 0,
                wordCount: nil
            )
            return range.location == NSNotFound
        }
    }
}

enum SemanticResultFilter {
    static let minimumSimilarity: Float = 0.24
    static let unsupportedQueryMinimumTopScore: Float = 0.34
    static let maximumResults = 60

    static func ids(
        from matches: [SQLiteSearchIndex.VectorMatch],
        hasLexicalEvidence: Bool
    ) -> [String] {
        guard let top = matches.first else { return [] }
        if !hasLexicalEvidence && top.score < unsupportedQueryMinimumTopScore {
            return []
        }
        let floor = max(minimumSimilarity, top.score - 0.10)
        return
            matches
            .prefix { $0.score >= floor }
            .prefix(maximumResults)
            .map(\.id)
    }

    static func similarityPercentage(for score: Float) -> Int {
        min(100, max(0, Int((score * 100).rounded())))
    }
}
