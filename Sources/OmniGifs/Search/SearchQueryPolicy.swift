import Foundation

enum SearchQueryPolicy {
    static let minimumCharacterCount = 2

    static func normalized(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isSearchable(_ query: String) -> Bool {
        normalized(query).count >= minimumCharacterCount
    }

    static func commaSeparatedClauses(_ query: String) -> [String] {
        normalized(query)
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func requiresStrictConjunction(_ query: String) -> Bool {
        query.contains(",") && commaSeparatedClauses(query).count > 1
    }

    static func intersectClauseMatches(_ matches: [Set<String>]) -> Set<String> {
        guard let first = matches.first else { return [] }
        return matches.dropFirst().reduce(first) { result, next in
            result.intersection(next)
        }
    }
}
