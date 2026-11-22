import Accelerate

nonisolated enum VectorMath {
    static func normalize(_ vector: [Float]) -> [Float] {
        var sum: Float = 0
        vDSP_svesq(vector, 1, &sum, vDSP_Length(vector.count))
        let norm = sqrt(sum)
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }

    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var result: Float = 0
        vDSP_dotpr(a, 1, b, 1, &result, vDSP_Length(a.count))
        return result
    }

    /// Vectors are stored L2-normalised, so cosine distance is 1 - dot.
    static func cosineDistance(_ a: [Float], _ b: [Float]) -> Float {
        1 - dot(a, b)
    }

    static func mean(_ vectors: [[Float]]) -> [Float] {
        guard let first = vectors.first else { return [] }
        var result = [Float](repeating: 0, count: first.count)
        for vector in vectors {
            guard vector.count == first.count else { continue }
            for index in result.indices {
                result[index] += vector[index]
            }
        }
        let count = Float(vectors.count)
        return result.map { $0 / count }
    }
}
