import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        Group {
            if appModel.auth.isAuthorized {
                VStack(spacing: 0) {
                    if appModel.auth.isLimited {
                        Text("Limited access: only selected photos are scanned.")
                            .font(.footnote)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(.thinMaterial)
                    }
                    TabView {
                        PeopleGridView()
                            .tabItem { Label("People", systemImage: "person.2") }
                        ScanView()
                            .tabItem { Label("Scan", systemImage: "faceid") }
                        SettingsView()
                            .tabItem { Label("Settings", systemImage: "gear") }
                    }
                }
            } else {
                PermissionView(auth: appModel.auth)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            appModel.auth.refresh()
        }
        .task {
            appModel.prewarmModel()
            appModel.autoResumeIfNeeded()
        }
    }
}
