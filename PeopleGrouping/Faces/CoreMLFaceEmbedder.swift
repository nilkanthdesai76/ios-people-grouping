import CoreGraphics
import CoreImage
import CoreML
import CoreVideo

/// Loads FaceEmbedding.mlmodelc from the bundle at runtime and embeds face crops.
nonisolated struct CoreMLFaceEmbedder: FaceEmbedder {
    static let displayName = "FaceEmbedding (Core ML)"
    // Tuned on synthetic data: 0.40 kept people together without chaining lookalikes. Raise it if one person still splits.
    static let baseThreshold: Float = 0.4
    static let baseRange: ClosedRange<Float> = 0.25...0.65

    let name: String = CoreMLFaceEmbedder.displayName
    let isFallback = false
    let defaultThreshold: Float = CoreMLFaceEmbedder.baseThreshold
    let thresholdRange: ClosedRange<Float> = CoreMLFaceEmbedder.baseRange
    let dimension: Int

    nonisolated(unsafe) private let model: MLModel
    private let inputName: String
    private let outputName: String
    private let inputSize: CGSize
    private let usesImageInput: Bool

    static func load() -> CoreMLFaceEmbedder? {
        guard let url = Bundle.main.url(forResource: "FaceEmbedding", withExtension: "mlmodelc"),
              let model = try? MLModel(contentsOf: url) else { return nil }
        let description = model.modelDescription
        guard let input = description.inputDescriptionsByName.first(where: { $0.value.type == .image || $0.value.type == .multiArray }),
              let output = description.outputDescriptionsByName.first(where: { $0.value.type == .multiArray })
        else { return nil }
        let usesImageInput = input.value.type == .image
        let inputSize: CGSize
        if usesImageInput {
            let constraint = input.value.imageConstraint
            inputSize = CGSize(
                width: constraint?.pixelsWide ?? 112,
                height: constraint?.pixelsHigh ?? 112
            )
        } else {
            let shape = input.value.multiArrayConstraint?.shape.map { Int(truncating: $0) } ?? []
            inputSize = shape.count >= 2
                ? CGSize(width: shape[shape.count - 1], height: shape[shape.count - 2])
                : CGSize(width: 112, height: 112)
        }
        let dimension = output.value.multiArrayConstraint?.shape
            .reduce(1) { $0 * Int(truncating: $1) } ?? 0
        guard dimension > 0 else { return nil }
        return CoreMLFaceEmbedder(
            dimension: dimension,
            model: model,
            inputName: input.key,
            outputName: output.key,
            inputSize: inputSize,
            usesImageInput: usesImageInput
        )
    }

    /// Embedding of the face and of its mirror image, averaged ("flip test", standard for
    /// ArcFace models): less sensitive to head turn and to which side the light comes from.
    func embed(_ crop: CGImage) throws -> [Float] {
        let original = try embedOnce(crop)
        guard let mirrored = Self.mirrored(crop), let flipped = try? embedOnce(mirrored),
              flipped.count == original.count else { return original }
        return VectorMath.normalize(zip(original, flipped).map { $0 + $1 })
    }

    private static func mirrored(_ image: CGImage) -> CGImage? {
        guard let ctx = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        ctx.translateBy(x: CGFloat(image.width), y: 0)
        ctx.scaleBy(x: -1, y: 1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }

    private func embedOnce(_ crop: CGImage) throws -> [Float] {
        let provider: MLFeatureProvider
        if usesImageInput {
            let buffer = try makePixelBuffer(from: crop)
            provider = try MLDictionaryFeatureProvider(dictionary: [
                inputName: MLFeatureValue(pixelBuffer: buffer)
            ])
        } else {
            let array = try makeNormalizedArray(from: crop)
            provider = try MLDictionaryFeatureProvider(dictionary: [
                inputName: MLFeatureValue(multiArray: array)
            ])
        }
        let prediction = try model.prediction(from: provider)
        guard let output = prediction.featureValue(for: outputName)?.multiArrayValue
        else { throw EmbeddingError.outputMissing }
        var floats = [Float]()
        floats.reserveCapacity(output.count)
        for index in 0..<output.count {
            floats.append(output[index].floatValue)
        }
        return VectorMath.normalize(floats)
    }

    private func makePixelBuffer(from crop: CGImage) throws -> CVPixelBuffer {
        let width = Int(inputSize.width)
        let height = Int(inputSize.height)
        let scale = CGAffineTransform(
            scaleX: inputSize.width / CGFloat(crop.width),
            y: inputSize.height / CGFloat(crop.height)
        )
        let scaled = CIImage(cgImage: crop).transformed(by: scale)
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer
        )
        guard status == kCVReturnSuccess, let buffer else { throw EmbeddingError.pixelBuffer }
        FaceCropper.context.render(scaled, to: buffer)
        return buffer
    }

    /// [1, 3, H, W] float32, (pixel - 127.5) / 127.5, RGB order.
    private func makeNormalizedArray(from crop: CGImage) throws -> MLMultiArray {
        let width = Int(inputSize.width)
        let height = Int(inputSize.height)
        let bytesPerRow = width * 4
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else { throw EmbeddingError.pixelBuffer }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { throw EmbeddingError.pixelBuffer }
        let pixels = width * height
        let multi = try MLMultiArray(
            shape: [1, 3, NSNumber(value: height), NSNumber(value: width)],
            dataType: .float32
        )
        let destination = multi.dataPointer.bindMemory(to: Float.self, capacity: pixels * 3)
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        for pixel in 0..<pixels {
            let r = Float(bytes[pixel * 4 + 1])
            let g = Float(bytes[pixel * 4 + 2])
            let b = Float(bytes[pixel * 4 + 3])
            destination[pixel] = (r - 127.5) / 127.5
            destination[pixels + pixel] = (g - 127.5) / 127.5
            destination[2 * pixels + pixel] = (b - 127.5) / 127.5
        }
        return multi
    }
}
