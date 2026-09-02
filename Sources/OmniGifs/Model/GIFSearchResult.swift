import Foundation

struct GIFSearchResult: Hashable, Sendable {
    let id: String
    let matchedURL: Bool
    let matchedOCR: Bool
    let aiSimilarityPercentage: Int?

    var matchDescription: String {
        var parts: [String] = []
        if matchedURL { parts.append("URL") }
        if matchedOCR { parts.append("OCR") }
        if let aiSimilarityPercentage {
            parts.append("AI (\(aiSimilarityPercentage)%)")
        }
        return parts.joined(separator: ", ")
    }
}
