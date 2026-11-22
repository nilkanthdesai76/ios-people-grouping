import CoreGraphics
import Vision

nonisolated enum FaceDetector {
    /// Detect faces with landmarks; quality is matched from the capture-quality
    /// request by IoU (landmark observations usually lack faceCaptureQuality).
    static func detect(in image: CGImage) throws -> [DetectedFace] {
        let landmarksRequest = VNDetectFaceLandmarksRequest()
        let qualityRequest = VNDetectFaceCaptureQualityRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([landmarksRequest, qualityRequest])

        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let qualityObservations = qualityRequest.results ?? []
        return (landmarksRequest.results ?? []).map { observation in
            let box = topLeftBox(observation.boundingBox)
            let quality = bestQuality(for: observation.boundingBox, among: qualityObservations)
            let minSide = min(box.width * width, box.height * height)
            let scale = max(width, height) / FaceGate.scanSize
            let passesGate = minSide >= FaceGate.minimumFaceSide * scale && quality >= FaceGate.minimumQuality
            return DetectedFace(
                box: box,
                quality: quality,
                leftEye: eyePoint(observation.landmarks?.leftEye, faceBox: observation.boundingBox),
                rightEye: eyePoint(observation.landmarks?.rightEye, faceBox: observation.boundingBox),
                landmarks: alignmentPoints(observation.landmarks, faceBox: observation.boundingBox),
                passesGate: passesGate
            )
        }
    }

    /// Vision boxes have a bottom-left origin; move to top-left.
    private static func topLeftBox(_ box: CGRect) -> CGRect {
        CGRect(x: box.minX, y: 1 - (box.minY + box.height), width: box.width, height: box.height)
    }

    private static func bestQuality(for box: CGRect, among observations: [VNFaceObservation]) -> Float {
        var best: Float = 0.5
        var bestIoU: CGFloat = 0
        for observation in observations {
            guard let quality = observation.faceCaptureQuality else { continue }
            let iou = intersectionOverUnion(box, observation.boundingBox)
            if iou > bestIoU {
                bestIoU = iou
                best = Float(quality)
            }
        }
        return best
    }

    /// Pupils (or eye centres) and mouth corners, in image order (smaller x first).
    private static func alignmentPoints(_ landmarks: VNFaceLandmarks2D?, faceBox: CGRect) -> [CGPoint]? {
        guard let landmarks,
              let first = eyePoint(landmarks.leftPupil ?? landmarks.leftEye, faceBox: faceBox),
              let second = eyePoint(landmarks.rightPupil ?? landmarks.rightEye, faceBox: faceBox)
        else { return nil }
        let eyes = first.x <= second.x ? [first, second] : [second, first]
        guard let lips = landmarks.outerLips, lips.pointCount > 2 else { return eyes }
        var corners: [CGPoint] = []
        for index in 0..<lips.pointCount {
            let point = lips.normalizedPoints[index]
            corners.append(CGPoint(
                x: faceBox.minX + point.x * faceBox.width,
                y: 1 - (faceBox.minY + point.y * faceBox.height)
            ))
        }
        guard let left = corners.min(by: { $0.x < $1.x }),
              let right = corners.max(by: { $0.x < $1.x }) else { return eyes }
        return eyes + [left, right]
    }

    private static func eyePoint(_ region: VNFaceLandmarkRegion2D?, faceBox: CGRect) -> CGPoint? {
        guard let region, region.pointCount > 0 else { return nil }
        var sum = CGPoint.zero
        for index in 0..<region.pointCount {
            let point = region.normalizedPoints[index]
            sum.x += faceBox.minX + point.x * faceBox.width
            sum.y += 1 - (faceBox.minY + point.y * faceBox.height)
        }
        let count = CGFloat(region.pointCount)
        return CGPoint(x: sum.x / count, y: sum.y / count)
    }

    private static func intersectionOverUnion(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        guard !intersection.isNull else { return 0 }
        let area = intersection.width * intersection.height
        let union = a.width * a.height + b.width * b.height - area
        guard union > 0 else { return 0 }
        return area / union
    }
}
