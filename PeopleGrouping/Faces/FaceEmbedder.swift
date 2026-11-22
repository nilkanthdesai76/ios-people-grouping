import CoreGraphics
import Foundation

enum EmbeddingError: Error {
    case pixelBuffer
    case inputLayout
    case outputMissing
    case noFeaturePrint
}

nonisolated protocol FaceEmbedder: Sendable {
    var name: String { get }
    var dimension: Int { get }
    var isFallback: Bool { get }
    /// Cosine-distance threshold that suits this model's vector space.
    var defaultThreshold: Float { get }
    var thresholdRange: ClosedRange<Float> { get }
    func embed(_ crop: CGImage) throws -> [Float]
}

/// What the UI needs to know about the embedder without paying for the model load.
nonisolated struct EmbedderInfo: Sendable {
    var name: String
    var isFallback: Bool
    var defaultThreshold: Float
    var thresholdRange: ClosedRange<Float>
}

nonisolated enum FaceEmbedderFactory {
    /// Cheap: only checks whether the compiled model is bundled. Safe on the main thread.
    static func info() -> EmbedderInfo {
        if Bundle.main.url(forResource: "FaceEmbedding", withExtension: "mlmodelc") != nil {
            return EmbedderInfo(
                name: CoreMLFaceEmbedder.displayName,
                isFallback: false,
                defaultThreshold: CoreMLFaceEmbedder.baseThreshold,
                thresholdRange: CoreMLFaceEmbedder.baseRange
            )
        }
        return EmbedderInfo(
            name: FeaturePrintEmbedder.displayName,
            isFallback: true,
            defaultThreshold: FeaturePrintEmbedder.baseThreshold,
            thresholdRange: FeaturePrintEmbedder.baseRange
        )
    }

    /// Core ML model when present, Vision feature print otherwise. Slow (model preparation): call off the main thread.
    static func make() -> any FaceEmbedder {
        if let coreML = CoreMLFaceEmbedder.load() {
            return coreML
        }
        return FeaturePrintEmbedder()
    }

    /// `make()` plus one throwaway prediction so the first real face is not slow.
    static func makeWarmed() -> any FaceEmbedder {
        let embedder = make()
        if let blank = blankImage() { _ = try? embedder.embed(blank) }
        return embedder
    }

    private static func blankImage() -> CGImage? {
        CGContext(
            data: nil, width: 112, height: 112, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )?.makeImage()
    }
}
