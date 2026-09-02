import Foundation

struct GIFSearchResult: Hashable, Sendable {
    let id: String
    let matchedURL: Bool
    let matchedTag: Bool
    let matchedOCR: Bool
    let aiSimilarityPercentage: Int?

    init(
        id: String,
        matchedURL: Bool,
        matchedTag: Bool = false,
        matchedOCR: Bool,
        aiSimilarityPercentage: Int?
    ) {
        self.id = id
        self.matchedURL = matchedURL
        self.matchedTag = matchedTag
        self.matchedOCR = matchedOCR
        self.aiSimilarityPercentage = aiSimilarityPercentage
    }

    var matchDescription: String {
        var parts: [String] = []
        if matchedURL { parts.append("URL") }
        if matchedTag { parts.append("Tag") }
        if matchedOCR { parts.append("OCR") }
        if let aiSimilarityPercentage {
            parts.append("AI (\(aiSimilarityPercentage)%)")
        }
        return parts.joined(separator: ", ")
    }
}
