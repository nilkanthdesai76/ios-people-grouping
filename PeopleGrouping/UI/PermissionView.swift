import Photos
import SwiftUI
import UIKit

struct PermissionView: View {
    let auth: PhotoAuthorization

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "person.2.crop.square.stack")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Find people in your photos")
                .font(.title2.bold())
            Text("PeopleGrouping reads your photos on this device to group them by person. Nothing leaves your phone.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            actionButton
        }
        .padding(32)
    }

    @ViewBuilder
    private var actionButton: some View {
        switch auth.status {
        case .notDetermined:
            Button("Allow Photos Access") {
                Task { await auth.request() }
            }
            .buttonStyle(.borderedProminent)
        case .denied, .restricted:
            VStack(spacing: 12) {
                Text("Photo access is turned off. You can enable it in Settings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        default:
            EmptyView()
        }
    }
}
