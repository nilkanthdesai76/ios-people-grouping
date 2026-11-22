import Foundation

/// On-disk JPEG cache for face thumbnails (Caches/FaceThumbs).
actor ThumbnailCache {
    private let directory: URL

    init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("FaceThumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Thumbnails made before the crop fix (no version suffix) show the wrong area: drop them.
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in files where !name.hasSuffix(Self.suffix) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    private static let suffix = "-v2.jpg"

    func save(faceID: UUID, jpeg: Data) {
        let url = fileURL(for: faceID)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? jpeg.write(to: url, options: .atomic)
        }
    }

    func url(forFaceID faceID: UUID) -> URL? {
        let url = fileURL(for: faceID)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func fileURL(for faceID: UUID) -> URL {
        directory.appendingPathComponent(faceID.uuidString + Self.suffix)
    }
}
