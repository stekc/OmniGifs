import Accelerate
import CoreImage
import CoreML
import Foundation
import OSLog

actor CLIPEmbeddingService {
    private static let logger = Logger(subsystem: "win.stkc.omnigifs", category: "Embeddings")
    enum ModelError: LocalizedError {
        case missingModels
        case missingFeature(String)
        case pixelBuffer

        var errorDescription: String? {
            switch self {
            case .missingModels:
                return "OpenAI CLIP ViT-B/32 image and text encoders are not installed."
            case .missingFeature(let name):
                return "The OpenAI CLIP model did not produce \(name)."
            case .pixelBuffer:
                return "Could not create an OpenAI CLIP image buffer."
            }
        }
    }

    static let modelVersion = "openai-clip-vit-b32-coreml-fp16-v1"
    private static let imageSize = 224

    /// A cheap availability check for startup/index bookkeeping. Constructing
    /// the service loads the text encoder, which is unnecessary while the
    /// menu-bar popover is closed and the persisted index is already current.
    static var isInstalled: Bool {
        modelDirectories.contains { directory in
            findModel(named: "openai_clip_vit_b32_image", in: directory) != nil
                && findModel(named: "openai_clip_vit_b32_text", in: directory) != nil
        }
    }

    private var imageModel: MLModel?
    private let imageModelURL: URL
    private let textModelURL: URL
    private var inProcessTextModel: MLModel?
    private var inProcessTokenizer: CLIPTokenizer?
    private var textWorker: TextEmbeddingWorker?
    private let imageContext = CIContext(options: [.cacheIntermediates: false])

    static func loadIfInstalled() -> CLIPEmbeddingService? {
        for directory in modelDirectories {
            do {
                let service = try CLIPEmbeddingService(modelDirectory: directory)
                return service
            } catch  where FileManager.default.fileExists(atPath: directory.path) {
                logger.error(
                    "Unable to load models: \(error.localizedDescription, privacy: .public)")
            } catch {
                continue
            }
        }
        return nil
    }

    init(modelDirectory: URL) throws {
        guard
            let imageURL = Self.findModel(
                named: "openai_clip_vit_b32_image", in: modelDirectory),
            let textURL = Self.findModel(
                named: "openai_clip_vit_b32_text", in: modelDirectory)
        else {
            throw ModelError.missingModels
        }

        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        imageModelURL = try Self.compiledURL(for: imageURL)
        textModelURL = try Self.compiledURL(for: textURL)
    }

    func embed(image: CGImage) throws -> [Float] {
        let imageModel: MLModel
        if let loaded = self.imageModel {
            imageModel = loaded
        } else {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .all
            let loaded = try MLModel(contentsOf: imageModelURL, configuration: configuration)
            self.imageModel = loaded
            imageModel = loaded
        }
        guard let buffer = makePixelBuffer(from: image) else { throw ModelError.pixelBuffer }
        let input = try MLDictionaryFeatureProvider(dictionary: ["image": buffer])
        let result = try imageModel.prediction(from: input)
        guard let array = result.featureValue(for: "embedding")?.multiArrayValue else {
            throw ModelError.missingFeature("embedding")
        }
        return normalizedFloats(array)
    }

    func embed(text: String) throws -> [Float] {
        if textWorker == nil {
            textWorker = try TextEmbeddingWorker()
        }
        guard let vector = try textWorker?.embed(text: text) else {
            throw ModelError.missingFeature("text worker output")
        }
        return vector
    }

    /// Used only by the isolated helper process. The main app never loads the
    /// text model, because CoreML's allocator keeps hundreds of MB dirty after
    /// an in-process prediction even after every model object is released.
    func embedTextInProcess(_ text: String) throws -> [Float] {
        let textModel: MLModel
        if let loaded = inProcessTextModel {
            textModel = loaded
        } else {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .all
            let loaded = try MLModel(contentsOf: textModelURL, configuration: configuration)
            inProcessTextModel = loaded
            textModel = loaded
        }
        let tokenizer: CLIPTokenizer
        if let loaded = inProcessTokenizer {
            tokenizer = loaded
        } else {
            let loaded = try CLIPTokenizer()
            inProcessTokenizer = loaded
            tokenizer = loaded
        }
        let ids = try tokenizer.encode(text)
        let array = try MLMultiArray(shape: [1, 77], dataType: .int32)
        for (index, token) in ids.enumerated() { array[index] = NSNumber(value: token) }
        let input = try MLDictionaryFeatureProvider(dictionary: ["text": array])
        let result = try textModel.prediction(from: input)
        guard let output = result.featureValue(for: "embedding")?.multiArrayValue else {
            throw ModelError.missingFeature("embedding")
        }
        return normalizedFloats(output)
    }

    func releaseImageEncoder() {
        imageModel = nil
    }

    func shutdown() {
        textWorker?.stop()
        textWorker = nil
        imageModel = nil
        inProcessTextModel = nil
        inProcessTokenizer = nil
    }

    private func makePixelBuffer(from image: CGImage) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        guard
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                Self.imageSize,
                Self.imageSize,
                kCVPixelFormatType_32ARGB,
                attributes as CFDictionary,
                &buffer
            ) == kCVReturnSuccess, let buffer
        else { return nil }

        let input = CIImage(cgImage: image)
        let side = min(input.extent.width, input.extent.height)
        let crop = CGRect(
            x: input.extent.midX - side / 2,
            y: input.extent.midY - side / 2,
            width: side,
            height: side
        )
        let cropped = input.cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            .transformed(
                by: CGAffineTransform(
                    scaleX: CGFloat(Self.imageSize) / side,
                    y: CGFloat(Self.imageSize) / side
                ))
        imageContext.render(cropped, to: buffer)
        return buffer
    }

    private func normalizedFloats(_ array: MLMultiArray) -> [Float] {
        var values = (0..<array.count).map { array[$0].floatValue }
        var squared: Float = 0
        vDSP_svesq(values, 1, &squared, vDSP_Length(values.count))
        var magnitude = sqrt(max(squared, .leastNonzeroMagnitude))
        vDSP_vsdiv(values, 1, &magnitude, &values, 1, vDSP_Length(values.count))
        return values
    }

    private static var modelDirectory: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return
            base
            .appendingPathComponent("OmniGifs", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    private static var modelDirectories: [URL] {
        var directories = [modelDirectory]
        if let resources = Bundle.main.resourceURL {
            directories.append(resources.appendingPathComponent("Models", isDirectory: true))
        }
        return directories
    }

    private static func findModel(named name: String, in directory: URL) -> URL? {
        let compiled = directory.appendingPathComponent("\(name).mlmodelc")
        if FileManager.default.fileExists(atPath: compiled.path) { return compiled }
        let package = directory.appendingPathComponent("\(name).mlpackage")
        if FileManager.default.fileExists(atPath: package.path) { return package }
        return nil
    }

    private static func compiledURL(for url: URL) throws -> URL {
        url.pathExtension == "mlmodelc" ? url : try MLModel.compileModel(at: url)
    }
}

private final class TextEmbeddingWorker: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var stopped = false

    init() throws {
        guard let executable = Bundle.main.executableURL else {
            throw CLIPEmbeddingService.ModelError.missingModels
        }
        process.executableURL = executable
        process.arguments = ["--omnigifs-text-embedding-worker"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    func embed(text: String) throws -> [Float] {
        guard !stopped, process.isRunning else {
            throw CLIPEmbeddingService.ModelError.missingFeature("text worker")
        }
        let request = Data(text.utf8)
        try writePacket(request, to: input.fileHandleForWriting)
        guard let response = try readPacket(from: output.fileHandleForReading),
            response.count.isMultiple(of: MemoryLayout<Float>.size),
            !response.isEmpty
        else {
            throw CLIPEmbeddingService.ModelError.missingFeature("text worker output")
        }
        return response.withUnsafeBytes { bytes in
            Array(bytes.bindMemory(to: Float.self))
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        try? input.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
            // Reap the worker before reporting runtime resources released.
            // Otherwise Activity Monitor can continue grouping its CoreML
            // model footprint under OmniGifs after the popover has closed.
            process.waitUntilExit()
        }
        try? output.fileHandleForReading.close()
    }

    deinit { stop() }
}

enum TextEmbeddingWorkerRuntime {
    static func run() {
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            defer { semaphore.signal() }
            guard let service = CLIPEmbeddingService.loadIfInstalled() else { return }
            while let request = try? readPacket(from: .standardInput),
                let text = String(data: request, encoding: .utf8)
            {
                do {
                    let vector = try await service.embedTextInProcess(text)
                    let response = vector.withUnsafeBytes { Data($0) }
                    try writePacket(response, to: .standardOutput)
                } catch {
                    try? writePacket(Data(), to: .standardOutput)
                }
            }
        }
        semaphore.wait()
    }
}

private func writePacket(_ data: Data, to handle: FileHandle) throws {
    var length = UInt32(data.count).littleEndian
    try withUnsafeBytes(of: &length) { bytes in
        try handle.write(contentsOf: Data(bytes))
    }
    try handle.write(contentsOf: data)
}

private func readPacket(from handle: FileHandle) throws -> Data? {
    guard let lengthData = try readExactly(4, from: handle) else { return nil }
    let length = lengthData.withUnsafeBytes {
        UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))
    }
    return try readExactly(Int(length), from: handle) ?? Data()
}

private func readExactly(_ count: Int, from handle: FileHandle) throws -> Data? {
    if count == 0 { return Data() }
    var result = Data()
    result.reserveCapacity(count)
    while result.count < count {
        guard let chunk = try handle.read(upToCount: count - result.count),
            !chunk.isEmpty
        else { return nil }
        result.append(chunk)
    }
    return result
}
