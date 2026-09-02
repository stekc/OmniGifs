import Testing

@testable import OmniGifs

struct SemanticResultFilterTests {
    @Test func rejectsUnsupportedLowConfidenceQuery() {
        let matches = [
            SQLiteSearchIndex.VectorMatch(id: "one", score: 0.3057),
            SQLiteSearchIndex.VectorMatch(id: "two", score: 0.2911),
        ]
        #expect(
            SemanticResultFilter.ids(
                from: matches,
                hasLexicalEvidence: false
            ).isEmpty)
    }

    @Test func keepsCalibratedMatchesForNaturalLanguage() {
        let matches = [
            SQLiteSearchIndex.VectorMatch(id: "lorem", score: 0.2909),
            SQLiteSearchIndex.VectorMatch(id: "ipsum", score: 0.2605),
            SQLiteSearchIndex.VectorMatch(id: "dolor", score: 0.231),
        ]
        #expect(
            SemanticResultFilter.ids(
                from: matches,
                hasLexicalEvidence: true
            ) == ["lorem", "ipsum"])
    }

    @Test func reportsAbsoluteSimilarityInsteadOfTopResultRelativeConfidence() {
        #expect(SemanticResultFilter.similarityPercentage(for: 0.2909) == 29)
        #expect(SemanticResultFilter.similarityPercentage(for: 1.5) == 100)
        #expect(SemanticResultFilter.similarityPercentage(for: -0.2) == 0)
    }

    @MainActor
    @Test func spellCheckerDistinguishesWordsFromGibberish() {
        #expect(SemanticQueryGate.looksNatural("sample search"))
        #expect(!SemanticQueryGate.looksNatural("qzxvbnmqqq"))
        #expect(!SemanticQueryGate.looksNatural("vwxzqprkkk"))
    }

    @Test func commaConjunctionIntersectsEveryClauseMatchMethod() {
        let loremMatches: Set<String> = ["exact", "lorem-example", "another"]
        let ipsumMatches: Set<String> = ["exact", "ipsum-example"]
        #expect(
            SearchQueryPolicy.intersectClauseMatches([
                loremMatches,
                ipsumMatches,
            ]) == ["exact"])
        #expect(
            SearchQueryPolicy.commaSeparatedClauses("lorem, ipsum") == [
                "lorem", "ipsum",
            ])
    }
}
