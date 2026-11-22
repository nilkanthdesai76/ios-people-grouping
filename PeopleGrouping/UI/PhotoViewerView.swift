import SwiftUI

struct PhotoViewerView: View {
    let assetID: String
    @Environment(AppModel.self) private var appModel
    @State private var image: UIImage?
    @State private var faces: [FaceInfo] = []
    @State private var loadFailed = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .overlay(alignment: .topLeading) {
                            FaceBoxesOverlay(faces: faces, imageSize: image.size, container: proxy.size)
                        }
                        .accessibilityLabel("Photo")
                } else if loadFailed {
                    Image(systemName: "icloud.slash")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Photo could not be loaded from iCloud")
                } else {
                    ProgressView()
                }
            }
        }
        .ignoresSafeArea()
        .navigationBarTitleDisplayMode(.inline)
        .task {
            async let loaded: UIImage? = PhotoLibraryService().loadDisplayImage(
                id: assetID,
                targetSize: CGSize(width: 2048, height: 2048)
            )
            async let stored: [FaceInfo] = appModel.store.faces(inAsset: assetID)
            let resolved = await loaded
            if let resolved {
                image = resolved
            } else {
                loadFailed = true
            }
            faces = await stored
        }
    }
}

/// Face rectangles and name labels, positioned over the aspect-fitted image.
private struct FaceBoxesOverlay: View {
    let faces: [FaceInfo]
    let imageSize: CGSize
    let container: CGSize

    var body: some View {
        let fitted = fittedRect
        ZStack(alignment: .topLeading) {
            ForEach(faces) { face in
                let rect = CGRect(
                    x: fitted.minX + face.box.minX * fitted.width,
                    y: fitted.minY + face.box.minY * fitted.height,
                    width: face.box.width * fitted.width,
                    height: face.box.height * fitted.height
                )
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.yellow, lineWidth: 2)
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    .overlay(alignment: .top) {
                        if let name = face.personName {
                            Text(name)
                                .font(.caption2.bold())
                                .padding(.horizontal, 4)
                                .background(.black.opacity(0.6), in: Capsule())
                                .foregroundStyle(.white)
                                .offset(y: -18)
                        }
                    }
            }
        }
        .frame(width: container.width, height: container.height)
        .accessibilityHidden(true)
    }

    private var fittedRect: CGRect {
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }
}
