import Photos
import SwiftUI

/// Tracks photo library authorization. MainActor is fine: this is UI-facing state.
@Observable
final class PhotoAuthorization {
    private(set) var status: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)

    var isAuthorized: Bool {
        status == .authorized || status == .limited
    }

    var isLimited: Bool { status == .limited }

    func refresh() {
        status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    func request() async {
        status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }
}
