import CoreGraphics

/// One detected face in image-normalised coordinates, origin TOP-LEFT.
nonisolated struct DetectedFace: Sendable {
    var box: CGRect
    var quality: Float
    var leftEye: CGPoint?
    var rightEye: CGPoint?
    /// Alignment points in image-normalised coordinates, origin TOP-LEFT, image-left first:
    /// [left eye, right eye] or [left eye, right eye, mouth left, mouth right].
    var landmarks: [CGPoint]?
    /// False faces are counted but not embedded.
    var passesGate: Bool
}

/// Detection quality gates, fixed here so they live in one place.
nonisolated enum FaceGate {
    /// Scan images are requested at this longest side.
    static let scanSize: CGFloat = 1024
    /// Minimum face shorter side in px at `scanSize` scale.
    static let minimumFaceSide: CGFloat = 60
    static let minimumQuality: Float = 0.25

    /// Size half of the gate only (relative to the image, so it is the same at any resolution).
    static func passesSize(_ face: DetectedFace, width: Int, height: Int) -> Bool {
        let w = CGFloat(width), h = CGFloat(height)
        let minSide = min(face.box.width * w, face.box.height * h)
        return minSide >= minimumFaceSide * max(w, h) / scanSize
    }

    /// Shortest face side in pixels of the image it was detected in.
    static func pixelSide(_ face: DetectedFace, width: Int, height: Int) -> CGFloat {
        min(face.box.width * CGFloat(width), face.box.height * CGFloat(height))
    }

    /// Faces at least this big in a local preview embed well without downloading.
    static let previewEmbedSide: CGFloat = 100
}
