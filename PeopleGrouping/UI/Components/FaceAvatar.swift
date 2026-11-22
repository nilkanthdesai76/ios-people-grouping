import SwiftUI

struct FaceAvatar: View {
    var faceID: UUID
    var size: CGFloat = 72
    @Environment(AppModel.self) private var appModel
    @State private var image: UIImage?

    var body: some View {
        Circle()
            .fill(.secondary.opacity(0.15))
            .frame(width: size, height: size)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipShape(Circle())
            .task(id: faceID) {
                image = nil
                image = await appModel.faceThumbnail(faceID: faceID)
            }
            .accessibilityHidden(true)
    }
}
