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
