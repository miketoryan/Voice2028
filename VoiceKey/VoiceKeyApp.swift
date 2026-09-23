import SwiftUI

@main
struct Voice2028App: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .onOpenURL { url in
                    Task { await model.handleIncomingURL(url) }
                }
        }
    }
}
