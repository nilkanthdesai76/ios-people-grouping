import CoreGraphics
import Vision

/// Fallback embedder used when the Core ML model is absent.
nonisolated struct FeaturePrintEmbedder: FaceEmbedder {
    let name: String = FeaturePrintEmbedder.displayName
    let isFallback = true
    let dimension = 128
    // Feature prints of different faces are far more alike than ArcFace vectors, so a much lower threshold.
    static let baseThreshold: Float = 0.2
    static let baseRange: ClosedRange<Float> = 0.02...0.50
    static let displayName = "Vision feature print (fallback)"
    let defaultThreshold: Float = FeaturePrintEmbedder.baseThreshold
    let thresholdRange: ClosedRange<Float> = FeaturePrintEmbedder.baseRange

    func embed(_ crop: CGImage) throws -> [Float] {
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: crop, options: [:])
        try handler.perform([request])
        guard let observation = request.results?.first,
              observation.elementType == .float else { throw EmbeddingError.noFeaturePrint }
        let data = observation.data
        let count = data.count / MemoryLayout<Float>.size
        guard count > 0 else { throw EmbeddingError.noFeaturePrint }
        var floats = [Float](repeating: 0, count: count)
        let copied = floats.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        guard copied == data.count else { throw EmbeddingError.noFeaturePrint }
        return VectorMath.normalize(floats)
    }
}
