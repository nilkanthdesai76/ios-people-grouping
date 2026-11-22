import Foundation

nonisolated enum ScanState: String, Sendable {
    case idle
    case running
    case paused
    case waitingForNetwork
    case finished
}

nonisolated struct ScanProgress: Sendable {
    var scanned: Int
    var total: Int
    var facesFound: Int
    var peopleCount: Int
    var inCloudPending: Int
    var downloading: Int
    var cloudFailed: Int
    /// iCloud photos finished from the on-device preview, without a download.
    var downloadsSaved: Int = 0
    var state: ScanState

    static let initial = ScanProgress(
        scanned: 0, total: 0, facesFound: 0, peopleCount: 0,
        inCloudPending: 0, downloading: 0, cloudFailed: 0, state: .idle
    )
}

nonisolated struct FaceThumb: Sendable {
    var faceID: UUID
    var jpeg: Data
}

/// Per-photo stage timings in milliseconds, recorded by the coordinator.
nonisolated struct StageTiming: Sendable {
    var load: Double
    var detect: Double
    var embed: Double
    var total: Double
}

nonisolated struct PhotoResult: Sendable {
    var assetID: String
    var status: ScanStatus
    var detectedCount: Int
    var faces: [NewFace]
    var thumbnails: [FaceThumb]
    /// True when processed by the network (cloud) phase.
    var fromCloud: Bool
    var timing: StageTiming?
    /// True when an iCloud photo was finished from its on-device preview (no download).
    var savedDownload = false
}

nonisolated extension PhotoResult {
    func withCloudFlag(_ fromCloud: Bool) -> PhotoResult {
        var copy = self
        copy.fromCloud = fromCloud
        return copy
    }
}

/// Running averages of per-stage timings, for the diagnostics screen.
nonisolated struct StageAverages: Sendable {
    var photos: Int
    var loadMs: Double
    var detectMs: Double
    var embedMs: Double
    var totalMs: Double
}

/// User policy for the iCloud download pass.
nonisolated struct CloudPolicy: Sendable {
    var includeICloud: Bool
    var wifiOnly: Bool
    /// Check the on-device preview first and download only when it has faces too small to use.
    var previewFirst: Bool = true
}
