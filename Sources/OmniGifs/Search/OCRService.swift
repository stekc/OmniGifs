import CoreGraphics
import Vision

actor OCRService {
    static let shared = OCRService()

    func recognizeText(in image: CGImage) async -> String {
        await Task.detached(priority: .utility) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.automaticallyDetectsLanguage = true
            request.usesLanguageCorrection = true
            request.minimumTextHeight = 0.018

            do {
                let handler = VNImageRequestHandler(cgImage: image)
                try handler.perform([request])
                return (request.results ?? [])
                    .compactMap { $0.topCandidates(1).first }
                    .filter { $0.confidence >= 0.25 }
                    .map(\.string)
                    .joined(separator: " \n")
            } catch {
                return ""
            }
        }.value
    }
}
