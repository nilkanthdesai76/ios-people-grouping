import CoreGraphics
import CoreImage
import Foundation

nonisolated enum FaceCropper {
    static let context = CIContext()

    /// ArcFace / InsightFace 112 x 112 template, top-left origin: left eye, right eye, mouth left, mouth right.
    private static let template: [CGPoint] = [
        CGPoint(x: 38.2946, y: 51.6963),
        CGPoint(x: 73.5318, y: 51.5014),
        CGPoint(x: 41.5493, y: 92.3655),
        CGPoint(x: 70.7299, y: 92.2041),
    ]

    /// `aligned` warps the face onto the recognition template (needed for good embeddings).
    /// Without it, or when landmarks are missing, a looser upright crop is produced (also used for thumbnails).
    static func crop(face: DetectedFace, from image: CGImage, size: CGFloat = 112, aligned: Bool = true) -> CGImage? {
        if aligned, let points = face.landmarks,
           let warped = alignedCrop(points: points, from: image, size: size) {
            return warped
        }
        return looseCrop(face: face, from: image, size: size)
    }

    // MARK: - Aligned

    /// Least-squares similarity transform (scale, rotation, translation) from detected points to the template.
    private static func alignedCrop(points: [CGPoint], from image: CGImage, size: CGFloat) -> CGImage? {
        let count = min(points.count, template.count)
        guard count >= 2 else { return nil }
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let factor = size / 112
        let source = points.prefix(count).map { CGPoint(x: $0.x * width, y: $0.y * height) }
        let target = template.prefix(count).map { CGPoint(x: $0.x * factor, y: $0.y * factor) }

        let sourceMean = mean(source)
        let targetMean = mean(target)
        var dotSum: CGFloat = 0
        var crossSum: CGFloat = 0
        var normSum: CGFloat = 0
        for index in 0..<count {
            let s = CGPoint(x: source[index].x - sourceMean.x, y: source[index].y - sourceMean.y)
            let t = CGPoint(x: target[index].x - targetMean.x, y: target[index].y - targetMean.y)
            dotSum += s.x * t.x + s.y * t.y
            crossSum += s.x * t.y - s.y * t.x
            normSum += s.x * s.x + s.y * s.y
        }
        guard normSum > 1e-6 else { return nil }
        let a = dotSum / normSum
        let b = crossSum / normSum
        let tx = targetMean.x - (a * sourceMean.x - b * sourceMean.y)
        let ty = targetMean.y - (b * sourceMean.x + a * sourceMean.y)
        return render(image, a: a, b: b, tx: tx, ty: ty, size: size)
    }

    /// Draws `image` through the similarity [a -b; b a] + t, all in TOP-LEFT pixel coordinates,
    /// into a black `size` x `size` canvas.
    private static func render(_ image: CGImage, a: CGFloat, b: CGFloat, tx: CGFloat, ty: CGFloat, size: CGFloat) -> CGImage? {
        let side = Int(size)
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        guard side > 0, let ctx = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        ctx.interpolationQuality = .high
        // Work in a top-left origin: flip, apply the similarity, then flip the image upright.
        ctx.translateBy(x: 0, y: CGFloat(side))
        ctx.scaleBy(x: 1, y: -1)
        ctx.concatenate(CGAffineTransform(a: a, b: b, c: -b, d: a, tx: tx, ty: ty))
        ctx.translateBy(x: 0, y: height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    private static func mean(_ points: [CGPoint]) -> CGPoint {
        let count = CGFloat(points.count)
        return CGPoint(
            x: points.reduce(0) { $0 + $1.x } / count,
            y: points.reduce(0) { $0 + $1.y } / count
        )
    }

    // MARK: - Loose

    /// Square crop centred on the face (1.35 x the box), rotated so the eye line is level,
    /// black where it runs past the image. All maths in top-left pixel coordinates, the
    /// same space as `DetectedFace.box`, so the crop is exactly where the face is.
    private static func looseCrop(face: DetectedFace, from image: CGImage, size: CGFloat) -> CGImage? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let box = CGRect(
            x: face.box.minX * width, y: face.box.minY * height,
            width: face.box.width * width, height: face.box.height * height
        )
        let cropSide = max(box.width, box.height) * 1.35
        guard cropSide > 0 else { return nil }
        var angle: CGFloat = 0
        if let left = face.leftEye, let right = face.rightEye {
            angle = atan2((right.y - left.y) * height, (right.x - left.x) * width)
        }
        // Map the face centre to the canvas centre, rotated by -angle and scaled to `size`.
        let scale = size / cropSide
        let a = scale * cos(angle)
        let b = -scale * sin(angle)
        let centre = CGPoint(x: box.midX, y: box.midY)
        let tx = size / 2 - (a * centre.x - b * centre.y)
        let ty = size / 2 - (b * centre.x + a * centre.y)
        return render(image, a: a, b: b, tx: tx, ty: ty, size: size)
    }
}
