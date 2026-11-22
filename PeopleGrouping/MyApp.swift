import SwiftData
import SwiftUI

@main
struct MyApp: App {
    @State private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appModel)
        }
        .modelContainer(appModel.container)
    }
}
