import Foundation

/// A face produced by the scan pipeline, ready to persist.
nonisolated struct NewFace: Sendable {
    var id: UUID
    var box: CGRect
    var quality: Float
    var embedding: [Float]
    var passesGate: Bool
}

nonisolated struct FaceVector: Sendable {
    var faceID: UUID
    var vector: [Float]
    var rejectedPersonIDs: [UUID]
}

nonisolated struct Centroid: Sendable {
    var id: UUID
    var vector: [Float]
    var count: Int
    /// A spread sample of the person's face vectors (capped) used for nearest-member matching.
    var members: [[Float]] = []
    var isNamed: Bool = false
}

/// Faces grouped into a brand-new person by the clusterer.
nonisolated struct NewPersonFaces: Sendable {
    var faceIDs: [UUID]
}

nonisolated struct PersonSummary: Sendable, Identifiable {
    var id: UUID
    var name: String?
    var faceCount: Int
    var coverFaceID: UUID?
}

nonisolated struct FaceInfo: Sendable, Identifiable {
    var id: UUID
    var assetID: String
    var box: CGRect
    var quality: Float
    var personID: UUID?
    var personName: String?
}

nonisolated struct StoreStats: Sendable {
    var assetsScanned: Int
    var assetsFailed: Int
    var assetsInCloud: Int
    var assetsCloudFailed: Int
    var facesTotal: Int
    var facesAssigned: Int
    var peopleCount: Int
    var unassignedFaces: Int
}

extension Array where Element == Float {
    /// Raw bytes for SwiftData storage.
    nonisolated var floatData: Data {
        withUnsafeBytes { Data($0) }
    }
}
