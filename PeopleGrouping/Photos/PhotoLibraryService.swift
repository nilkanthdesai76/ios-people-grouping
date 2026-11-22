import os
import Photos
import UIKit

/// Result of a scan-size image request.
nonisolated enum ScanImageResult: Sendable {
    case image(CGImage)
    case inCloud
    case failed
}

/// Where the Photos app's item count goes, so the scan total can be explained.
nonisolated struct LibraryBreakdown: Sendable {
    var allItems: Int
    var videos: Int
    var photos: Int
    var screenshots: Int
    var hiddenPhotos: Int
    var extraBurstFrames: Int
    var sharedAlbumPhotos: Int
    var scanned: Int
}

/// Stateless PhotoKit reader. Only ever reads the library; never writes.
nonisolated final class PhotoLibraryService: Sendable {
    private static let noScreenshots = "(mediaSubtypes & %d) == 0"
    private static let scanSize = CGSize(width: 1024, height: 1024)

    /// Fast identifier-only fetch, newest first, user library only.
    func fetchImageAssetIDs() -> [String] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.includeAssetSourceTypes = [.typeUserLibrary]
        options.predicate = NSPredicate(
            format: Self.noScreenshots,
            PHAssetMediaSubtype.photoScreenshot.rawValue
        )
        let result = PHAsset.fetchAssets(with: .image, options: options)
        var ids: [String] = []
        ids.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            ids.append(asset.localIdentifier)
        }
        return ids
    }

    /// Counts only (no image loading). Run off the main thread on large libraries.
    func libraryBreakdown() -> LibraryBreakdown {
        func count(_ type: PHAssetMediaType?, _ configure: (PHFetchOptions) -> Void = { _ in }) -> Int {
            let options = PHFetchOptions()
            options.includeAssetSourceTypes = [.typeUserLibrary]
            configure(options)
            if let type { return PHAsset.fetchAssets(with: type, options: options).count }
            return PHAsset.fetchAssets(with: options).count
        }
        let photos = count(.image)
        let screenshot = PHAssetMediaSubtype.photoScreenshot.rawValue
        return LibraryBreakdown(
            allItems: count(nil),
            videos: count(.video),
            photos: photos,
            screenshots: count(.image) {
                $0.predicate = NSPredicate(format: "(mediaSubtypes & %d) != 0", screenshot)
            },
            hiddenPhotos: count(.image) { $0.includeHiddenAssets = true } - photos,
            extraBurstFrames: count(.image) { $0.includeAllBurstAssets = true } - photos,
            sharedAlbumPhotos: count(.image) { $0.includeAssetSourceTypes = [.typeCloudShared] },
            scanned: fetchImageAssetIDs().count
        )
    }

    func assetDate(id: String) -> Date? {
        PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject?.creationDate
    }

    /// Upright CGImage for scanning (max 1024 px, never originals).
    func loadScanImage(
        id: String,
        allowNetwork: Bool,
        timeout: Duration = .seconds(90)
    ) async -> ScanImageResult {
        switch await requestUIImage(
            id: id,
            targetSize: Self.scanSize,
            networkAllowed: allowNetwork,
            timeout: timeout
        ) {
        case .image(let uiImage):
            guard let cgImage = uprightCGImage(uiImage) else { return .failed }
            return .image(cgImage)
        case .inCloud:
            return .inCloud
        case .failed:
            return .failed
        }
    }

    /// Best image Photos already holds ON THIS DEVICE (never downloads). For iCloud-only
    /// photos this is the small local derivative; it is used to skip or avoid downloads.
    func loadLocalPreview(id: String, timeout: Duration = .seconds(5)) async -> CGImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
        else { return nil }
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isSynchronous = false
        let best = await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
            let state = OSAllocatedUnfairLock<(done: Bool, image: UIImage?)>(initialState: (false, nil))
            let timeoutBox = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
            let finish: @Sendable () -> Void = {
                let result: UIImage?? = state.withLock { value in
                    if value.done { return .none }
                    value.done = true
                    return .some(value.image)
                }
                guard let image = result else { return }
                timeoutBox.withLock { $0?.cancel() }
                continuation.resume(returning: image)
            }
            let requestID = PHImageManager.default().requestImage(
                for: asset,
                targetSize: Self.scanSize,
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                if let image {
                    state.withLock { value in
                        let current = value.image.map { $0.size.width * $0.size.height } ?? 0
                        if image.size.width * image.size.height > current { value.image = image }
                    }
                }
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
                let stopped = (info?[PHImageCancelledKey] as? Bool) == true || info?[PHImageErrorKey] != nil
                // Opportunistic delivers a degraded image first; the final callback (or an
                // in-cloud / error callback) ends the request.
                if !degraded || stopped || image == nil { finish() }
            }
            let timeoutTask = Task { @Sendable in
                try? await Task.sleep(until: .now + timeout, clock: .continuous)
                PHImageManager.default().cancelImageRequest(requestID)
                finish()
            }
            timeoutBox.withLock { $0 = timeoutTask }
        }
        return best.flatMap { uprightCGImage($0) }
    }

    /// UIImage for grids and the viewer. Nil when unavailable.
    func loadDisplayImage(id: String, targetSize: CGSize) async -> UIImage? {
        switch await requestUIImage(
            id: id,
            targetSize: targetSize,
            networkAllowed: true,
            timeout: .seconds(60)
        ) {
        case .image(let uiImage):
            return uiImage
        case .inCloud, .failed:
            return nil
        }
    }

    // MARK: - Private

    private enum RequestOutcome: Sendable {
        case image(UIImage)
        case inCloud
        case failed
    }

    /// Exactly-once, error-aware PhotoKit request: resumes on the first of a
    /// non-degraded image, error, cancel, in-cloud-without-network, or timeout.
    private func requestUIImage(
        id: String,
        targetSize: CGSize,
        networkAllowed: Bool,
        timeout: Duration
    ) async -> RequestOutcome {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
        else { return .failed }
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = networkAllowed
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isSynchronous = false
        return await withCheckedContinuation { continuation in
            let lock = OSAllocatedUnfairLock<Bool>(initialState: false)
            let timeoutBox = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
            let finish: @Sendable (RequestOutcome) -> Void = { outcome in
                let shouldResume = lock.withLock { done in
                    if done { return false }
                    done = true
                    return true
                }
                guard shouldResume else { return }
                timeoutBox.withLock { $0?.cancel() }
                continuation.resume(returning: outcome)
            }

            let requestID = PHImageManager.default().requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
                if degraded { return }
                if let image { finish(.image(image)); return }
                let inCloud = (info?[PHImageResultIsInCloudKey] as? Bool) == true
                if inCloud && !networkAllowed { finish(.inCloud); return }
                finish(.failed)
            }

            let timeoutTask = Task { @Sendable in
                try? await Task.sleep(until: .now + timeout, clock: .continuous)
                PHImageManager.default().cancelImageRequest(requestID)
            }
            timeoutBox.withLock { $0 = timeoutTask }
        }
    }

    /// PhotoKit may return a UIImage whose cgImage carries a non-upright orientation;
    /// redraw so the CGImage itself is upright for Vision.
    private func uprightCGImage(_ image: UIImage) -> CGImage? {
        if image.imageOrientation == .up {
            if let cgImage = image.cgImage { return cgImage }
            // iCloud placeholders can arrive CIImage-backed with no cgImage: render them.
            if let ciImage = image.ciImage {
                return FaceCropper.context.createCGImage(ciImage, from: ciImage.extent)
            }
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }.cgImage
    }
}
