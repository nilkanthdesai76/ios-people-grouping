import CoreGraphics
import Foundation
import SwiftData

enum ScanStatus: String, Codable {
    case ok
    /// Legacy status from before iCloud support; treated as pending cloud work.
    case unavailable
    case failed
    /// Local-only thumbnail missing; full data is in iCloud.
    case inCloud
    case cloudFailed
}

@Model
final class ScannedAsset {
    @Attribute(.unique) var localIdentifier: String
    var scannedAt: Date
    var faceCount: Int
    var status: ScanStatus

    init(localIdentifier: String, scannedAt: Date = Date(), faceCount: Int = 0, status: ScanStatus) {
        self.localIdentifier = localIdentifier
        self.scannedAt = scannedAt
        self.faceCount = faceCount
        self.status = status
    }
}

@Model
final class FaceRecord {
    var id: UUID
    var assetID: String
    var boxX: Double
    var boxY: Double
    var boxW: Double
    var boxH: Double
    var quality: Float
    var embedding: Data
    var personID: UUID?
    var isPinnedAway: Bool
    var rejectedPersonIDs: [UUID]

    init(
        id: UUID = UUID(),
        assetID: String,
        box: CGRect,
        quality: Float,
        embedding: Data,
        personID: UUID? = nil,
        isPinnedAway: Bool = false,
        rejectedPersonIDs: [UUID] = []
    ) {
        self.id = id
        self.assetID = assetID
        self.boxX = Double(box.minX)
        self.boxY = Double(box.minY)
        self.boxW = Double(box.width)
        self.boxH = Double(box.height)
        self.quality = quality
        self.embedding = embedding
        self.personID = personID
        self.isPinnedAway = isPinnedAway
        self.rejectedPersonIDs = rejectedPersonIDs
    }

    nonisolated var box: CGRect {
        CGRect(x: boxX, y: boxY, width: boxW, height: boxH)
    }

    nonisolated func vector() -> [Float] {
        embedding.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return [] }
            let count = raw.count / MemoryLayout<Float>.size
            return Array(UnsafeBufferPointer(start: base.assumingMemoryBound(to: Float.self), count: count))
        }
    }
}

@Model
final class Person {
    var id: UUID
    var name: String?
    var coverFaceID: UUID?
    var createdAt: Date
    var isHidden: Bool

    init(id: UUID = UUID(), name: String? = nil, coverFaceID: UUID? = nil, createdAt: Date = Date(), isHidden: Bool = false) {
        self.id = id
        self.name = name
        self.coverFaceID = coverFaceID
        self.createdAt = createdAt
        self.isHidden = isHidden
    }
}
